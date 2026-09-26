//! The writing end of the channel, shared by the thread that answers the client and the thread that tracks windows
//!
//! Every open of the channel is a new generation: the tracker speaks only to the generation it sent its snapshot to,
//! so an update never reaches a client that has not been told about the window first

use std::sync::{Arc, Mutex, MutexGuard};

use vibe_seam_helper::protocol::{self, Value};

use crate::channel::Writer;
use crate::log;

#[derive(Default)]
struct State {
    writer: Option<Writer>,
    generation: u64,
}

#[derive(Clone, Default)]
pub struct Link(Arc<Mutex<State>>);

impl Link {
    /// Takes the writer of a freshly opened channel and returns its generation
    pub fn attach(&self, writer: Writer) -> u64 {
        let mut state = self.lock();
        state.generation += 1;
        state.writer = Some(writer);
        state.generation
    }

    /// Lets the writer go: the channel closes once the reader is gone as well
    pub fn detach(&self) {
        self.lock().writer = None;
    }

    /// Sends bodies to the channel of that generation; false when it is gone or the write failed
    pub fn send(&self, generation: u64, bodies: &[Value]) -> bool {
        let mut state = self.lock();
        if state.generation != generation {
            return false;
        }
        let Some(writer) = state.writer.as_mut() else {
            return false;
        };
        for body in bodies {
            if let Err(error) = writer.write(&protocol::frame(body)) {
                log::line(&format!("write failed: {error}"));
                state.writer = None;
                return false;
            }
        }
        true
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        // A thread that panicked holding the lock left the state whole: every change above is a single assignment
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
