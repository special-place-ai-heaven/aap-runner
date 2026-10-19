//! `--dashboard` / `--settings` mode: the one window, in its own process (the tray's Win32 pump
//! cannot host an eframe loop). The fixed left column holds Power and the settings
//! (`settings_panel`); the right column shows only observed values: the header row, pool bars,
//! compact runner cards and the 60-minute strips, or the error panel in their place. Re-reads
//! `status.json` every 5 s and repaints every second. Bars, strips and symbols are plain
//! `Painter` calls. A second request (tray menu, a second `--settings`) arrives as a request file.

use crate::history::{History, Sample, secs};
use crate::mark::Sym;
use crate::problem::{self, Action, Class};
use crate::settings::Os;
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
    /// The identity page (org, App ids, labels, key file), in place of the runner cards.
    Identity,
    Wizard,
}

impl View {
    const ALL: [View; 6] = [
        View::Status,
        View::Settings,
        View::Diagnostics,
        View::Github,
        View::Identity,
        View::Wizard,
    ];

    /// The command line that opens the window this way.
    pub fn args(self) -> &'static [&'static str] {
        match self {
            View::Status => &["--dashboard"],
            View::Settings => &["--settings"],
            View::Diagnostics => &["--dashboard", "--problem"],
            View::Github => &["--github"],
            View::Identity => &["--identity"],
            View::Wizard => &["--setup"],
        }
    }

    /// The view a command line (without the exe) asks for; `None` = not a window command.
    pub fn from_args(args: &[String]) -> Option<View> {
        match args.first()?.as_str() {
            "--settings" => Some(View::Settings),
            "--github" => Some(View::Github),
            "--identity" => Some(View::Identity),
            "--setup" => Some(View::Wizard),
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
            View::Identity => "identity",
            View::Wizard => "wizard",
        }
    }
}

fn profile_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_default()
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

/// Default inner size. The window cannot shrink below min_size(); nothing scrolls in the left column.
const SIZE: [f32; 2] = [760.0, 924.0];

/// One card per reported slot, and no more than the runner limit.
fn cards_to_draw(slot_count: usize) -> usize {
    slot_count.min(*crate::settings::RUNNERS.end() as usize)
}

/// Windows placeholder cards after `linux` runner cards: the stored count, within five cards.
fn windows_cards_to_draw(linux: usize, windows: u32) -> u32 {
    windows.min(crate::settings::MAX_RUNNERS.saturating_sub(linux as u32))
}

/// `Linux 2`, `Windows 1`.
fn card_name(os: Os, n: u32) -> String {
    format!("{} {n}", os.name())
}

/// `Linux 0/3 busy`, and `Windows 2 not installed` while Windows runners are chosen.
fn header_counts(busy: usize, linux: usize, windows: u32) -> (String, Option<String>) {
    // ponytail: no Windows backend yet; it brings its own busy count.
    let windows = (windows > 0).then(|| format!("Windows {windows} not installed"));
    (format!("Linux {busy}/{linux} busy"), windows)
}

fn card_frame(p: &Palette) -> egui::Frame {
    egui::Frame::new()
        .fill(p.card)
        .stroke(Stroke::new(1.0, p.border))
        .corner_radius(4)
        .inner_margin(egui::Margin::symmetric(12, CARD_MARGIN_V))
}

/// The profile's colour down the card's left edge.
fn card_edge(ui: &egui::Ui, card: Rect, color: Color32) {
    let edge = Rect::from_min_max(card.min, pos2(card.min.x + 3.0, card.max.y));
    let round = egui::CornerRadius {
        nw: 4,
        sw: 4,
        ne: 0,
        se: 0,
    };
    ui.painter().rect_filled(edge, round, color);
}

fn card_height() -> f32 {
    CARD_SYM_H.max(INTERACT_H) // state row: ui.horizontal floored to interact_size.y
        + CARD_ITEM_GAP
        + CARD_TITLE_H // title / "Waiting" row: allocated explicitly to 24 px
        + CARD_ITEM_GAP
        + CARD_BARS_H.max(INTERACT_H) // bars row: ui.horizontal floored to interact_size.y
        + 2.0 * CARD_MARGIN_V as f32 // frame inner margins
        + 2.0 // frame border 1 px each side
}

fn right_column_height(slots: usize) -> f32 {
    let n = cards_to_draw(slots);
    PAD // frame top inner margin
        + HEADER_H + CARD_ITEM_GAP // header row + auto spacing
        + AFTER_HEADER // explicit add_space(AFTER_HEADER)
        + JOB_LINE_H + CARD_ITEM_GAP // job status line + auto spacing
        + JOB_STEP_H + CARD_ITEM_GAP // step / reason row (always allocated) + auto spacing
        + PAUSED_LINE_H + 4.0 + 2.0 * CARD_ITEM_GAP // Paused label + add_space(4) + gaps
        + n as f32 * card_height() // runner cards
        + n.saturating_sub(1) as f32 * (CARD_ITEM_GAP + CARD_GAP_SPACE) // inter-card gaps
        + PAD // frame bottom inner margin
}

/// Bottom-right inner size and outer position in a work area
/// `[left, top, right, bottom]`. Height is at most `max[1]` and shrinks so
/// the top stays inside the work area. Width shrinks only when it would
/// cross the left edge. `title` is the assumed title-bar height.
fn place_window(work: [f32; 4], max: [f32; 2], pad: f32, title: f32) -> (f32, f32, f32, f32) {
    let [left, top, right, bottom] = work;
    // clamped_window_height applies SIZE[1] and PAD; min(max[1]) lets tests override SIZE.
    let height = clamped_window_height(bottom - top, title).min(max[1]);
    let y = (bottom - pad - height - title).max(top);
    let mut width = max[0];
    let mut x = right - pad - width;
    if x < left {
        width = (right - left - pad).max(0.0);
        x = (right - pad - width).max(left);
    }
    (x, y, width, height)
}
/// Inner window height for a given work-area height, matching the clamp `place_window`
/// applies in `run()` when called with `max = SIZE`. `title` is the title-bar allowance
/// (32 pt in `run()`). Used in the layout test.
fn clamped_window_height(work_h: f32, title: f32) -> f32 {
    SIZE[1].min((work_h - PAD - title).max(0.0))
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
// ---- Layout constants (all used in drawing code) ----
/// Symbol widget height inside a runner card (state row).
const CARD_SYM_H: f32 = 20.0;
/// Title-row / "Waiting for a job" row height, allocated explicitly in drawing.
const CARD_TITLE_H: f32 = 24.0;
/// Mini-bar row height inside a runner card, allocated explicitly in drawing.
const CARD_BARS_H: f32 = 18.0;
/// Frame vertical inner-margin (each side) on a runner card.
const CARD_MARGIN_V: i8 = 10;
/// egui item_spacing.y, set explicitly in the right column for deterministic layout.
const CARD_ITEM_GAP: f32 = 4.0;
/// Explicit add_space between adjacent cards (CARD_ITEM_GAP auto-added on top).
const CARD_GAP_SPACE: f32 = 8.0;
/// Pinned header row height (symbol widget).
const HEADER_H: f32 = 24.0;
/// Space added below the header before the scroll content.
const AFTER_HEADER: f32 = 8.0;
/// Job status line height: CollapsingHeader header matches interact_size.y;
/// plain labels are allocated to this height for consistency.
const JOB_LINE_H: f32 = CARD_TITLE_H; // interact_size.y from style()
/// `interact_size.y` from `style()`; the minimum height of any `ui.horizontal` row.
const INTERACT_H: f32 = 24.0;
/// Conservative height of a bare body-font label (13 px × leading ≈ 16 px).
const PAUSED_LINE_H: f32 = 16.0;
/// Second status row: step / reason text (FAIL detail, declined error, STEP name).
const JOB_STEP_H: f32 = JOB_LINE_H;
/// Gap between the pool block and the footer buttons in the left column.
/// A future row that does not fit here grows SIZE[1], never adds a scrollbar.
const FOOTER_GAP: f32 = 8.0;
/// Height of a pool-bar caption row (right-aligned label, fixed allocation).
const CAPTION_H: f32 = 16.0;
/// Height of the pool-bar track row: fixed_label + track, both at BAR_ROW_H px.
const BAR_ROW_H: f32 = 18.0;
/// Fixed height for the cap-validation error label (two wrapped body-font lines).
pub(crate) const CAP_ERROR_H: f32 = 32.0;
/// Minimum inner window size: tall enough for both columns to show without clipping.
/// Height = left_column_height(true).max(right_column_height(5)) -- computed, never a literal.
fn min_size() -> [f32; 2] {
    [680.0, left_column_height(true).max(right_column_height(5))]
}

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

    /// A profile's colour: its glyph, row label and the card's left edge.
    pub fn os(&self, os: Os) -> Color32 {
        let (dark, light) = match os {
            Os::Linux => (0xF0883E, 0xB4540A),
            Os::Windows => (0x3AA0F0, 0x0067B8),
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
    s.spacing.interact_size.y = INTERACT_H;
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

/// Work disk bar: used fraction of the size, caption `40 GiB free of 100 · floor 15`.
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
                format!("{} GiB free of {}{floor_txt}", gib(free), gib(size)),
                over,
            )
        }
        _ => (None, None, "no sample".into(), false),
    }
}

/// Left-column IO cap label. Neither value is live traffic; both are caps.
/// `pool_io`: pool aggregate IO budget (snapshot `pool.io_mbps`).
/// `job_io`: per-runner IO cap from settings (`job_io_mbps`).
/// Returns an empty string when both are None.
fn pool_io_line(pool_io: Option<f64>, job_io: Option<f64>) -> String {
    match (pool_io, job_io) {
        (Some(u), Some(c)) => format!("IO cap {u:.0} pool \u{b7} {c:.0} each"),
        (Some(u), None) => format!("IO cap {u:.0} pool"),
        (None, Some(c)) => format!("IO cap {c:.0} each"),
        (None, None) => String::new(),
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
    /// The identity page replaces the right column's cards.
    identity: bool,
    ident: crate::identity::Store,
    wizard: Option<crate::wizard::Wizard>,
}

pub fn run(base: PathBuf, view: View) -> eframe::Result {
    // A request left by a window that closed before taking it would act on this one later.
    let _ = std::fs::remove_file(request_path());
    let ms = min_size();
    let default_size = [SIZE[0], SIZE[1].max(ms[1])];
    let mut viewport = egui::ViewportBuilder::default()
        .with_title(crate::dashboard_title())
        .with_inner_size(default_size)
        .with_min_inner_size(ms)
        .with_resizable(true);
    if let Some(work) = crate::win::work_area_points() {
        // ponytail: 32 pt assumed title bar; the position is not remembered.
        let (x, y, width, height) = place_window(work, default_size, PAD, 32.0);
        viewport = viewport
            .with_inner_size([width, height])
            .with_min_inner_size([ms[0].min(width), ms[1].min(height)])
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
                identity: false,
                ident: crate::identity::Store::load(crate::identity::path()),
                wizard: None,
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
        if self.wizard.is_some() {
            return;
        }
        match view {
            View::Wizard => {
                self.wizard = Some(crate::wizard::Wizard::load(
                    &self.base,
                    crate::wizard::draft_path(),
                ));
                self.panel = false;
                self.github = false;
                self.identity = false;
            }
            View::Status => {
                self.panel = false;
                self.github = false;
                self.identity = false;
            }
            View::Settings => self.want_focus = Some(true),
            View::Diagnostics => {
                self.github = false;
                self.identity = false;
                self.show_panel();
            }
            View::Github => {
                self.panel = false;
                self.identity = false;
                self.github = true;
                self.github_arm = false;
                self.github_met_at = None;
                self.setup.retry();
            }
            View::Identity => {
                self.panel = false;
                self.github = false;
                self.identity = true;
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

/// A profile glyph, painted like the state symbols: a Tux-style penguin (head, body, `hole`
/// belly and eyes, feet) for Linux, the four-pane window for Windows.
fn paint_os(pt: &egui::Painter, rect: Rect, os: Os, color: Color32, hole: Color32) {
    let s = rect.width();
    let c = rect.center();
    match os {
        Os::Windows => {
            let (half, gap) = (0.42 * s, (0.08 * s).max(1.0));
            let pane = (2.0 * half - gap) / 2.0;
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let min = pos2(
                    c.x - half + dx * (pane + gap),
                    c.y - half + dy * (pane + gap),
                );
                pt.rect_filled(Rect::from_min_size(min, vec2(pane, pane)), 0.0, color);
            }
        }
        Os::Linux => {
            let at = |dx: f32, dy: f32| pos2(c.x + dx * s, c.y + dy * s);
            pt.circle_filled(at(0.0, -0.24), 0.2 * s, color);
            pt.add(Shape::ellipse_filled(
                at(0.0, 0.1),
                vec2(0.3 * s, 0.32 * s),
                color,
            ));
            pt.add(Shape::ellipse_filled(
                at(0.0, 0.15),
                vec2(0.17 * s, 0.22 * s),
                hole,
            ));
            for dx in [-0.07, 0.07] {
                pt.circle_filled(at(dx, -0.27), (0.04 * s).max(0.8), hole);
            }
            for dx in [-0.17, 0.17] {
                pt.add(Shape::ellipse_filled(
                    at(dx, 0.42),
                    vec2(0.13 * s, 0.06 * s),
                    color,
                ));
            }
        }
    }
}

/// The profile glyph in the profile's colour, `size` square, over a `hole`-coloured background.
pub fn os_glyph(ui: &mut egui::Ui, p: &Palette, os: Os, size: f32, hole: Color32) {
    let (rect, r) = ui.allocate_exact_size(vec2(size, size), Sense::hover());
    paint_os(ui.painter(), rect, os, p.os(os), hole);
    a11y(&r, os.name().into());
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
        let (row, r) = ui.allocate_exact_size(vec2(w, BAR_ROW_H), Sense::hover());
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
        let (text, over) = match used {
            Some(u) => bar_numbers(u, share, cores),
            None => ("no sample".into(), false),
        };
        let color = self.number_color(used, over);
        // Row 1: label + track
        ui.horizontal(|ui| {
            fixed_label(ui, label, BAR_ROW_H);
            let r = self.track(ui, id, used, share, over, track_w);
            a11y(&r, format!("{name} {}", text.replace(" / ", " of ")));
        });
        // Row 2: caption in a fixed-height row -- no available_height() dependency.
        let row_w = ui.available_width();
        ui.allocate_ui_with_layout(
            vec2(row_w, CAPTION_H),
            Layout::right_to_left(Align::Center),
            |ui| {
                ui.label(RichText::new(&text).color(color));
            },
        );
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
                let (linux, windows) = header_counts(
                    self.snap.busy(),
                    self.snap.runners(),
                    self.settings.windows(),
                );
                os_glyph(ui, &p, Os::Linux, 14.0, p.bg);
                ui.label(linux);
                if let Some(windows) = windows {
                    os_glyph(ui, &p, Os::Windows, 14.0, p.bg);
                    ui.label(RichText::new(windows).color(p.muted));
                }
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

    /// Work disk bar. `cleaning` appends to the caption row (no room on track row).
    fn disk_bar(&self, ui: &mut egui::Ui, track_w: f32) {
        let (used, share, mut text, over) = disk_line(
            self.snap.work_disk_gib,
            self.snap.work_disk_free_gb,
            self.snap.work_disk_floor_gb,
            self.fresh(),
        );
        if self.snap.cleaning {
            text.push_str(" \u{b7} cleaning");
        }
        let color = self.number_color(used, over);
        // Row 1: label + track (cleaning is in the caption)
        ui.horizontal(|ui| {
            fixed_label(ui, "Disk", BAR_ROW_H);
            let r = self.track(ui, egui::Id::new("pool-disk"), used, share, over, track_w);
            a11y(&r, format!("Work disk {text}"));
        });
        // Row 2: caption (includes cleaning when active) -- no available_height().
        let row_w = ui.available_width();
        ui.allocate_ui_with_layout(
            vec2(row_w, CAPTION_H),
            Layout::right_to_left(Align::Center),
            |ui| {
                ui.label(RichText::new(&text).color(color));
            },
        );
    }

    /// Pool bars and the `IO …` / `sampled N s ago` line.
    fn pool(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let fresh = self.fresh();
        let a = self.snap.applied;
        let track_w = (ui.available_width() - LABEL_W - 8.0).clamp(80.0, 240.0);
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
        // IO cap line: fixed height; omitted when both values are None.
        let io_text = pool_io_line(
            self.snap.pool.io_mbps.filter(|_| fresh),
            self.snap.job_io_mbps,
        );
        if !io_text.is_empty() {
            let row_w = ui.available_width();
            ui.allocate_ui_with_layout(
                vec2(row_w, CAPTION_H),
                Layout::left_to_right(Align::Center),
                |ui| {
                    ui.label(RichText::new(&io_text).color(p.muted).small());
                },
            );
        }
        // Sampled-at line: right-aligned, fixed height.
        let sampled_text = match self
            .snap
            .sampled_at
            .and_then(|t| SystemTime::now().duration_since(t).ok())
        {
            Some(a) => format!("sampled {} ago", problem::ago(a)),
            None => "no sample".into(),
        };
        let row_w = ui.available_width();
        ui.allocate_ui_with_layout(
            vec2(row_w, CAPTION_H),
            Layout::right_to_left(Align::Center),
            |ui| {
                ui.label(RichText::new(&sampled_text).color(p.muted).small());
            },
        );
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
        // Every reported slot is the Linux manager's.
        let name = card_name(Os::Linux, slot.slot);
        let frame = card_frame(&p).show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = CARD_ITEM_GAP;
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                os_glyph(ui, &p, Os::Linux, 16.0, p.card);
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
                ui.allocate_ui(vec2(ui.available_width(), CARD_TITLE_H), |ui| {
                    ui.label(RichText::new("Waiting for a job").color(p.muted));
                });
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
        card_edge(ui, frame.response.rect, p.os(Os::Linux));
    }

    /// A chosen Windows runner while no Windows backend exists: the card's three rows at the
    /// same height as a runner card, saying it is not installed and starts nothing.
    fn windows_card(&mut self, ui: &mut egui::Ui, n: u32) {
        let p = self.pal();
        let name = card_name(Os::Windows, n);
        let frame = card_frame(&p).show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = CARD_ITEM_GAP;
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                os_glyph(ui, &p, Os::Windows, 16.0, p.card);
                ui.label(RichText::new(&name).font(FontId::new(13.0, semibold())));
                ui.add_space(8.0);
                sym_widget(
                    ui,
                    CARD_SYM_H,
                    Sym::NotInstalled,
                    &p,
                    p.card,
                    false,
                    format!("{name}, Not installed"),
                );
                ui.label(RichText::new("Not installed").color(p.state(Sym::NotInstalled)));
            });
            ui.allocate_ui(vec2(ui.available_width(), CARD_TITLE_H), |ui| {
                ui.label(RichText::new("Windows backend not installed").color(p.muted));
            });
            ui.horizontal(|ui| {
                ui.allocate_ui(vec2(ui.available_width(), CARD_BARS_H), |ui| {
                    ui.label(
                        RichText::new("Coming with the native Windows runner. Starts nothing.")
                            .color(p.muted)
                            .small(),
                    );
                });
            });
        });
        card_edge(ui, frame.response.rect, p.os(Os::Windows));
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
                .allocate_ui(vec2(w, CARD_TITLE_H), |ui| {
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
        if self.wizard.is_none()
            && ui
                .add(
                    egui::Button::new(RichText::new("< Back to runners").color(p.accent))
                        .frame(false),
                )
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
        if self.wizard.is_none() && ui.add_enabled(met, egui::Button::new("Next")).clicked() {
            self.open(View::Identity);
        }
    }

    fn identity_page(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        if self.wizard.is_none()
            && ui
                .add(
                    egui::Button::new(RichText::new("< Back to runners").color(p.accent))
                        .frame(false),
                )
                .clicked()
        {
            self.identity = false;
            return;
        }
        ui.label(RichText::new("Identity").strong());
        ui.label(
            RichText::new(
                "The key file stays where it is. Apply hands its path to the elevated helper, which copies it into the distro as root. Nothing here is logged.",
            )
            .color(p.muted)
            .small(),
        );
        self.job_status_line(ui);
        ui.add_space(8.0);
        let fields = self.ident.fields();
        let rows = self.ident.rows();
        let apps =
            crate::github_setup::links(crate::github_setup::Kind::Org, &fields.org).map(|l| l.apps);
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
            let mut edited: Option<String> = None;
            let hint = match row.id {
                crate::identity::RowId::Org => {
                    ui.label(RichText::new(&fields.org).monospace());
                    "From the GitHub setup page."
                }
                crate::identity::RowId::AppId => {
                    edited = self.identity_edit(ui, &fields.app_id);
                    "The App ID is on the app's settings page."
                }
                crate::identity::RowId::Installation => {
                    edited = self.identity_edit(ui, &fields.installation_id);
                    "The number at the end of the installation URL: .../settings/installations/<id>."
                }
                crate::identity::RowId::Group => {
                    edited = self.identity_edit(ui, &fields.group);
                    "The runner group from the checklist."
                }
                crate::identity::RowId::Labels => {
                    edited = self.identity_edit(ui, &fields.labels);
                    "Comma list. The manager expects self-hosted,linux plus its base label."
                }
                crate::identity::RowId::Key => {
                    ui.horizontal(|ui| {
                        edited = self.identity_edit(ui, &fields.key_path);
                        if ui.button("Browse\u{2026}").clicked() {
                            let owner = crate::win::find_window(&crate::dashboard_title());
                            let start = profile_dir().join("Downloads");
                            if let Some(picked) = crate::win::pick_pem_file(owner, &start) {
                                edited = Some(picked.display().to_string());
                            }
                        }
                    });
                    "The .pem downloaded from the app page, saved under your user profile."
                }
            };
            if let Some(value) = edited {
                match row.id {
                    crate::identity::RowId::AppId => self.ident.set_app_id(value),
                    crate::identity::RowId::Installation => self.ident.set_installation_id(value),
                    crate::identity::RowId::Group => self.ident.set_group(value),
                    crate::identity::RowId::Labels => self.ident.set_labels(value),
                    crate::identity::RowId::Key => self.ident.set_key_path(value),
                    crate::identity::RowId::Org => {}
                }
            }
            if !row.missing.is_empty() {
                ui.label(RichText::new(&row.missing).color(p.over));
            }
            ui.label(RichText::new(hint).color(p.muted).small());
            if let (crate::identity::RowId::AppId, Some(link)) = (row.id, &apps) {
                ui.hyperlink_to(link, link);
            }
            ui.add_space(6.0);
        }
        if self.wizard.is_some() {
            return;
        }
        let valid = self.ident.valid();
        let pool_reason =
            crate::identity::pool_block(self.desired == Desired::On, self.snap.status.pool_word());
        if let Some(reason) = pool_reason {
            ui.label(RichText::new(reason).color(p.over));
        }
        ui.add_space(4.0);
        if ui
            .add_enabled(
                valid.is_some() && pool_reason.is_none(),
                egui::Button::new("Apply"),
            )
            .clicked()
            && let Some(v) = valid
        {
            if let Err(e) = crate::helper::launch_identity(&self.base, &v) {
                state::log(&self.base, &e);
            }
            self.job = crate::helper::load_job(&self.base);
            self.job_at = Instant::now();
        }
    }

    /// One text field of the identity page; `Some` when the text changed this frame.
    fn wizard_ui(&mut self, ui: &mut egui::Ui) {
        use crate::wizard::{Step, all_met};
        self.setup.pump();
        self.setup.retry();
        self.ident.set_org(self.setup.org().unwrap_or_default());
        self.ident.tick(&profile_dir());
        self.setup.set_identity(self.ident.identity());
        self.wizard.as_mut().unwrap().tick(&self.base);
        let step = self.wizard.as_ref().unwrap().draft.step;
        let p = self.pal();
        let frame = egui::Frame::new().fill(p.bg).inner_margin(PAD as i8);
        egui::CentralPanel::default().frame(frame).show(ui, |ui| {
            ui.heading("Set up AAP Runner");
            ui.label(RichText::new(step.label()).color(p.accent));
            ui.label(RichText::new("Runners are available while you are logged on to Windows.").small().color(p.muted));
            ui.separator();
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                let before_fields = self.ident.fields();
                let before_target = self.setup.input().to_string();
                let mut met = false;
                match step {
                    Step::Prerequisites => {
                        let w = self.wizard.as_ref().unwrap();
                        let rows = crate::wizard::prerequisites(w.facts.as_ref(), w.error.as_deref(), crate::helper::install_location_ok(), w.draft.operator_ready);
                        met = all_met(&rows);
                        if wizard_rows(ui, &p, &rows) { self.wizard.as_mut().unwrap().recheck(); met = false; }
                        let w = self.wizard.as_mut().unwrap();
                        if ui.checkbox(&mut w.draft.operator_ready, "I verified the Ubuntu-24.04 tools and /mnt/c with the command above").changed() { w.met_at = None; w.save(); met = false; }
                    }
                    Step::Github => {
                        self.github_page(ui);
                        met = self.setup.rows().iter().all(|r| r.phase == crate::github_setup::Phase::Met);
                    }
                    Step::Identity => {
                        self.identity_page(ui);
                        self.ident.tick(&profile_dir());
                        let fields = self.ident.fields();
                        let supported = fields.group == crate::identity::GROUP_DEFAULT && crate::identity::parse_labels(&fields.labels).is_ok_and(|v| v.join(",") == crate::identity::LABELS_DEFAULT);
                        if !supported { ui.label(RichText::new("First install requires runner group aap-crrr and labels self-hosted,linux,crrr. Edit those fields above.").color(p.over)); }
                        met = self.ident.valid().is_some() && supported;
                    }
                    Step::Sizing => {
                        let w = self.wizard.as_mut().unwrap();
                        let previous = w.draft.sizing.clone();
                        let s = &mut w.draft.sizing;
                        let backend = crate::settings::WINDOWS_BACKEND;
                        let fits_linux = crate::settings::count_range(Os::Linux, s.windows_runner_count, backend);
                        let fits_windows = crate::settings::count_range(Os::Windows, s.runner_count, backend);
                        ui.horizontal(|ui| {
                            os_glyph(ui, &p, Os::Linux, 14.0, p.bg);
                            ui.label("Linux runners");
                            for n in 0..=5 { ui.add_enabled_ui(fits_linux.contains(&n), |ui| ui.selectable_value(&mut s.runner_count, n, n.to_string())); }
                        });
                        ui.horizontal(|ui| {
                            os_glyph(ui, &p, Os::Windows, 14.0, p.bg);
                            ui.label("Windows runners");
                            for n in 0..=5 { ui.add_enabled_ui(fits_windows.contains(&n), |ui| ui.selectable_value(&mut s.windows_runner_count, n, n.to_string())); }
                        });
                        ui.label(RichText::new(crate::settings_panel::WINDOWS_INERT).color(p.over).small());
                        ui.horizontal(|ui| { ui.label("Total CPUs"); ui.add(egui::DragValue::new(&mut s.job_cpus).range(1..=28)); });
                        ui.horizontal(|ui| { ui.label("Total memory (GiB)"); ui.add(egui::DragValue::new(&mut s.job_memory_gib).range(1..=80)); });
                        ui.horizontal(|ui| { ui.label("Work disk (GiB)"); ui.add(egui::DragValue::new(&mut s.work_disk_gib).range(60..=512)); });
                        for line in crate::wizard::sizing_each(s) { ui.label(line); }
                        if let Some(f) = &w.facts {
                            let (cpus, gib) = f.vm().cap();
                            ui.label(format!("Pool capacity: {cpus} CPUs, {gib} GiB after Windows/WSL headroom."));
                        }
                        if previous != *s { w.met_at = None; w.save(); }
                        let rows = crate::wizard::sizing_rows(&w.draft.sizing, w.facts.as_ref());
                        met = all_met(&rows);
                        if wizard_rows(ui, &p, &rows) { w.recheck(); met = false; }
                    }
                    Step::Install => self.wizard_install(ui),
                    Step::Done => {
                        ui.label(RichText::new("Installation completed. The supervisor has been started.").strong());
                        ui.label("The runner pool starts with your selected limits. Close setup to open the tray.");
                        if ui.button("Open tray").clicked() { ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close); }
                    }
                }
                let changed = before_fields != self.ident.fields() || before_target != self.setup.input();
                let w = self.wizard.as_mut().unwrap();
                if changed { w.met_at = None; }
                if !matches!(step, Step::Install | Step::Done) {
                    ui.separator();
                    let auto = w.advance(met && !changed, Instant::now());
                    let mut next = false;
                    ui.horizontal(|ui| {
                        if step != Step::Prerequisites && ui.button("Back").clicked() { w.go(step.previous()); }
                        next = ui.add_enabled(met && !changed, egui::Button::new("Next")).clicked();
                        if met { ui.label("Continuing in 2 seconds…"); }
                    });
                    if next || auto { w.go(step.next()); }
                }
                if let Some(error) = &w.error { ui.label(RichText::new(error).color(p.over)); }
            });
        });
    }

    fn wizard_install(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let w = self.wizard.as_ref().unwrap();
        let active = w.draft.submitted || w.job.as_ref().is_some_and(|j| j.active());
        let failed = w.launch_error.is_some()
            || w.job
                .as_ref()
                .is_some_and(|j| matches!(j.state.as_str(), "failed" | "rejected" | "declined"));
        let valid = self.ident.valid();
        let ready = !active && valid.is_some() && w.draft.sizing.check_shape().is_ok();
        let mut primary = None;
        let linux = w.draft.sizing.linux();
        ui.label(format!(
            "{} Linux runners · {} CPUs total · {} GiB total · {} GiB work disk",
            linux.runner_count, linux.job_cpus, linux.job_memory_gib, linux.work_disk_gib
        ));
        if w.draft.sizing.windows_runner_count > 0 {
            ui.label(
                RichText::new(format!(
                    "{} Windows runners chosen, not installed: they start nothing until the \
                     native Windows runner exists.",
                    w.draft.sizing.windows_runner_count
                ))
                .color(p.muted),
            );
        }
        if let Some(job) = &w.job {
            ui.label(job_status_text(&job.verb, &job.state, job.exit_code));
            ui.label(&job.step);
            egui::CollapsingHeader::new("Open log")
                .id_salt("install-log")
                .default_open(true)
                .show(ui, |ui| {
                    for line in &job.lines {
                        ui.label(RichText::new(line).monospace());
                    }
                });
            if failed {
                primary = install_failure(ui, &p, &job.step, ready);
                if ui.button("Copy diagnostics").clicked() {
                    ui.ctx().copy_text(format!(
                        "{}\n{}\n{}",
                        crate::version(),
                        job.summary(),
                        job.lines.join("\n")
                    ));
                }
            }
        } else if active {
            ui.spinner();
            ui.label("Waiting for the elevated helper. Setup can be closed and resumed. A second install will not be started.");
        } else {
            ui.label("Install asks Windows for administrator permission once, then shows each completed action here.");
        }
        if let Some(error) = &w.launch_error {
            ui.label(RichText::new(error).color(p.over));
        }
        let orphan_launch = w.draft.submitted && w.draft.process.is_none() && w.job.is_none();
        if orphan_launch {
            ui.label("No helper process or trusted job was recorded. If Windows was restarted or the permission prompt was cancelled, recover this interrupted launch.");
            if ui.button("Recover interrupted launch").clicked() {
                let w = self.wizard.as_mut().unwrap();
                w.draft.submitted = false;
                w.save();
                return;
            }
        }
        if valid.is_none() && !active {
            ui.label("Identity details or the selected key file are no longer valid. Go Back and fix the named row.");
        }
        let log_id = w.draft.job_id.clone();
        let mut launch = primary == Some(Action::Retry);
        if primary == Some(Action::OpenLogs)
            && let Some(id) = log_id
            && let Err(error) = crate::helper::open_install_log(&self.base, &id)
        {
            self.wizard.as_mut().unwrap().launch_error = Some(error);
        }
        if primary == Some(Action::Settings) {
            self.wizard
                .as_mut()
                .unwrap()
                .go(crate::wizard::Step::Sizing);
        }
        ui.horizontal(|ui| {
            if ui.add_enabled(!active, egui::Button::new("Back")).clicked() {
                self.wizard
                    .as_mut()
                    .unwrap()
                    .go(crate::wizard::Step::Sizing);
            }
            launch |= ui
                .add_enabled(
                    ready,
                    egui::Button::new(if failed { "Retry" } else { "Install" }),
                )
                .clicked();
        });
        if launch && let Some(identity) = valid {
            let w = self.wizard.as_mut().unwrap();
            w.launch_error = None;
            w.draft.submitted = true;
            if !w.save() {
                w.draft.submitted = false;
                return;
            }
            // The installer sets up the Linux pool only: its runners and their part of the totals.
            if let Err(e) =
                crate::helper::launch_install(&self.base, &identity, &w.draft.sizing.linux())
            {
                w.launch_error = Some(e);
                w.draft.submitted = false;
                w.save();
            } else {
                w.draft.job_id = crate::helper::issued_install_id();
                w.draft.process = crate::helper::install_process();
                w.save();
            }
        }
    }

    fn identity_edit(&mut self, ui: &mut egui::Ui, value: &str) -> Option<String> {
        let mut text = value.to_string();
        let r = ui.text_edit_singleline(&mut text);
        if self.right_first.is_none() {
            self.right_first = Some(r.id);
        }
        r.changed().then_some(text)
    }

    /// One-line helper status: `Verb · state · exit N` on failure,
    /// `Verb · ok` on success, `Verb · running…` while active.
    /// With log lines: a CollapsingHeader (closed by default) appends `· Open log`.
    fn job_status_line(&self, ui: &mut egui::Ui) {
        let Some(job) = &self.job else {
            return;
        };
        let p = self.pal();
        let text = job_status_text(&job.verb, &job.state, job.exit_code);
        // Line 1: summary status
        if job.lines.is_empty() {
            ui.allocate_ui(vec2(ui.available_width(), JOB_LINE_H), |ui| {
                ui.label(RichText::new(&text).small().color(p.muted));
            });
        } else {
            egui::CollapsingHeader::new(
                RichText::new(format!("{text} · Open log"))
                    .small()
                    .color(p.muted),
            )
            .default_open(false)
            .id_salt("helper-log")
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
        // Line 2: step / reason text.
        let show_step = !job.step.is_empty() && !job.step.starts_with("exit ");
        ui.allocate_ui(vec2(ui.available_width(), JOB_STEP_H), |ui| {
            if show_step {
                ui.label(RichText::new(&job.step).small().color(p.muted));
            }
        });
    }

    fn right(&mut self, ui: &mut egui::Ui) {
        if self.github {
            self.github_page(ui);
            return;
        }
        if self.identity {
            self.identity_page(ui);
            return;
        }
        self.job_status_line(ui); // shown in every state (Off, Not installed, error panel)
        let p = self.pal();
        match self.snap.status.clone() {
            _ if self.panel && self.problem.is_some() => self.error_panel(ui),
            Status::NotInstalled => self.empty(ui, "AAP Runner is not installed on this PC."),
            Status::Off => self.empty(ui, "Runners are off. No jobs are taken."),
            status => {
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
                let linux = cards_to_draw(slots.len());
                for (i, slot) in slots.iter().take(linux).enumerate() {
                    if i > 0 {
                        ui.add_space(CARD_GAP_SPACE);
                    }
                    self.card(ui, slot, share);
                }
                if slots.is_empty() && self.problem.is_none() {
                    ui.label(RichText::new("No runner slots reported.").color(p.muted));
                }
                for n in 1..=windows_cards_to_draw(linux, self.settings.windows()) {
                    ui.add_space(CARD_GAP_SPACE);
                    self.windows_card(ui, n);
                }
                self.history(ui);
                self.note_line(ui);
            }
        }
    }
}

/// Pure helper-status formatter for the right column's job status line.
/// active states append `…`, "passed" maps to "ok", non-zero exit appends `· exit N`.
fn install_failure(ui: &mut egui::Ui, p: &Palette, detail: &str, ready: bool) -> Option<Action> {
    let class = problem::classify(detail, None);
    ui.label(RichText::new(problem::one_liner(class, detail, None)).color(p.over));
    // A first install can retry or adjust sizing; existing-install repair/restart operations
    // remain outside this wizard. Other failures use the existing Open logs primary action.
    let action = match class.action() {
        Action::Retry => Action::Retry,
        Action::Settings => Action::Settings,
        _ => Action::OpenLogs,
    };
    ui.add_enabled(
        ready || action == Action::OpenLogs,
        egui::Button::new(action.label()),
    )
    .clicked()
    .then_some(action)
}

fn wizard_rows(ui: &mut egui::Ui, p: &Palette, rows: &[crate::wizard::Row]) -> bool {
    let mut recheck = false;
    for row in rows {
        let (mark, color) = match row.phase {
            crate::github_setup::Phase::Checking => ("…", p.muted),
            crate::github_setup::Phase::Met => ("✓", p.text),
            crate::github_setup::Phase::Unmet => ("✕", p.over),
            crate::github_setup::Phase::Blocked => ("–", p.muted),
        };
        ui.label(RichText::new(format!("{mark}  {}", row.title)).color(color));
        if !row.missing.is_empty() {
            ui.label(&row.missing);
        }
        if row.phase == crate::github_setup::Phase::Unmet {
            if row.link.is_none()
                && row.command.is_none()
                && ui.button(format!("Re-check {}", row.title)).clicked()
            {
                recheck = true;
            }
            if let Some(link) = row.link
                && ui.hyperlink_to("Fix / instructions", link).clicked()
            {
                recheck = true;
            }
            if let Some(command) = row.command {
                ui.label(RichText::new(command).monospace());
                if ui
                    .button(format!("Copy command for {}", row.title))
                    .clicked()
                {
                    ui.ctx().copy_text(command.into());
                    recheck = true;
                }
            }
        }
        ui.add_space(6.0);
    }
    recheck || ui.button("Re-check now").clicked()
}

fn job_status_text(verb: &str, state: &str, exit: Option<i32>) -> String {
    let v = match verb {
        "repair" => "Repair",
        "identity" => "Identity",
        "install" => "Install",
        _ => "Verify",
    };
    let ellipsis = matches!(state, "waiting" | "queued" | "running");
    let s = if state == "passed" { "ok" } else { state };
    let sfx = if ellipsis { "…" } else { "" };
    match exit.filter(|&c| c != 0) {
        Some(code) => format!("{v} · {s}{sfx} · exit {code}"),
        None => format!("{v} · {s}{sfx}"),
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
        if self.wizard.is_some() {
            self.wizard_ui(ui);
            ctx.request_repaint_after(Duration::from_millis(250));
            return;
        }
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
            // The checklist ticks its app rows from the identity page and the last Verify.
            self.ident.set_org(self.setup.org().unwrap_or_default());
            self.setup.set_identity(self.ident.identity());
            if let Some(job) = &self.job
                && job.verb == "verify"
                && let Some(ok) = job.app_token
            {
                self.setup.set_verify(crate::github_setup::Verify {
                    app_authenticates: Some(ok),
                    installation_matches: Some(ok),
                    runner_group_exists: None,
                });
            }
        }
        if self.identity {
            self.ident.set_org(self.setup.org().unwrap_or_default());
            self.ident.tick(&profile_dir());
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
                    self.github_arm = false;
                    self.github_met_at = None;
                    self.open(View::Identity);
                }
            }
        }
        if esc {
            if self.panel {
                self.panel = false;
            } else if self.github {
                self.github = false;
            } else if self.identity {
                self.identity = false;
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
                // No ScrollArea: every row is fixed height.
                // A future row that does not fit grows SIZE[1], never adds a scrollbar.
                let mut focus =
                    self.settings
                        .show_top(ui, &p, &self.base, &self.snap, &mut self.desired);
                ui.add_space(8.0);
                self.pool(ui);
                ui.add_space(FOOTER_GAP);
                self.settings.show_bottom(ui, &p, &self.base, &mut focus);
                focus
            })
            .inner;
        self.right_first = None;
        egui::CentralPanel::default().frame(frame).show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = CARD_ITEM_GAP;
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

/// Height of the left column full area (2 x PAD + settings + pool + footer buttons).
///
/// `job_line`: include the pending section (changes label + cap error + Apply/Revert).
///
/// # Row heights (all ui.horizontal rows floor to INTERACT_H = 24)
/// Every `ui.horizontal` row is INTERACT_H, including `now()` rows and pool track rows.
/// Bare `ui.label` ~ PAUSED_LINE_H. `CAP_ERROR_H` for the wrapped cap-error.
/// No row calls `available_height()` or `available_size()`.
/// A new row that does not fit grows SIZE[1], never adds a scrollbar.
fn left_column_height(job_line: bool) -> f32 {
    // settings (show_top) -- 22 items, 21 auto-gaps
    let settings = 2.0 * INTERACT_H          // Power: label row + Start/Stop row
        + 12.0                                // add_space(12)
        + INTERACT_H + INTERACT_H             // Linux + now-runners (ui.horizontal)
        + 4.0                                 // add_space(4)
        + INTERACT_H + INTERACT_H             // Each + now-each
        + INTERACT_H                          // Total
        + 4.0 + INTERACT_H + CAP_ERROR_H      // add_space(4) + Windows + not-installed note
        + INTERACT_H + INTERACT_H             // Windows Each + Total
        + 4.0 + INTERACT_H                    // add_space(4) + Host
        + 4.0 + INTERACT_H + INTERACT_H      // add_space(4) + IO cap + now-io
        + 4.0 + INTERACT_H + INTERACT_H      // add_space(4) + Sharing + now-sharing
        + 21.0 * CARD_ITEM_GAP; // 22 items -> 21 auto-gaps

    let job_row = if job_line {
        // add_space(12) + changes label + cap error + Apply/Revert + 4 auto-gaps
        CARD_ITEM_GAP
            + 12.0
            + CARD_ITEM_GAP
            + PAUSED_LINE_H
            + CARD_ITEM_GAP
            + CAP_ERROR_H
            + CARD_ITEM_GAP
            + INTERACT_H
    } else {
        0.0
    };

    // auto-gap + add_space(8) + auto-gap between settings and pool
    let to_pool = CARD_ITEM_GAP + 8.0 + CARD_ITEM_GAP;

    // pool: 3 track rows (INTERACT_H) + 3 captions + IO + sampled + 7 auto-gaps
    let pool = 3.0 * (INTERACT_H + CAPTION_H) + CAPTION_H + CAPTION_H + 7.0 * CARD_ITEM_GAP;

    // footer: FOOTER_GAP + 3 button rows + 3 auto-gaps
    let footer = FOOTER_GAP + 3.0 * INTERACT_H + 3.0 * CARD_ITEM_GAP;

    PAD + settings + job_row + to_pool + pool + CARD_ITEM_GAP + footer + PAD
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wizard_checklist_renders_missing_items_without_live_probes() {
        let context = egui::Context::default();
        let rows = crate::wizard::prerequisites(
            None,
            Some("Windows check unavailable; re-check now."),
            Ok(()),
            false,
        );
        let mut output = context.run_ui(egui::RawInput::default(), |ui| {
            egui::CentralPanel::default().show(ui, |ui| {
                assert!(!wizard_rows(ui, &DARK, &rows));
            });
        });
        assert!(!output.shapes.is_empty());
        assert!(output.shapes.iter().any(|s| matches!(&s.shape, egui::Shape::Text(t) if t.galley.text().contains("Windows check unavailable"))));
        output.textures_delta.clear();
        assert!(!crate::wizard::all_met(&rows));
    }

    #[test]
    fn installer_failure_page_shows_the_existing_class_summary_and_primary_action() {
        let context = egui::Context::default();
        let detail = "FAIL installation: operator distro has no jq";
        assert_eq!(problem::classify(detail, None), Class::Other);
        let mut output = context.run_ui(egui::RawInput::default(), |ui| {
            assert!(install_failure(ui, &DARK, detail, false).is_none());
        });
        for expected in [detail, Action::OpenLogs.label()] {
            assert!(output.shapes.iter().any(|s| matches!(&s.shape, egui::Shape::Text(t) if t.galley.text().contains(expected))), "missing {expected}");
        }
        output.textures_delta.clear();
    }

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
    fn left_column_draws_both_profiles_and_the_inert_windows_note() {
        let base = state::temp_base("dash-profiles");
        std::fs::write(
            state::inbox(&base).join("settings.json"),
            r#"{"runner_count":3,"windows_runner_count":2,"job_cpus":15,"job_memory_gib":43}"#,
        )
        .unwrap();
        let mut panel = SettingsPanel::load(&base);
        assert_eq!(panel.windows(), 2);
        let snap = Snapshot::bare(Status::Idle);
        let mut desired = Desired::On;
        let context = egui::Context::default();
        context.set_fonts(fonts()); // binds "semibold", as the window does
        let mut output = context.run_ui(egui::RawInput::default(), |ui| {
            egui::CentralPanel::default().show(ui, |ui| {
                panel.show_top(ui, &DARK, &base, &snap, &mut desired);
            });
        });
        let texts: Vec<String> = output
            .shapes
            .iter()
            .filter_map(|s| match &s.shape {
                egui::Shape::Text(t) => Some(t.galley.text().to_string()),
                _ => None,
            })
            .collect();
        for want in [
            "Linux",
            "Windows",
            "Windows backend not installed",
            "keeps 2 CPU 8 GiB",
        ] {
            assert!(
                texts.iter().any(|t| t.contains(want)),
                "missing {want}: {texts:?}"
            );
        }
        output.textures_delta.clear();
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn cards_and_header_name_each_profile() {
        assert_eq!(card_name(Os::Linux, 2), "Linux 2");
        assert_eq!(card_name(Os::Windows, 1), "Windows 1");
        assert_eq!(header_counts(0, 3, 0), ("Linux 0/3 busy".into(), None));
        assert_eq!(
            header_counts(1, 3, 2),
            (
                "Linux 1/3 busy".into(),
                Some("Windows 2 not installed".into())
            )
        );
        assert_eq!(windows_cards_to_draw(3, 2), 2);
        assert_eq!(windows_cards_to_draw(5, 2), 0, "never more than five cards");
        assert_eq!(windows_cards_to_draw(4, 2), 1);
        assert_eq!(windows_cards_to_draw(0, 4), 4);
        assert_eq!(windows_cards_to_draw(9, 1), 0);
        for p in [DARK, LIGHT] {
            let (linux, windows) = (p.os(Os::Linux), p.os(Os::Windows));
            assert_ne!(linux, windows);
            for c in [linux, windows] {
                assert_ne!(c, p.accent);
                for s in crate::mark::SYMS {
                    assert_ne!(c, p.state(s), "{s:?}");
                }
            }
        }
    }

    #[test]
    fn card_count_is_the_slot_count_up_to_five() {
        for n in 0..=5 {
            assert_eq!(cards_to_draw(n), n, "{n}");
        }
        assert_eq!(cards_to_draw(6), 5);
        // 102 = 24 + 4 + 24 + 4 + 24 + 20 + 2: each ui.horizontal row is floored to
        // INTERACT_H = 24 (interact_size.y). Computed from floor rules, not from the fn body.
        assert_eq!(card_height(), 102.0);
        assert!(right_column_height(5) <= clamped_window_height(1080.0, 32.0));
    }

    #[test]
    fn window_height_stays_inside_the_work_area() {
        let max = SIZE;
        let pad = PAD;
        let title = 32.0;
        // Tall monitor: the preferred 924 height, bottom-right, top inside.
        let (x, y, w, h) = place_window([0.0, 0.0, 1920.0, 1080.0], max, pad, title);
        assert_eq!((w, h), (760.0, 924.0));
        assert_eq!(y, 1080.0 - pad - 924.0 - title);
        assert!(y >= 0.0);
        assert_eq!(x, 1920.0 - pad - 760.0);
        // Short work area: height shrinks and the top is the work-area top.
        let (x, y, w, h) = place_window([10.0, 40.0, 1400.0, 500.0], max, pad, title);
        assert_eq!(w, 760.0);
        assert_eq!(h, 500.0 - 40.0 - pad - title);
        assert!(h < 924.0);
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
        assert_eq!(text, "40 GiB free of 100 \u{b7} floor 15");
        assert!(disk_line(Some(100.0), Some(10.0), Some(15.0), true).3);
        let (used, share, text, over) = disk_line(None, None, None, true);
        assert_eq!((used, share, over), (None, None, false));
        assert_eq!(text, "no sample");
    }

    #[test]
    fn five_cards_fit_clamped_height() {
        let h = right_column_height(5);
        // 1080 px work area: clamps to SIZE[1] = 924.
        let h_1080 = clamped_window_height(1080.0, 32.0);
        assert_eq!(h_1080, SIZE[1], "sanity: 1080p clamps to default size");
        assert!(
            h <= h_1080,
            "five cards overflow 1080p: {h:.0} > {h_1080:.0}"
        );
        // 768 px work area (laptop): clamps below SIZE[1].
        let h_768 = clamped_window_height(768.0, 32.0);
        assert!(h_768 < SIZE[1]);
        assert!(h <= h_768, "five cards overflow 768p: {h:.0} > {h_768:.0}");
    }

    #[test]
    fn job_status_text_formats_exactly() {
        assert_eq!(
            job_status_text("verify", "failed", Some(1)),
            "Verify · failed · exit 1"
        );
        assert_eq!(
            job_status_text("repair", "running", None),
            "Repair · running…"
        );
        assert_eq!(job_status_text("verify", "passed", None), "Verify · ok");
        assert_eq!(
            job_status_text("identity", "running", None),
            "Identity · running…"
        );
        assert_eq!(
            job_status_text("verify", "failed", Some(0)),
            "Verify · failed"
        ); // exit 0 not appended
    }

    #[test]
    fn pool_io_line_formats_four_cases() {
        assert_eq!(
            pool_io_line(Some(3579.0), Some(715.0)),
            "IO cap 3579 pool \u{b7} 715 each"
        );
        assert_eq!(pool_io_line(Some(3579.0), None), "IO cap 3579 pool");
        assert_eq!(pool_io_line(None, Some(715.0)), "IO cap 715 each");
        assert_eq!(pool_io_line(None, None), "");
    }

    #[test]
    fn left_column_height_fits_minimum_window() {
        // Independent row inventory (paused=true, job_line=true -- worst case).
        // No row below uses available_height(); every height is a named constant.
        // The left column has no ScrollArea; a future row that does not fit grows
        // SIZE[1] instead of adding a scrollbar.
        let rows = [
            INTERACT_H,  // Power label row
            INTERACT_H,  // Power Start/Stop . Pause/Resume row
            12.0_f32,    // add_space(12)
            INTERACT_H,  // Linux control
            INTERACT_H,  // ui.horizontal in now(): now-runners
            4.0_f32,     // add_space(4)
            INTERACT_H,  // Each
            INTERACT_H,  // ui.horizontal in now(): now-each
            INTERACT_H,  // Total
            4.0_f32,     // add_space(4)
            INTERACT_H,  // Windows control
            CAP_ERROR_H, // allocate_ui_with_layout: Windows not-installed note, two lines
            INTERACT_H,  // Windows Each
            INTERACT_H,  // Windows Total
            4.0_f32,     // add_space(4)
            INTERACT_H,  // Host reserve
            4.0_f32,     // add_space(4)
            INTERACT_H,  // IO cap
            INTERACT_H,  // ui.horizontal in now(): now-io
            4.0_f32,     // add_space(4)
            INTERACT_H,  // Sharing
            INTERACT_H,  // ui.horizontal in now(): now-sharing
            // --- pending (job_line=true) ---
            12.0_f32,      // add_space(12)
            PAUSED_LINE_H, // ui.label: "N changes not applied" (bare label)
            CAP_ERROR_H,   // allocate_ui_with_layout: cap-error, two body-font lines
            INTERACT_H,    // ui.horizontal: Apply + Revert buttons
        ];
        let pool_rows = [
            INTERACT_H, // ui.horizontal: Cores fixed_label + track
            CAPTION_H,  // Cores caption
            INTERACT_H, // ui.horizontal: Memory fixed_label + track
            CAPTION_H,  // Memory caption
            INTERACT_H, // ui.horizontal: Disk fixed_label + track
            CAPTION_H,  // Disk caption
            CAPTION_H,  // IO cap line
            CAPTION_H,  // sampled line
        ];
        // Footer: FOOTER_GAP + 3 button rows + 3 auto-gaps
        let footer_rows = [
            FOOTER_GAP, // add_space before buttons
            INTERACT_H, // Verify install
            INTERACT_H, // Repair install
            INTERACT_H, // Open logs
        ];
        let s: f32 = rows.iter().sum::<f32>() + (rows.len() - 1) as f32 * CARD_ITEM_GAP;
        let p: f32 = pool_rows.iter().sum::<f32>() + (pool_rows.len() - 1) as f32 * CARD_ITEM_GAP;
        let f: f32 =
            footer_rows.iter().sum::<f32>() + (footer_rows.len() - 1) as f32 * CARD_ITEM_GAP;
        let to_pool = CARD_ITEM_GAP + 8.0 + CARD_ITEM_GAP;
        let expected = PAD + s + to_pool + p + CARD_ITEM_GAP + f + PAD;
        assert_eq!(
            left_column_height(true),
            expected,
            "left_column_height formula drifted from the row inventory"
        );
        // The right column with 5 cards must fit the clamped window heights.
        let title = 32.0;
        let rh = right_column_height(5);
        assert!(
            rh <= clamped_window_height(1080.0, title),
            "right column overflows 1080p: {rh:.0} > {}",
            clamped_window_height(1080.0, title)
        );
        assert!(
            rh <= clamped_window_height(768.0, title),
            "right column overflows 768p: {rh:.0} > {}",
            clamped_window_height(768.0, title)
        );
    }

    #[test]
    fn min_size_height_is_consistent() {
        // min_size() is computed from the column height functions, never a literal.
        let ms = min_size();
        assert!(
            ms[1] >= left_column_height(true),
            "min_size[1]={} < left column worst={}",
            ms[1],
            left_column_height(true)
        );
        assert!(
            ms[1] >= right_column_height(5),
            "min_size[1]={} < right column 5 cards={}",
            ms[1],
            right_column_height(5)
        );
        // place_window caps the placed height at SIZE[1]: the left column must fit it.
        assert!(
            SIZE[1] >= left_column_height(true),
            "SIZE[1]={} < left column worst={}: grow SIZE[1]",
            SIZE[1],
            left_column_height(true)
        );
        // The applied default height must be >= min_size.
        let default_h = SIZE[1].max(ms[1]);
        assert!(
            default_h >= ms[1],
            "default height {default_h} < min_size[1]={}",
            ms[1]
        );
    }

    #[test]
    fn disk_line_stale_is_no_sample_like_the_other_bars() {
        let (used, share, text, over) = disk_line(Some(100.0), Some(10.0), Some(15.0), false);
        assert_eq!((used, share, over), (None, None, false));
        assert_eq!(text, "no sample");
    }
}
