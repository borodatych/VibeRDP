//! The Start menu of this user on Windows: its two folders, the icons of its shortcuts, and starting them
//!
//! The list and the icons take a while on a large menu, so they go out from a thread of their own

use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::null;

use vibe_seam_helper::launcher::{self, Root};
use vibe_seam_helper::session::{self, Failure};
use windows_sys::Win32::UI::Shell::{
    SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGetFileInfoW, ShellExecuteW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{DestroyIcon, SW_SHOWNORMAL};

use crate::icons;
use crate::link::Link;
use crate::log;

/// Where the menus live under their environment folders
const PROGRAMS: &str = "Microsoft\\Windows\\Start Menu\\Programs";
/// ShellExecute reports success with a value above this one
const SHELL_EXECUTE_OK: isize = 32;

/// The user's menu and the common one, those whose variables are set
pub fn roots() -> Vec<Root> {
    [("user", "APPDATA"), ("common", "PROGRAMDATA")]
        .into_iter()
        .filter_map(|(name, variable)| {
            std::env::var_os(variable).map(|base| Root {
                name,
                path: PathBuf::from(base).join(PROGRAMS),
            })
        })
        .collect()
}

/// Sends the list, then the icons, to the channel of that generation, from a thread of its own
pub fn send_list(link: Link, generation: u64, seq: u64) {
    std::thread::spawn(move || {
        let roots = roots();
        let apps = launcher::scan(&roots);
        if !link.send(generation, &[launcher::apps_message(seq, &apps)]) {
            return;
        }
        log::line(&format!("start menu sent: {} programs", apps.len()));
        for app in &apps {
            let Some(path) = launcher::resolve(&roots, &app.id) else {
                continue;
            };
            if let Some(png) = icon(&path)
                && !link.send(generation, &[launcher::icon_message(&app.id, png)])
            {
                return;
            }
        }
    });
}

/// Starts a program of the menu and answers the request
pub fn launch(link: &Link, generation: u64, seq: u64, id: &str) -> bool {
    let result = match launcher::resolve(&roots(), id) {
        None => Err(Failure {
            code: "no-app",
            message: format!("{id} is not a shortcut of the Start menu"),
        }),
        Some(path) => start(&path),
    };
    if let Err(failure) = &result {
        log::line(&format!(
            "launch {seq} of {id}: {} {}",
            failure.code, failure.message
        ));
    }
    link.send(generation, &[session::reply(seq, result)])
}

fn start(path: &Path) -> Result<(), Failure> {
    let file = wide(path);
    let verb: Vec<u16> = "open".encode_utf16().chain([0]).collect();
    // SAFETY: both strings are NUL-terminated and outlive the call; no window owns the start
    let instance = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            null(),
            null(),
            SW_SHOWNORMAL,
        )
    };
    if instance as isize > SHELL_EXECUTE_OK {
        Ok(())
    } else {
        Err(Failure {
            code: "failed",
            message: format!("ShellExecute returned {}", instance as isize),
        })
    }
}

/// The large icon the shell shows for the shortcut, as PNG
fn icon(path: &Path) -> Option<Vec<u8>> {
    let file = wide(path);
    // SAFETY: SHFILEINFOW is plain data filled by the call; the icon it hands out is destroyed below
    unsafe {
        let mut info: SHFILEINFOW = std::mem::zeroed();
        let found = SHGetFileInfoW(
            file.as_ptr(),
            0,
            &mut info,
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON,
        );
        if found == 0 || info.hIcon.is_null() {
            return None;
        }
        let png = icons::png_of(info.hIcon);
        DestroyIcon(info.hIcon);
        png
    }
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}
