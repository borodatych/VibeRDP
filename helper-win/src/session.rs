//! One conversation over an open channel, free of the channel itself: what the helper says first,
//! and what it answers to each message of the client
//!
//! The Windows side feeds it the bodies it read and writes back the replies; the logic stays testable on any host

use crate::protocol::{self, Value};

/// What this build of the helper does beyond keeping the channel: grows as the window stages land
pub const CAPABILITIES: &[&str] = &[];

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

/// The answer to one message: bodies to send back and a line for the log
#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub replies: Vec<Value>,
    pub note: Option<String>,
}

impl Outcome {
    fn note(text: String) -> Self {
        Outcome {
            replies: Vec::new(),
            note: Some(text),
        }
    }
}

pub struct Session {
    peer: Peer,
    agent: String,
}

impl Session {
    pub fn new(agent: &str) -> Self {
        Session {
            peer: Peer::Waiting,
            agent: agent.to_string(),
        }
    }

    pub fn peer(&self) -> Peer {
        self.peer
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
                    note: None,
                },
                None => Outcome::note("ping without seq skipped".to_string()),
            },
            // Requests the helper has not announced still get an answer, so the client does not wait for one
            "command" | "input.layout" => match seq(body) {
                Some(seq) => Outcome {
                    replies: vec![error(seq, "unsupported")],
                    note: Some(format!("\"{kind}\" is not supported by this build")),
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
            Outcome::note(format!("client {agent} speaks version {version}"))
        } else {
            self.peer = Peer::Incompatible(version);
            Outcome::note(format!(
                "client {agent} speaks version {version}, the helper {}: staying silent",
                protocol::VERSION
            ))
        }
    }
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

    #[test]
    fn unannounced_command_is_answered_unsupported() {
        let mut session = Session::new("helper");
        session.handle(&client_hello(1));
        let command = message(
            "command",
            vec![
                ("seq", Value::UInt(3)),
                ("id", Value::UInt(132290)),
                ("action", Value::Str("activate".into())),
            ],
        );
        assert_eq!(
            session.handle(&command).replies,
            vec![error(3, "unsupported")]
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
