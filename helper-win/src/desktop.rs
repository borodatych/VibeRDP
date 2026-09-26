//! What the client knows about the windows of the host, and the messages that keep it right
//!
//! The Windows side reads windows and feeds them here; this module decides what changed and what to say about it,
//! so the rules of protocol/seam-protocol.md, section 6, stay testable on any host

use std::collections::HashMap;

use crate::protocol::{self, Value};

/// Classes of the shell that are never shown as windows of their own: the taskbar and the desktop
pub const SHELL_CLASSES: &[&str] = &["Shell_TrayWnd", "Progman", "WorkerW"];
/// Classes of windows that are popups whatever their style: menus and tooltips
const POPUP_CLASSES: &[&str] = &["#32768", "tooltips_class32"];
const WS_POPUP: u32 = 0x8000_0000;
const WS_CAPTION: u32 = 0x00C0_0000;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum State {
    Normal,
    Minimized,
    Maximized,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Normal => "normal",
            State::Minimized => "minimized",
            State::Maximized => "maximized",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    App,
    Popup,
}

impl Kind {
    /// A menu, a tooltip, or a popup without a caption; everything else is a window of an application
    pub fn of(class: &str, style: u32) -> Kind {
        if POPUP_CLASSES.contains(&class)
            || (style & WS_POPUP != 0 && style & WS_CAPTION != WS_CAPTION)
        {
            Kind::Popup
        } else {
            Kind::App
        }
    }

    fn name(self) -> &'static str {
        match self {
            Kind::App => "app",
            Kind::Popup => "popup",
        }
    }
}

/// One window as the protocol describes it
#[derive(Clone, Debug, PartialEq)]
pub struct Window {
    pub id: u64,
    pub owner: u64,
    /// Visible bounds: x, y, width, height
    pub rect: [i32; 4],
    pub title: String,
    pub state: State,
    pub kind: Kind,
    pub pid: u32,
    pub exe: String,
}

impl Window {
    /// Every key, for window.create
    fn create(&self) -> Value {
        protocol::message("window.create", self.fields(None))
    }

    /// The keys that differ from what the client has, for window.update; None when nothing does
    fn update(&self, known: &Window) -> Option<Value> {
        let fields = self.fields(Some(known));
        (fields.len() > 1).then(|| protocol::message("window.update", fields))
    }

    fn fields(&self, known: Option<&Window>) -> Vec<(&'static str, Value)> {
        let changed = |same: fn(&Window, &Window) -> bool| known.is_none_or(|k| !same(self, k));
        let mut fields = vec![("id", Value::UInt(self.id))];
        if changed(|a, b| a.owner == b.owner) {
            fields.push(("owner", Value::UInt(self.owner)));
        }
        if changed(|a, b| a.rect == b.rect) {
            let [x, y, width, height] = self.rect;
            fields.push(("rect", protocol::rect(x, y, width, height)));
        }
        if changed(|a, b| a.title == b.title) {
            fields.push(("title", Value::Str(self.title.clone())));
        }
        if changed(|a, b| a.state == b.state) {
            fields.push(("state", Value::Str(self.state.name().to_string())));
        }
        if changed(|a, b| a.kind == b.kind) {
            fields.push(("kind", Value::Str(self.kind.name().to_string())));
        }
        if changed(|a, b| a.pid == b.pid) {
            fields.push(("pid", Value::UInt(u64::from(self.pid))));
        }
        if changed(|a, b| a.exe == b.exe) {
            fields.push(("exe", Value::Str(self.exe.clone())));
        }
        fields
    }
}

/// The windows the client has been told about, their order and the one with the focus
#[derive(Default)]
pub struct Desktop {
    windows: HashMap<u64, Window>,
    order: Vec<u64>,
    foreground: u64,
}

impl Desktop {
    pub fn get(&self, id: u64) -> Option<&Window> {
        self.windows.get(&id)
    }

    /// Forgets what the client knew and tells it everything: windows top to bottom, their order, the focus
    pub fn snapshot(&mut self, windows: Vec<Window>, foreground: u64) -> Vec<Value> {
        self.windows.clear();
        self.order.clear();
        self.foreground = 0;
        let order: Vec<u64> = windows.iter().map(|w| w.id).collect();
        let mut messages: Vec<Value> = windows.iter().map(Window::create).collect();
        self.windows = windows.into_iter().map(|w| (w.id, w)).collect();
        messages.extend(self.reorder(order));
        messages.extend(self.focus(foreground));
        messages
    }

    /// A window as it is now, or None when it no longer passes the filter
    pub fn observe(&mut self, id: u64, window: Option<Window>) -> Option<Value> {
        match (window, self.windows.get(&id)) {
            (Some(window), Some(known)) => {
                let message = window.update(known);
                self.windows.insert(id, window);
                message
            }
            (Some(window), None) => {
                let message = window.create();
                self.windows.insert(id, window);
                Some(message)
            }
            (None, Some(_)) => {
                self.windows.remove(&id);
                self.order.retain(|&known| known != id);
                if self.foreground == id {
                    self.foreground = 0;
                }
                Some(protocol::message(
                    "window.destroy",
                    vec![("id", Value::UInt(id))],
                ))
            }
            (None, None) => None,
        }
    }

    /// The order of all top-level windows, top to bottom; says zorder when the order of known ones changed
    pub fn reorder(&mut self, all: Vec<u64>) -> Option<Value> {
        let order: Vec<u64> = all
            .into_iter()
            .filter(|id| self.windows.contains_key(id))
            .collect();
        if order == self.order {
            return None;
        }
        self.order = order;
        let ids = self.order.iter().map(|&id| Value::UInt(id)).collect();
        Some(protocol::message(
            "zorder",
            vec![("ids", Value::Array(ids))],
        ))
    }

    /// The window with the focus; one outside the list counts as none
    pub fn focus(&mut self, id: u64) -> Option<Value> {
        let id = if self.windows.contains_key(&id) {
            id
        } else {
            0
        };
        if id == self.foreground {
            return None;
        }
        self.foreground = id;
        Some(protocol::message(
            "foreground",
            vec![("id", Value::UInt(id))],
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::message;

    fn excel() -> Window {
        Window {
            id: 132290,
            owner: 0,
            rect: [120, 80, 1280, 800],
            title: "Книга1 - Excel".into(),
            state: State::Normal,
            kind: Kind::App,
            pid: 7412,
            exe: "EXCEL.EXE".into(),
        }
    }

    fn kind_of(message: &Value) -> &str {
        message.get("type").and_then(Value::as_str).unwrap()
    }

    #[test]
    fn snapshot_creates_every_window_then_order_then_focus() {
        let mut desktop = Desktop::default();
        let mut notepad = excel();
        notepad.id = 5;
        let messages = desktop.snapshot(vec![excel(), notepad], 5);
        let kinds: Vec<&str> = messages.iter().map(kind_of).collect();
        assert_eq!(
            kinds,
            ["window.create", "window.create", "zorder", "foreground"]
        );
        assert_eq!(
            messages[2],
            message(
                "zorder",
                vec![(
                    "ids",
                    Value::Array(vec![Value::UInt(132290), Value::UInt(5)])
                )]
            )
        );
    }

    #[test]
    fn create_carries_every_key() {
        let created = excel().create();
        for key in [
            "id", "owner", "rect", "title", "state", "kind", "pid", "exe",
        ] {
            assert!(created.get(key).is_some(), "{key} missing");
        }
    }

    #[test]
    fn update_carries_only_what_changed() {
        let mut desktop = Desktop::default();
        desktop.observe(132290, Some(excel()));
        let mut moved = excel();
        moved.rect = [0, 0, 800, 600];
        assert_eq!(
            desktop.observe(132290, Some(moved.clone())),
            Some(message(
                "window.update",
                vec![
                    ("id", Value::UInt(132290)),
                    ("rect", protocol::rect(0, 0, 800, 600))
                ]
            ))
        );
        assert_eq!(desktop.observe(132290, Some(moved)), None);
    }

    #[test]
    fn window_leaving_the_filter_is_destroyed_once() {
        let mut desktop = Desktop::default();
        desktop.snapshot(vec![excel()], 132290);
        assert_eq!(
            desktop.observe(132290, None),
            Some(message("window.destroy", vec![("id", Value::UInt(132290))]))
        );
        assert_eq!(desktop.observe(132290, None), None);
        assert_eq!(desktop.focus(0), None);
    }

    #[test]
    fn order_ignores_unknown_windows_and_repeats() {
        let mut desktop = Desktop::default();
        desktop.observe(132290, Some(excel()));
        assert!(desktop.reorder(vec![1, 132290, 2]).is_some());
        assert_eq!(desktop.reorder(vec![3, 132290]), None);
    }

    #[test]
    fn focus_outside_the_list_is_none() {
        let mut desktop = Desktop::default();
        desktop.observe(132290, Some(excel()));
        assert!(desktop.focus(132290).is_some());
        assert_eq!(
            desktop.focus(99),
            Some(message("foreground", vec![("id", Value::UInt(0))]))
        );
    }

    #[test]
    fn kind_follows_class_and_style() {
        assert_eq!(Kind::of("XLMAIN", WS_CAPTION), Kind::App);
        assert_eq!(Kind::of("#32768", WS_POPUP), Kind::Popup);
        assert_eq!(Kind::of("tooltips_class32", 0), Kind::Popup);
        assert_eq!(Kind::of("Custom", WS_POPUP), Kind::Popup);
        assert_eq!(Kind::of("Dialog", WS_POPUP | WS_CAPTION), Kind::App);
    }
}
