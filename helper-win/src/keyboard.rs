//! Switches the keyboard layout of the window with the focus, as the Mac switched its own
//!
//! ActivateKeyboardLayout would switch only the helper itself: the window with the focus is asked instead,
//! with WM_INPUTLANGCHANGEREQUEST, and may turn it down, docs/knowledge/windows/keyboardLayout.md

use std::ptr::null_mut;

use vibe_seam_helper::layout;
use vibe_seam_helper::session::Failure;
use windows_sys::Win32::Globalization::LocaleNameToLCID;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetKeyboardLayoutList, HKL};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GUITHREADINFO, GetForegroundWindow, GetGUIThreadInfo, GetWindowThreadProcessId, PostMessageW,
    WM_INPUTLANGCHANGEREQUEST,
};

/// The most layouts a session is expected to hold
const MAX_LAYOUTS: usize = 64;

pub fn switch(language: &str) -> Result<(), Failure> {
    let name: Vec<u16> = language.encode_utf16().chain([0]).collect();
    // SAFETY: the name is NUL-terminated
    let lcid = unsafe { LocaleNameToLCID(name.as_ptr(), 0) };
    if lcid == 0 {
        return Err(failure(
            "unsupported",
            format!("{language} is not a language Windows knows"),
        ));
    }
    let mut layouts: [HKL; MAX_LAYOUTS] = [null_mut(); MAX_LAYOUTS];
    // SAFETY: the buffer holds as many handles as the call is told
    let count =
        unsafe { GetKeyboardLayoutList(MAX_LAYOUTS as i32, layouts.as_mut_ptr()) }.max(0) as usize;
    let languages: Vec<u16> = layouts[..count]
        .iter()
        .map(|&hkl| hkl as usize as u16)
        .collect();
    let Some(index) = layout::matching(&languages, lcid as u16) else {
        return Err(failure(
            "unsupported",
            format!("no layout of {language} is installed in this session"),
        ));
    };
    // SAFETY: plain calls; the focus is asked for in the thread of the foreground window
    let target = unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return Err(failure("no-window", "no window has the focus".to_string()));
        }
        let mut info: GUITHREADINFO = std::mem::zeroed();
        info.cbSize = size_of::<GUITHREADINFO>() as u32;
        let thread = GetWindowThreadProcessId(foreground, null_mut());
        if GetGUIThreadInfo(thread, &mut info) != 0 && !info.hwndFocus.is_null() {
            info.hwndFocus
        } else {
            foreground
        }
    };
    // SAFETY: the message carries the layout handle by value
    if unsafe {
        PostMessageW(
            target,
            WM_INPUTLANGCHANGEREQUEST,
            0,
            layouts[index] as isize,
        )
    } == 0
    {
        return Err(failure(
            "failed",
            std::io::Error::last_os_error().to_string(),
        ));
    }
    Ok(())
}

fn failure(code: &'static str, message: String) -> Failure {
    Failure { code, message }
}
