//! The thread that watches the windows of the session and tells the client about them
//!
//! Window events come through SetWinEventHook out of context, so they arrive on this thread's message loop;
//! the loop also takes the request for a full snapshot once a client has said hello

use std::cell::RefCell;
use std::collections::VecDeque;
use std::ptr::null_mut;
use std::sync::mpsc;
use std::thread;

use vibe_seam_helper::desktop::{Desktop, Kind, SHELL_CLASSES, State, Window};
use windows_sys::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use windows_sys::Win32::Graphics::Dwm::{
    DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentThreadId, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW,
};
use windows_sys::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CHILDID_SELF, DispatchMessageW, EVENT_OBJECT_CLOAKED, EVENT_OBJECT_CREATE,
    EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE, EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_NAMECHANGE,
    EVENT_OBJECT_SHOW, EVENT_OBJECT_UNCLOAKED, EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND,
    EVENT_SYSTEM_MINIMIZESTART, EnumWindows, GA_ROOT, GW_OWNER, GWL_STYLE, GetAncestor,
    GetClassNameW, GetForegroundWindow, GetMessageW, GetWindow, GetWindowLongW, GetWindowRect,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    IsZoomed, MSG, OBJID_WINDOW, PM_NOREMOVE, PeekMessageW, PostThreadMessageW,
    WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WM_APP,
};

use crate::icons;
use crate::link::Link;
use crate::log;

/// The thread message asking for a snapshot; wParam carries the generation of the channel
const WM_SNAPSHOT: u32 = WM_APP + 1;
/// Longest class name Windows keeps
const CLASS_NAME_LENGTH: usize = 256;
/// Room for an executable path, long paths included
const PATH_LENGTH: usize = 32_768;

/// The tracker thread, as the rest of the helper sees it
pub struct Tracker {
    thread: u32,
}

impl Tracker {
    /// Starts the thread and waits until it can take requests
    pub fn start(link: Link) -> Tracker {
        let (ready, started) = mpsc::channel();
        thread::spawn(move || run(link, ready));
        Tracker {
            thread: started
                .recv()
                .expect("the tracker thread reports its id before anything else"),
        }
    }

    /// Asks for everything to be sent to the channel of that generation
    pub fn snapshot(&self, generation: u64) {
        // SAFETY: the thread has a message queue, created before it reported its id
        if unsafe { PostThreadMessageW(self.thread, WM_SNAPSHOT, generation as usize, 0) } == 0 {
            log::line(&format!(
                "snapshot request lost: {}",
                std::io::Error::last_os_error()
            ));
        }
    }
}

/// What the thread keeps between events
struct Watch {
    link: Link,
    desktop: Desktop,
    /// The generation the client was sent a snapshot on; updates go to it only
    live: u64,
}

thread_local! {
    static WATCH: RefCell<Option<Watch>> = const { RefCell::new(None) };
    /// Events wait here while one is handled: a callback may come again during a call that waits
    static PENDING: RefCell<VecDeque<(u32, u64)>> = const { RefCell::new(VecDeque::new()) };
}

fn run(link: Link, ready: mpsc::Sender<u32>) {
    let mut msg: MSG = unsafe { std::mem::zeroed() };
    // SAFETY: peeking creates the message queue of this thread before anyone posts to it
    unsafe { PeekMessageW(&mut msg, null_mut(), 0, 0, PM_NOREMOVE) };
    WATCH.with(|watch| {
        *watch.borrow_mut() = Some(Watch {
            link,
            desktop: Desktop::default(),
            live: 0,
        })
    });
    // SAFETY: the callbacks are functions of this module; out of context they run on this thread
    let hooks: [HWINEVENTHOOK; 2] = unsafe {
        [
            SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND,
                EVENT_SYSTEM_MINIMIZEEND,
                null_mut(),
                Some(on_event),
                0,
                0,
                WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
            ),
            SetWinEventHook(
                EVENT_OBJECT_CREATE,
                EVENT_OBJECT_UNCLOAKED,
                null_mut(),
                Some(on_event),
                0,
                0,
                WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
            ),
        ]
    };
    if hooks.iter().any(|hook| hook.is_null()) {
        log::line(&format!(
            "window events not hooked: {}",
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: plain call returning this thread's id
    let _ = ready.send(unsafe { GetCurrentThreadId() });
    // SAFETY: a standard message loop; the hooks live as long as the process
    while unsafe { GetMessageW(&mut msg, null_mut(), 0, 0) } > 0 {
        if msg.hwnd.is_null() && msg.message == WM_SNAPSHOT {
            with_watch(|watch| snapshot(watch, msg.wParam as u64));
        } else {
            unsafe { DispatchMessageW(&msg) };
        }
    }
}

unsafe extern "system" fn on_event(
    _hook: HWINEVENTHOOK,
    event: u32,
    hwnd: HWND,
    object: i32,
    child: i32,
    _thread: u32,
    _time: u32,
) {
    // Only whole windows: the caret, the cursor and controls inside windows raise these events too
    if hwnd.is_null() || object != OBJID_WINDOW || child != CHILDID_SELF as i32 {
        return;
    }
    if !is_watched(event) {
        return;
    }
    PENDING.with(|pending| pending.borrow_mut().push_back((event, id(hwnd))));
    with_watch(|_| {});
}

fn is_watched(event: u32) -> bool {
    matches!(
        event,
        EVENT_SYSTEM_FOREGROUND
            | EVENT_SYSTEM_MINIMIZESTART
            | EVENT_SYSTEM_MINIMIZEEND
            | EVENT_OBJECT_CREATE
            | EVENT_OBJECT_DESTROY
            | EVENT_OBJECT_SHOW
            | EVENT_OBJECT_HIDE
            | EVENT_OBJECT_LOCATIONCHANGE
            | EVENT_OBJECT_NAMECHANGE
            | EVENT_OBJECT_CLOAKED
            | EVENT_OBJECT_UNCLOAKED
    )
}

/// Runs with the state, then handles the events that queued up meanwhile
/// A call further up the stack that already holds the state is left to drain them itself
fn with_watch(f: impl FnOnce(&mut Watch)) {
    WATCH.with(|watch| {
        if let Ok(mut slot) = watch.try_borrow_mut()
            && let Some(watch) = slot.as_mut()
        {
            f(watch);
            while let Some((event, id)) = PENDING.with(|pending| pending.borrow_mut().pop_front()) {
                handle(watch, event, id);
            }
        }
    });
}

fn snapshot(watch: &mut Watch, generation: u64) {
    let windows: Vec<Window> = top_level()
        .into_iter()
        .filter_map(|id| read(id, None))
        .collect();
    let count = windows.len();
    let apps: Vec<u64> = windows
        .iter()
        .filter(|w| w.kind == Kind::App)
        .map(|w| w.id)
        .collect();
    // SAFETY: plain call
    let foreground = id(unsafe { GetForegroundWindow() });
    let mut messages = watch.desktop.snapshot(windows, foreground);
    messages.extend(apps.into_iter().filter_map(|id| icon(watch, id)));
    if watch.link.send(generation, &messages) {
        watch.live = generation;
        log::line(&format!("snapshot sent: {count} windows"));
    }
}

fn handle(watch: &mut Watch, event: u32, id: u64) {
    let mut messages = Vec::new();
    let window = read(id, watch.desktop.get(id));
    messages.extend(watch.desktop.observe(id, window));
    if event != EVENT_OBJECT_LOCATIONCHANGE && event != EVENT_OBJECT_NAMECHANGE {
        messages.extend(watch.desktop.reorder(top_level()));
    }
    if event == EVENT_SYSTEM_FOREGROUND {
        messages.extend(watch.desktop.focus(id));
    }
    // No event says an icon changed: it is looked at when a window appears, is renamed or takes the focus
    if icon_may_change(event) && watch.desktop.get(id).is_some_and(|w| w.kind == Kind::App) {
        messages.extend(icon(watch, id));
    }
    if !messages.is_empty() {
        watch.link.send(watch.live, &messages);
    }
}

fn icon_may_change(event: u32) -> bool {
    matches!(
        event,
        EVENT_OBJECT_CREATE
            | EVENT_OBJECT_SHOW
            | EVENT_OBJECT_UNCLOAKED
            | EVENT_OBJECT_NAMECHANGE
            | EVENT_SYSTEM_FOREGROUND
    )
}

fn icon(watch: &mut Watch, id: u64) -> Option<vibe_seam_helper::protocol::Value> {
    watch.desktop.icon(id, icons::png(hwnd(id))?)
}

fn id(hwnd: HWND) -> u64 {
    hwnd as usize as u64
}

fn hwnd(id: u64) -> HWND {
    id as usize as HWND
}

/// All top-level windows, top to bottom
fn top_level() -> Vec<u64> {
    unsafe extern "system" fn collect(hwnd: HWND, ids: LPARAM) -> i32 {
        // SAFETY: LPARAM is the vector passed below, alive for the whole enumeration
        unsafe { (*(ids as *mut Vec<u64>)).push(id(hwnd)) };
        1
    }
    let mut ids = Vec::new();
    // SAFETY: the callback only pushes into the vector it is given
    unsafe { EnumWindows(Some(collect), &mut ids as *mut Vec<u64> as LPARAM) };
    ids
}

/// The window as the protocol describes it, or None when it does not pass the filter of section 6
fn read(id: u64, known: Option<&Window>) -> Option<Window> {
    let hwnd = hwnd(id);
    // SAFETY: every call below takes a window handle and tolerates one that is already gone
    unsafe {
        if IsWindowVisible(hwnd) == 0 || GetAncestor(hwnd, GA_ROOT) != hwnd || is_cloaked(hwnd) {
            return None;
        }
        let class = class_name(hwnd);
        if SHELL_CLASSES.contains(&class.as_str()) {
            return None;
        }
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let state = if IsIconic(hwnd) != 0 {
            State::Minimized
        } else if IsZoomed(hwnd) != 0 {
            State::Maximized
        } else {
            State::Normal
        };
        // The process of a window never changes: it is asked once
        let (pid, exe) = match known {
            Some(window) => (window.pid, window.exe.clone()),
            None => {
                let mut pid = 0;
                GetWindowThreadProcessId(hwnd, &mut pid);
                (pid, exe_name(pid))
            }
        };
        Some(Window {
            id,
            owner: id_of(GetWindow(hwnd, GW_OWNER)),
            rect: bounds(hwnd)?,
            title: title(hwnd),
            state,
            kind: Kind::of(&class, style),
            pid,
            exe,
        })
    }
}

fn id_of(hwnd: HWND) -> u64 {
    if hwnd.is_null() { 0 } else { id(hwnd) }
}

fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    // SAFETY: the attribute is a DWORD, the buffer is one
    let result = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED as u32,
            &mut cloaked as *mut u32 as *mut _,
            size_of::<u32>() as u32,
        )
    };
    result >= 0 && cloaked != 0
}

/// Visible bounds without the shadow; the window rectangle when DWM has none for it
fn bounds(hwnd: HWND) -> Option<[i32; 4]> {
    let mut rect: RECT = unsafe { std::mem::zeroed() };
    // SAFETY: the attribute is a RECT, the buffer is one
    let extended = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS as u32,
            &mut rect as *mut RECT as *mut _,
            size_of::<RECT>() as u32,
        )
    };
    // SAFETY: the buffer is a RECT
    if extended < 0 && unsafe { GetWindowRect(hwnd, &mut rect) } == 0 {
        return None;
    }
    Some([
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
    ])
}

fn class_name(hwnd: HWND) -> String {
    let mut buffer = [0u16; CLASS_NAME_LENGTH];
    // SAFETY: the length passed is the buffer's
    let len = unsafe { GetClassNameW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32) };
    String::from_utf16_lossy(&buffer[..len.max(0) as usize])
}

/// The title; for a window of another process Windows reads it without sending a message, so a hung one cannot stall
fn title(hwnd: HWND) -> String {
    // SAFETY: the buffer holds the length Windows reported and the NUL after it
    unsafe {
        let len = GetWindowTextLengthW(hwnd).max(0) as usize;
        let mut buffer = vec![0u16; len + 1];
        let copied = GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32);
        String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
    }
}

/// The file name of a process's executable; empty when the process does not let itself be asked
fn exe_name(pid: u32) -> String {
    // SAFETY: the process handle is checked and closed; the size is the buffer's
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return String::new();
        }
        let mut buffer = vec![0u16; PATH_LENGTH];
        let mut size = buffer.len() as u32;
        let ok =
            QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut size);
        CloseHandle(process);
        if ok == 0 {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buffer[..size as usize]);
        path.rsplit('\\').next().unwrap_or_default().to_string()
    }
}
