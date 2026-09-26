//! The programs of the Start menu, section 8 of protocol/seam-protocol.md
//!
//! The walk over the folders and the mapping between ids and paths are plain file work, testable on any host;
//! finding the folders, reading icons and starting a shortcut are the Windows side's

use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::protocol::{self, Value};

/// How deep the walk goes into the folders of the menu, and how many shortcuts it takes at most:
/// a menu with a loop of junctions or a folder of thousands must not stall the helper
const MAX_DEPTH: usize = 8;
const MAX_APPS: usize = 2000;
const EXTENSION: &str = "lnk";

/// One root of the Start menu: the user's or the common one
pub struct Root {
    /// The first part of every id under it: "user" or "common"
    pub name: &'static str,
    pub path: PathBuf,
}

/// A shortcut of the menu as the protocol describes it
#[derive(Clone, Debug, PartialEq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub folder: String,
}

/// Every shortcut under the roots, sorted by folder and name, case aside
pub fn scan(roots: &[Root]) -> Vec<App> {
    let mut apps = Vec::new();
    for root in roots {
        walk(root, &root.path, &mut Vec::new(), &mut apps);
    }
    apps.sort_by_key(|app| {
        (
            app.folder.to_lowercase(),
            app.name.to_lowercase(),
            app.id.clone(),
        )
    });
    apps
}

fn walk(root: &Root, dir: &Path, folder: &mut Vec<String>, apps: &mut Vec<App>) {
    if folder.len() > MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if apps.len() >= MAX_APPS {
            return;
        }
        // Links are not followed: a junction back up the menu would loop
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        if kind.is_dir() {
            folder.push(name);
            walk(root, &entry.path(), folder, apps);
            folder.pop();
        } else if kind.is_file() {
            let path = Path::new(&name);
            if path
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case(EXTENSION))
            {
                let stem = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&name)
                    .to_string();
                let mut parts = vec![root.name.to_string()];
                parts.extend(folder.iter().cloned());
                parts.push(name);
                apps.push(App {
                    id: parts.join("/"),
                    name: stem,
                    folder: folder.join("/"),
                });
            }
        }
    }
}

/// The shortcut an id names, if it is one of the menu: under a known root, with no way out of it, ending in .lnk
pub fn resolve(roots: &[Root], id: &str) -> Option<PathBuf> {
    let (root_name, rest) = id.split_once('/')?;
    let root = roots.iter().find(|root| root.name == root_name)?;
    let relative = Path::new(rest);
    let plain = !rest.is_empty()
        && !rest.contains('\\')
        && !rest.contains(':')
        && relative
            .components()
            .all(|part| matches!(part, Component::Normal(_)));
    let shortcut = relative
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case(EXTENSION));
    if !plain || !shortcut {
        return None;
    }
    let path = rest
        .split('/')
        .fold(root.path.clone(), |path, part| path.join(part));
    path.is_file().then_some(path)
}

/// The answer to apps.request: the list without icons, which follow one message each
pub fn apps_message(seq: u64, apps: &[App]) -> Value {
    let items = apps
        .iter()
        .map(|app| {
            Value::Map(vec![
                ("id".to_string(), Value::Str(app.id.clone())),
                ("name".to_string(), Value::Str(app.name.clone())),
                ("folder".to_string(), Value::Str(app.folder.clone())),
            ])
        })
        .collect();
    protocol::message(
        "apps",
        vec![("seq", Value::UInt(seq)), ("items", Value::Array(items))],
    )
}

pub fn icon_message(id: &str, png: Vec<u8>) -> Value {
    protocol::message(
        "app.icon",
        vec![("id", Value::Str(id.to_string())), ("png", Value::Bin(png))],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A menu of two roots in a folder of its own, removed after the test
    struct Menu {
        base: PathBuf,
    }

    impl Menu {
        fn new(name: &str) -> Menu {
            let base = std::env::temp_dir()
                .join(format!("vibe-seam-launcher-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&base);
            for file in [
                "user/Excel.lnk",
                "user/Tools/zeta.LNK",
                "user/readme.txt",
                "common/Accessories/Notepad.lnk",
                "common/Accessories/System Tools/Character Map.lnk",
            ] {
                let path = base.join(file);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, b"").unwrap();
            }
            Menu { base }
        }

        fn roots(&self) -> Vec<Root> {
            vec![
                Root {
                    name: "user",
                    path: self.base.join("user"),
                },
                Root {
                    name: "common",
                    path: self.base.join("common"),
                },
            ]
        }
    }

    impl Drop for Menu {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.base);
        }
    }

    #[test]
    fn scan_finds_shortcuts_sorted_by_folder_and_name() {
        let menu = Menu::new("scan");
        let apps = scan(&menu.roots());
        let ids: Vec<&str> = apps.iter().map(|app| app.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "user/Excel.lnk",
                "common/Accessories/Notepad.lnk",
                "common/Accessories/System Tools/Character Map.lnk",
                "user/Tools/zeta.LNK",
            ]
        );
        assert_eq!(apps[1].name, "Notepad");
        assert_eq!(apps[1].folder, "Accessories");
    }

    #[test]
    fn resolve_takes_only_shortcuts_of_the_menu() {
        let menu = Menu::new("resolve");
        let roots = menu.roots();
        assert_eq!(
            resolve(&roots, "common/Accessories/Notepad.lnk"),
            Some(
                menu.base
                    .join("common")
                    .join("Accessories")
                    .join("Notepad.lnk")
            )
        );
        for id in [
            "user/../common/Accessories/Notepad.lnk",
            "user/readme.txt",
            "other/Excel.lnk",
            "user/Missing.lnk",
            "user/C:/Windows/notepad.lnk",
            "user/Tools\\zeta.LNK",
            "user/",
            "Excel.lnk",
        ] {
            assert_eq!(resolve(&roots, id), None, "{id}");
        }
    }

    #[test]
    fn apps_message_lists_every_key() {
        let apps = vec![App {
            id: "user/Excel.lnk".into(),
            name: "Excel".into(),
            folder: String::new(),
        }];
        let message = apps_message(4, &apps);
        assert_eq!(message.get("seq").and_then(Value::as_u64), Some(4));
        let Some(Value::Array(items)) = message.get("items") else {
            panic!("items")
        };
        assert_eq!(items[0].get("name").and_then(Value::as_str), Some("Excel"));
        assert_eq!(items[0].get("folder").and_then(Value::as_str), Some(""));
    }
}
