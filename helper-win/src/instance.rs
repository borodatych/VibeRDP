//! One helper per session, and a way for the installer to stop it
//!
//! Both names live in the Local namespace, which is the session's own: another user's helper is not touched

use std::ptr::null;
use std::thread::sleep;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE};
use windows_sys::Win32::System::Threading::{
    CreateEventW, CreateMutexW, INFINITE, ResetEvent, SetEvent, WaitForSingleObject,
};

use crate::log;

const MUTEX: &str = "Local\\VibeSeamHelper";
/// Auto-reset: one signal stops one helper
const QUIT_EVENT: &str = "Local\\VibeSeamHelperQuit";
/// How long a running helper gets to exit before the installer gives up
const STOP_TIMEOUT: Duration = Duration::from_secs(5);
const STOP_POLL: Duration = Duration::from_millis(50);

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

/// A named object of the session and whether it existed before this call
fn mutex() -> Option<(HANDLE, bool)> {
    let name = wide(MUTEX);
    // SAFETY: the name is NUL-terminated
    let handle = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };
    // SAFETY: GetLastError right after the call it reports on
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    (!handle.is_null()).then_some((handle, existed))
}

fn quit_event() -> Option<HANDLE> {
    let name = wide(QUIT_EVENT);
    // SAFETY: the name is NUL-terminated
    let handle = unsafe { CreateEventW(null(), 0, 0, name.as_ptr()) };
    (!handle.is_null()).then_some(handle)
}

/// Takes the session's mutex for the life of the process; false when another helper holds it
pub fn claim() -> bool {
    match mutex() {
        // The handle stays open on purpose: the mutex lives as long as this helper
        Some((_, existed)) => !existed,
        None => false,
    }
}

/// Ends the process when the installer asks: it replaces or removes this helper
pub fn exit_on_request() {
    let Some(event) = quit_event() else {
        log::line("quit event not created: the installer cannot stop this helper");
        return;
    };
    // A raw handle is not Send; the number is, and names the same kernel object
    let event = event as usize;
    std::thread::spawn(move || {
        // SAFETY: the handle stays open for the life of the process
        unsafe { WaitForSingleObject(event as HANDLE, INFINITE) };
        log::line("stopped by the installer");
        std::process::exit(0);
    });
}

/// Stops the helper running in this session, if any; false when it did not exit in time
pub fn stop_running() -> bool {
    let Some(event) = quit_event() else {
        return false;
    };
    // SAFETY: the event is ours to signal, reset and close
    unsafe { SetEvent(event) };
    let deadline = Instant::now() + STOP_TIMEOUT;
    let stopped = loop {
        match mutex() {
            Some((handle, existed)) => {
                // SAFETY: the handle was just opened for this check
                unsafe { CloseHandle(handle) };
                if !existed {
                    break true;
                }
            }
            None => break false,
        }
        if Instant::now() >= deadline {
            break false;
        }
        sleep(STOP_POLL);
    };
    // With no helper to take it, the signal would stop the next one at its start
    // SAFETY: as above
    unsafe {
        ResetEvent(event);
        CloseHandle(event);
    }
    stopped
}
