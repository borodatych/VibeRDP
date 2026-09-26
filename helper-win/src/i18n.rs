//! The words of the helper: Russian built in, every other language a file, docs/manuals/langSpec.md, section 7
//!
//! The helper speaks only in the message boxes of its installer; the language is chosen at install time
//! with --language and kept beside its log, a missing file falls back to the built-in Russian

use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// The built-in language: always complete, the base under every file
pub const BASE: &str = "ru";
/// English as the helper seeds it into the folder of languages: the same rules as for a language of a user
pub const ENGLISH: &str = include_str!("../lang/en.json");

/// The catalog of the built-in language, flat dotted keys with named values in braces
pub const KEYS: &[(&str, &str)] = &[
    (
        "install.done",
        "Хелпер VibeRDP установлен и запущен\nОн будет стартовать при каждом входе в Windows\n\nФайл: {path}",
    ),
    ("install.failed", "Хелпер VibeRDP не установлен:\n{error}"),
    (
        "uninstall.done",
        "Хелпер VibeRDP остановлен и удалён из автозагрузки",
    ),
    (
        "uninstall.leftFile",
        "Хелпер VibeRDP остановлен и удалён из автозагрузки\n\nФайл {path} запущен сейчас и сам себя удалить не может: удалите его вручную",
    ),
    ("uninstall.failed", "Хелпер VibeRDP не удалён:\n{error}"),
    (
        "usage",
        "Неизвестный параметр: {argument}\n\nБез параметров — работа хелпера\n--install — установка в автозагрузку\n--install --language en — установка с языком сообщений из файла en.json\n--uninstall — удаление",
    ),
    (
        "error.notStopped",
        "запущенный хелпер не остановился за 5 секунд",
    ),
    (
        "error.notStarted",
        "файл скопирован, но не запустился: {error}\nВозможно, запуск программ из папки пользователя запрещён политикой AppLocker",
    ),
    ("error.noLocalAppData", "не задана переменная LOCALAPPDATA"),
    (
        "shortcut.description",
        "VibeRDP: окна Windows отдельными окнами Mac",
    ),
];

/// The strings of one language over the built-in ones
pub struct Catalog {
    strings: HashMap<String, String>,
}

impl Catalog {
    pub fn base() -> Catalog {
        Catalog {
            strings: KEYS
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    /// The language of this code from the folder, over the built-in one; a missing or broken file is Russian
    pub fn load(folder: &Path, code: &str) -> Catalog {
        let mut catalog = Catalog::base();
        if code == BASE && !folder.join("ru.json").is_file() || !is_code(code) {
            return catalog;
        }
        let file = folder.join(format!("{code}.json"));
        if let Some(strings) = fs::read_to_string(file).ok().and_then(|text| parse(&text)) {
            // Only keys the helper knows: a stray one would never show, a missing one keeps the Russian
            for (key, value) in strings {
                if let Some(slot) = catalog.strings.get_mut(&key) {
                    *slot = value;
                }
            }
        }
        catalog
    }

    /// The text of a key with its values put in; a value not given stays as {name}, so the gap shows
    pub fn text(&self, key: &str, values: &[(&str, &str)]) -> String {
        let mut text = self
            .strings
            .get(key)
            .cloned()
            .unwrap_or_else(|| key.to_string());
        for (name, value) in values {
            text = text.replace(&format!("{{{name}}}"), value);
        }
        text
    }
}

/// A code of a language as a file name takes it: letters, then an optional region, "en" or "pt-BR"
pub fn is_code(code: &str) -> bool {
    let (language, region) = code.split_once('-').unwrap_or((code, ""));
    (2..=3).contains(&language.len())
        && language.chars().all(|c| c.is_ascii_lowercase())
        && (region.is_empty()
            || region.len() == 2 && region.chars().all(|c| c.is_ascii_uppercase()))
}

/// A flat JSON object of strings; None for anything else
pub fn parse(text: &str) -> Option<HashMap<String, String>> {
    let mut reader = Reader {
        chars: text.chars().collect(),
        at: 0,
    };
    let mut strings = HashMap::new();
    reader.space();
    reader.expect('{')?;
    reader.space();
    if reader.peek() == Some('}') {
        reader.at += 1;
    } else {
        loop {
            reader.space();
            let key = reader.string()?;
            reader.space();
            reader.expect(':')?;
            reader.space();
            let value = reader.string()?;
            strings.insert(key, value);
            reader.space();
            match reader.next()? {
                ',' => continue,
                '}' => break,
                _ => return None,
            }
        }
    }
    reader.space();
    (reader.at == reader.chars.len()).then_some(strings)
}

struct Reader {
    chars: Vec<char>,
    at: usize,
}

impl Reader {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    fn next(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.at += 1;
        Some(c)
    }

    fn expect(&mut self, wanted: char) -> Option<()> {
        (self.next()? == wanted).then_some(())
    }

    fn space(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.at += 1;
        }
    }

    fn string(&mut self) -> Option<String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.next()? {
                '"' => return Some(out),
                '\\' => match self.next()? {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'n' => out.push('\n'),
                    't' => out.push('\t'),
                    'r' => out.push('\r'),
                    'u' => {
                        let hex: String = (0..4).map(|_| self.next()).collect::<Option<_>>()?;
                        out.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
                    }
                    _ => return None,
                },
                c => out.push(c),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placeholders(text: &str) -> Vec<String> {
        let mut names: Vec<String> = text
            .split('{')
            .skip(1)
            .filter_map(|part| part.split_once('}').map(|(name, _)| name.to_string()))
            .collect();
        names.sort();
        names
    }

    /// The gate: English has every key and no other, with the same named values
    #[test]
    fn english_is_complete_and_keeps_the_placeholders() {
        let english = parse(ENGLISH).expect("en.json is a flat object of strings");
        for (key, russian) in KEYS {
            let translated = english
                .get(*key)
                .unwrap_or_else(|| panic!("{key} has no English"));
            assert_eq!(placeholders(russian), placeholders(translated), "{key}");
        }
        assert_eq!(
            english.len(),
            KEYS.len(),
            "en.json has keys the helper does not know"
        );
    }

    /// The gate: no Russian text in the code of the installer outside this catalog
    #[test]
    fn installer_says_nothing_outside_the_catalog() {
        let source = include_str!("setup.rs");
        let cyrillic = source
            .chars()
            .find(|c| ('\u{0400}'..='\u{04FF}').contains(c));
        assert_eq!(
            cyrillic, None,
            "setup.rs has text in Russian outside the catalog"
        );
    }

    #[test]
    fn file_overrides_known_keys_and_falls_back() {
        let folder = std::env::temp_dir().join(format!("vibe-seam-lang-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        fs::write(
            folder.join("de.json"),
            r#"{ "usage": "Unbekannt: {argument}", "stray": "x" }"#,
        )
        .unwrap();
        let german = Catalog::load(&folder, "de");
        assert_eq!(
            german.text("usage", &[("argument", "--x")]),
            "Unbekannt: --x"
        );
        assert!(
            german.text("uninstall.done", &[]).starts_with("Хелпер"),
            "a missing key keeps the Russian"
        );
        let missing = Catalog::load(&folder, "fr");
        assert!(missing.text("uninstall.done", &[]).starts_with("Хелпер"));
        let unsafe_code = Catalog::load(&folder, "../de");
        assert!(unsafe_code.text("usage", &[]).starts_with("Неизвестный"));
        fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn values_fill_their_names_and_missing_ones_show() {
        let catalog = Catalog::base();
        assert!(
            catalog
                .text("install.failed", &[("error", "нет места")])
                .ends_with("нет места")
        );
        assert!(catalog.text("install.failed", &[]).ends_with("{error}"));
    }

    #[test]
    fn parser_takes_flat_strings_only() {
        let parsed = parse(r#" { "a": "x\n\"y\" é", "b": "" } "#).unwrap();
        assert_eq!(parsed["a"], "x\n\"y\" é");
        assert_eq!(parsed["b"], "");
        assert_eq!(parse("{}").map(|p| p.len()), Some(0));
        for bad in [
            r#"{"a": 1}"#,
            r#"{"a": {"b": "c"}}"#,
            r#"["a"]"#,
            r#"{"a": "b",}"#,
            r#"{"a": "b"} x"#,
        ] {
            assert!(parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn codes_are_plain_names() {
        for good in ["en", "de", "pt-BR", "fil"] {
            assert!(is_code(good), "{good}");
        }
        for bad in ["", "EN", "../en", "en_US", "english", "en-us"] {
            assert!(!is_code(bad), "{bad}");
        }
    }
}
