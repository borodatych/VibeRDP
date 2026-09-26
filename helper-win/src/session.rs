//! One conversation over an open channel, free of the channel itself: what the helper says first,
//! and what it answers to each message of the client
//!
//! The Windows side feeds it the bodies it read and writes back the replies; the logic stays testable on any host

use crate::protocol::{self, Value};

/// What this build of the helper does beyond keeping the channel: grows as the window stages land
pub const CAPABILITIES: &[&str] = &["windows", "icons", "commands"];

/// Where the conversation is: the client greets once, and its version decides whether the two talk
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Peer {
    /// The client has not said hello yet
    Waiting,
    /// The client speaks our version
    Ready,
    /// The client speaks another version: the helper stays silent on this channel
    Incompatible(u64),
}

/// What a command asks of a window: protocol/seam-protocol.md, section 7
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    Activate,
    /// New visible bounds: x, y, width, height
    Move([i32; 4]),
    Minimize,
    Maximize,
    Restore,
    Close,
}

/// A command for the Windows side to carry out and answer with reply()
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Command {
    pub seq: u64,
    pub id: u64,
    pub action: Action,
}

/// Why a command was not carried out, as the error message names it
#[derive(Debug, PartialEq)]
pub struct Failure {
    /// "no-window", "denied", "unsupported" or "failed"
    pub code: &'static str,
    pub message: String,
}

/// The answer to one message: bodies to send back, a command to carry out and a line for the log
#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub replies: Vec<Value>,
    pub command: Option<Command>,
    pub note: Option<String>,
}

impl Outcome {
    fn note(text: String) -> Self {
        Outcome {
            note: Some(text),
            ..Outcome::default()
        }
    }
}

/// The answer to a carried-out command: ack, or error with the code and the detail
pub fn reply(seq: u64, result: Result<(), Failure>) -> Value {
    match result {
        Ok(()) => protocol::message("ack", vec![("seq", Value::UInt(seq))]),
        Err(failure) => protocol::message(
            "error",
            vec![
                ("seq", Value::UInt(seq)),
                ("code", Value::Str(failure.code.to_string())),
                ("message", Value::Str(failure.message)),
            ],
        ),
    }
}

pub struct Session {
    peer: Peer,
    agent: String,
    /// The client said it shows windows of its own: only then do the windows go to it
    shows_windows: bool,
}

/// The capability of a client that shows the windows of the host, section 5 of the specification
const SHOWS_WINDOWS: &str = "seam";

impl Session {
    pub fn new(agent: &str) -> Self {
        Session {
            peer: Peer::Waiting,
            agent: agent.to_string(),
            shows_windows: false,
        }
    }

    pub fn peer(&self) -> Peer {
        self.peer
    }

    /// A ready client that shows windows: the windows, their icons and their order go to it
    pub fn wants_windows(&self) -> bool {
        self.peer == Peer::Ready && self.shows_windows
    }

    /// The first body on a freshly opened channel
    pub fn greeting(&self) -> Value {
        protocol::hello(CAPABILITIES, &self.agent)
    }

    /// Answers one body of the client
    pub fn handle(&mut self, body: &Value) -> Outcome {
        let Some(kind) = body.get("type").and_then(Value::as_str) else {
            return Outcome::note("message without a type skipped".to_string());
        };
        if kind == "hello" {
            return self.greet(body);
        }
        match self.peer {
            Peer::Waiting => return Outcome::note(format!("\"{kind}\" before hello skipped")),
            Peer::Incompatible(_) => return Outcome::default(),
            Peer::Ready => {}
        }
        match kind {
            "ping" => match seq(body) {
                Some(seq) => Outcome {
                    replies: vec![protocol::message("pong", vec![("seq", Value::UInt(seq))])],
                    ..Outcome::default()
                },
                None => Outcome::note("ping without seq skipped".to_string()),
            },
            "command" => command(body),
            // Requests the helper has not announced still get an answer, so the client does not wait for one
            "input.layout" => match seq(body) {
                Some(seq) => Outcome {
                    replies: vec![error(seq, "unsupported")],
                    note: Some(format!("\"{kind}\" is not supported by this build")),
                    ..Outcome::default()
                },
                None => Outcome::note(format!("\"{kind}\" without seq skipped")),
            },
            _ => Outcome::note(format!("unknown message \"{kind}\" skipped")),
        }
    }

    fn greet(&mut self, body: &Value) -> Outcome {
        let Some(version) = body.get("version").and_then(Value::as_u64) else {
            return Outcome::note("hello without version skipped".to_string());
        };
        let agent = body
            .get("agent")
            .and_then(Value::as_str)
            .unwrap_or("unknown client");
        if version == u64::from(protocol::VERSION) {
            self.peer = Peer::Ready;
            self.shows_windows = matches!(body.get("capabilities"), Some(Value::Array(items))
                if items.iter().any(|item| item.as_str() == Some(SHOWS_WINDOWS)));
            Outcome::note(format!(
                "client {agent} speaks version {version}{}",
                if self.shows_windows {
                    ", shows windows"
                } else {
                    ", keeps the desktop"
                }
            ))
        } else {
            self.peer = Peer::Incompatible(version);
            Outcome::note(format!(
                "client {agent} speaks version {version}, the helper {}: staying silent",
                protocol::VERSION
            ))
        }
    }
}

/// A command whose required keys are all there; an action this build does not know is answered unsupported
fn command(body: &Value) -> Outcome {
    let (Some(seq), Some(id), Some(action)) = (
        seq(body),
        body.get("id").and_then(Value::as_u64),
        body.get("action").and_then(Value::as_str),
    ) else {
        return Outcome::note("command without seq, id or action skipped".to_string());
    };
    let action = match action {
        "activate" => Action::Activate,
        "move" => match body.get("rect").and_then(rect) {
            Some(rect) => Action::Move(rect),
            None => return Outcome::note(format!("move {seq} without a valid rect skipped")),
        },
        "minimize" => Action::Minimize,
        "maximize" => Action::Maximize,
        "restore" => Action::Restore,
        "close" => Action::Close,
        other => {
            return Outcome {
                replies: vec![error(seq, "unsupported")],
                note: Some(format!("unknown action \"{other}\" of command {seq}")),
                ..Outcome::default()
            };
        }
    };
    Outcome {
        command: Some(Command { seq, id, action }),
        ..Outcome::default()
    }
}

/// A rect of four i32 values, with a size that is not negative
fn rect(value: &Value) -> Option<[i32; 4]> {
    let Value::Array(items) = value else {
        return None;
    };
    let numbers: Vec<i32> = items
        .iter()
        .map(|item| item.as_i64().and_then(|n| i32::try_from(n).ok()))
        .collect::<Option<_>>()?;
    let rect: [i32; 4] = numbers.try_into().ok()?;
    (rect[2] >= 0 && rect[3] >= 0).then_some(rect)
}

/// The request number, if it fits the u32 the protocol gives it
fn seq(body: &Value) -> Option<u64> {
    body.get("seq")
        .and_then(Value::as_u64)
        .filter(|&n| n <= u64::from(u32::MAX))
}

fn error(seq: u64, code: &str) -> Value {
    protocol::message(
        "error",
        vec![
            ("seq", Value::UInt(seq)),
            ("code", Value::Str(code.to_string())),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::message;

    fn client_hello(version: u64) -> Value {
        message(
            "hello",
            vec![
                ("version", Value::UInt(version)),
                (
                    "capabilities",
                    Value::Array(vec![Value::Str("seam".into())]),
                ),
                ("agent", Value::Str("VibeRDP 0.1.20".into())),
            ],
        )
    }

    fn ping(seq: u64) -> Value {
        message("ping", vec![("seq", Value::UInt(seq))])
    }

    #[test]
    fn greeting_is_hello_of_this_version() {
        let greeting = Session::new("vibe-seam-helper 0.1.0").greeting();
        assert_eq!(greeting.get("type").and_then(Value::as_str), Some("hello"));
        assert_eq!(greeting.get("version").and_then(Value::as_u64), Some(1));
    }

    #[test]
    fn only_a_client_that_shows_windows_wants_them() {
        let mut session = Session::new("helper");
        assert!(!session.wants_windows());
        session.handle(&client_hello(1));
        assert!(session.wants_windows());
        let mut desktop = Session::new("helper");
        desktop.handle(&message(
            "hello",
            vec![
                ("version", Value::UInt(1)),
                ("capabilities", Value::Array(vec![])),
                ("agent", Value::Str("VibeRDP".into())),
            ],
        ));
        assert_eq!(desktop.peer(), Peer::Ready);
        assert!(!desktop.wants_windows());
    }

    #[test]
    fn ping_before_hello_is_skipped() {
        let mut session = Session::new("helper");
        let outcome = session.handle(&ping(1));
        assert!(outcome.replies.is_empty());
        assert!(outcome.note.is_some());
        assert_eq!(session.peer(), Peer::Waiting);
    }

    #[test]
    fn ping_after_hello_gets_pong_with_its_seq() {
        let mut session = Session::new("helper");
        session.handle(&client_hello(1));
        assert_eq!(session.peer(), Peer::Ready);
        let outcome = session.handle(&ping(7));
        assert_eq!(
            outcome.replies,
            vec![message("pong", vec![("seq", Value::UInt(7))])]
        );
    }

    #[test]
    fn other_version_silences_the_helper() {
        let mut session = Session::new("helper");
        session.handle(&client_hello(2));
        assert_eq!(session.peer(), Peer::Incompatible(2));
        assert_eq!(session.handle(&ping(1)), Outcome::default());
    }

    fn command(action: &str, rect: Option<Value>) -> Value {
        let mut entries = vec![
            ("seq", Value::UInt(3)),
            ("id", Value::UInt(132290)),
            ("action", Value::Str(action.into())),
        ];
        entries.extend(rect.map(|rect| ("rect", rect)));
        message("command", entries)
    }

    fn ready() -> Session {
        let mut session = Session::new("helper");
        session.handle(&client_hello(1));
        session
    }

    #[test]
    fn command_is_handed_out_to_carry_out() {
        let outcome = ready().handle(&command("activate", None));
        assert!(outcome.replies.is_empty());
        assert_eq!(
            outcome.command,
            Some(Command {
                seq: 3,
                id: 132290,
                action: Action::Activate
            })
        );
        let outcome = ready().handle(&command("move", Some(protocol::rect(-10, 20, 800, 600))));
        assert_eq!(
            outcome.command.map(|c| c.action),
            Some(Action::Move([-10, 20, 800, 600]))
        );
    }

    #[test]
    fn move_without_a_valid_rect_is_skipped() {
        for rect in [
            None,
            Some(Value::Array(vec![Value::Int(1)])),
            Some(protocol::rect(0, 0, -1, 5)),
        ] {
            let outcome = ready().handle(&command("move", rect));
            assert_eq!(outcome.command, None);
            assert!(outcome.replies.is_empty());
            assert!(outcome.note.is_some());
        }
    }

    #[test]
    fn unknown_action_is_answered_unsupported() {
        let outcome = ready().handle(&command("snap", None));
        assert_eq!(outcome.command, None);
        assert_eq!(outcome.replies, vec![error(3, "unsupported")]);
    }

    #[test]
    fn reply_is_ack_or_error_with_the_same_seq() {
        assert_eq!(
            reply(3, Ok(())),
            message("ack", vec![("seq", Value::UInt(3))])
        );
        let failure = Failure {
            code: "no-window",
            message: "gone".into(),
        };
        assert_eq!(
            reply(3, Err(failure)),
            message(
                "error",
                vec![
                    ("seq", Value::UInt(3)),
                    ("code", Value::Str("no-window".into())),
                    ("message", Value::Str("gone".into())),
                ]
            )
        );
    }

    #[test]
    fn malformed_messages_are_skipped_without_replies() {
        let mut session = Session::new("helper");
        session.handle(&client_hello(1));
        for body in [
            Value::Map(vec![]),
            message("ping", vec![]),
            message("ping", vec![("seq", Value::UInt(1 << 40))]),
            message("window.snap", vec![]),
        ] {
            let outcome = session.handle(&body);
            assert!(outcome.replies.is_empty());
            assert!(outcome.note.is_some());
        }
    }
}
