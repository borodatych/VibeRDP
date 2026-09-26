//! The icon of a window, read out of GDI as PNG
//!
//! A window gives its icon on WM_GETICON, and its class holds one when the window has none of its own;
//! the message goes with a timeout so a hung application cannot stall the tracker

use std::mem::size_of;
use std::ptr::null_mut;

use vibe_seam_helper::icon;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAP, BITMAPINFO, BITMAPINFOHEADER, DIB_RGB_COLORS, DeleteObject, GetDC, GetDIBits,
    GetObjectW, HBITMAP, ReleaseDC,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GCLP_HICON, GCLP_HICONSM, GetClassLongPtrW, GetIconInfo, HICON, ICON_BIG, ICON_SMALL2,
    ICONINFO, SMTO_ABORTIFHUNG, SendMessageTimeoutW, WM_GETICON,
};

/// How long a window may take to hand out its icon
const ICON_TIMEOUT_MS: u32 = 100;

/// The icon of a window as PNG; None when it has none that can be read
pub fn png(hwnd: HWND) -> Option<Vec<u8>> {
    png_of(find(hwnd)?)
}

/// An icon as PNG; the icon stays the caller's
pub fn png_of(icon: HICON) -> Option<Vec<u8>> {
    // SAFETY: ICONINFO is plain data filled by the call; both bitmaps it creates are deleted below
    unsafe {
        let mut info: ICONINFO = std::mem::zeroed();
        if GetIconInfo(icon, &mut info) == 0 {
            return None;
        }
        let png = encode(info.hbmColor, info.hbmMask);
        if !info.hbmColor.is_null() {
            DeleteObject(info.hbmColor);
        }
        if !info.hbmMask.is_null() {
            DeleteObject(info.hbmMask);
        }
        png
    }
}

/// The largest icon the window or its class offers
fn find(hwnd: HWND) -> Option<HICON> {
    for kind in [ICON_BIG, ICON_SMALL2] {
        let mut result = 0usize;
        // SAFETY: WM_GETICON takes no pointers; the result is written to a local
        let sent = unsafe {
            SendMessageTimeoutW(
                hwnd,
                WM_GETICON,
                kind as usize,
                0,
                SMTO_ABORTIFHUNG,
                ICON_TIMEOUT_MS,
                &mut result,
            )
        };
        if sent != 0 && result != 0 {
            return Some(result as HICON);
        }
    }
    [GCLP_HICON, GCLP_HICONSM].into_iter().find_map(|index| {
        // SAFETY: reads a field of the window's class
        let handle = unsafe { GetClassLongPtrW(hwnd, index) };
        (handle != 0).then_some(handle as HICON)
    })
}

/// A colour icon as PNG; a monochrome one, without a colour bitmap, is left out
fn encode(color: HBITMAP, mask: HBITMAP) -> Option<Vec<u8>> {
    if color.is_null() {
        return None;
    }
    // SAFETY: BITMAP is plain data, the size passed is its own
    let (width, height) = unsafe {
        let mut bitmap: BITMAP = std::mem::zeroed();
        if GetObjectW(
            color,
            size_of::<BITMAP>() as i32,
            &mut bitmap as *mut BITMAP as *mut _,
        ) == 0
        {
            return None;
        }
        (bitmap.bmWidth, bitmap.bmHeight)
    };
    if width <= 0 || height <= 0 || width as u32 > icon::MAX_SIDE || height as u32 > icon::MAX_SIDE
    {
        return None;
    }
    let bgra = pixels(color, width, height)?;
    let mask = (!mask.is_null())
        .then(|| pixels(mask, width, height))
        .flatten();
    icon::png(
        width as u32,
        height as u32,
        &icon::rgba(&bgra, mask.as_deref()),
    )
}

/// Top-down 32-bit BGRA rows of a bitmap
fn pixels(bitmap: HBITMAP, width: i32, height: i32) -> Option<Vec<u8>> {
    let mut buffer = vec![0u8; width as usize * height as usize * 4];
    // SAFETY: BITMAPINFO is plain data; a negative height asks for top-down rows; the buffer fits them all
    unsafe {
        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..std::mem::zeroed()
        };
        let dc = GetDC(null_mut());
        if dc.is_null() {
            return None;
        }
        let lines = GetDIBits(
            dc,
            bitmap,
            0,
            height as u32,
            buffer.as_mut_ptr() as *mut _,
            &mut info,
            DIB_RGB_COLORS,
        );
        ReleaseDC(null_mut(), dc);
        (lines == height).then_some(buffer)
    }
}
