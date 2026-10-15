//! `--dashboard` / `--settings` mode: the one window, in its own process (the tray's Win32 pump
//! cannot host an eframe loop). The fixed left column holds Power and the settings
//! (`settings_panel`); the right column shows only observed values: the header row, pool bars,
//! compact runner cards and the 60-minute strips, or the error panel in their place. Re-reads
//! `status.json` every 5 s and repaints every second. Bars, strips and symbols are plain
//! `Painter` calls. A second request (tray menu, a second `--settings`) arrives as a request file.

use crate::history::{History, Sample, secs};
use crate::mark::Sym;
use crate::problem::{self, Action, Class};
use crate::settings_panel::SettingsPanel;
use crate::state::{self, Desired, Slot, Snapshot, Status};
use eframe::egui::{
    self, Align, Align2, Color32, FontFamily, FontId, Key, Layout, Rect, RichText, Sense, Shape,
    Stroke, StrokeKind, Theme, pos2, vec2,
};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

/// What the window shows when it opens or is asked again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    /// The runner cards.
    Status,
    /// Focus on the left column's first control (`--settings`, Settings…).
    Settings,
    /// The error panel, while there is a problem.
    Diagnostics,
    /// The GitHub setup checklist, in place of the runner cards.
    Github,
}

impl View {
    const ALL: [View; 4] = [
        View::Status,
        View::Settings,
        View::Diagnostics,
        View::Github,
    ];

    /// The command line that opens the window this way.
    pub fn args(self) -> &'static [&'static str] {
        match self {
            View::Status => &["--dashboard"],
            View::Settings => &["--settings"],
            View::Diagnostics => &["--dashboard", "--problem"],
            View::Github => &["--github"],
        }
    }

    /// The view a command line (without the exe) asks for; `None` = not a window command.
    pub fn from_args(args: &[String]) -> Option<View> {
        match args.first()?.as_str() {
            "--settings" => Some(View::Settings),
            "--github" => Some(View::Github),
            "--dashboard" if args.iter().any(|a| a == "--problem") => Some(View::Diagnostics),
            "--dashboard" => Some(View::Status),
            _ => None,
        }
    }

    fn word(self) -> &'static str {
        match self {
            View::Status => "status",
            View::Settings => "settings",
            View::Diagnostics => "diagnostics",
            View::Github => "github",
        }
    }
}

/// `%TEMP%\aap-runner-tray\tab.request`: one word, written by whoever wants the open window to
/// show another view, taken (read and deleted) by the window.
pub fn request_path() -> PathBuf {
    History::path().with_file_name("view.request")
}

pub fn write_request(path: &Path, view: View) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    state::write_atomic(path, view.word().as_bytes())
}

/// The pending request, if any; it is removed either way.
fn take_request(path: &Path) -> Option<View> {
    let text = std::fs::read_to_string(path).ok()?;
    let _ = std::fs::remove_file(path);
    View::ALL.into_iter().find(|v| v.word() == text.trim())
}

/// Default inner size fits five compact cards. The column scrolls below the minimum.
const SIZE: [f32; 2] = [760.0, 760.0];
const MIN_SIZE: [f32; 2] = [680.0, 460.0];

/// One card per reported slot, and no more than the runner limit.
fn cards_to_draw(slot_count: usize) -> usize {
    slot_count.min(*crate::settings::RUNNERS.end() as usize)
}

/// Total height the right column needs for slots runner cards, the pinned
/// header, the job status line, and vertical padding (worst case). Used by
/// the layout test to prove five cards fit at SIZE[1] without scrolling.
#[cfg(test)]
fn right_column_height(slots: usize) -> f32 {
    let n = cards_to_draw(slots);
    PAD                                               // top inner margin
    + HEADER_H + ITEM_SPACING                        // header row + auto spacing
    + AFTER_HEADER                                   // add_space after header
    + JOB_LINE_H                                     // worst-case job status line
    + n as f32 * CARD_H                              // cards
    + n.saturating_sub(1) as f32 * CARD_GAP          // gaps between cards
    + PAD // bottom inner margin
}

/// Bottom-right inner size and outer position in a work area
/// `[left, top, right, bottom]`. Height is at most `max[1]` and shrinks so
/// the top stays inside the work area. Width shrinks only when it would
/// cross the left edge. `title` is the assumed title-bar height.
fn place_window(work: [f32; 4], max: [f32; 2], pad: f32, title: f32) -> (f32, f32, f32, f32) {
    let [left, top, right, bottom] = work;
    let avail_h = (bottom - top - pad - title).max(0.0);
    let height = max[1].min(avail_h);
    let y = (bottom - pad - height - title).max(top);
    let mut width = max[0];
    let mut x = right - pad - width;
    if x < left {
        width = (right - left - pad).max(0.0);
        x = (right - pad - width).max(left);
    }
    (x, y, width, height)
}
/// The fixed settings column.
const LEFT_W: f32 = 260.0;
const PAD: f32 = 12.0;
const REFRESH: Duration = Duration::from_secs(5);
/// A sample older than this draws as "no sample".
const SAMPLE_STALE: Duration = Duration::from_secs(150);
const LABEL_W: f32 = 56.0;
const BAR_H: f32 = 8.0;
const LOG_ROWS: usize = 20;
// --- Layout constants (draw-time) ---
/// Symbol widget height inside a runner card (state row).
const CARD_SYM_H: f32 = 20.0;
/// Mini-bar / title row height inside a runner card.
const CARD_BARS_H: f32 = 18.0;
/// Frame vertical inner-margin (each side) on a runner card.
const CARD_MARGIN_V: i8 = 10;
/// Explicit add_space between adjacent cards.
const CARD_GAP_SPACE: f32 = 8.0;
/// Pinned header row height (symbol widget).
const HEADER_H: f32 = 24.0;
/// Space added below the header before the scroll content.
const AFTER_HEADER: f32 = 8.0;

// --- Layout constants (test-only) ---
// These aggregate the draw-time constants; a change to card sizing that does
// not update CARD_SYM_H / CARD_BARS_H / CARD_MARGIN_V will break five_cards_fit.
#[cfg(test)]
const ITEM_SPACING: f32 = 4.0;
#[cfg(test)]
const CARD_H: f32 = CARD_SYM_H
    + ITEM_SPACING
    + CARD_BARS_H
    + ITEM_SPACING
    + CARD_BARS_H
    + 2.0 * CARD_MARGIN_V as f32
    + 2.0;
#[cfg(test)]
const CARD_GAP: f32 = ITEM_SPACING + CARD_GAP_SPACE;
#[cfg(test)]
const JOB_LINE_H: f32 = ITEM_SPACING + CARD_BARS_H;
const SCHTASKS: &str = r"C:\Windows\System32\schtasks.exe";
const SUPERVISOR_TASK: &str = "AAP-CRRR-Supervisor";
/// `CREATE_NO_WINDOW`: schtasks is a console program; never flash a console.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Copy)]
pub struct Palette {
    pub dark: bool,
    pub bg: Color32,
    pub card: Color32,
    pub border: Color32,
    pub text: Color32,
    pub muted: Color32,
    /// Link, focus ring and used fill.
    pub accent: Color32,
    pub track: Color32,
    pub over: Color32,
}

pub const fn hex(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

const DARK: Palette = Palette {
    dark: true,
    bg: hex(0x1E1F22),
    card: hex(0x26272B),
    border: hex(0x3A3B40),
    text: hex(0xECECEE),
    muted: hex(0xA6A8AD),
    accent: hex(0x6CB4FF),
    track: hex(0x3A3C42),
    over: hex(0xE8B04A),
};

const LIGHT: Palette = Palette {
    dark: false,
    bg: hex(0xF5F5F7),
    card: hex(0xFFFFFF),
    border: hex(0xD6D7DB),
    text: hex(0x1A1A1A),
    muted: hex(0x5C5F66),
    accent: hex(0x0B63C4),
    track: hex(0xE3E4E8),
    over: hex(0xB26E00),
};

impl Palette {
    pub fn state(&self, s: Sym) -> Color32 {
        let (dark, light) = match s {
            Sym::Off | Sym::NotInstalled | Sym::Paused => (0x9A9CA2, 0x6B6E75),
            Sym::Down | Sym::Error => (0xFF7070, 0xC62828),
            Sym::Starting => (0x6CB4FF, 0x0B63C4),
            Sym::Idle => (0xECECEE, 0x1A1A1A),
            Sym::Running => (0x4CC38A, 0x1A7F4B),
            Sym::Draining => (0xE8B04A, 0x8A5A00),
        };
        hex(if self.dark { dark } else { light })
    }
}

pub fn semibold() -> FontFamily {
    FontFamily::Name("semibold".into())
}

/// Segoe UI and Segoe UI Semibold from the Windows fonts folder, egui's fonts behind them.
fn fonts() -> egui::FontDefinitions {
    let mut f = egui::FontDefinitions::default();
    let dir = Path::new(r"C:\Windows\Fonts");
    let mut prop = f
        .families
        .get(&FontFamily::Proportional)
        .cloned()
        .unwrap_or_default();
    let mut semi = prop.clone();
    if let Ok(b) = std::fs::read(dir.join("segoeui.ttf")) {
        f.font_data
            .insert("segoe".into(), Arc::new(egui::FontData::from_owned(b)));
        prop.insert(0, "segoe".into());
        semi.insert(0, "segoe".into());
    }
    if let Ok(b) = std::fs::read(dir.join("seguisb.ttf")) {
        f.font_data
            .insert("segoe-sb".into(), Arc::new(egui::FontData::from_owned(b)));
        semi.insert(0, "segoe-sb".into());
    }
    f.families.insert(FontFamily::Proportional, prop);
    f.families.insert(semibold(), semi);
    f
}

fn visuals(p: &Palette) -> egui::Visuals {
    let mut v = if p.dark {
        egui::Visuals::dark()
    } else {
        egui::Visuals::light()
    };
    v.panel_fill = p.bg;
    v.window_fill = p.card;
    v.override_text_color = Some(p.text);
    v.weak_text_color = Some(p.muted);
    v.hyperlink_color = p.accent;
    v.window_shadow = egui::Shadow::NONE;
    v.popup_shadow = egui::Shadow::NONE;
    v.selection.stroke = Stroke::new(2.0, p.accent);
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, p.border);
    v
}

fn style(s: &mut egui::Style) {
    use egui::TextStyle;
    s.text_styles = [
        (TextStyle::Heading, FontId::new(16.0, semibold())),
        (TextStyle::Body, FontId::proportional(13.0)),
        (TextStyle::Button, FontId::proportional(13.0)),
        (TextStyle::Small, FontId::proportional(12.0)),
        (TextStyle::Monospace, FontId::monospace(12.0)),
    ]
    .into();
    s.spacing.item_spacing = vec2(8.0, 4.0);
    s.spacing.button_padding = vec2(10.0, 4.0);
    s.spacing.interact_size.y = 24.0;
}

/// `45s`, `12m 04s`, `1h 03m`.
pub fn elapsed(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m {:02}s", s / 60, s % 60),
        _ => format!("{}h {:02}m", s / 3600, s % 3600 / 60),
    }
}

/// `HH:MM` local for unix seconds and a UTC offset.
pub(crate) fn clock(t: u64, offset: i64) -> String {
    let s = (t as i64 + offset).rem_euclid(86_400);
    format!("{:02}:{:02}", s / 3600, s % 3600 / 60)
}

/// `24`, `7.5`, `4.8`: whole numbers without a decimal.
fn whole(v: f64) -> String {
    crate::settings::one_decimal(v)
}

/// `9.1` below 10, `41` above: GiB the way the mockups write them.
fn gib(v: f64) -> String {
    if v < 10.0 {
        format!("{v:.1}")
    } else {
        format!("{v:.0}")
    }
}

/// The text right of a bar: `14.2 / 24`, `41 / 72 GiB`, `9.4 / 8 over share`, and whether the
/// use is over the share.
fn bar_numbers(used: f64, share: Option<f64>, cores: bool) -> (String, bool) {
    let u = if cores {
        format!("{used:.1}")
    } else {
        gib(used)
    };
    let unit = if cores { "" } else { " GiB" };
    match share {
        Some(s) if used > s + 1e-9 => (format!("{u} / {}{unit} over share", whole(s)), true),
        Some(s) => (format!("{u} / {}{unit}", whole(s)), false),
        None => (format!("{u}{unit}"), false),
    }
}

/// Work disk bar: used fraction of the size, caption `40 free / 100 GiB · floor 15`.
/// `over` is free space under the floor. A stale status (`fresh` false, the
/// same `SAMPLE_STALE` rule as the cores and memory bars) is no sample.
fn disk_line(
    size: Option<f64>,
    free: Option<f64>,
    floor: Option<f64>,
    fresh: bool,
) -> (Option<f64>, Option<f64>, String, bool) {
    match (size, free) {
        (Some(size), Some(free))
            if fresh && size.is_finite() && free.is_finite() && size >= 0.0 && free >= 0.0 =>
        {
            let used = (size - free).max(0.0);
            let over = floor.is_some_and(|f| free < f);
            let floor_txt = floor
                .map(|f| format!(" \u{b7} floor {}", gib(f)))
                .unwrap_or_default();
            (
                Some(used),
                Some(size),
                format!("{} free / {} GiB{floor_txt}", gib(free), gib(size)),
                over,
            )
        }
        _ => (None, None, "no sample".into(), false),
    }
}

/// Copy, Open: the URL a title opens, checked again at the moment of use.
fn checked(url: &str) -> Option<&str> {
    (state::valid_job_url(url) || state::valid_run_url(url)).then_some(url)
}

/// `6.2/8`, `20/24`: a compact card's numbers, and whether the use is over the share.
fn compact_numbers(used: f64, share: Option<f64>, cores: bool) -> (String, bool) {
    let u = if cores {
        format!("{used:.1}")
    } else {
        format!("{used:.0}")
    };
    match share {
        Some(s) => (format!("{u}/{}", whole(s)), used > s + 1e-9),
        None => (u, false),
    }
}

struct Dash {
    base: PathBuf,
    snap: Snapshot,
    /// `status.json` verbatim, for Copy diagnostics.
    raw: Option<String>,
    history: History,
    /// `inbox\state.json`: what was asked for. The right column shows what is.
    desired: Desired,
    read_at: Instant,
    light: bool,
    animate: bool,
    offset: i64,
    /// The error panel replaces the right column's cards.
    panel: bool,
    settings: SettingsPanel,
    problem: Option<Class>,
    /// Log tail (`None` = not readable), read while the error panel is shown.
    log: Option<Vec<String>>,
    note: Option<(String, Instant)>,
    copied: Option<(String, Instant)>,
    /// The right column's first focusable control this frame (the F6 target).
    right_first: Option<egui::Id>,
    /// Move focus to the first control of the left (`true`) or right column.
    want_focus: Option<bool>,
    /// Latest elevated Verify/Repair, polled from the temp pointer and `jobs\<id>\`.
    job: Option<crate::helper::JobUi>,
    job_at: Instant,
    /// The GitHub setup checklist replaces the right column's cards.
    github: bool,
    setup: crate::github_setup::Store,
    /// Saw an unmet row this visit, so a later all-met state may advance.
    github_arm: bool,
    github_met_at: Option<Instant>,
}

pub fn run(base: PathBuf, view: View) -> eframe::Result {
    // A request left by a window that closed before taking it would act on this one later.
    let _ = std::fs::remove_file(request_path());
    let mut viewport = egui::ViewportBuilder::default()
        .with_title(crate::dashboard_title())
        .with_inner_size(SIZE)
        .with_min_inner_size(MIN_SIZE)
        .with_resizable(true);
    if let Some(work) = crate::win::work_area_points() {
        // ponytail: 32 pt assumed title bar; the position is not remembered.
        let (x, y, width, height) = place_window(work, SIZE, PAD, 32.0);
        viewport = viewport
            .with_inner_size([width, height])
            .with_min_inner_size([MIN_SIZE[0].min(width), MIN_SIZE[1].min(height)])
            .with_position(pos2(x, y));
    }
    let options = eframe::NativeOptions {
        viewport,
        ..Default::default()
    };
    eframe::run_native(
        "aap-runner-dashboard",
        options,
        Box::new(move |cc| {
            cc.egui_ctx.set_fonts(fonts());
            cc.egui_ctx.set_visuals_of(Theme::Dark, visuals(&DARK));
            cc.egui_ctx.set_visuals_of(Theme::Light, visuals(&LIGHT));
            cc.egui_ctx.all_styles_mut(style);
            let settings = SettingsPanel::load(&base);
            let mut d = Dash {
                base,
                snap: Snapshot::bare(Status::Unknown),
                raw: None,
                history: History::default(),
                desired: Desired::Off,
                read_at: Instant::now(),
                light: false,
                animate: true,
                offset: 0,
                panel: false,
                settings,
                problem: None,
                log: None,
                note: None,
                copied: None,
                right_first: None,
                want_focus: None,
                job: None,
                job_at: Instant::now(),
                github: false,
                setup: crate::github_setup::Store::load(crate::github_setup::path()),
                github_arm: false,
                github_met_at: None,
            };
            d.job = crate::helper::load_job(&d.base);
            d.refresh(&cc.egui_ctx);
            // Initial focus: the problem button when there is an error, otherwise none.
            if d.problem.is_some() {
                d.want_focus = Some(false);
            }
            d.open(view);
            Ok(Box::new(d))
        }),
    )
}

impl Dash {
    fn pal(&self) -> Palette {
        if self.light { LIGHT } else { DARK }
    }

    fn refresh(&mut self, ctx: &egui::Context) {
        let now = SystemTime::now();
        self.read_at = Instant::now();
        let before = self.problem;
        self.snap = state::read_status(&self.base, now);
        self.raw = state::read_bounded(&self.base.join("status.json"));
        self.history = History::load(&History::path());
        self.desired = state::read_desired(&self.base);
        self.settings.reload(&self.base);
        self.light = crate::win::apps_use_light_theme();
        ctx.set_theme(if self.light {
            Theme::Light
        } else {
            Theme::Dark
        });
        self.animate = crate::win::animations_enabled();
        self.offset = crate::win::local_offset_secs();
        let needs_log = self.panel
            || matches!(&self.snap.status, Status::Error(d) if d == problem::OLD_MANAGER);
        self.log = if needs_log || before.is_none() {
            self.read_log()
        } else {
            self.log.take()
        };
        let probe = self.log.as_deref().and_then(problem::last_probe_exit);
        self.problem = problem::current(&self.snap, probe);
        // Entering a problem shows the error panel; leaving it shows the cards again.
        if self.problem.is_some() && before.is_none() && self.snap.status != Status::Paused {
            self.panel = true;
        }
        if self.problem.is_none() {
            self.panel = false;
        }
    }

    fn read_log(&self) -> Option<Vec<String>> {
        problem::read_tail(
            &self.base.join("logs").join("supervisor.log"),
            problem::LOG_TAIL_BYTES,
        )
        .ok()
    }

    /// Show what `view` asks for: the cards, focus in the left column, or the error panel.
    fn open(&mut self, view: View) {
        match view {
            View::Status => {
                self.panel = false;
                self.github = false;
            }
            View::Settings => self.want_focus = Some(true),
            View::Diagnostics => {
                self.github = false;
                self.show_panel();
            }
            View::Github => {
                self.panel = false;
                self.github = true;
                self.github_arm = false;
                self.github_met_at = None;
                self.setup.retry();
            }
        }
    }

    /// The error panel with a fresh log tail; only while there is a problem.
    fn show_panel(&mut self) {
        if self.problem.is_none() {
            return;
        }
        if !self.panel {
            self.log = self.read_log();
        }
        self.panel = true;
    }

    fn detail(&self) -> &str {
        match &self.snap.status {
            Status::Error(d) => d,
            _ => &self.snap.detail,
        }
    }

    fn age(&self) -> Option<Duration> {
        self.snap
            .updated
            .and_then(|u| SystemTime::now().duration_since(u).ok())
    }

    fn one_liner(&self) -> Option<String> {
        self.problem
            .map(|c| problem::one_liner(c, self.detail(), self.age()))
    }

    fn anim(&self, ctx: &egui::Context, id: egui::Id, v: f32) -> f32 {
        ctx.animate_value_with_time(id, v, if self.animate { 0.15 } else { 0.0 })
    }

    fn act(&mut self, a: Action) {
        let result = match a {
            Action::Retry => state::write_retry(&self.base, SystemTime::now())
                .map(|()| "Retry requested.".to_string())
                .map_err(|e| format!("Could not request a retry: {e}")),
            Action::Settings => {
                self.want_focus = Some(true);
                return;
            }
            Action::OpenLogs => {
                crate::open_logs(&self.base);
                return;
            }
            Action::Repair => crate::helper::launch(&self.base, crate::helper::Verb::Repair)
                .map(|()| "Approve the prompt to repair.".to_string()),
            Action::RestartService => Command::new(SCHTASKS)
                .args(["/run", "/tn", SUPERVISOR_TASK])
                .creation_flags(CREATE_NO_WINDOW)
                .output()
                .map_err(|e| format!("Could not run schtasks: {e}"))
                .and_then(|o| {
                    if o.status.success() {
                        Ok("Service start requested.".to_string())
                    } else {
                        Err(format!(
                            "schtasks refused: {}",
                            String::from_utf8_lossy(&o.stderr).trim()
                        ))
                    }
                }),
        };
        let text = result.unwrap_or_else(|e| {
            state::log(&self.base, &e);
            e
        });
        self.note = Some((text, Instant::now()));
    }

    /// Plain text for the clipboard. Never `manager.conf` or the key: the tray never reads them.
    fn diagnostics(&self) -> String {
        let now = secs(SystemTime::now());
        let mut out = format!(
            "{}\nlocal time {} (unix {now}, UTC{:+03}:{:02})\nclass {:?}\ndetail {}\n\nstatus.json:\n{}\n\nlog:\n",
            crate::version(),
            clock(now, self.offset),
            self.offset / 3600,
            self.offset.abs() % 3600 / 60,
            self.problem,
            self.detail(),
            self.raw.as_deref().unwrap_or("(missing or unreadable)")
        );
        for l in self.log_lines() {
            out += &l;
            out.push('\n');
        }
        out += "\nrecent problems:\n";
        for (since, until, line) in self.recent() {
            out += &format!("{since}  {until}  {line}\n");
        }
        out
    }

    fn log_lines(&self) -> Vec<String> {
        match (&self.log, self.problem) {
            (Some(lines), Some(class)) => problem::relevant(lines, class, LOG_ROWS),
            (Some(lines), None) => lines[lines.len().saturating_sub(LOG_ROWS)..].to_vec(),
            (None, _) => Vec::new(),
        }
    }

    /// `(since, until or "now", one-liner)`, newest first: tray-seen transitions plus drain
    /// timeouts from the log.
    fn recent(&self) -> Vec<(String, String, String)> {
        let mut rows: Vec<(u64, String, String, String)> = self
            .history
            .problems
            .iter()
            .map(|p| {
                (
                    p.since,
                    clock(p.since, self.offset),
                    p.until.map_or("now".into(), |u| clock(u, self.offset)),
                    p.line.clone(),
                )
            })
            .collect();
        if let Some(lines) = &self.log {
            for (t, hm) in problem::drain_timeouts(lines) {
                let line = problem::one_liner(Class::DrainTimeout, "", None);
                rows.push((secs(t), hm.clone(), hm, line));
            }
        }
        rows.sort_by_key(|r| std::cmp::Reverse(r.0));
        rows.truncate(10);
        rows.into_iter().map(|(_, a, b, c)| (a, b, c)).collect()
    }
}

/// The 2 px focus ring, 2 px out, in the accent colour. Never removed.
pub fn ring(ui: &egui::Ui, r: &egui::Response, p: &Palette) {
    if r.has_focus() {
        ui.painter().rect_stroke(
            r.rect.expand(2.0),
            4.0,
            Stroke::new(2.0, p.accent),
            StrokeKind::Outside,
        );
    }
}

/// A plain button with the focus ring.
pub fn button(ui: &mut egui::Ui, p: &Palette, label: &str) -> egui::Response {
    let r = ui.button(label);
    ring(ui, &r, p);
    r
}

/// The filled accent button: one per view, the action that helps most.
pub fn primary_button(
    ui: &mut egui::Ui,
    p: &Palette,
    label: &str,
    enabled: bool,
) -> egui::Response {
    let on = if p.dark { hex(0x1E1F22) } else { hex(0xFFFFFF) };
    let r = ui.add_enabled(
        enabled,
        egui::Button::new(RichText::new(label).color(on)).fill(p.accent),
    );
    ring(ui, &r, p);
    r
}

/// A left-aligned label in the fixed 56 px label column.
fn fixed_label(ui: &mut egui::Ui, text: &str, h: f32) {
    fixed_label_w(ui, text, LABEL_W, h);
}

/// A left-aligned label in a fixed `w` column.
fn fixed_label_w(ui: &mut egui::Ui, text: &str, w: f32, h: f32) {
    ui.allocate_ui_with_layout(vec2(w, h), Layout::left_to_right(Align::Center), |ui| {
        ui.set_min_size(vec2(w, h));
        ui.label(text);
    });
}

fn a11y(r: &egui::Response, label: String) {
    r.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Label, true, &label));
}

/// One state symbol, painted (never a font glyph): `s` = size, stroke `max(1.5, s/12)`.
fn paint_sym(p: &egui::Painter, rect: Rect, sym: Sym, color: Color32, hole: Color32) {
    let s = rect.width();
    let c = rect.center();
    let w = (s / 12.0).max(1.5);
    match sym {
        Sym::Off => {
            p.circle_stroke(c, 0.38 * s, Stroke::new(w, color));
        }
        Sym::NotInstalled => {
            p.rect_filled(
                Rect::from_center_size(c, vec2(0.6 * s, 0.16 * s)),
                0.0,
                color,
            );
        }
        Sym::Down => {
            p.circle_stroke(c, 0.42 * s, Stroke::new(w, color));
            p.text(
                c,
                Align2::CENTER_CENTER,
                "?",
                FontId::new(0.6 * s, semibold()),
                color,
            );
        }
        Sym::Starting => {
            for dy in [-0.28, 0.0, 0.28] {
                p.circle_filled(c + vec2(0.0, dy * s), 0.09 * s, color);
            }
        }
        Sym::Idle => {
            p.circle_filled(c, 0.32 * s, color);
        }
        Sym::Running => {
            let h = 0.6 * s;
            let len = h * 0.87;
            let left = c.x - len / 3.0;
            p.add(Shape::convex_polygon(
                vec![
                    pos2(left, c.y - h / 2.0),
                    pos2(left + len, c.y),
                    pos2(left, c.y + h / 2.0),
                ],
                color,
                Stroke::NONE,
            ));
        }
        Sym::Draining => {
            let (hw, hh, bar) = (0.28 * s, 0.34 * s, 0.08 * s);
            let (top, bottom) = (c.y - hh, c.y + hh);
            p.rect_filled(
                Rect::from_min_max(
                    pos2(c.x - hw - bar / 2.0, top - bar),
                    pos2(c.x + hw + bar / 2.0, top),
                ),
                0.0,
                color,
            );
            p.rect_filled(
                Rect::from_min_max(
                    pos2(c.x - hw - bar / 2.0, bottom),
                    pos2(c.x + hw + bar / 2.0, bottom + bar),
                ),
                0.0,
                color,
            );
            for (y, apex) in [(top, c.y), (bottom, c.y)] {
                p.add(Shape::convex_polygon(
                    vec![pos2(c.x - hw, y), pos2(c.x + hw, y), pos2(c.x, apex)],
                    color,
                    Stroke::NONE,
                ));
            }
        }
        Sym::Paused => {
            for x in [c.x - 0.08 * s - 0.18 * s, c.x + 0.08 * s] {
                p.rect_filled(
                    Rect::from_min_size(pos2(x, c.y - 0.3 * s), vec2(0.18 * s, 0.6 * s)),
                    1.0,
                    color,
                );
            }
        }
        Sym::Error => {
            p.circle_filled(c, 0.42 * s, color);
            p.rect_filled(
                Rect::from_min_max(
                    pos2(c.x - 0.06 * s, c.y - 0.26 * s),
                    pos2(c.x + 0.06 * s, c.y + 0.06 * s),
                ),
                1.0,
                hole,
            );
            p.circle_filled(c + vec2(0.0, 0.18 * s), 0.065 * s, hole);
        }
    }
}

/// A symbol at `size`; `clickable` lets a click open the error panel (not a Tab stop).
fn sym_widget(
    ui: &mut egui::Ui,
    size: f32,
    sym: Sym,
    p: &Palette,
    hole: Color32,
    clickable: bool,
    label: String,
) -> egui::Response {
    let sense = if clickable {
        Sense::CLICK
    } else {
        Sense::hover()
    };
    let (rect, r) = ui.allocate_exact_size(vec2(size, size), sense);
    paint_sym(ui.painter(), rect, sym, p.state(sym), hole);
    a11y(&r, label);
    if clickable {
        r.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        r
    }
}

impl Dash {
    /// The track (the share), the fill `min(used, share)` and a 6 px over-share segment at the
    /// right end; `w` wide. No (fresh) sample: the track only.
    fn track(
        &self,
        ui: &mut egui::Ui,
        id: egui::Id,
        used: Option<f64>,
        share: Option<f64>,
        over: bool,
        w: f32,
    ) -> egui::Response {
        let p = self.pal();
        let (row, r) = ui.allocate_exact_size(vec2(w, 18.0), Sense::hover());
        let track = Rect::from_center_size(row.center(), vec2(w, BAR_H));
        ui.painter().rect_filled(track, 2.0, p.track);
        if let Some(u) = used {
            let frac = share.map_or(0.0, |s| if s > 0.0 { (u / s).min(1.0) } else { 0.0 });
            let frac = self.anim(ui.ctx(), id, frac as f32);
            if frac > 0.0 {
                let fill = Rect::from_min_size(track.min, vec2(w * frac, BAR_H));
                ui.painter().rect_filled(fill, 2.0, p.accent);
            }
            if over {
                let seg = Rect::from_min_max(pos2(track.max.x - 6.0, track.min.y), track.max);
                ui.painter().rect_filled(seg, 2.0, p.over);
            }
        }
        r
    }

    fn number_color(&self, used: Option<f64>, over: bool) -> Color32 {
        let p = self.pal();
        if over {
            p.over
        } else if used.is_none() {
            p.muted
        } else {
            p.text
        }
    }

    /// `Label  [track]  numbers`, the pool bars.
    #[allow(clippy::too_many_arguments)]
    fn bar(
        &self,
        ui: &mut egui::Ui,
        id: egui::Id,
        label: &str,
        used: Option<f64>,
        share: Option<f64>,
        cores: bool,
        track_w: f32,
        name: String,
    ) {
        ui.horizontal(|ui| {
            fixed_label(ui, label, 18.0);
            let (text, over) = match used {
                Some(u) => bar_numbers(u, share, cores),
                None => ("no sample".into(), false),
            };
            let r = self.track(ui, id, used, share, over, track_w);
            a11y(&r, format!("{name} {}", text.replace(" / ", " of ")));
            let color = self.number_color(used, over);
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(RichText::new(text).color(color));
            });
        });
    }

    /// Half of a compact card's bar row: `CPU [track] 6.2/8`, `w` wide in all.
    #[allow(clippy::too_many_arguments)]
    fn mini_bar(
        &self,
        ui: &mut egui::Ui,
        id: egui::Id,
        label: &str,
        used: Option<f64>,
        share: Option<f64>,
        cores: bool,
        w: f32,
        name: String,
    ) {
        ui.allocate_ui_with_layout(
            vec2(w, CARD_BARS_H),
            Layout::left_to_right(Align::Center),
            |ui| {
                ui.set_min_width(w);
                fixed_label_w(ui, label, 32.0, 18.0);
                let (text, over) = match used {
                    Some(u) => compact_numbers(u, share, cores),
                    None => ("no sample".into(), false),
                };
                let track_w = (ui.available_width() - 64.0).max(16.0);
                let r = self.track(ui, id, used, share, over, track_w);
                let spoken = text.replace('/', " of ");
                a11y(
                    &r,
                    if over {
                        format!("{name} {spoken} over share")
                    } else {
                        format!("{name} {spoken}")
                    },
                );
                let color = self.number_color(used, over);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ui.label(RichText::new(text).color(color).small());
                });
            },
        );
    }

    /// The pinned row: symbol, state, `N/M busy`, then `All OK` or the `1 problem` button.
    fn header_row(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let sym = self.snap.status.sym();
        let problem = self.problem;
        ui.horizontal(|ui| {
            let r = sym_widget(
                ui,
                HEADER_H,
                sym,
                &p,
                p.bg,
                problem.is_some(),
                format!("State, {}", sym.label()),
            );
            if r.clicked() && problem.is_some() {
                self.show_panel();
            }
            ui.label(
                RichText::new(sym.label())
                    .font(FontId::new(16.0, semibold()))
                    .color(p.state(sym)),
            );
            if !matches!(
                self.snap.status,
                Status::NotInstalled | Status::Off | Status::Unknown
            ) {
                ui.label(format!("{}/{} busy", self.snap.busy(), self.snap.runners()));
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if problem.is_some() {
                    let r = self.problem_button(ui);
                    self.right_first.get_or_insert(r.id);
                    if r.clicked() {
                        self.show_panel();
                    }
                } else {
                    ui.label(RichText::new("All OK").color(p.muted));
                }
            });
        });
    }

    /// Work disk next to the pool totals. `cleaning` while the manager cleans.
    fn disk_bar(&self, ui: &mut egui::Ui, track_w: f32) {
        let (used, share, text, over) = disk_line(
            self.snap.work_disk_gib,
            self.snap.work_disk_free_gb,
            self.snap.work_disk_floor_gb,
            self.fresh(),
        );
        ui.horizontal(|ui| {
            fixed_label(ui, "Disk", 18.0);
            let r = self.track(ui, egui::Id::new("pool-disk"), used, share, over, track_w);
            a11y(&r, format!("Work disk {text}"));
            let color = self.number_color(used, over);
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if self.snap.cleaning {
                    ui.label(RichText::new("cleaning").color(self.pal().muted).small());
                }
                ui.label(RichText::new(text).color(color));
            });
        });
    }

    /// Pool bars and the `IO …` / `sampled N s ago` line.
    fn pool(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let fresh = self.fresh();
        let a = self.snap.applied;
        let track_w = (ui.available_width() - LABEL_W - 130.0).clamp(80.0, 240.0);
        self.bar(
            ui,
            egui::Id::new("pool-cores"),
            "Cores",
            self.snap.pool.cpu_cores.filter(|_| fresh),
            a.job_cpus.map(f64::from),
            true,
            track_w,
            "Pool cores".into(),
        );
        self.bar(
            ui,
            egui::Id::new("pool-mem"),
            "Memory",
            self.snap.pool.mem_gib.filter(|_| fresh),
            a.job_memory_gib.map(f64::from),
            false,
            track_w,
            "Pool memory".into(),
        );
        self.disk_bar(ui, track_w);
        ui.horizontal(|ui| {
            let io = match (
                self.snap.pool.io_mbps.filter(|_| fresh),
                self.snap.job_io_mbps,
            ) {
                (Some(u), Some(c)) => format!("IO {u:.0} / {c:.0} MiB/s"),
                (Some(u), None) => format!("IO {u:.0} MiB/s"),
                (None, Some(c)) => format!("IO cap {c:.0} MiB/s"),
                (None, None) => String::new(),
            };
            ui.label(RichText::new(io).color(p.muted).small());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let text = match self
                    .snap
                    .sampled_at
                    .and_then(|t| SystemTime::now().duration_since(t).ok())
                {
                    Some(a) => format!("sampled {} ago", problem::ago(a)),
                    None => "no sample".into(),
                };
                ui.label(RichText::new(text).color(p.muted).small());
            });
        });
    }

    fn fresh(&self) -> bool {
        self.snap.sampled_at.is_some_and(|t| {
            SystemTime::now()
                .duration_since(t)
                .map_or(true, |a| a <= SAMPLE_STALE)
        })
    }

    /// The red `1 problem` button with the Error symbol.
    fn problem_button(&self, ui: &mut egui::Ui) -> egui::Response {
        let p = self.pal();
        let red = p.state(Sym::Error);
        let on_red = if p.dark { hex(0x1E1F22) } else { hex(0xFFFFFF) };
        let font = FontId::new(13.0, semibold());
        let galley = ui
            .painter()
            .layout_no_wrap("1 problem".into(), font, on_red);
        let size = vec2(8.0 + 16.0 + 6.0 + galley.size().x + 10.0, 24.0);
        let (rect, r) = ui.allocate_exact_size(size, Sense::click());
        ui.painter().rect_filled(rect, 4.0, red);
        let icon = Rect::from_min_size(
            pos2(rect.min.x + 8.0, rect.center().y - 8.0),
            vec2(16.0, 16.0),
        );
        paint_sym(ui.painter(), icon, Sym::Error, on_red, red);
        ui.painter().galley(
            pos2(icon.max.x + 6.0, rect.center().y - galley.size().y / 2.0),
            galley,
            on_red,
        );
        ring(ui, &r, &p);
        r.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, "1 problem"));
        r.on_hover_cursor(egui::CursorIcon::PointingHand)
    }

    /// Three rows: name, symbol, state and elapsed; `title · repo` on one line with the copy
    /// button; Cores and Memory side by side against this slot's share.
    fn card(&mut self, ui: &mut egui::Ui, slot: &Slot, share: (Option<f64>, Option<f64>)) {
        let p = self.pal();
        let fresh = self.fresh();
        let name = format!("Runner {}", slot.slot);
        egui::Frame::new()
            .fill(p.card)
            .stroke(Stroke::new(1.0, p.border))
            .corner_radius(4)
            .inner_margin(egui::Margin::symmetric(12, CARD_MARGIN_V))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.label(RichText::new(&name).font(FontId::new(13.0, semibold())));
                    ui.add_space(8.0);
                    let error = slot.state == Sym::Error && self.problem.is_some();
                    let r = sym_widget(
                        ui,
                        CARD_SYM_H,
                        slot.state,
                        &p,
                        p.card,
                        error,
                        format!("{name}, {}", slot.state.label()),
                    );
                    if r.clicked() && error {
                        self.show_panel();
                    }
                    ui.label(RichText::new(slot.state.label()).color(p.state(slot.state)));
                    if let Some(start) = slot.started_at.filter(|_| slot.busy()) {
                        let d = SystemTime::now().duration_since(start).unwrap_or_default();
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            ui.label(elapsed(d));
                        });
                    }
                });
                if slot.busy() || !slot.job.is_empty() {
                    self.title_row(ui, slot);
                } else {
                    ui.label(RichText::new("Waiting for a job").color(p.muted));
                }
                let idle = !slot.busy();
                let used = |v: Option<f64>| if idle { Some(0.0) } else { v.filter(|_| fresh) };
                let gap = 12.0;
                let half = (ui.available_width() - gap) / 2.0;
                ui.horizontal(|ui| {
                    ui.spacing_mut().item_spacing.x = gap;
                    self.mini_bar(
                        ui,
                        egui::Id::new(("slot-cores", slot.slot)),
                        "CPU",
                        used(slot.cpu_cores),
                        share.0,
                        true,
                        half,
                        format!("{name} cores"),
                    );
                    self.mini_bar(
                        ui,
                        egui::Id::new(("slot-mem", slot.slot)),
                        "Mem",
                        used(slot.mem_gib),
                        share.1,
                        false,
                        half,
                        format!("{name} memory"),
                    );
                });
            });
    }

    /// `title · repo` on one line with an ellipsis and the full text in a tooltip, a link when
    /// the URL checks out, then the 24 x 24 copy button.
    fn title_row(&mut self, ui: &mut egui::Ui, slot: &Slot) {
        let p = self.pal();
        let title = if slot.job.is_empty() {
            "Job"
        } else {
            slot.job.as_str()
        };
        let short = slot.repo.rsplit('/').next().unwrap_or("");
        let text = if short.is_empty() {
            title.to_owned()
        } else {
            format!("{title} \u{b7} {short}")
        };
        let link = slot.link().map(str::to_owned);
        ui.horizontal(|ui| {
            let w = ui.available_width() - if link.is_some() { 24.0 + 8.0 } else { 0.0 };
            let color = if link.is_some() { p.accent } else { p.text };
            let sense = if link.is_some() {
                Sense::click()
            } else {
                Sense::hover()
            };
            let r = ui
                .allocate_ui(vec2(w, 24.0), |ui| {
                    ui.add(
                        egui::Label::new(RichText::new(&text).color(color))
                            .truncate()
                            .show_tooltip_when_elided(false)
                            .sense(sense),
                    )
                })
                .inner;
            ring(ui, &r, &p);
            let tip = match &link {
                Some(url) => format!("{text}\n{url}"),
                None => text.clone(),
            };
            let r = r.on_hover_text(tip);
            if let Some(url) = link.as_deref() {
                self.right_first.get_or_insert(r.id);
                let r = r.on_hover_cursor(egui::CursorIcon::PointingHand);
                if r.clicked()
                    && let Some(url) = checked(url)
                    && let Err(e) = Command::new(crate::EXPLORER).arg(url).spawn()
                {
                    state::log(&self.base, &format!("open job failed: {e}"));
                }
            }
            if let Some(url) = link {
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let copied = self.copied.as_ref().is_some_and(|(u, at)| {
                        *u == url && at.elapsed() < Duration::from_millis(1500)
                    });
                    let r = copy_button(ui, &p, copied);
                    if r.clicked()
                        && let Some(url) = checked(&url)
                    {
                        ui.ctx().copy_text(url.to_owned());
                        self.copied = Some((url.to_owned(), Instant::now()));
                    }
                });
            }
        });
    }

    fn history(&self, ui: &mut egui::Ui) {
        let p = self.pal();
        ui.add_space(4.0);
        ui.label(RichText::new("Last 60 min").font(FontId::new(13.0, semibold())));
        let a = self.snap.applied;
        let now_min = secs(SystemTime::now()) / 60;
        let samples = &self.history.samples;
        let at = |minute: u64| samples.iter().rev().find(|s| s.t / 60 == minute);
        for (label, cap, pick, unit) in [
            (
                "Cores",
                a.job_cpus,
                (|s: &Sample| s.cores) as fn(&Sample) -> Option<f64>,
                "cores",
            ),
            ("Memory", a.job_memory_gib, |s: &Sample| s.gib, "GiB"),
        ] {
            ui.horizontal(|ui| {
                fixed_label(ui, label, 28.0);
                let w = ui.available_width() - 56.0;
                let (rect, _) = ui.allocate_exact_size(vec2(w, 28.0), Sense::hover());
                ui.painter().rect_filled(rect, 2.0, p.track);
                let peak = samples.iter().filter_map(pick).fold(0.0_f64, f64::max);
                let top = cap.map_or(peak, |c| f64::from(c).max(peak)).max(1e-9);
                let col_w = w / 60.0;
                for i in 0..60u64 {
                    let minute = now_min - 59 + i;
                    let x = rect.min.x + i as f32 * col_w;
                    let col = Rect::from_min_max(pos2(x, rect.min.y), pos2(x + col_w, rect.max.y));
                    let Some(s) = at(minute) else { continue };
                    if let Some(v) = pick(s) {
                        let h = ((v / top) as f32 * rect.height()).max(1.0);
                        let bar = Rect::from_min_max(
                            pos2(x, rect.max.y - h),
                            pos2(x + col_w - 1.0, rect.max.y),
                        );
                        ui.painter().rect_filled(bar, 0.0, p.accent);
                    }
                    let tip = format!(
                        "{} \u{b7} {} cores \u{b7} {} GiB",
                        clock(s.t, self.offset),
                        s.cores.map_or("-".into(), |c| format!("{c:.1}")),
                        s.gib.map_or("-".into(), gib)
                    );
                    ui.interact(col, ui.id().with((label, i)), Sense::hover())
                        .on_hover_text(tip);
                }
                if let Some(c) = cap {
                    let y = rect.max.y - (f64::from(c) / top) as f32 * rect.height();
                    ui.painter()
                        .hline(rect.x_range(), y, Stroke::new(1.0, p.muted));
                    ui.label(RichText::new(format!("cap {c}")).color(p.muted).small());
                }
                let _ = unit;
            });
        }
        let peak = |pick: fn(&Sample) -> Option<f64>| {
            samples
                .iter()
                .filter_map(|s| pick(s).map(|v| (v, s.t)))
                .max_by(|a, b| a.0.total_cmp(&b.0))
        };
        let mut text = Vec::new();
        if let Some((v, t)) = peak(|s| s.cores) {
            text.push(format!("{v:.1} cores at {}", clock(t, self.offset)));
        }
        if let Some((v, t)) = peak(|s| s.gib) {
            text.push(format!("{} GiB at {}", gib(v), clock(t, self.offset)));
        }
        let line = if text.is_empty() {
            "No samples yet".to_string()
        } else {
            format!("Peak {}", text.join(" \u{b7} "))
        };
        ui.label(RichText::new(line).color(p.muted).small());
    }

    /// The error panel (section 5) in place of the cards, with `< Back to runners` on top.
    fn error_panel(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let r = ui.add(
            egui::Button::new(RichText::new("< Back to runners").color(p.accent)).frame(false),
        );
        ring(ui, &r, &p);
        self.right_first.get_or_insert(r.id);
        if r.clicked() {
            self.panel = false;
            return;
        }
        let Some(class) = self.problem else { return };
        let sym = self.snap.status.sym();
        let color = p.state(if sym == Sym::Paused { Sym::Error } else { sym });
        ui.horizontal(|ui| {
            let (rect, _) = ui.allocate_exact_size(vec2(20.0, 20.0), Sense::hover());
            paint_sym(
                ui.painter(),
                rect,
                if sym == Sym::Down {
                    Sym::Down
                } else {
                    Sym::Error
                },
                color,
                p.bg,
            );
            ui.add(
                egui::Label::new(
                    RichText::new(self.one_liner().unwrap_or_default())
                        .font(FontId::new(16.0, semibold()))
                        .color(color),
                )
                .wrap(),
            );
        });
        self.problem_detail(ui);
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let action = class.action();
            if primary_button(ui, &p, action.label(), true).clicked() {
                self.act(action);
            }
            if button(ui, &p, "Copy diagnostics").clicked() {
                ui.ctx().copy_text(self.diagnostics());
                self.copied = Some(("diagnostics".into(), Instant::now()));
            }
            if self.copied.as_ref().is_some_and(|(u, at)| {
                u == "diagnostics" && at.elapsed() < Duration::from_millis(1500)
            }) {
                ui.label(RichText::new("Copied").color(p.muted));
            }
        });
        self.note_line(ui);
        ui.add_space(4.0);
        ui.label(RichText::new("Last 20 log lines").font(FontId::new(13.0, semibold())));
        let lines = self.log_lines();
        egui::Frame::new()
            .fill(p.card)
            .stroke(Stroke::new(1.0, p.border))
            .corner_radius(4)
            .inner_margin(egui::Margin::symmetric(8, 6))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                egui::ScrollArea::both()
                    .max_height(LOG_ROWS as f32 * 15.0)
                    .stick_to_bottom(true)
                    .show(ui, |ui| {
                        if self.log.is_none() {
                            ui.label(RichText::new("Log not readable").color(p.muted));
                        }
                        for l in &lines {
                            ui.add(
                                egui::Label::new(RichText::new(l).monospace())
                                    .wrap_mode(egui::TextWrapMode::Extend),
                            );
                        }
                    });
            });
        ui.add_space(4.0);
        ui.label(RichText::new("Recent problems").font(FontId::new(13.0, semibold())));
        let recent = self.recent();
        if recent.is_empty() {
            ui.label(RichText::new("None recorded").color(p.muted).small());
        }
        for (since, until, line) in recent {
            ui.label(RichText::new(format!("{since}  {until:<5}  {line}")).small());
        }
        ui.add_space(4.0);
        ui.label(RichText::new("About").font(FontId::new(13.0, semibold())));
        let base = &self.base;
        for (label, value) in [
            ("Version", crate::version()),
            ("Data", base.display().to_string()),
            (
                "Log",
                base.join("logs")
                    .join("supervisor.log")
                    .display()
                    .to_string(),
            ),
            ("Inbox", state::inbox(base).display().to_string()),
            ("History", History::path().display().to_string()),
        ] {
            ui.horizontal(|ui| {
                fixed_label(ui, label, 18.0);
                ui.add(
                    egui::Label::new(RichText::new(value).color(p.muted).small())
                        .selectable(true)
                        .truncate(),
                );
            });
        }
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            if ui.button("Verify install").clicked()
                && let Err(e) = crate::helper::launch(&self.base, crate::helper::Verb::Verify)
            {
                self.note = Some((e, Instant::now()));
            }
            if ui.button("Repair install").clicked()
                && let Err(e) = crate::helper::launch(&self.base, crate::helper::Verb::Repair)
            {
                self.note = Some((e, Instant::now()));
            }
        });
        if let Some(job) = &self.job {
            ui.label(RichText::new(job.summary()).small());
        }
    }

    /// The raw `detail` and since when.
    fn problem_detail(&self, ui: &mut egui::Ui) {
        let detail = self.detail().to_owned();
        if !detail.is_empty() {
            ui.add(
                egui::Label::new(RichText::new(&detail).monospace())
                    .selectable(true)
                    .wrap(),
            );
        }
        let since = self
            .log
            .as_deref()
            .and_then(|l| problem::error_since(l, &detail))
            .map(|(t, hm)| (secs(t), hm.to_owned()))
            .or_else(|| {
                self.history
                    .problems
                    .back()
                    .filter(|p| p.until.is_none())
                    .map(|p| (p.since, clock(p.since, self.offset)))
            });
        if let Some((t, hm)) = since {
            let mins = secs(SystemTime::now()).saturating_sub(t) / 60;
            ui.label(format!("Since {hm} ({mins} min)"));
        }
    }

    fn note_line(&self, ui: &mut egui::Ui) {
        if let Some((text, at)) = &self.note
            && at.elapsed() < Duration::from_secs(8)
        {
            ui.label(RichText::new(text).color(self.pal().muted).small());
        }
    }

    fn empty(&self, ui: &mut egui::Ui, text: &str) {
        ui.add_space(24.0);
        ui.vertical_centered(|ui| {
            ui.label(text);
        });
        ui.add_space(24.0);
    }

    fn github_page(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        if ui
            .add(egui::Button::new(RichText::new("< Back to runners").color(p.accent)).frame(false))
            .clicked()
        {
            self.github = false;
            return;
        }
        ui.label(RichText::new("GitHub setup").strong());
        ui.label(
            RichText::new("No token. The public API only checks that the account exists.")
                .color(p.muted)
                .small(),
        );
        let mut input = self.setup.input().to_string();
        let edit = ui.text_edit_singleline(&mut input);
        if self.right_first.is_none() {
            self.right_first = Some(edit.id);
        }
        if edit.changed() {
            self.setup.set_input(input);
        }
        let submit =
            edit.lost_focus() || (edit.has_focus() && ui.input(|i| i.key_pressed(Key::Enter)));
        if submit {
            self.setup.commit();
        }
        ui.add_space(8.0);
        let rows = self.setup.rows();
        let start = crate::github_setup::first_open(&rows);
        for row in &rows {
            let mark = match row.phase {
                crate::github_setup::Phase::Checking => "\u{2026}",
                crate::github_setup::Phase::Met => "\u{2713}",
                crate::github_setup::Phase::Unmet => "\u{2715}",
                crate::github_setup::Phase::Blocked => "\u{2013}",
            };
            let color = if row.phase == crate::github_setup::Phase::Blocked {
                p.muted
            } else {
                p.text
            };
            ui.label(RichText::new(format!("{mark}  {}", row.title)).color(color));
            if row.phase == crate::github_setup::Phase::Blocked {
                continue;
            }
            if row.show_group {
                let mut group = self.setup.group().to_string();
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Group").color(p.muted));
                    if ui.text_edit_singleline(&mut group).changed() {
                        self.setup.set_group(group);
                    }
                });
            }
            let active = Some(row.id) == start;
            if active && !row.missing.is_empty() {
                ui.label(RichText::new(&row.missing).color(p.over));
            }
            if active && !row.action.is_empty() {
                ui.label(RichText::new(&row.action).color(p.muted).small());
            }
            if let Some(link) = &row.link {
                ui.hyperlink_to(link, link);
            }
            if let Some(copy) = &row.copy {
                let mut shown = copy.clone();
                ui.add(
                    egui::TextEdit::multiline(&mut shown)
                        .code_editor()
                        .desired_width(f32::INFINITY)
                        .interactive(false),
                );
                if ui.button("Copy").clicked() {
                    ui.ctx().copy_text(copy.clone());
                }
            }
            if row.manual {
                let mut on = row.phase == crate::github_setup::Phase::Met;
                if ui.checkbox(&mut on, "Done").changed() {
                    self.setup.toggle(row.id, on);
                }
            }
            ui.add_space(6.0);
        }
        let met = rows
            .iter()
            .all(|r| r.phase == crate::github_setup::Phase::Met);
        ui.add_space(4.0);
        if ui.add_enabled(met, egui::Button::new("Next")).clicked() {
            self.github = false;
        }
    }

    /// One-line helper status shown under the header. format: `Verb · state · step · Open log`
    /// when log lines exist (CollapsingHeader, closed by default); plain muted label otherwise.
    fn job_status_line(&self, ui: &mut egui::Ui) {
        let Some(job) = &self.job else {
            return;
        };
        let p = self.pal();
        if job.lines.is_empty() {
            ui.label(RichText::new(job.summary()).small().color(p.muted));
        } else {
            egui::CollapsingHeader::new(
                RichText::new(format!("{} · Open log", job.summary()))
                    .small()
                    .color(p.muted),
            )
            .default_open(false)
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .max_height(8.0 * 15.0)
                    .stick_to_bottom(true)
                    .show(ui, |ui| {
                        for line in &job.lines {
                            ui.add(
                                egui::Label::new(RichText::new(line).monospace())
                                    .wrap_mode(egui::TextWrapMode::Extend),
                            );
                        }
                    });
            });
        }
    }

    fn right(&mut self, ui: &mut egui::Ui) {
        if self.github {
            self.github_page(ui);
            return;
        }
        let p = self.pal();
        match self.snap.status.clone() {
            _ if self.panel && self.problem.is_some() => self.error_panel(ui),
            Status::NotInstalled => self.empty(ui, "AAP Runner is not installed on this PC."),
            Status::Off => self.empty(ui, "Runners are off. No jobs are taken."),
            status => {
                self.job_status_line(ui); // helper status; pool moved to left column
                if status == Status::Paused {
                    ui.label(match self.snap.busy() {
                        0 => "Paused \u{b7} no jobs".to_string(),
                        1 => "Paused \u{b7} 1 job finishing".to_string(),
                        n => format!("Paused \u{b7} {n} jobs finishing"),
                    });
                    ui.add_space(4.0);
                }
                let n = self.snap.runners().max(1) as u32;
                let fixed = self.snap.sharing.as_deref() == Some("fixed");
                let a = self.snap.applied;
                let share = (
                    a.job_cpus.map(|c| crate::settings::cpu_share(c, n, fixed)),
                    a.job_memory_gib.map(|g| f64::from(g) / f64::from(n.max(1))),
                );
                let slots = self.snap.slots.clone();
                for (i, slot) in slots.iter().take(cards_to_draw(slots.len())).enumerate() {
                    if i > 0 {
                        ui.add_space(CARD_GAP_SPACE);
                    }
                    self.card(ui, slot, share);
                }
                if slots.is_empty() && self.problem.is_none() {
                    ui.label(RichText::new("No runner slots reported.").color(p.muted));
                }
                self.history(ui);
                self.note_line(ui);
            }
        }
    }
}

fn copy_button(ui: &mut egui::Ui, p: &Palette, copied: bool) -> egui::Response {
    if copied {
        ui.label(RichText::new("Copied").color(p.muted).small());
    }
    let (rect, r) = ui.allocate_exact_size(vec2(24.0, 24.0), Sense::click());
    if r.hovered() {
        ui.painter().rect_filled(rect, 4.0, p.track);
    }
    let stroke = Stroke::new(1.5, p.muted);
    let back = Rect::from_min_size(rect.min + vec2(6.0, 5.0), vec2(9.0, 11.0));
    let front = back.translate(vec2(3.0, 3.0));
    ui.painter()
        .rect_stroke(back, 1.5, stroke, StrokeKind::Middle);
    ui.painter().rect_filled(front, 1.5, p.card);
    ui.painter()
        .rect_stroke(front, 1.5, stroke, StrokeKind::Middle);
    ring(ui, &r, p);
    r.widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, "Copy link"));
    r.on_hover_text("Copy link")
}

impl eframe::App for Dash {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.setup.pump();
        if self.read_at.elapsed() >= REFRESH {
            if crate::window_exits_without_tray(crate::probe_tray_lock()) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
            if self.github {
                self.setup.retry();
            }
            self.refresh(&ctx);
        }
        let job_every = if self.job.as_ref().is_some_and(|j| j.active()) {
            Duration::from_millis(500)
        } else {
            Duration::from_secs(1)
        };
        if self.job_at.elapsed() >= job_every {
            self.job = crate::helper::load_job(&self.base);
            self.job_at = Instant::now();
        }
        ctx.request_repaint_after(Duration::from_secs(1));
        if let Some(view) = take_request(&request_path()) {
            self.open(view);
        }
        let (esc, f6) = ctx.input(|i| (i.key_pressed(Key::Escape), i.key_pressed(Key::F6)));
        // Esc first leaves the error panel, then closes the window.
        if self.github {
            let met = self
                .setup
                .rows()
                .iter()
                .all(|r| r.phase == crate::github_setup::Phase::Met);
            if !met {
                self.github_arm = true;
                self.github_met_at = None;
            } else if self.github_arm {
                let at = *self.github_met_at.get_or_insert_with(Instant::now);
                if crate::github_setup::ready_to_advance(true, true, at.elapsed()) {
                    self.github = false;
                    self.github_arm = false;
                    self.github_met_at = None;
                }
            }
        }
        if esc {
            if self.panel {
                self.panel = false;
            } else if self.github {
                self.github = false;
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
        let p = self.pal();
        let frame = egui::Frame::new().fill(p.bg).inner_margin(PAD as i8);
        let left = egui::Panel::left("settings")
            .exact_size(LEFT_W)
            .resizable(false)
            .frame(frame)
            .show(ui, |ui| {
                let mut focus =
                    self.settings
                        .show_top(ui, &p, &self.base, &self.snap, &mut self.desired);
                ui.add_space(8.0);
                self.pool(ui); // pool bars live in the left column
                self.settings
                    .show_bottom(ui, &p, &self.base, self.job.as_ref(), &mut focus);
                focus
            })
            .inner;
        self.right_first = None;
        egui::CentralPanel::default().frame(frame).show(ui, |ui| {
            self.header_row(ui);
            ui.add_space(AFTER_HEADER);
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| self.right(ui));
        });
        // F6: the first control of the other column.
        if f6 {
            self.want_focus = Some(!left.has);
        }
        if let Some(to_left) = self.want_focus.take()
            && let Some(id) = if to_left {
                left.first
            } else {
                self.right_first
            }
        {
            ctx.memory_mut(|m| m.request_focus(id));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn views_route_from_the_command_line() {
        for view in View::ALL {
            assert_eq!(View::from_args(&args(view.args())), Some(view), "{view:?}");
        }
        assert_eq!(
            View::from_args(&args(&["--settings"])),
            Some(View::Settings)
        );
        assert_eq!(View::from_args(&args(&["--dashboard"])), Some(View::Status));
        assert_eq!(
            View::from_args(&args(&["--dashboard", "--problem"])),
            Some(View::Diagnostics)
        );
        assert_eq!(View::from_args(&args(&[])), None, "the tray itself");
        assert_eq!(View::from_args(&args(&["--version"])), None);
        assert_eq!(View::from_args(&args(&["--problem"])), None);
    }

    #[test]
    fn views_route_through_the_request_file() {
        let base = state::temp_base("view-request");
        let path = base.join("sub").join("view.request");
        assert_eq!(take_request(&path), None, "no request");
        for view in View::ALL {
            write_request(&path, view).unwrap();
            assert_eq!(take_request(&path), Some(view));
            assert_eq!(take_request(&path), None, "taken once");
        }
        std::fs::write(&path, "nonsense").unwrap();
        assert_eq!(take_request(&path), None);
        assert!(!path.exists(), "a bad request is removed too");
        assert_eq!(request_path().file_name().unwrap(), "view.request");
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn elapsed_formats() {
        let e = |s| elapsed(Duration::from_secs(s));
        assert_eq!(e(0), "0s");
        assert_eq!(e(45), "45s");
        assert_eq!(e(60), "1m 00s");
        assert_eq!(e(12 * 60 + 4), "12m 04s");
        assert_eq!(e(3599), "59m 59s");
        assert_eq!(e(3600 + 3 * 60 + 59), "1h 03m");
        assert_eq!(e(26 * 3600), "26h 00m");
    }

    #[test]
    fn bar_numbers_read_like_the_mockups() {
        assert_eq!(
            bar_numbers(14.2, Some(24.0), true),
            ("14.2 / 24".into(), false)
        );
        assert_eq!(
            bar_numbers(41.0, Some(72.0), false),
            ("41 / 72 GiB".into(), false)
        );
        assert_eq!(
            bar_numbers(9.1, Some(24.0), false),
            ("9.1 / 24 GiB".into(), false)
        );
        assert_eq!(
            bar_numbers(9.4, Some(8.0), true),
            ("9.4 / 8 over share".into(), true)
        );
        assert_eq!(
            bar_numbers(2.0, Some(26.0 / 3.0), true),
            ("2.0 / 8.7".into(), false)
        );
        assert_eq!(bar_numbers(3.0, None, false), ("3.0 GiB".into(), false));
        assert_eq!(
            bar_numbers(4.8, Some(24.0 / 5.0), true),
            ("4.8 / 4.8".into(), false)
        );
        assert_eq!(
            bar_numbers(0.0, Some(72.0 / 5.0), false),
            ("0.0 / 14.4 GiB".into(), false)
        );
    }

    #[test]
    fn compact_numbers_read_like_the_mockup() {
        assert_eq!(
            compact_numbers(6.2, Some(8.0), true),
            ("6.2/8".into(), false)
        );
        assert_eq!(
            compact_numbers(9.4, Some(8.0), true),
            ("9.4/8".into(), true)
        );
        assert_eq!(
            compact_numbers(20.0, Some(24.0), false),
            ("20/24".into(), false)
        );
        assert_eq!(
            compact_numbers(2.0, Some(26.0 / 3.0), true),
            ("2.0/8.7".into(), false)
        );
        assert_eq!(compact_numbers(3.0, None, false), ("3".into(), false));
        assert_eq!(
            compact_numbers(4.8, Some(24.0 / 5.0), true),
            ("4.8/4.8".into(), false)
        );
        assert_eq!(
            compact_numbers(0.0, Some(72.0 / 5.0), false),
            ("0/14.4".into(), false)
        );
    }

    #[test]
    fn clock_applies_the_offset() {
        assert_eq!(clock(12 * 3600 + 2 * 60, 2 * 3600), "14:02");
        assert_eq!(clock(23 * 3600, 2 * 3600), "01:00");
        assert_eq!(clock(30 * 60, -3600), "23:30");
    }

    #[test]
    fn only_checked_urls_open_or_copy() {
        assert!(checked("https://github.com/a/b/actions/runs/1/job/2").is_some());
        assert!(checked("https://github.com/a/b/actions/runs/1").is_some());
        assert!(checked("https://github.com/a/b/actions/runs/1/job/").is_none());
        assert!(checked("javascript:alert(1)").is_none());
    }

    #[test]
    fn every_state_has_a_colour_per_theme() {
        for s in crate::mark::SYMS {
            assert_ne!(DARK.state(s), LIGHT.state(s), "{s:?}");
        }
    }

    #[test]
    fn card_count_is_the_slot_count_up_to_five() {
        for n in 0..=5 {
            assert_eq!(cards_to_draw(n), n, "{n}");
        }
        assert_eq!(cards_to_draw(6), 5);
        // Constants mirror the draw code; see CARD_H and CARD_GAP.
        assert_eq!(CARD_H, 20.0 + 4.0 + 18.0 + 4.0 + 18.0 + 20.0 + 2.0);
        assert_eq!(CARD_GAP, 4.0 + 8.0);
        assert!(right_column_height(5) <= SIZE[1]);
    }

    #[test]
    fn window_height_stays_inside_the_work_area() {
        let max = SIZE;
        let pad = PAD;
        let title = 32.0;
        // Tall monitor: the preferred 760 height, bottom-right, top inside.
        let (x, y, w, h) = place_window([0.0, 0.0, 1920.0, 1080.0], max, pad, title);
        assert_eq!((w, h), (760.0, 760.0));
        assert_eq!(y, 1080.0 - pad - 760.0 - title);
        assert!(y >= 0.0);
        assert_eq!(x, 1920.0 - pad - 760.0);
        // Short work area: height shrinks and the top is the work-area top.
        let (x, y, w, h) = place_window([10.0, 40.0, 1400.0, 500.0], max, pad, title);
        assert_eq!(w, 760.0);
        assert_eq!(h, 500.0 - 40.0 - pad - title);
        assert!(h < 760.0);
        assert_eq!(y, 40.0);
        assert!(x >= 10.0);
        // Too short for the title bar and padding: height is zero, y is the top.
        let (_, y, _, h) = place_window([0.0, 80.0, 800.0, 100.0], max, pad, title);
        assert_eq!(h, 0.0);
        assert_eq!(y, 80.0);
    }

    #[test]
    fn disk_line_names_free_size_and_floor() {
        let (used, share, text, over) = disk_line(Some(100.0), Some(40.0), Some(15.0), true);
        assert_eq!((used, share, over), (Some(60.0), Some(100.0), false));
        assert_eq!(text, "40 free / 100 GiB \u{b7} floor 15");
        assert!(disk_line(Some(100.0), Some(10.0), Some(15.0), true).3);
        let (used, share, text, over) = disk_line(None, None, None, true);
        assert_eq!((used, share, over), (None, None, false));
        assert_eq!(text, "no sample");
    }

    #[test]
    fn five_cards_fit_default_height() {
        // right_column_height uses the same named constants as the draw code.
        // A change to card layout that does not update CARD_H / CARD_GAP breaks this.
        assert!(
            right_column_height(5) <= SIZE[1],
            "five cards overflow: {:.0} > {:.0}",
            right_column_height(5),
            SIZE[1]
        );
    }

    #[test]
    fn disk_line_stale_is_no_sample_like_the_other_bars() {
        let (used, share, text, over) = disk_line(Some(100.0), Some(10.0), Some(15.0), false);
        assert_eq!((used, share, over), (None, None, false));
        assert_eq!(text, "no sample");
    }
}
