//! vibe-seam-helper: the Windows side of the VibeRDP Seam mode
//!
//! Runs once per session, opens the VibeSeam channel whenever a VibeRDP client offers it, and reopens it after
//! every break: a reconnect of the session or a client without the listener is the normal course, not an error

// No console window: the helper starts with the session from shell:startup and runs in the background
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod channel;
#[cfg(windows)]
mod commands;
#[cfg(windows)]
mod icons;
#[cfg(windows)]
mod instance;
#[cfg(windows)]
mod keyboard;
#[cfg(windows)]
mod link;
#[cfg(windows)]
mod log;
#[cfg(windows)]
mod setup;
#[cfg(windows)]
mod startmenu;
#[cfg(windows)]
mod tracker;

#[cfg(windows)]
fn main() {
    use vibe_seam_helper::cli::Mode;
    match Mode::parse(std::env::args().skip(1)) {
        Mode::Run => helper::run(),
        Mode::Install { language } => setup::install(language.as_deref()),
        Mode::Uninstall => setup::uninstall(),
        Mode::Unknown(argument) => setup::usage(&argument),
    }
}

/// The helper lives in a Windows session: elsewhere the binary only builds, for the checks of the host
#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
mod helper {
    use std::thread::sleep;
    use std::time::Duration;

    use vibe_seam_helper::protocol::FrameReader;
    use vibe_seam_helper::session::{self, LauncherRequest, Peer, Session};

    use crate::channel::{self, Reader};
    use crate::commands;
    use crate::instance;
    use crate::keyboard;
    use crate::link::Link;
    use crate::log;
    use crate::startmenu;
    use crate::tracker::Tracker;

    const AGENT: &str = concat!("vibe-seam-helper ", env!("CARGO_PKG_VERSION"));
    /// The wait before reopening grows from the first to the last value while the channel stays shut
    /// The last one is short: a try costs next to nothing, and every second of it the user looks at the desktop
    /// in place of the windows after a reconnection
    const RETRY_FIRST: Duration = Duration::from_millis(500);
    const RETRY_LAST: Duration = Duration::from_secs(2);

    pub fn run() {
        if !instance::claim() {
            return;
        }
        log::open();
        instance::exit_on_request();
        log::line(&format!("{AGENT} started"));
        let link = Link::default();
        let tracker = Tracker::start(link.clone());
        let mut retry = RETRY_FIRST;
        let mut shut_logged = false;
        loop {
            match channel::open() {
                Ok((reader, writer)) => {
                    log::line("channel open");
                    shut_logged = false;
                    retry = RETRY_FIRST;
                    let generation = link.attach(writer);
                    let reason = converse(reader, &link, generation, &tracker);
                    link.detach();
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
    fn converse(mut reader: Reader, link: &Link, generation: u64, tracker: &Tracker) -> String {
        let mut session = Session::new(AGENT);
        if !link.send(generation, &[session.greeting()]) {
            return "hello not sent".to_string();
        }
        let mut frames = FrameReader::default();
        loop {
            let bodies = match reader.read().map(|chunk| frames.push(chunk)) {
                Ok(Ok(bodies)) => bodies,
                Ok(Err(error)) => return format!("protocol error {error:?}"),
                Err(error) => return error.to_string(),
            };
            for body in bodies {
                let before = session.peer();
                let outcome = session.handle(&body);
                if let Some(note) = outcome.note {
                    log::line(&note);
                }
                if !outcome.replies.is_empty() && !link.send(generation, &outcome.replies) {
                    return "reply not sent".to_string();
                }
                if let Some(command) = outcome.command {
                    let result = commands::execute(command);
                    if let Err(failure) = &result {
                        log::line(&format!(
                            "command {} {:?} on {}: {} {}",
                            command.seq, command.action, command.id, failure.code, failure.message
                        ));
                    }
                    if !link.send(generation, &[session::reply(command.seq, result)]) {
                        return "reply not sent".to_string();
                    }
                }
                if let Some(request) = outcome.layout {
                    let result = keyboard::switch(&request.language);
                    if let Err(failure) = &result {
                        log::line(&format!(
                            "layout {} for {}: {} {}",
                            request.seq, request.language, failure.code, failure.message
                        ));
                    }
                    if !link.send(generation, &[session::reply(request.seq, result)]) {
                        return "reply not sent".to_string();
                    }
                }
                match outcome.launcher {
                    Some(LauncherRequest::List { seq }) => {
                        startmenu::send_list(link.clone(), generation, seq)
                    }
                    Some(LauncherRequest::Launch { seq, id })
                        if !startmenu::launch(link, generation, seq, &id) =>
                    {
                        return "reply not sent".to_string();
                    }
                    _ => {}
                }
                // The client learns the windows once it has said hello in our version and shows them
                if before != Peer::Ready && session.wants_windows() {
                    tracker.snapshot(generation);
                }
            }
        }
    }
}
