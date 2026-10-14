//! `--dashboard` mode: the status window, in its own process like `--settings` (the tray's
//! Win32 pump cannot host an eframe loop). Re-reads `status.json` every 5 s, repaints every
//! second for elapsed times, and reads the tray's history mirror for the 60-minute strips and
//! Recent problems. Bars, strips and symbols are plain `Painter` calls.

use crate::history::{History, Sample, secs};
use crate::mark::Sym;
use crate::problem::{self, Action, Class};
use crate::settings;
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

const WIDTH: f32 = 440.0;
const PAD: f32 = 12.0;
const REFRESH: Duration = Duration::from_secs(5);
/// A sample older than this draws as "no sample".
const SAMPLE_STALE: Duration = Duration::from_secs(150);
const LABEL_W: f32 = 56.0;
const BAR_H: f32 = 8.0;
const LOG_ROWS: usize = 20;
const SCHTASKS: &str = r"C:\Windows\System32\schtasks.exe";
const SUPERVISOR_TASK: &str = "AAP-CRRR-Supervisor";
/// `CREATE_NO_WINDOW`: schtasks is a console program; never flash a console.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Copy)]
struct Palette {
    dark: bool,
    bg: Color32,
    card: Color32,
    border: Color32,
    text: Color32,
    muted: Color32,
    /// Link, focus ring and used fill.
    accent: Color32,
    track: Color32,
    over: Color32,
}

const fn hex(v: u32) -> Color32 {
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
    fn state(&self, s: Sym) -> Color32 {
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

fn semibold() -> FontFamily {
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
fn clock(t: u64, offset: i64) -> String {
    let s = (t as i64 + offset).rem_euclid(86_400);
    format!("{:02}:{:02}", s / 3600, s % 3600 / 60)
}

/// `24`, `7.5`: whole numbers without a decimal.
fn whole(v: f64) -> String {
    if (v - v.round()).abs() < 0.05 {
        format!("{v:.0}")
    } else {
        format!("{v:.1}")
    }
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

/// Copy, Open: the URL a title opens, checked again at the moment of use.
fn checked(url: &str) -> Option<&str> {
    (state::valid_job_url(url) || state::valid_run_url(url)).then_some(url)
}

struct Dash {
    base: PathBuf,
    snap: Snapshot,
    /// `status.json` verbatim, for Copy diagnostics.
    raw: Option<String>,
    history: History,
    paused_setting: bool,
    read_at: Instant,
    light: bool,
    animate: bool,
    offset: i64,
    /// The error panel replaces the cards.
    panel: bool,
    problem: Option<Class>,
    /// Log tail (`None` = not readable), read while the panel is open.
    log: Option<Vec<String>>,
    note: Option<(String, Instant)>,
    copied: Option<(String, Instant)>,
    /// Content height last sent to the window.
    sized: f32,
    work_area: Option<[f32; 4]>,
}

pub fn run(base: PathBuf, open_problem: bool) -> eframe::Result {
    let work_area = crate::win::work_area_points();
    let start_h = 400.0;
    let mut viewport = egui::ViewportBuilder::default()
        .with_title(crate::dashboard_title())
        .with_inner_size([WIDTH, start_h])
        .with_resizable(false)
        .with_maximize_button(false);
    if let Some([_, _, right, bottom]) = work_area {
        // ponytail: 32 pt assumed title bar until the first frame measures the real one.
        viewport = viewport.with_position(pos2(right - PAD - WIDTH, bottom - PAD - start_h - 32.0));
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
            let mut d = Dash {
                base,
                snap: Snapshot::bare(Status::Unknown),
                raw: None,
                history: History::default(),
                paused_setting: false,
                read_at: Instant::now(),
                light: false,
                animate: true,
                offset: 0,
                panel: open_problem,
                problem: None,
                log: None,
                note: None,
                copied: None,
                sized: 0.0,
                work_area,
            };
            d.refresh(&cc.egui_ctx);
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
        self.paused_setting = settings::read_settings(&self.base).paused;
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
            problem::read_tail(
                &self.base.join("logs").join("supervisor.log"),
                problem::LOG_TAIL_BYTES,
            )
            .ok()
        } else {
            self.log.take()
        };
        let probe = self.log.as_deref().and_then(problem::last_probe_exit);
        self.problem = problem::current(&self.snap, probe);
        // Entering a problem shows the panel; leaving it shows the cards again.
        if self.problem.is_some() && before.is_none() && self.snap.status != Status::Paused {
            self.panel = true;
        }
        if self.problem.is_none() {
            self.panel = false;
        }
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
                crate::open_settings(&self.base);
                return;
            }
            Action::OpenLogs => {
                crate::open_logs(&self.base);
                return;
            }
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
        match &self.log {
            Some(lines) => problem::relevant(lines, self.problem.unwrap_or(Class::Other), LOG_ROWS),
            None => Vec::new(),
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
fn ring(ui: &egui::Ui, r: &egui::Response, p: &Palette) {
    if r.has_focus() {
        ui.painter().rect_stroke(
            r.rect.expand(2.0),
            4.0,
            Stroke::new(2.0, p.accent),
            StrokeKind::Outside,
        );
    }
}

/// A left-aligned label in the fixed 56 px label column.
fn fixed_label(ui: &mut egui::Ui, text: &str, h: f32) {
    ui.allocate_ui_with_layout(
        vec2(LABEL_W, h),
        Layout::left_to_right(Align::Center),
        |ui| {
            ui.set_min_size(vec2(LABEL_W, h));
            ui.label(text);
        },
    );
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
    /// `Label  [track]  numbers`: track = share, fill = min(used, share), a 6 px over-share
    /// segment at the right end. No (fresh) sample: the track only and "no sample".
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
        let p = self.pal();
        ui.horizontal(|ui| {
            fixed_label(ui, label, 18.0);
            let (row, r) = ui.allocate_exact_size(vec2(track_w, 18.0), Sense::hover());
            let track = Rect::from_center_size(row.center(), vec2(track_w, BAR_H));
            ui.painter().rect_filled(track, 2.0, p.track);
            let (text, over) = match used {
                Some(u) => bar_numbers(u, share, cores),
                None => ("no sample".into(), false),
            };
            if let Some(u) = used {
                let frac = share.map_or(0.0, |s| if s > 0.0 { (u / s).min(1.0) } else { 0.0 });
                let frac = self.anim(ui.ctx(), id, frac as f32);
                if frac > 0.0 {
                    let fill = Rect::from_min_size(track.min, vec2(track_w * frac, BAR_H));
                    ui.painter().rect_filled(fill, 2.0, p.accent);
                }
                if over {
                    let seg = Rect::from_min_max(pos2(track.max.x - 6.0, track.min.y), track.max);
                    ui.painter().rect_filled(seg, 2.0, p.over);
                }
            }
            a11y(&r, format!("{name} {}", text.replace(" / ", " of ")));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let color = if over {
                    p.over
                } else if used.is_none() {
                    p.muted
                } else {
                    p.text
                };
                ui.label(RichText::new(text).color(color));
            });
        });
    }

    fn header(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let sym = self.snap.status.sym();
        let problem = self.problem;
        ui.horizontal(|ui| {
            let r = sym_widget(
                ui,
                24.0,
                sym,
                &p,
                p.bg,
                problem.is_some(),
                format!("State, {}", sym.label()),
            );
            if r.clicked() && problem.is_some() {
                self.panel = true;
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
                    if self.problem_button(ui).clicked() {
                        self.panel = true;
                    }
                } else {
                    ui.label(RichText::new("All OK").color(p.muted));
                }
            });
        });
        if matches!(self.snap.status, Status::NotInstalled | Status::Off) {
            return;
        }
        let fresh = self.fresh();
        let a = self.snap.applied;
        let track_w = 240.0;
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

    fn card(&mut self, ui: &mut egui::Ui, slot: &Slot, share: (Option<f64>, Option<f64>)) {
        let p = self.pal();
        let fresh = self.fresh();
        let name = format!("Runner {}", slot.slot);
        egui::Frame::new()
            .fill(p.card)
            .stroke(Stroke::new(1.0, p.border))
            .corner_radius(4)
            .inner_margin(egui::Margin::symmetric(12, 10))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.label(RichText::new(&name).font(FontId::new(13.0, semibold())));
                    ui.add_space(8.0);
                    let error = slot.state == Sym::Error && self.problem.is_some();
                    let r = sym_widget(
                        ui,
                        20.0,
                        slot.state,
                        &p,
                        p.card,
                        error,
                        format!("{name}, {}", slot.state.label()),
                    );
                    if r.clicked() && error {
                        self.panel = true;
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
                    if !slot.repo.is_empty() {
                        let short = slot.repo.rsplit('/').next().unwrap_or(&slot.repo);
                        ui.label(RichText::new(short).color(p.muted));
                    }
                } else {
                    ui.label(RichText::new("Waiting for a job").color(p.muted));
                }
                let track_w = (ui.available_width() - LABEL_W - 130.0).max(80.0);
                let idle = !slot.busy();
                let used = |v: Option<f64>| if idle { Some(0.0) } else { v.filter(|_| fresh) };
                self.bar(
                    ui,
                    egui::Id::new(("slot-cores", slot.slot)),
                    "Cores",
                    used(slot.cpu_cores),
                    share.0,
                    true,
                    track_w,
                    format!("{name} cores"),
                );
                self.bar(
                    ui,
                    egui::Id::new(("slot-mem", slot.slot)),
                    "Memory",
                    used(slot.mem_gib),
                    share.1,
                    false,
                    track_w,
                    format!("{name} memory"),
                );
            });
    }

    /// The job title as a link (two lines, then an ellipsis) and the 24 x 24 copy button.
    fn title_row(&mut self, ui: &mut egui::Ui, slot: &Slot) {
        let p = self.pal();
        let title = if slot.job.is_empty() {
            "Job".to_string()
        } else {
            slot.job.clone()
        };
        let link = slot.link().map(str::to_owned);
        ui.horizontal_top(|ui| {
            let wrap = ui.available_width() - 24.0 - 8.0;
            let color = if link.is_some() { p.accent } else { p.text };
            let mut job =
                egui::text::LayoutJob::simple(title, FontId::proportional(13.0), color, wrap);
            job.wrap.max_rows = 2;
            job.wrap.break_anywhere = false;
            job.wrap.overflow_character = Some('\u{2026}');
            ui.allocate_ui(vec2(wrap, 0.0), |ui| {
                let sense = if link.is_some() {
                    Sense::click()
                } else {
                    Sense::hover()
                };
                let r = ui.add(egui::Label::new(job).wrap().sense(sense));
                ring(ui, &r, &p);
                if let Some(url) = link.as_deref() {
                    let r = r
                        .on_hover_cursor(egui::CursorIcon::PointingHand)
                        .on_hover_text(url);
                    if r.clicked()
                        && let Some(url) = checked(url)
                        && let Err(e) = Command::new(crate::EXPLORER).arg(url).spawn()
                    {
                        state::log(&self.base, &format!("open job failed: {e}"));
                    }
                }
            });
            if let Some(url) = link {
                ui.with_layout(Layout::right_to_left(Align::Min), |ui| {
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

    fn error_panel(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let Some(class) = self.problem else { return };
        let sym = self.snap.status.sym();
        let color = p.state(if sym == Sym::Paused { Sym::Error } else { sym });
        ui.separator();
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
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let action = class.action();
            let primary = egui::Button::new(RichText::new(action.label()).color(if p.dark {
                hex(0x1E1F22)
            } else {
                hex(0xFFFFFF)
            }))
            .fill(p.accent);
            let r = ui.add(primary);
            ring(ui, &r, &p);
            if r.clicked() {
                self.act(action);
            }
            let r = ui.button("Copy diagnostics");
            ring(ui, &r, &p);
            if r.clicked() {
                ui.ctx().copy_text(self.diagnostics());
                self.copied = Some(("diagnostics".into(), Instant::now()));
            }
            if self.copied.as_ref().is_some_and(|(u, at)| {
                u == "diagnostics" && at.elapsed() < Duration::from_millis(1500)
            }) {
                ui.label(RichText::new("Copied").color(p.muted));
            }
            if action != Action::OpenLogs {
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let r = ui.button("Open logs");
                    ring(ui, &r, &p);
                    if r.clicked() {
                        self.act(Action::OpenLogs);
                    }
                });
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
    }

    fn note_line(&self, ui: &mut egui::Ui) {
        if let Some((text, at)) = &self.note
            && at.elapsed() < Duration::from_secs(8)
        {
            ui.label(RichText::new(text).color(self.pal().muted).small());
        }
    }

    fn actions(&mut self, ui: &mut egui::Ui) {
        let p = self.pal();
        let installed = self.snap.status != Status::NotInstalled;
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            ui.add_enabled_ui(installed, |ui| {
                let label = if self.paused_setting {
                    "Resume"
                } else {
                    "Pause"
                };
                let r = ui.button(label);
                ring(ui, &r, &p);
                if r.clicked() {
                    crate::toggle_pause(&self.base);
                    self.paused_setting = !self.paused_setting;
                }
                let off = self.snap.status == Status::Off;
                let r = ui.button(if off { "Start" } else { "Stop" });
                ring(ui, &r, &p);
                let r = if off {
                    r
                } else {
                    r.on_hover_text("Stops after running jobs finish")
                };
                if r.clicked() {
                    crate::set_desired(&self.base, if off { Desired::On } else { Desired::Off });
                }
                let r = ui.button("Settings\u{2026}");
                ring(ui, &r, &p);
                if r.clicked() {
                    crate::open_settings(&self.base);
                }
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let r = ui.add_enabled(
                    self.base.join("logs").is_dir(),
                    egui::Button::new("Open logs"),
                );
                ring(ui, &r, &p);
                if r.clicked() {
                    crate::open_logs(&self.base);
                }
            });
        });
    }

    fn empty(&mut self, ui: &mut egui::Ui, text: &str, button: Option<&str>) -> bool {
        let p = self.pal();
        let mut clicked = false;
        ui.add_space(24.0);
        ui.vertical_centered(|ui| {
            ui.label(text);
            if let Some(b) = button {
                ui.add_space(12.0);
                let r = ui.button(b);
                ring(ui, &r, &p);
                clicked = r.clicked();
            }
        });
        ui.add_space(24.0);
        clicked
    }

    /// Fit the window to its content and keep it bottom-right in the work area.
    fn fit(&mut self, ctx: &egui::Context, content_h: f32) {
        let h = content_h.ceil();
        if (h - self.sized).abs() < 1.0 {
            return;
        }
        self.sized = h;
        ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(vec2(WIDTH, h)));
        let (outer, inner) = ctx.input(|i| (i.viewport().outer_rect, i.viewport().inner_rect));
        if let Some([_, _, right, bottom]) = self.work_area {
            let chrome = match (outer, inner) {
                (Some(o), Some(i)) => o.height() - i.height(),
                _ => 32.0,
            };
            let w = outer.map_or(WIDTH, |o| o.width());
            ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(pos2(
                right - PAD - w,
                bottom - PAD - h - chrome,
            )));
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
        if self.read_at.elapsed() >= REFRESH {
            self.refresh(&ctx);
        }
        ctx.request_repaint_after(Duration::from_secs(1));
        if ctx.input(|i| i.key_pressed(Key::Escape)) {
            if self.panel {
                self.panel = false;
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
        let p = self.pal();
        let frame = egui::Frame::new().fill(p.bg).inner_margin(PAD as i8);
        let content_h = egui::CentralPanel::default()
            .frame(frame)
            .show(ui, |ui| {
                self.header(ui);
                ui.add_space(8.0);
                match self.snap.status.clone() {
                    Status::NotInstalled => {
                        self.empty(ui, "AAP Runner is not installed on this PC.", None);
                    }
                    Status::Off => {
                        if self.empty(
                            ui,
                            "Runners are off. No jobs are taken.",
                            Some("Start runners"),
                        ) {
                            crate::set_desired(&self.base, Desired::On);
                        }
                    }
                    _ if self.panel && self.problem.is_some() => self.error_panel(ui),
                    status => {
                        if status == Status::Paused {
                            let line = match self.snap.busy() {
                                0 => "Paused \u{b7} no jobs".to_string(),
                                1 => "Paused \u{b7} 1 job finishing".to_string(),
                                n => format!("Paused \u{b7} {n} jobs finishing"),
                            };
                            ui.horizontal(|ui| {
                                ui.label(line);
                                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                    let r = ui.button("Resume");
                                    ring(ui, &r, &p);
                                    if r.clicked() {
                                        crate::toggle_pause(&self.base);
                                        self.paused_setting = false;
                                    }
                                });
                            });
                            ui.add_space(4.0);
                        }
                        let runners = self.snap.runners().max(1) as f64;
                        let a = self.snap.applied;
                        let share = (
                            a.job_cpus.map(|c| f64::from(c) / runners),
                            a.job_memory_gib.map(|g| f64::from(g) / runners),
                        );
                        let slots = self.snap.slots.clone();
                        for (i, slot) in slots.iter().take(3).enumerate() {
                            if i > 0 {
                                ui.add_space(8.0);
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
                self.actions(ui);
                ui.min_rect().height()
            })
            .inner;
        self.fit(&ctx, content_h + 2.0 * PAD);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
