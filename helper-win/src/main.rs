//! vibe-seam-helper: the Windows side of the VibeRDP Seam mode
//!
//! Runs once per session, opens the VibeSeam channel whenever a VibeRDP client offers it, and reopens it after
//! every break: a reconnect of the session or a client without the listener is the normal course, not an error

// No console window: the helper starts with the session from shell:startup and runs in the background
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod channel;
#[cfg(windows)]
mod log;

#[cfg(windows)]
fn main() {
    helper::run();
}

/// The helper lives in a Windows session: elsewhere the binary only builds, for the checks of the host
#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
mod helper {
    use std::thread::sleep;
    use std::time::Duration;

    use vibe_seam_helper::protocol::{self, FrameReader};
    use vibe_seam_helper::session::Session;
    use windows_sys::Win32::Foundation::{ERROR_ALREADY_EXISTS, GetLastError};
    use windows_sys::Win32::System::Threading::CreateMutexW;

    use crate::channel::Channel;
    use crate::log;

    const AGENT: &str = concat!("vibe-seam-helper ", env!("CARGO_PKG_VERSION"));
    /// One helper per session: the Local namespace is the session's own
    const INSTANCE_MUTEX: &str = "Local\\VibeSeamHelper";
    /// The wait before reopening grows from the first to the last value while the channel stays shut
    const RETRY_FIRST: Duration = Duration::from_secs(1);
    const RETRY_LAST: Duration = Duration::from_secs(30);

    pub fn run() {
        if !single_instance() {
            return;
        }
        log::open();
        log::line(&format!("{AGENT} started"));
        let mut retry = RETRY_FIRST;
        let mut shut_logged = false;
        loop {
            match Channel::open() {
                Ok(channel) => {
                    log::line("channel open");
                    shut_logged = false;
                    retry = RETRY_FIRST;
                    let reason = converse(channel);
                    log::line(&format!("channel closed: {reason}"));
                }
                // Logged once per stretch: the client may stay away for hours
                Err(error) if !shut_logged => {
                    log::line(&format!("channel not available: {error}"));
                    shut_logged = true;
                }
                Err(_) => {}
            }
            sleep(retry);
            retry = (retry * 2).min(RETRY_LAST);
        }
    }

    /// Talks over an open channel until it breaks, and says why it did
    fn converse(mut channel: Channel) -> String {
        let mut session = Session::new(AGENT);
        if let Err(error) = channel.write(&protocol::frame(&session.greeting())) {
            return format!("hello not sent: {error}");
        }
        let mut frames = FrameReader::default();
        loop {
            let bodies = match channel.read().map(|chunk| frames.push(chunk)) {
                Ok(Ok(bodies)) => bodies,
                Ok(Err(error)) => return format!("protocol error {error:?}"),
                Err(error) => return error.to_string(),
            };
            for body in bodies {
                let outcome = session.handle(&body);
                if let Some(note) = outcome.note {
                    log::line(&note);
                }
                for reply in outcome.replies {
                    if let Err(error) = channel.write(&protocol::frame(&reply)) {
                        return format!("reply not sent: {error}");
                    }
                }
            }
        }
    }

    /// Takes the session's mutex; false when another helper already holds it
    fn single_instance() -> bool {
        let name: Vec<u16> = INSTANCE_MUTEX.encode_utf16().chain([0]).collect();
        // SAFETY: the name is NUL-terminated; the handle is kept open for the life of the process on purpose
        let mutex = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        // SAFETY: GetLastError right after the call it reports on
        !mutex.is_null() && unsafe { GetLastError() } != ERROR_ALREADY_EXISTS
    }
}
