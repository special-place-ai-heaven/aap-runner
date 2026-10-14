#![cfg_attr(windows, windows_subsystem = "windows")]

//! Tray front-end for the AAP self-hosted runner. Reads `status.json` and `logs\supervisor.log`,
//! writes only under `inbox\` (`state.json`, `settings.json`, `tray.log`, `jobs\<id>.json`) plus
//! its own history mirror, view request, and helper pointer in `%TEMP%`. Opens the logs folder and
//! its own window (`--dashboard`, `--settings`). `--helper` is the elevated mode: it writes
//! `jobs\<id>\` and runs the embedded install scripts. The window never starts `wsl.exe`.
//!
//! Like Fathom: a raw Win32 message pump on the main thread drives `tray-icon` directly.

mod dashboard;
mod helper;
mod history;
#[cfg(test)]
mod ico;
mod mark;
mod problem;
mod settings;
mod settings_panel;
mod state;
mod win;

use dashboard::View;
use history::History;
use mark::Sym;
use state::{DEFAULT_BASE, Desired, Snapshot, Status};
use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

const POLL: Duration = Duration::from_secs(5);
/// ponytail: theme poll like Fathom; RegNotifyChangeKeyValue if 2 s ever matters.
const THEME_POLL: Duration = Duration::from_secs(2);
const RESTART_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// Absolute: a bare `explorer.exe` would be found in the tray's own folder first.
const EXPLORER: &str = r"C:\Windows\explorer.exe";
const TICK: Duration = Duration::from_millis(16);
/// `NOTIFYICONDATA` holds 128 UTF-16 units including the NUL.
const TOOLTIP_UNITS: usize = 127;

fn version_string(version: &str, commit: &str) -> String {
    format!("AAP Runner v{version} ({commit})")
}

/// `AAP Runner v0.5.0 (abcdef12)`: menu, error panel and `--version`.
pub fn version() -> String {
    version_string(env!("CARGO_PKG_VERSION"), env!("AAP_TRAY_COMMIT"))
}

/// `AAP Runner · v0.5.0 (abcdef12)`: the window's title, which is also how the tray finds it.
pub fn dashboard_title() -> String {
    format!(
        "AAP Runner \u{b7} v{} ({})",
        env!("CARGO_PKG_VERSION"),
        env!("AAP_TRAY_COMMIT")
    )
}

/// At most `max` UTF-16 units; a cut string ends in an ellipsis.
fn cap_units(s: &str, max: usize) -> String {
    if s.encode_utf16().count() <= max {
        return s.to_owned();
    }
    let mut out = String::new();
    let mut units = 0;
    for c in s.chars() {
        if units + c.len_utf16() > max - 1 {
            break;
        }
        units += c.len_utf16();
        out.push(c);
    }
    out.push('\u{2026}');
    out
}

/// One line: `AAP Runner · 2/3 busy · 14 cores · 41 GiB · Workspace, Backend Tests`,
/// `AAP Runner · Idle · 0/3 busy`, `AAP Runner · Error · <one-liner>`,
/// `AAP Runner · Paused · 1 job finishing`. Job titles are cut to fit 127 UTF-16 units.
fn tooltip(snap: &Snapshot, problem_line: Option<&str>) -> String {
    let (busy, runners) = (snap.busy(), snap.runners());
    let label = snap.status.sym().label();
    let body = match &snap.status {
        Status::Running(job) => {
            let mut t = format!("{busy}/{runners} busy");
            if let Some(c) = snap.pool.cpu_cores {
                t += &format!(" \u{b7} {c:.0} cores");
            }
            if let Some(g) = snap.pool.mem_gib {
                t += &format!(" \u{b7} {g:.0} GiB");
            }
            let mut jobs: Vec<&str> = snap
                .slots
                .iter()
                .filter(|s| s.busy() && !s.job.is_empty())
                .map(|s| s.job.as_str())
                .collect();
            if jobs.is_empty() && !job.is_empty() {
                jobs.push(job);
            }
            if !jobs.is_empty() {
                t += &format!(" \u{b7} {}", jobs.join(", "));
            }
            t
        }
        Status::Paused => match busy {
            0 => format!("{label} \u{b7} no jobs"),
            1 => format!("{label} \u{b7} 1 job finishing"),
            n => format!("{label} \u{b7} {n} jobs finishing"),
        },
        Status::Error(_) => format!("{label} \u{b7} {}", problem_line.unwrap_or("")),
        Status::Idle | Status::Starting | Status::Draining => {
            format!("{label} \u{b7} {busy}/{runners} busy")
        }
        Status::Off | Status::NotInstalled | Status::Unknown => label.to_owned(),
    };
    cap_units(&format!("AAP Runner \u{b7} {body}"), TOOLTIP_UNITS)
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

/// Start this exe with `args`; the child takes its own lock, so a repeat is a no-op.
fn spawn_self(base: &Path, args: &[&str]) {
    let spawned = std::env::current_exe().and_then(|exe| Command::new(exe).args(args).spawn());
    if let Err(e) = spawned {
        state::log(base, &format!("open {args:?} failed: {e}"));
    }
}

fn open_logs(base: &Path) {
    if let Err(e) = Command::new(EXPLORER).arg(base.join("logs")).spawn() {
        state::log(base, &format!("open logs failed: {e}"));
    }
}

/// Ask the open window to show `view`.
fn request_view(base: &Path, view: View) {
    if let Err(e) = dashboard::write_request(&dashboard::request_path(), view) {
        state::log(base, &format!("write view request failed: {e}"));
    }
}

/// Open the window as `view` asks (`None`: Status), or focus it if it is open and pass `view`
/// on (`None`: no change). `toggle`: a left click on the icon closes it when it was the last
/// active window.
fn show_window(base: &Path, view: Option<View>, toggle: Option<Option<isize>>) {
    match (win::find_window(&dashboard_title()), toggle) {
        (Some(h), Some(last)) if last == Some(h) => win::close(h),
        (Some(h), _) => {
            if let Some(view) = view {
                request_view(base, view);
            }
            win::focus(h);
        }
        (None, _) => spawn_self(base, view.unwrap_or(View::Status).args()),
    }
}

fn main() {
    let base = std::env::var_os("AAP_FAKE_BASE").map_or(PathBuf::from(DEFAULT_BASE), PathBuf::from);
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "--version") {
        // GUI subsystem: visible when stdout is redirected or piped (scripts), silent otherwise.
        println!("{}", version());
        return;
    }
    if args.first().is_some_and(|a| a == "--helper") {
        // Elevated mode. Paths come from the constant data directory, never from AAP_FAKE_BASE.
        let code = match args.get(1).zip(args.get(2)) {
            Some((verb, id)) if args.len() == 3 => helper::run_elevated(verb, id),
            _ => 2,
        };
        std::process::exit(code);
    }
    if let Some(view) = View::from_args(&args) {
        // One window: a second request passes its view to the open one and focuses it.
        let Some(_lock) = single_instance("aap-runner-tray-dashboard.lock") else {
            request_view(&base, view);
            if let Some(h) = win::find_window(&dashboard_title()) {
                win::focus(h);
            }
            return;
        };
        if let Err(e) = dashboard::run(base.clone(), view) {
            state::log(&base, &format!("window failed: {e}"));
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
    let dark_menus = win::DarkMenus::load();
    let mut apps_light = win::apps_use_light_theme();
    win::apply_dark_menus(dark_menus, None, !apps_light);
    let dashboard = MenuItem::new("Open dashboard", true, None);
    let status_item = MenuItem::new("", false, None);
    let open_job = MenuItem::new("Open job", false, None);
    let start = MenuItem::new("Start", true, None);
    let stop = MenuItem::new("Stop", true, None);
    let restart = MenuItem::new("Restart", true, None);
    let pause = MenuItem::new("Pause", true, None);
    let settings_item = MenuItem::new("Settings\u{2026}", true, None);
    let verify_item = MenuItem::new("Verify install", true, None);
    let repair_item = MenuItem::new("Repair install", true, None);
    let logs = MenuItem::new("Open logs", true, None);
    let version_item = MenuItem::new(version(), false, None);
    let quit = MenuItem::new("Quit", true, None);
    let menu = Menu::with_items(&[
        &dashboard,
        &PredefinedMenuItem::separator(),
        &status_item,
        &open_job,
        &PredefinedMenuItem::separator(),
        &start,
        &stop,
        &restart,
        &PredefinedMenuItem::separator(),
        &pause,
        &settings_item,
        &verify_item,
        &repair_item,
        &PredefinedMenuItem::separator(),
        &logs,
        &PredefinedMenuItem::separator(),
        &version_item,
        &quit,
    ])?;
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("AAP Runner")
        .build()?;
    let tray_window = Some(tray.window_handle() as isize).filter(|&h| h != 0);
    win::apply_dark_menus(dark_menus, tray_window, !apps_light);

    let menu_rx = MenuEvent::receiver();
    let click_rx = TrayIconEvent::receiver();
    let restarting = Arc::new(AtomicBool::new(false));
    let mut light = win::taskbar_uses_light_theme();
    let mut size = mark::tuned_size_for_dpi(win::system_dpi());
    let mut theme_read = Instant::now();
    let mut next_poll = Instant::now();
    let mut last_busy = false;
    let mut current = (Sym::Down, 0);
    let mut shown_icon = None;
    let mut shown_text = None;
    let mut shown_tip = None;
    // Only ever a `valid_run_url`, set from the last poll.
    let mut job_url: Option<String> = None;
    let mut in_problem = false;
    // The last active window that is not the taskbar: a click on the icon moves focus there.
    let mut last_app = None;
    let history_path = History::path();
    let mut history = History::load(&history_path);

    loop {
        if !win::pump_messages() {
            return Ok(());
        }
        if let Some(h) = win::foreground_app() {
            last_app = Some(h);
        }
        while let Ok(e) = click_rx.try_recv() {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = e
            {
                show_window(
                    base,
                    in_problem.then_some(View::Diagnostics),
                    Some(last_app),
                );
            }
        }
        while let Ok(e) = menu_rx.try_recv() {
            let id = e.id();
            if id == dashboard.id() {
                show_window(base, Some(View::Status), None);
            } else if id == start.id() {
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
                show_window(base, Some(View::Settings), None);
            } else if id == verify_item.id() {
                if let Err(e) = helper::launch(base, helper::Verb::Verify) {
                    state::log(base, &e);
                }
                show_window(base, Some(View::Status), None);
            } else if id == repair_item.id() {
                if let Err(e) = helper::launch(base, helper::Verb::Repair) {
                    state::log(base, &e);
                }
                show_window(base, Some(View::Status), None);
            } else if id == open_job.id() {
                if let Some(url) = job_url.as_deref().filter(|u| state::valid_run_url(u))
                    && let Err(e) = Command::new(EXPLORER).arg(url).spawn()
                {
                    state::log(base, &format!("open job failed: {e}"));
                }
            } else if id == logs.id() {
                open_logs(base);
            } else if id == quit.id() {
                return Ok(()); // dropping `tray` removes the icon; no file is touched
            }
            next_poll = Instant::now();
        }

        if theme_read.elapsed() >= THEME_POLL {
            theme_read = Instant::now();
            light = win::taskbar_uses_light_theme();
            size = mark::tuned_size_for_dpi(win::system_dpi());
            // The menu follows the app theme; uxtheme re-reads it and drops its cached menu
            // theme, so the next popup draws in the new mode without rebuilding the menu.
            let now_light = win::apps_use_light_theme();
            if now_light != apps_light {
                apps_light = now_light;
                win::apply_dark_menus(dark_menus, tray_window, !apps_light);
            }
        }

        let busy = restarting.load(Ordering::SeqCst);
        if Instant::now() >= next_poll || busy != last_busy {
            last_busy = busy;
            let now = SystemTime::now();
            let snap = state::read_status(base, now);
            let probe = match &snap.status {
                Status::Error(d) if d == problem::OLD_MANAGER => problem::read_tail(
                    &base.join("logs").join("supervisor.log"),
                    problem::LOG_TAIL_BYTES,
                )
                .ok()
                .and_then(|l| problem::last_probe_exit(&l)),
                _ => None,
            };
            let class = problem::current(&snap, probe);
            let detail = match &snap.status {
                Status::Error(d) => d.as_str(),
                _ => snap.detail.as_str(),
            };
            let age = snap.updated.and_then(|u| now.duration_since(u).ok());
            let line = class.map(|c| problem::one_liner(c, detail, age));
            in_problem = class.is_some();
            if history.observe(&snap, class, line.as_deref().unwrap_or(""), now)
                && let Err(e) = history.save(&history_path)
            {
                state::log(base, &format!("write history failed: {e}"));
            }
            current = (snap.status.sym(), snap.busy());
            let text = if busy {
                "Restarting\u{2026}".to_string()
            } else {
                snap.line()
            };
            if shown_text.as_ref() != Some(&text) {
                status_item.set_text(&text);
                shown_text = Some(text);
            }
            let tip = if busy {
                "AAP Runner \u{b7} Restarting\u{2026}".to_string()
            } else {
                tooltip(&snap, line.as_deref())
            };
            if shown_tip.as_ref() != Some(&tip) {
                let _ = tray.set_tooltip(Some(&tip));
                shown_tip = Some(tip);
            }
            job_url = snap.job_url().map(str::to_owned);
            open_job.set_enabled(job_url.is_some());
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
            let (sym, n) = current;
            let icon = Icon::from_rgba(mark::tray_rgba(size, sym, n, light), size, size)?;
            let _ = tray.set_icon(Some(icon));
            shown_icon = Some(key);
        }
        thread::sleep(TICK);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use state::{Pool, Slot, parse_status};

    #[test]
    fn each_state_maps_to_its_symbol() {
        assert_eq!(Status::Off.sym(), Sym::Off);
        assert_eq!(Status::Unknown.sym(), Sym::Down);
        assert_eq!(Status::NotInstalled.sym(), Sym::NotInstalled);
        assert_eq!(Status::Starting.sym(), Sym::Starting);
        assert_eq!(Status::Idle.sym(), Sym::Idle);
        assert_eq!(Status::Draining.sym(), Sym::Draining);
        assert_eq!(Status::Running("x".into()).sym(), Sym::Running);
        assert_eq!(Status::Paused.sym(), Sym::Paused);
        assert_eq!(Status::Error("x".into()).sym(), Sym::Error);
    }

    fn slot(n: u32, state: Sym, job: &str) -> Slot {
        Slot {
            slot: n,
            state,
            job: job.into(),
            repo: String::new(),
            run_url: String::new(),
            job_url: String::new(),
            started_at: None,
            cpu_cores: None,
            mem_gib: None,
        }
    }

    #[test]
    fn tooltip_lines() {
        let mut running = Snapshot::bare(Status::Running("Workspace".into()));
        running.applied.runner_count = Some(3);
        running.pool = Pool {
            cpu_cores: Some(14.2),
            mem_gib: Some(41.0),
            io_mbps: None,
        };
        running.slots = vec![
            slot(1, Sym::Running, "Workspace"),
            slot(2, Sym::Draining, "Backend Tests"),
            slot(3, Sym::Idle, ""),
        ];
        assert_eq!(
            tooltip(&running, None),
            "AAP Runner \u{b7} 2/3 busy \u{b7} 14 cores \u{b7} 41 GiB \u{b7} Workspace, Backend Tests"
        );
        running.pool = Pool::default();
        assert_eq!(
            tooltip(&running, None),
            "AAP Runner \u{b7} 2/3 busy \u{b7} Workspace, Backend Tests",
            "no sample, no numbers"
        );
        let mut idle = Snapshot::bare(Status::Idle);
        idle.applied.runner_count = Some(3);
        assert_eq!(
            tooltip(&idle, None),
            "AAP Runner \u{b7} Idle \u{b7} 0/3 busy"
        );
        let mut paused = Snapshot::bare(Status::Paused);
        paused.slots = vec![slot(1, Sym::Running, "x")];
        assert_eq!(
            tooltip(&paused, None),
            "AAP Runner \u{b7} Paused \u{b7} 1 job finishing"
        );
        assert_eq!(
            tooltip(
                &Snapshot::bare(Status::Error("x".into())),
                Some("Runner service keeps stopping")
            ),
            "AAP Runner \u{b7} Error \u{b7} Runner service keeps stopping"
        );
        assert_eq!(
            tooltip(&Snapshot::bare(Status::Unknown), None),
            "AAP Runner \u{b7} Service not running"
        );
        let now = SystemTime::now();
        let old = parse_status(
            r#"{"state":"running","job":"test-pg","updated":"2099-01-01T00:00:00Z","runner_count":3}"#,
            now,
        );
        assert_eq!(
            tooltip(&old, None),
            "AAP Runner \u{b7} 1/3 busy \u{b7} test-pg",
            "older supervisor: one slot from the top-level fields"
        );
    }

    #[test]
    fn tooltip_is_capped_at_127_utf16_units() {
        let mut s = Snapshot::bare(Status::Running(String::new()));
        s.slots = (1..=3)
            .map(|n| slot(n, Sym::Running, &"\u{1F600}job title ".repeat(12)))
            .collect();
        let t = tooltip(&s, None);
        assert!(
            t.encode_utf16().count() <= TOOLTIP_UNITS,
            "{}",
            t.encode_utf16().count()
        );
        assert!(t.ends_with('\u{2026}'));
        assert!(t.starts_with("AAP Runner \u{b7} 3/3 busy \u{b7} "));
        assert_eq!(cap_units("short", 127), "short");
        let exact = "x".repeat(127);
        assert_eq!(cap_units(&exact, 127), exact);
        let cut = cap_units(&"x".repeat(200), 127);
        assert_eq!(cut.encode_utf16().count(), 127);
        // A surrogate pair is never split.
        let emoji = cap_units(&"\u{1F600}".repeat(100), 127);
        assert!(emoji.encode_utf16().count() <= 127);
        assert!(emoji.ends_with('\u{2026}'));
    }

    #[test]
    fn version_string_names_version_and_commit() {
        assert_eq!(
            version_string("0.2.0", "abcdef12"),
            "AAP Runner v0.2.0 (abcdef12)"
        );
        assert_eq!(
            version_string("0.2.0", "local"),
            "AAP Runner v0.2.0 (local)"
        );
        assert_eq!(
            version(),
            format!(
                "AAP Runner v{} ({})",
                env!("CARGO_PKG_VERSION"),
                env!("AAP_TRAY_COMMIT")
            )
        );
        assert_eq!(env!("CARGO_PKG_VERSION"), "0.5.0");
        assert!(!env!("AAP_TRAY_COMMIT").is_empty());
        assert_eq!(
            dashboard_title(),
            format!("AAP Runner \u{b7} v0.5.0 ({})", env!("AAP_TRAY_COMMIT"))
        );
    }
}
