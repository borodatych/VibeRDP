//! What the helper was started to do: its command line

/// The mode of one start of the helper
#[derive(Debug, PartialEq)]
pub enum Mode {
    /// No arguments: the helper itself, as the startup shortcut runs it
    Run,
    /// Copy to the user's folder, add the startup shortcut, start the copy
    Install,
    /// Stop the running helper, remove the shortcut and the copy
    Uninstall,
    /// Anything else: the argument that was not understood
    Unknown(String),
}

impl Mode {
    /// The mode from the arguments after the program name; only one argument is understood
    pub fn parse(mut args: impl Iterator<Item = String>) -> Mode {
        match (args.next(), args.next()) {
            (None, _) => Mode::Run,
            (Some(arg), None) if arg == "--install" => Mode::Install,
            (Some(arg), None) if arg == "--uninstall" => Mode::Uninstall,
            (Some(arg), None) => Mode::Unknown(arg),
            (Some(_), Some(extra)) => Mode::Unknown(extra),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Mode {
        Mode::parse(args.iter().map(|a| a.to_string()))
    }

    #[test]
    fn modes_follow_the_single_argument() {
        assert_eq!(parse(&[]), Mode::Run);
        assert_eq!(parse(&["--install"]), Mode::Install);
        assert_eq!(parse(&["--uninstall"]), Mode::Uninstall);
        assert_eq!(parse(&["/install"]), Mode::Unknown("/install".into()));
        assert_eq!(
            parse(&["--install", "--uninstall"]),
            Mode::Unknown("--uninstall".into())
        );
    }
}
