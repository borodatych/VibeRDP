//! The VibeSeam dynamic virtual channel of this session, read and written through its file handle
//!
//! A dynamic channel is served by the file handle WTSVirtualChannelQuery hands out, opened for overlapped I/O:
//! each read returns one CHANNEL_PDU_HEADER and a chunk of the stream, and the header is dropped here
//!
//! Reads and writes go on at once from different threads, each with its own OVERLAPPED and event

use std::io;
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::Arc;

use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_IO_PENDING, GetLastError, HANDLE,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::RemoteDesktop::{
    CHANNEL_CHUNK_LENGTH, CHANNEL_PDU_HEADER, WTS_CHANNEL_OPTION_DYNAMIC, WTS_CURRENT_SESSION,
    WTSFreeMemory, WTSVirtualChannelClose, WTSVirtualChannelOpenEx, WTSVirtualChannelQuery,
    WTSVirtualFileHandle,
};
use windows_sys::Win32::System::Threading::{CreateEventW, GetCurrentProcess};

/// The channel name, NUL-terminated for the ANSI call: protocol/seam-protocol.md, section 1
const NAME: &[u8] = b"VibeSeam\0";
/// One read takes a header and a whole chunk, the most the server puts in one
const READ_SIZE: usize = size_of::<CHANNEL_PDU_HEADER>() + CHANNEL_CHUNK_LENGTH as usize;

/// The channel and its file handle, closed when the reader and the writer are both gone
struct Handles {
    wts: HANDLE,
    file: HANDLE,
}

// SAFETY: kernel handles are usable from any thread; reads and writes each bring their own OVERLAPPED
unsafe impl Send for Handles {}
unsafe impl Sync for Handles {}

impl Drop for Handles {
    fn drop(&mut self) {
        // SAFETY: both handles are owned here and closed once
        unsafe {
            CloseHandle(self.file);
            WTSVirtualChannelClose(self.wts);
        }
    }
}

/// Manual-reset event of one side's overlapped calls: each side has one call in flight at a time
struct Event(HANDLE);

// SAFETY: an event handle is usable from any thread
unsafe impl Send for Event {}

impl Event {
    fn new() -> io::Result<Event> {
        // SAFETY: plain event creation, no name and no security attributes
        let event = unsafe { CreateEventW(null(), 1, 0, null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(Event(event))
    }
}

impl Drop for Event {
    fn drop(&mut self) {
        // SAFETY: the event is owned here and closed once
        unsafe { CloseHandle(self.0) };
    }
}

/// The reading side: the thread that answers the client owns it
pub struct Reader {
    handles: Arc<Handles>,
    event: Event,
    buffer: Vec<u8>,
}

/// The writing side: any thread may hold it, one write at a time
pub struct Writer {
    handles: Arc<Handles>,
    event: Event,
}

/// Opens the channel of the current session; fails while the client has no listener for it
pub fn open() -> io::Result<(Reader, Writer)> {
    // SAFETY: NAME is NUL-terminated; the handle is checked before use
    let wts = unsafe {
        WTSVirtualChannelOpenEx(
            WTS_CURRENT_SESSION,
            NAME.as_ptr(),
            WTS_CHANNEL_OPTION_DYNAMIC,
        )
    };
    if wts.is_null() {
        return Err(io::Error::last_os_error());
    }
    let file = match file_handle(wts) {
        Ok(file) => file,
        Err(error) => {
            // SAFETY: the channel was opened above and is closed once
            unsafe { WTSVirtualChannelClose(wts) };
            return Err(error);
        }
    };
    let handles = Arc::new(Handles { wts, file });
    let reader = Reader {
        handles: Arc::clone(&handles),
        event: Event::new()?,
        buffer: vec![0; READ_SIZE],
    };
    let writer = Writer {
        handles,
        event: Event::new()?,
    };
    Ok((reader, writer))
}

impl Reader {
    /// Waits for the next chunk of the stream; an error means the channel is gone
    pub fn read(&mut self) -> io::Result<&[u8]> {
        let mut overlapped = overlapped(&self.event);
        // SAFETY: buffer and overlapped outlive the call, which completes before they are touched again
        let started = unsafe {
            ReadFile(
                self.handles.file,
                self.buffer.as_mut_ptr(),
                self.buffer.len() as u32,
                null_mut(),
                &mut overlapped,
            )
        };
        let read = finish(self.handles.file, started, &overlapped)?;
        let header = size_of::<CHANNEL_PDU_HEADER>();
        if read < header {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("chunk of {read} bytes has no channel header"),
            ));
        }
        Ok(&self.buffer[header..read])
    }
}

impl Writer {
    /// Writes bytes of the stream: the channel splits them into chunks itself
    pub fn write(&mut self, bytes: &[u8]) -> io::Result<()> {
        let mut overlapped = overlapped(&self.event);
        // SAFETY: bytes and overlapped outlive the call, which completes before returning
        let started = unsafe {
            WriteFile(
                self.handles.file,
                bytes.as_ptr(),
                bytes.len() as u32,
                null_mut(),
                &mut overlapped,
            )
        };
        let written = finish(self.handles.file, started, &overlapped)?;
        if written != bytes.len() {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                format!("{written} of {} bytes written", bytes.len()),
            ));
        }
        Ok(())
    }
}

fn overlapped(event: &Event) -> OVERLAPPED {
    // SAFETY: OVERLAPPED is plain data, zero is its initial state
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = event.0;
    overlapped
}

/// Waits for an overlapped call to complete and returns the bytes it moved
fn finish(file: HANDLE, started: i32, overlapped: &OVERLAPPED) -> io::Result<usize> {
    // SAFETY: GetLastError right after the call it reports on
    if started == 0 && unsafe { GetLastError() } != ERROR_IO_PENDING {
        return Err(io::Error::last_os_error());
    }
    let mut moved = 0u32;
    // SAFETY: the overlapped belongs to the call on this handle; waiting keeps it alive until completion
    if unsafe { GetOverlappedResult(file, overlapped, &mut moved, 1) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(moved as usize)
}

/// The file handle of the channel, duplicated: the one the query returns lives in memory freed right after
fn file_handle(wts: HANDLE) -> io::Result<HANDLE> {
    let mut data = null_mut();
    let mut size = 0u32;
    // SAFETY: the out-pointers are valid; the buffer is freed below on every path
    if unsafe { WTSVirtualChannelQuery(wts, WTSVirtualFileHandle, &mut data, &mut size) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut file = null_mut();
    // The error is taken before the buffer is freed: freeing may overwrite the last error
    let result = if (size as usize) < size_of::<HANDLE>() {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file handle query returned {size} bytes"),
        ))
    // SAFETY: the buffer holds one HANDLE, as the query class promises and the size confirms
    } else if unsafe {
        DuplicateHandle(
            GetCurrentProcess(),
            *(data as *const HANDLE),
            GetCurrentProcess(),
            &mut file,
            0,
            0,
            DUPLICATE_SAME_ACCESS,
        )
    } == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(file)
    };
    // SAFETY: the buffer came from the query above and is freed once
    unsafe { WTSFreeMemory(data) };
    result
}
