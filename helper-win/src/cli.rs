//! What the helper was started to do: its command line

/// The mode of one start of the helper
#[derive(Debug, PartialEq)]
pub enum Mode {
    /// No arguments: the helper itself, as the startup shortcut runs it
    Run,
    /// Copy to the user's folder, add the startup shortcut, start the copy; a language for the messages from now on
    Install { language: Option<String> },
    /// Stop the running helper, remove the shortcut and the copy
    Uninstall,
    /// Anything else: the argument that was not understood
    Unknown(String),
}

impl Mode {
    /// The mode from the arguments after the program name: --install [--language code], --uninstall or none
    pub fn parse(args: impl Iterator<Item = String>) -> Mode {
        let args: Vec<String> = args.collect();
        let words: Vec<&str> = args.iter().map(String::as_str).collect();
        match words.as_slice() {
            [] => Mode::Run,
            ["--install"] => Mode::Install { language: None },
            ["--install", "--language", code] if crate::i18n::is_code(code) => Mode::Install {
                language: Some(code.to_string()),
            },
            ["--uninstall"] => Mode::Uninstall,
            [first, ..] if *first != "--install" => Mode::Unknown(first.to_string()),
            [_, rest @ ..] => Mode::Unknown(rest.join(" ")),
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
    fn modes_follow_the_arguments() {
        assert_eq!(parse(&[]), Mode::Run);
        assert_eq!(parse(&["--install"]), Mode::Install { language: None });
        assert_eq!(
            parse(&["--install", "--language", "en"]),
            Mode::Install {
                language: Some("en".into())
            }
        );
        assert_eq!(parse(&["--uninstall"]), Mode::Uninstall);
        assert_eq!(parse(&["/install"]), Mode::Unknown("/install".into()));
        assert_eq!(
            parse(&["--install", "--uninstall"]),
            Mode::Unknown("--uninstall".into())
        );
        assert_eq!(
            parse(&["--install", "--language", "../x"]),
            Mode::Unknown("--language ../x".into())
        );
        assert_eq!(
            parse(&["--uninstall", "x"]),
            Mode::Unknown("--uninstall".into())
        );
    }
}
