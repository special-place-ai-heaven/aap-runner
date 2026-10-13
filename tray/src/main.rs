#![cfg_attr(windows, windows_subsystem = "windows")]

//! Tray front-end for the AAP self-hosted runner. Reads `status.json`, writes only under
//! `inbox\` (`state.json`, `settings.json`, `tray.log`), opens the logs folder and its own
//! `--settings` window (via `current_exe`). Nothing else.
//!
//! Like Fathom: a raw Win32 message pump on the main thread drives `tray-icon` directly.

mod dialog;
#[cfg(test)]
mod ico;
mod mark;
mod settings;
mod state;
mod win;

use mark::Badge;
use state::{DEFAULT_BASE, Desired, Status};
use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIconBuilder};

const POLL: Duration = Duration::from_secs(5);
/// ponytail: theme poll like Fathom; RegNotifyChangeKeyValue if 2 s ever matters.
const THEME_POLL: Duration = Duration::from_secs(2);
const RESTART_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// Absolute: a bare `explorer.exe` would be found in the tray's own folder first.
const EXPLORER: &str = r"C:\Windows\explorer.exe";
const TICK: Duration = Duration::from_millis(16);

fn badge(s: &Status) -> Badge {
    match s {
        Status::Idle | Status::Starting | Status::Draining => Badge::Solid,
        Status::Running(_) => Badge::Running,
        Status::Paused => Badge::Paused,
        Status::Error(_) => Badge::Error,
        Status::Off | Status::Unknown | Status::NotInstalled => Badge::Hollow,
    }
}

fn tooltip(line: &str) -> String {
    // Windows caps tooltips at 127 UTF-16 units.
    format!("AAP Runner: {line}").chars().take(120).collect()
}

/// Per-user single instance via an OS file lock held for the process lifetime.
/// `None` = another instance holds it. If the lock file cannot be opened, run anyway.
fn single_instance(name: &str) -> Option<Option<File>> {
    let path = std::env::temp_dir().join(name);
    let Ok(f) = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
    else {
        return Some(None);
    };
    match f.try_lock() {
        Ok(()) => Some(Some(f)),
        Err(TryLockError::WouldBlock) => None,
        Err(TryLockError::Error(_)) => Some(None),
    }
}

fn set_desired(base: &Path, d: Desired) {
    if let Err(e) = state::write_desired(base, d) {
        state::log(base, &format!("write {d:?} failed: {e}"));
    }
}

fn toggle_pause(base: &Path) {
    let mut s = settings::read_settings(base);
    s.paused = !s.paused;
    if let Err(e) = settings::write_settings(base, &s, &settings::VmLimit::read()) {
        state::log(base, &format!("write settings failed: {e}"));
    }
}

fn open_settings(base: &Path) {
    // The child takes its own lock, so a second click while it is open is a no-op.
    let spawned =
        std::env::current_exe().and_then(|exe| Command::new(exe).arg("--settings").spawn());
    if let Err(e) = spawned {
        state::log(base, &format!("open settings failed: {e}"));
    }
}

fn main() {
    let base = PathBuf::from(DEFAULT_BASE);
    if std::env::args().nth(1).as_deref() == Some("--settings") {
        let Some(_lock) = single_instance("aap-runner-tray-settings.lock") else {
            return;
        };
        if let Err(e) = dialog::run(base.clone()) {
            state::log(&base, &format!("settings window failed: {e}"));
        }
        return;
    }
    let Some(_lock) = single_instance("aap-runner-tray.lock") else {
        return;
    };
    if let Err(e) = run_tray(&base) {
        state::log(&base, &format!("tray failed: {e}"));
    }
}

fn run_tray(base: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let status_item = MenuItem::new("", false, None);
    let start = MenuItem::new("Start", true, None);
    let stop = MenuItem::new("Stop", true, None);
    let restart = MenuItem::new("Restart", true, None);
    let pause = MenuItem::new("Pause", true, None);
    let settings_item = MenuItem::new("Settings\u{2026}", true, None);
    let logs = MenuItem::new("Open logs", true, None);
    let quit = MenuItem::new("Quit", true, None);
    let menu = Menu::with_items(&[
        &status_item,
        &PredefinedMenuItem::separator(),
        &start,
        &stop,
        &restart,
        &PredefinedMenuItem::separator(),
        &pause,
        &settings_item,
        &PredefinedMenuItem::separator(),
        &logs,
        &PredefinedMenuItem::separator(),
        &quit,
    ])?;
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("AAP Runner")
        .build()?;

    let menu_rx = MenuEvent::receiver();
    let restarting = Arc::new(AtomicBool::new(false));
    let mut light = win::taskbar_uses_light_theme();
    let mut size = mark::tuned_size_for_dpi(win::system_dpi());
    let mut theme_read = Instant::now();
    let mut next_poll = Instant::now();
    let mut last_busy = false;
    let mut current = Badge::Hollow;
    let mut shown_icon = None;
    let mut shown_text = None;

    loop {
        if !win::pump_messages() {
            return Ok(());
        }
        while let Ok(e) = menu_rx.try_recv() {
            let id = e.id();
            if id == start.id() {
                set_desired(base, Desired::On);
            } else if id == stop.id() {
                set_desired(base, Desired::Off);
            } else if id == restart.id() && !restarting.swap(true, Ordering::SeqCst) {
                let (base, flag) = (base.to_path_buf(), restarting.clone());
                thread::spawn(move || {
                    match state::restart(&base, POLL, RESTART_TIMEOUT) {
                        Ok(true) => {}
                        Ok(false) => state::log(&base, "restart: timed out waiting for off"),
                        Err(e) => state::log(&base, &format!("restart failed: {e}")),
                    }
                    flag.store(false, Ordering::SeqCst);
                });
            } else if id == pause.id() {
                toggle_pause(base);
            } else if id == settings_item.id() {
                open_settings(base);
            } else if id == logs.id() {
                if let Err(e) = Command::new(EXPLORER).arg(base.join("logs")).spawn() {
                    state::log(base, &format!("open logs failed: {e}"));
                }
            } else if id == quit.id() {
                return Ok(()); // dropping `tray` removes the icon; no file is touched
            }
            next_poll = Instant::now();
        }

        if theme_read.elapsed() >= THEME_POLL {
            theme_read = Instant::now();
            light = win::taskbar_uses_light_theme();
            size = mark::tuned_size_for_dpi(win::system_dpi());
        }

        let busy = restarting.load(Ordering::SeqCst);
        if Instant::now() >= next_poll || busy != last_busy {
            last_busy = busy;
            let snap = state::read_status(base, SystemTime::now());
            current = badge(&snap.status);
            let text = if busy {
                "Restarting\u{2026}".to_string()
            } else {
                snap.line()
            };
            if shown_text.as_ref() != Some(&text) {
                status_item.set_text(&text);
                let _ = tray.set_tooltip(Some(tooltip(&text)));
                shown_text = Some(text);
            }
            let installed = snap.status != Status::NotInstalled;
            pause.set_text(settings::read_settings(base).toggle_label());
            pause.set_enabled(installed);
            settings_item.set_enabled(installed);
            start.set_enabled(installed && !busy);
            stop.set_enabled(installed && !busy);
            restart.set_enabled(installed && !busy);
            logs.set_enabled(base.join("logs").is_dir());
            next_poll = Instant::now() + POLL;
        }

        let key = (size, current, light);
        if shown_icon != Some(key) {
            let icon = Icon::from_rgba(mark::tray_rgba(size, current, light), size, size)?;
            let _ = tray.set_icon(Some(icon));
            shown_icon = Some(key);
        }
        thread::sleep(TICK);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_state_maps_to_its_badge() {
        assert_eq!(badge(&Status::Off), Badge::Hollow);
        assert_eq!(badge(&Status::Unknown), Badge::Hollow);
        assert_eq!(badge(&Status::NotInstalled), Badge::Hollow);
        assert_eq!(badge(&Status::Starting), Badge::Solid);
        assert_eq!(badge(&Status::Idle), Badge::Solid);
        assert_eq!(badge(&Status::Draining), Badge::Solid);
        assert_eq!(badge(&Status::Running("x".into())), Badge::Running);
        assert_eq!(badge(&Status::Paused), Badge::Paused);
        assert_eq!(badge(&Status::Error("x".into())), Badge::Error);
    }

    #[test]
    fn tooltip_is_prefixed_and_capped() {
        assert_eq!(tooltip("Idle"), "AAP Runner: Idle");
        assert_eq!(tooltip(&"x".repeat(300)).chars().count(), 120);
    }
}
