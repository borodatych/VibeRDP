//! Installs the helper for the current user without administrator rights, and removes it
//!
//! The exe is copied to %LOCALAPPDATA%\VibeRDP and started at every logon by a shortcut in shell:startup;
//! nothing goes to HKLM or Program Files, so an ordinary user can do both

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
    CoTaskMemFree, CoUninitialize, IPersistFile,
};
use windows::Win32::UI::Shell::{
    FOLDERID_Startup, IShellLinkW, KF_FLAG_DEFAULT, SHGetKnownFolderPath, ShellLink,
};
use windows::core::{HSTRING, Interface};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    MB_ICONERROR, MB_ICONINFORMATION, MB_OK, MessageBoxW,
};

use crate::instance;

const FOLDER: &str = "VibeRDP";
const EXE_NAME: &str = "vibe-seam-helper.exe";
const SHORTCUT_NAME: &str = "VibeRDP Seam.lnk";
const SHORTCUT_DESCRIPTION: &str = "VibeRDP: окна Windows отдельными окнами Mac";
const TITLE: &str = "VibeRDP Seam";

/// Copies the helper, adds the shortcut and starts the copy; the result goes to a message box
pub fn install() {
    match try_install() {
        Ok(exe) => inform(&format!(
            "Хелпер VibeRDP установлен и запущен\nОн будет стартовать при каждом входе в Windows\n\nФайл: {}",
            exe.display()
        )),
        Err(error) => fail(&format!("Хелпер VibeRDP не установлен:\n{error}")),
    }
}

/// Stops the helper and removes the shortcut and the copy; the result goes to a message box
pub fn uninstall() {
    match try_uninstall() {
        Ok(None) => inform("Хелпер VibeRDP остановлен и удалён из автозагрузки"),
        Ok(Some(left)) => inform(&format!(
            "Хелпер VibeRDP остановлен и удалён из автозагрузки\n\nФайл {} запущен сейчас и сам себя удалить не может: удалите его вручную",
            left.display()
        )),
        Err(error) => fail(&format!("Хелпер VibeRDP не удалён:\n{error}")),
    }
}

/// The message box for an argument the helper does not know
pub fn usage(argument: &str) {
    fail(&format!(
        "Неизвестный параметр: {argument}\n\nБез параметров — работа хелпера\n--install — установка в автозагрузку\n--uninstall — удаление"
    ));
}

fn try_install() -> io::Result<PathBuf> {
    let source = std::env::current_exe()?;
    let folder = install_folder()?;
    let target = folder.join(EXE_NAME);
    // A running copy holds its file: it is stopped before being replaced
    if !instance::stop_running() {
        return Err(io::Error::other(
            "запущенный хелпер не остановился за 5 секунд",
        ));
    }
    fs::create_dir_all(&folder)?;
    if !same_file(&source, &target) {
        fs::copy(&source, &target)?;
    }
    create_shortcut(&target, &startup_folder()?.join(SHORTCUT_NAME))?;
    Command::new(&target).current_dir(&folder).spawn().map_err(|error| {
        io::Error::other(format!(
            "файл скопирован, но не запустился: {error}\nВозможно, запуск программ из папки пользователя запрещён политикой AppLocker"
        ))
    })?;
    Ok(target)
}

/// Removes what install added; returns the copy when it is this very process and cannot go
fn try_uninstall() -> io::Result<Option<PathBuf>> {
    if !instance::stop_running() {
        return Err(io::Error::other(
            "запущенный хелпер не остановился за 5 секунд",
        ));
    }
    remove_if_present(&startup_folder()?.join(SHORTCUT_NAME))?;
    let folder = install_folder()?;
    let target = folder.join(EXE_NAME);
    if same_file(&std::env::current_exe()?, &target) {
        return Ok(Some(target));
    }
    remove_if_present(&target)?;
    Ok(None)
}

fn install_folder() -> io::Result<PathBuf> {
    std::env::var_os("LOCALAPPDATA")
        .map(|base| PathBuf::from(base).join(FOLDER))
        .ok_or_else(|| io::Error::other("не задана переменная LOCALAPPDATA"))
}

fn same_file(a: &Path, b: &Path) -> bool {
    matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(a), Ok(b)) if a == b)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

fn startup_folder() -> io::Result<PathBuf> {
    // SAFETY: the returned string is copied and freed with the allocator it came from
    unsafe {
        let path = SHGetKnownFolderPath(&FOLDERID_Startup, KF_FLAG_DEFAULT, None)
            .map_err(io::Error::other)?;
        let folder = path.to_string().map_err(io::Error::other);
        CoTaskMemFree(Some(path.0 as *const _));
        Ok(PathBuf::from(folder?))
    }
}

/// A shell shortcut to the exe, the way Explorer makes one
fn create_shortcut(exe: &Path, shortcut: &Path) -> io::Result<()> {
    // SAFETY: COM is started and stopped around its own use on this thread
    unsafe {
        let started = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let result = (|| -> windows::core::Result<()> {
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
            link.SetPath(&HSTRING::from(exe.as_os_str()))?;
            if let Some(folder) = exe.parent() {
                link.SetWorkingDirectory(&HSTRING::from(folder.as_os_str()))?;
            }
            link.SetDescription(&HSTRING::from(SHORTCUT_DESCRIPTION))?;
            link.cast::<IPersistFile>()?
                .Save(&HSTRING::from(shortcut.as_os_str()), true)
        })();
        if started {
            CoUninitialize();
        }
        result.map_err(io::Error::other)
    }
}

fn inform(text: &str) {
    message(text, MB_ICONINFORMATION);
}

fn fail(text: &str) {
    message(text, MB_ICONERROR);
}

fn message(text: &str, icon: u32) {
    let text: Vec<u16> = text.encode_utf16().chain([0]).collect();
    let title: Vec<u16> = TITLE.encode_utf16().chain([0]).collect();
    // SAFETY: both strings are NUL-terminated and outlive the call
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | icon,
        )
    };
}
