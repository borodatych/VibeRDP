//! The log of the helper: it has no window, so this file is the only way to see what it did
//!
//! %LOCALAPPDATA%\VibeRDP\seam-helper.log, started afresh at every launch so it never grows past one session

use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use windows_sys::Win32::Foundation::SYSTEMTIME;
use windows_sys::Win32::System::SystemInformation::GetLocalTime;

const FOLDER: &str = "VibeRDP";
const FILE_NAME: &str = "seam-helper.log";

static FILE: Mutex<Option<File>> = Mutex::new(None);

/// Opens the log; without a writable folder the helper runs on and logs nowhere
pub fn open() {
    let Some(base) = std::env::var_os("LOCALAPPDATA") else {
        return;
    };
    let folder = PathBuf::from(base).join(FOLDER);
    let file = fs::create_dir_all(&folder).and_then(|_| File::create(folder.join(FILE_NAME)));
    if let (Ok(file), Ok(mut slot)) = (file, FILE.lock()) {
        *slot = Some(file);
    }
}

/// Writes a line with the local time in front
pub fn line(text: &str) {
    let Ok(mut slot) = FILE.lock() else {
        return;
    };
    let Some(file) = slot.as_mut() else {
        return;
    };
    // SAFETY: SYSTEMTIME is plain data filled in by the call
    let now = unsafe {
        let mut now: SYSTEMTIME = std::mem::zeroed();
        GetLocalTime(&mut now);
        now
    };
    // A failed write cannot be reported anywhere else: the line is lost, the helper goes on
    let _ = writeln!(
        file,
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03} {text}",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
    );
}
