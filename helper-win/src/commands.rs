//! Carries out the commands of the client on the windows of the host: protocol/seam-protocol.md, section 7
//!
//! The tracker sees the results through its events, so a command only acts and reports whether it could

use std::io;

use vibe_seam_helper::desktop::outer_rect;
use vibe_seam_helper::session::{Action, Command, Failure};
use windows_sys::Win32::Foundation::{HWND, RECT};
use windows_sys::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, GetForegroundWindow, GetWindowRect, GetWindowThreadProcessId, IsIconic,
    IsWindow, PostMessageW, SC_CLOSE, SC_MAXIMIZE, SC_MINIMIZE, SC_RESTORE, SW_RESTORE,
    SWP_NOACTIVATE, SWP_NOZORDER, SetForegroundWindow, SetWindowPos, ShowWindow, WM_SYSCOMMAND,
};

use crate::tracker;

pub fn execute(command: Command) -> Result<(), Failure> {
    let hwnd = command.id as usize as HWND;
    // SAFETY: IsWindow takes any value and says whether it is a window
    if unsafe { IsWindow(hwnd) } == 0 {
        return Err(failure(
            "no-window",
            format!("{} is not a window", command.id),
        ));
    }
    match command.action {
        Action::Activate => activate(hwnd),
        Action::Move(target) => move_to(hwnd, target),
        Action::Minimize => system_command(hwnd, SC_MINIMIZE),
        Action::Maximize => system_command(hwnd, SC_MAXIMIZE),
        Action::Restore => system_command(hwnd, SC_RESTORE),
        Action::Close => system_command(hwnd, SC_CLOSE),
    }
}

/// Brings the window to the front
///
/// Windows lets only the process of the last input take the foreground, and the helper never gets input:
/// joining the input of the current foreground thread for the call is the way it lends that right
fn activate(hwnd: HWND) -> Result<(), Failure> {
    // SAFETY: plain calls on a window handle and thread ids; the input is detached on every path
    unsafe {
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        let own = GetCurrentThreadId();
        let foreground = GetWindowThreadProcessId(GetForegroundWindow(), std::ptr::null_mut());
        let attached =
            foreground != 0 && foreground != own && AttachThreadInput(own, foreground, 1) != 0;
        BringWindowToTop(hwnd);
        let done = SetForegroundWindow(hwnd) != 0;
        if attached {
            AttachThreadInput(own, foreground, 0);
        }
        if done {
            Ok(())
        } else {
            Err(failure(
                "denied",
                "Windows kept the foreground where it was".to_string(),
            ))
        }
    }
}

fn move_to(hwnd: HWND, target: [i32; 4]) -> Result<(), Failure> {
    let visible = tracker::bounds(hwnd).ok_or_else(|| os_failure("bounds not read"))?;
    let window = window_rect(hwnd).ok_or_else(|| os_failure("window rectangle not read"))?;
    let [x, y, width, height] = outer_rect(target, window, visible);
    // SAFETY: plain call on a window handle
    let moved = unsafe {
        SetWindowPos(
            hwnd,
            std::ptr::null_mut(),
            x,
            y,
            width,
            height,
            SWP_NOZORDER | SWP_NOACTIVATE,
        )
    };
    if moved == 0 {
        return Err(os_failure("SetWindowPos"));
    }
    Ok(())
}

/// Posts the command as the window menu would: posting, so a hung window cannot hold the helper
fn system_command(hwnd: HWND, command: u32) -> Result<(), Failure> {
    // SAFETY: WM_SYSCOMMAND carries no pointers
    if unsafe { PostMessageW(hwnd, WM_SYSCOMMAND, command as usize, 0) } == 0 {
        return Err(os_failure("PostMessage"));
    }
    Ok(())
}

fn window_rect(hwnd: HWND) -> Option<[i32; 4]> {
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    // SAFETY: the buffer is a RECT
    (unsafe { GetWindowRect(hwnd, &mut rect) } != 0).then(|| {
        [
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
        ]
    })
}

fn failure(code: &'static str, message: String) -> Failure {
    Failure { code, message }
}

fn os_failure(what: &str) -> Failure {
    failure("failed", format!("{what}: {}", io::Error::last_os_error()))
}
