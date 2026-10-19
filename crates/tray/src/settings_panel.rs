//! The window's left column (the separate `--settings` dialog until 0.5.0): Power, then the
//! settings `inbox\settings.json` holds. Start/Stop and Pause/Resume act at once, as the menu
//! does; the Linux and Windows counts, IO cap and Sharing are edits that Apply writes. Every
//! runner gets an even share of the caps whatever its OS, shown to one decimal. The file stores
//! Linux's part of the caps; the Windows count is stored only, it starts nothing yet.

use crate::dashboard::{CAP_ERROR_H, Palette, button, primary_button, ring, semibold};
use crate::mark::Sym;
use crate::settings::{
    self, HOST_CPUS, HOST_GIB, IO_PERCENT, Os, Settings, Sharing, VmLimit, WINDOWS_BACKEND,
};
use crate::state::{Applied, Desired, Snapshot, Status};
use eframe::egui::{self, Align, FontId, Key, Layout, RichText, Sense, Stroke, StrokeKind, vec2};
use std::path::Path;

/// Left-column label width ("Windows", "Sharing").
const LABEL_W: f32 = 64.0;

const SHARING_TIP: &str = "Slice: idle share can be borrowed. Fixed: hard limit per runner.";

/// Under the Windows row while no Windows backend exists.
pub const WINDOWS_INERT: &str =
    "Windows backend not installed \u{2014} coming with the native Windows runner. Starts nothing.";

const COUNTS: [(u32, &str); 6] = [(0, "0"), (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5")];

pub struct SettingsPanel {
    /// `settings.json` as last read.
    stored: Settings,
    linux: u32,
    windows: u32,
    io_percent: u32,
    sharing: Sharing,
    vm: VmLimit,
    write_error: Option<String>,
}

/// What the window needs from the left column for keyboard focus (F6, `--settings`).
pub struct Focus {
    /// Start/Stop.
    pub first: Option<egui::Id>,
    /// A left-column control has the focus.
    pub has: bool,
}

impl Focus {
    fn track(&mut self, ui: &egui::Ui, p: &Palette, r: &egui::Response) {
        ring(ui, r, p);
        self.has |= r.has_focus();
    }
}

impl SettingsPanel {
    pub fn load(base: &Path) -> Self {
        let stored = settings::read_settings(base);
        SettingsPanel {
            stored,
            linux: stored.runner_count,
            windows: stored.windows_runner_count,
            io_percent: stored.io_percent,
            sharing: stored.sharing,
            vm: VmLimit::read(),
            write_error: None,
        }
    }

    /// Re-read the file. Inputs with no pending change follow it; pending edits stay pending.
    pub fn reload(&mut self, base: &Path) {
        let follow = self.changes() == 0;
        self.stored = settings::read_settings(base);
        if follow {
            self.revert();
        }
    }

    /// The stored Windows count (the cards show it; nothing runs it yet).
    pub fn windows(&self) -> u32 {
        self.stored.windows_runner_count
    }

    fn revert(&mut self) {
        self.linux = self.stored.runner_count;
        self.windows = self.stored.windows_runner_count;
        self.io_percent = self.stored.io_percent;
        self.sharing = self.stored.sharing;
        self.write_error = None;
    }

    /// What Apply writes: the derived limits for the edited inputs, `paused` as stored (Pause
    /// rewrites only that).
    fn edit(&self) -> Settings {
        let keep = Settings {
            io_percent: self.io_percent,
            sharing: self.sharing,
            ..Settings::default()
        };
        edited(
            &keep,
            self.linux,
            self.windows,
            self.stored.paused,
            &self.vm,
        )
    }

    /// Inputs that differ from the file.
    fn changes(&self) -> usize {
        [
            self.linux != self.stored.runner_count,
            self.windows != self.stored.windows_runner_count,
            self.io_percent != self.stored.io_percent,
            self.sharing != self.stored.sharing,
        ]
        .into_iter()
        .filter(|c| *c)
        .count()
    }

    /// Apply/Revert show while the edits (or the derived totals) differ from the file, or a save
    /// failed.
    fn pending(&self) -> bool {
        self.edit() != self.stored || self.write_error.is_some()
    }

    fn apply(&mut self, base: &Path) -> bool {
        let edit = self.edit();
        match settings::write_settings(base, &edit, &self.vm) {
            Ok(()) => {
                self.stored = edit;
                self.write_error = None;
                true
            }
            Err(e) => {
                self.write_error = Some(format!("Could not save: {e}"));
                false
            }
        }
    }

    /// Top part of the left column: Power and the settings inputs.
    /// Call `show_bottom` afterwards (with the pool block in between).
    pub fn show_top(
        &mut self,
        ui: &mut egui::Ui,
        p: &Palette,
        base: &Path,
        snap: &Snapshot,
        desired: &mut Desired,
    ) -> Focus {
        let mut focus = Focus {
            first: None,
            has: false,
        };
        let installed = snap.status != Status::NotInstalled;
        let running = running_now(snap);
        ui.add_enabled_ui(installed, |ui| {
            self.power(ui, p, base, desired, &mut focus);
            ui.add_space(12.0);
            self.inputs(ui, p, base, snap, running, &mut focus);
        });
        focus
    }

    /// Footer buttons (Verify / Repair / Open logs) in the normal left-column flow,
    /// preceded by add_space(FOOTER_GAP).  No scroll area in the left column;
    /// a new row here grows the window height (SIZE[1]), never adds a scrollbar.
    pub fn show_bottom(&mut self, ui: &mut egui::Ui, p: &Palette, base: &Path, focus: &mut Focus) {
        let verify = ui.button("Verify install");
        focus.track(ui, p, &verify);
        if verify.clicked()
            && let Err(e) = crate::helper::launch(base, crate::helper::Verb::Verify)
        {
            crate::state::log(base, &e);
        }
        let repair = ui.button("Repair install");
        focus.track(ui, p, &repair);
        if repair.clicked()
            && let Err(e) = crate::helper::launch(base, crate::helper::Verb::Repair)
        {
            crate::state::log(base, &e);
        }
        let r = ui.add_enabled(base.join("logs").is_dir(), egui::Button::new("Open logs"));
        focus.track(ui, p, &r);
        if r.clicked() {
            crate::open_logs(base);
        }
    }

    fn power(
        &mut self,
        ui: &mut egui::Ui,
        p: &Palette,
        base: &Path,
        desired: &mut Desired,
        focus: &mut Focus,
    ) {
        let on = *desired == Desired::On;
        ui.horizontal(|ui| {
            label(ui, "Power");
            ui.label(
                RichText::new(if on { "On" } else { "Off" }).font(FontId::new(13.0, semibold())),
            );
        });
        ui.horizontal(|ui| {
            let r = ui.button(if on { "Stop" } else { "Start" });
            focus.track(ui, p, &r);
            focus.first = Some(r.id);
            let r = if on {
                r.on_hover_text("Stops after running jobs finish")
            } else {
                r
            };
            if r.clicked() {
                *desired = if on { Desired::Off } else { Desired::On };
                crate::set_desired(base, *desired);
            }
            let r = ui.button(self.stored.toggle_label());
            focus.track(ui, p, &r);
            if r.clicked() {
                crate::toggle_pause(base);
                self.reload(base);
            }
        });
    }

    fn inputs(
        &mut self,
        ui: &mut egui::Ui,
        p: &Palette,
        base: &Path,
        snap: &Snapshot,
        running: Option<Applied>,
        focus: &mut Focus,
    ) {
        let vm = self.vm;
        // From before the inputs: a change shows on the next frame, which egui paints right
        // after the input event.
        let edit = self.edit();
        let (linux_each, linux_total) = profile_lines(&edit, &vm, Os::Linux);
        let (windows_each, windows_total) = profile_lines(&edit, &vm, Os::Windows);
        let fits_linux = settings::count_range(Os::Linux, self.windows, WINDOWS_BACKEND);
        let fits_windows = settings::count_range(Os::Windows, self.linux, WINDOWS_BACKEND);
        ui.horizontal(|ui| {
            os_label(ui, p, Os::Linux);
            segmented(
                ui,
                p,
                &mut self.linux,
                &COUNTS,
                |n| fits_linux.contains(&n),
                focus,
            );
        });
        now(ui, p, now_runners(running));
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            label(ui, "Each");
            ui.label(linux_each);
        });
        now(
            ui,
            p,
            now_each(running, snap.sharing.as_deref() == Some("fixed")),
        );
        ui.horizontal(|ui| {
            label(ui, "Total");
            ui.label(linux_total);
        });
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            os_label(ui, p, Os::Windows);
            segmented(
                ui,
                p,
                &mut self.windows,
                &COUNTS,
                |n| fits_windows.contains(&n),
                focus,
            )
            .on_hover_text(WINDOWS_INERT);
        });
        let row_w = ui.available_width();
        ui.allocate_ui_with_layout(
            vec2(row_w, CAP_ERROR_H),
            Layout::top_down(Align::Min),
            |ui| {
                ui.set_min_size(vec2(row_w, CAP_ERROR_H));
                ui.add(egui::Label::new(RichText::new(WINDOWS_INERT).color(p.over).small()).wrap());
            },
        );
        ui.horizontal(|ui| {
            label(ui, "Each");
            ui.label(windows_each);
        });
        ui.horizontal(|ui| {
            label(ui, "Total");
            ui.label(windows_total);
        });
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            label(ui, "Host");
            ui.label(RichText::new(host_line()).color(p.muted));
        })
        .response
        .on_hover_text("Kept for Windows and WSL; the totals above never use it.");
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            label(ui, "IO cap");
            let r = ui.add(egui::DragValue::new(&mut self.io_percent).range(IO_PERCENT));
            focus.track(ui, p, &r);
            if r.changed() {
                self.io_percent = step5(self.io_percent);
            }
            ui.label("%");
        });
        now(ui, p, now_io(running.is_some(), snap.job_io_mbps));
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            label(ui, "Sharing");
            segmented(
                ui,
                p,
                &mut self.sharing,
                &[(Sharing::Slice, "Slice"), (Sharing::Fixed, "Fixed")],
                |_| true,
                focus,
            )
            .on_hover_text(SHARING_TIP);
        });
        now(
            ui,
            p,
            now_sharing(running.is_some(), snap.sharing.as_deref()),
        );
        if !self.pending() {
            return;
        }
        ui.add_space(12.0);
        let changes = self.changes();
        ui.label(match changes {
            0 => "The stored file differs; Apply rewrites it.".to_string(),
            1 => "1 change not applied".to_string(),
            n => format!("{n} changes not applied"),
        });
        let invalid = self.edit().validate(&vm).err();
        if let Some(e) = invalid.as_ref().or(self.write_error.as_ref()) {
            let row_w = ui.available_width();
            ui.allocate_ui_with_layout(
                vec2(row_w, CAP_ERROR_H),
                Layout::top_down(Align::Min),
                |ui| {
                    ui.add(egui::Label::new(RichText::new(e).color(p.state(Sym::Error))).wrap());
                },
            );
        }
        ui.horizontal(|ui| {
            let r = primary_button(ui, p, "Apply", invalid.is_none());
            focus.has |= r.has_focus();
            if r.clicked() {
                self.apply(base);
            }
            let r = button(ui, p, "Revert");
            focus.has |= r.has_focus();
            if r.clicked() {
                self.stored = settings::read_settings(base);
                self.revert();
            }
        });
    }
}

fn label(ui: &mut egui::Ui, text: &str) {
    ui.allocate_ui_with_layout(
        vec2(LABEL_W, 24.0),
        Layout::left_to_right(Align::Center),
        |ui| {
            ui.set_min_size(vec2(LABEL_W, 24.0));
            ui.label(text);
        },
    );
}

/// The row label for a profile, in its colour with its glyph.
fn os_label(ui: &mut egui::Ui, p: &Palette, os: Os) {
    ui.allocate_ui_with_layout(
        vec2(LABEL_W, 24.0),
        Layout::left_to_right(Align::Center),
        |ui| {
            ui.set_min_size(vec2(LABEL_W, 24.0));
            ui.spacing_mut().item_spacing.x = 3.0;
            crate::dashboard::os_glyph(ui, p, os, 12.0, p.bg);
            ui.label(
                RichText::new(os.name())
                    .font(FontId::new(13.0, semibold()))
                    .color(p.os(os)),
            );
        },
    );
}

/// A muted `now …` line, indented under the input.
fn now(ui: &mut egui::Ui, p: &Palette, text: String) {
    ui.horizontal(|ui| {
        ui.add_space(LABEL_W + ui.spacing().item_spacing.x);
        ui.label(RichText::new(text).color(p.muted).small());
    });
}

/// Equal cells, the selected one filled with the accent; cells `allowed` refuses are greyed and
/// inert. Cells shrink to share the row width. Only the selected cell is a Tab stop; Left and
/// Right move the selection to an allowed neighbour while it has focus. Returns the group's
/// response.
fn segmented<T: Copy + PartialEq>(
    ui: &mut egui::Ui,
    p: &Palette,
    value: &mut T,
    options: &[(T, &str)],
    allowed: impl Fn(T) -> bool,
    focus: &mut Focus,
) -> egui::Response {
    let on_accent = if p.dark {
        crate::dashboard::hex(0x1E1F22)
    } else {
        crate::dashboard::hex(0xFFFFFF)
    };
    let enabled = ui.is_enabled();
    let fit = (ui.available_width() / options.len().max(1) as f32).floor();
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 0.0;
        let mut ids = Vec::with_capacity(options.len());
        let mut focused = None;
        for (i, (v, text)) in options.iter().enumerate() {
            let selected = *value == *v;
            let ok = allowed(*v);
            let color = if selected {
                on_accent
            } else if ok {
                p.text
            } else {
                p.muted.gamma_multiply(0.5)
            };
            let galley =
                ui.painter()
                    .layout_no_wrap((*text).into(), FontId::proportional(13.0), color);
            let w = galley.size().x;
            let size = vec2((w + 20.0).max(32.0).min(fit.max(w + 8.0)), 24.0);
            let sense = if selected {
                Sense::click()
            } else if ok {
                Sense::CLICK
            } else {
                Sense::hover()
            };
            let (rect, r) = ui.allocate_exact_size(size, sense);
            let fill = if selected {
                p.accent
            } else if !ok {
                p.bg
            } else if r.hovered() && enabled {
                p.track
            } else {
                p.card
            };
            ui.painter().rect_filled(rect, 0.0, fill);
            ui.painter()
                .rect_stroke(rect, 0.0, Stroke::new(1.0, p.border), StrokeKind::Inside);
            ui.painter()
                .galley(rect.center() - galley.size() / 2.0, galley, color);
            r.widget_info(|| {
                egui::WidgetInfo::selected(
                    egui::WidgetType::RadioButton,
                    enabled && ok,
                    selected,
                    *text,
                )
            });
            focus.track(ui, p, &r);
            if r.clicked() && ok {
                *value = *v;
            }
            if r.has_focus() {
                focused = Some(i);
            }
            ids.push(r.id);
        }
        if let Some(i) = focused {
            let (left, right) = ui.input(|inp| {
                (
                    inp.key_pressed(Key::ArrowLeft),
                    inp.key_pressed(Key::ArrowRight),
                )
            });
            let to = match (left, right) {
                (true, false) => i.checked_sub(1),
                (false, true) => (i + 1 < options.len()).then_some(i + 1),
                _ => None,
            }
            .filter(|&j| allowed(options[j].0));
            if let Some(j) = to {
                *value = options[j].0;
                ui.memory_mut(|m| m.request_focus(ids[j]));
            }
        }
    })
    .response
}

/// One profile's `Each` (`8.7 CPU 24 GiB`, `-` with no runners) and `Total`
/// (`15/26 CPU · 43/72 GiB`, its part against the caps). Linux's part is what the file stores;
/// Windows has the rest of the caps.
fn profile_lines(edit: &Settings, vm: &VmLimit, os: Os) -> (String, String) {
    let (cap_cpus, cap_gib) = vm.cap();
    let (n, cpus, gib) = match os {
        Os::Linux => (edit.runner_count, edit.job_cpus, edit.job_memory_gib),
        Os::Windows => (
            edit.windows_runner_count,
            cap_cpus.saturating_sub(edit.job_cpus),
            cap_gib.saturating_sub(edit.job_memory_gib),
        ),
    };
    let each = if n == 0 {
        "-".to_string()
    } else {
        format!(
            "{} CPU {} GiB",
            settings::one_decimal(settings::cpu_share(cpus, n, edit.sharing == Sharing::Fixed)),
            settings::share_text(gib, n)
        )
    };
    (
        each,
        format!("{cpus}/{cap_cpus} CPU \u{b7} {gib}/{cap_gib} GiB"),
    )
}

/// `keeps 2 CPU 8 GiB`: the reserve the caps leave for Windows and WSL itself.
fn host_line() -> String {
    format!("keeps {HOST_CPUS} CPU {HOST_GIB} GiB")
}

/// IO cap moves in steps of 5.
fn step5(v: u32) -> u32 {
    ((v + 2) / 5 * 5).min(*IO_PERCENT.end())
}

/// What Apply writes: the derived limits with the IO cap and sharing mode from `keep`.
fn edited(keep: &Settings, linux: u32, windows: u32, paused: bool, vm: &VmLimit) -> Settings {
    Settings {
        io_percent: keep.io_percent,
        sharing: keep.sharing,
        ..Settings::derived(linux, windows, paused, vm)
    }
}

/// The applied limits while the manager has runner slots (starting, idle, running, draining).
fn running_now(snap: &Snapshot) -> Option<Applied> {
    matches!(
        snap.status,
        Status::Starting | Status::Idle | Status::Running(_) | Status::Draining
    )
    .then_some(snap.applied)
}

/// Nothing runs, or the supervisor did not report the value.
const NONE: &str = "now -";

fn now_runners(running: Option<Applied>) -> String {
    running
        .and_then(|a| a.runner_count)
        .map_or(NONE.into(), |n| format!("now {n}"))
}

/// `now 4.8 CPU 14.4 GiB`: the reported totals divided by the reported runner count.
fn now_each(running: Option<Applied>, fixed: bool) -> String {
    let Some(a) = running else {
        return NONE.into();
    };
    match (a.job_cpus, a.job_memory_gib, a.runner_count) {
        (Some(c), Some(g), Some(r)) if r > 0 => format!(
            "now {} CPU {} GiB",
            settings::one_decimal(settings::cpu_share(c, r, fixed)),
            settings::share_text(g, r)
        ),
        _ => NONE.into(),
    }
}

/// `now 200 MiB/s` (status `job_io_mbps` per job; docker reads "mb" as MiB).
fn now_io(running: bool, mbps: Option<f64>) -> String {
    match (running, mbps) {
        (true, Some(v)) => format!("now {v:.0} MiB/s"),
        _ => NONE.into(),
    }
}

/// `now Slice`.
fn now_sharing(running: bool, sharing: Option<&str>) -> String {
    match (running, sharing) {
        (true, Some(s)) if !s.is_empty() => {
            let mut c = s.chars();
            let first = c.next().map(|f| f.to_uppercase().collect::<String>());
            format!("now {}{}", first.unwrap_or_default(), c.as_str())
        }
        _ => NONE.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn applied(runners: Option<u32>, cpus: Option<u32>, gib: Option<u32>) -> Applied {
        Applied {
            runner_count: runners,
            job_cpus: cpus,
            job_memory_gib: gib,
        }
    }

    #[test]
    fn now_lines_show_applied_values_or_a_dash() {
        let a = Some(applied(Some(3), Some(24), Some(72)));
        assert_eq!(now_runners(a), "now 3");
        assert_eq!(now_each(a, false), "now 8 CPU 24 GiB");
        assert_eq!(
            now_each(Some(applied(Some(3), Some(25), Some(72))), false),
            "now 8.3 CPU 24 GiB"
        );
        assert_eq!(
            now_each(Some(applied(Some(5), Some(24), Some(72))), false),
            "now 4.8 CPU 14.4 GiB"
        );
        assert_eq!(
            now_each(Some(applied(Some(5), Some(24), Some(72))), true),
            "now 4 CPU 14.4 GiB"
        );
        assert_eq!(
            now_each(Some(applied(Some(0), Some(24), Some(72))), false),
            NONE
        );
        assert_eq!(
            now_each(Some(applied(Some(2), None, Some(72))), false),
            NONE
        );
        assert_eq!(now_runners(Some(applied(None, None, None))), NONE);
        assert_eq!(now_runners(None), NONE);
        assert_eq!(now_each(None, false), NONE);
        assert_eq!(now_io(true, Some(199.6)), "now 200 MiB/s");
        assert_eq!(now_io(true, None), NONE);
        assert_eq!(now_io(false, Some(1.0)), NONE);
        assert_eq!(now_sharing(true, Some("slice")), "now Slice");
        assert_eq!(now_sharing(true, Some("")), NONE);
        assert_eq!(now_sharing(false, Some("fixed")), NONE);
    }

    #[test]
    fn derived_lines() {
        let vm = VmLimit::ASSUMED;
        let line = |runners| {
            let e = edited(&Settings::default(), runners, 0, false, &vm);
            profile_lines(&e, &vm, Os::Linux)
        };
        assert_eq!(
            line(1),
            ("26 CPU 72 GiB".into(), "26/26 CPU \u{b7} 72/72 GiB".into())
        );
        assert_eq!(
            line(2),
            ("13 CPU 36 GiB".into(), "26/26 CPU \u{b7} 72/72 GiB".into())
        );
        assert_eq!(
            line(3),
            ("8.7 CPU 24 GiB".into(), "26/26 CPU \u{b7} 72/72 GiB".into())
        );
        assert_eq!(
            line(4),
            ("6.5 CPU 18 GiB".into(), "26/26 CPU \u{b7} 72/72 GiB".into())
        );
        assert_eq!(
            line(5),
            (
                "5.2 CPU 14.4 GiB".into(),
                "26/26 CPU \u{b7} 72/72 GiB".into()
            )
        );
    }

    #[test]
    fn fixed_sharing_shows_the_floored_cpu() {
        let vm = VmLimit {
            cpus: 26,
            gib: 80,
            assumed: false,
        };
        let keep = Settings {
            sharing: Sharing::Fixed,
            ..Settings::default()
        };
        let e = edited(&keep, 5, 0, false, &vm);
        assert_eq!(profile_lines(&e, &vm, Os::Linux).0, "4 CPU 14.4 GiB");
    }

    #[test]
    fn apply_and_revert_show_only_while_something_differs() {
        let base = crate::state::temp_base("settings-pending");
        let mut panel = SettingsPanel::load(&base);
        panel.vm = VmLimit::ASSUMED;
        panel.stored = panel.edit();
        assert!(!panel.pending(), "inputs as stored");
        panel.sharing = Sharing::Fixed;
        assert!(panel.pending());
        panel.revert();
        assert!(!panel.pending(), "Revert hides them");
        panel.stored.job_cpus = 25;
        assert_eq!(panel.changes(), 0);
        assert!(
            panel.pending(),
            "stored totals not derived: Apply rewrites them"
        );
        panel.stored = panel.edit();
        panel.write_error = Some("x".into());
        assert!(panel.pending(), "a failed save stays visible");
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn io_cap_moves_in_fives() {
        assert_eq!(step5(0), 0);
        assert_eq!(step5(42), 40);
        assert_eq!(step5(43), 45);
        assert_eq!(step5(100), 100);
        assert_eq!(step5(99), 100);
    }

    #[test]
    fn edited_keeps_io_sharing_and_paused() {
        let keep = Settings {
            io_percent: 40,
            sharing: Sharing::Fixed,
            ..Settings::default()
        };
        let e = edited(&keep, 3, 0, true, &VmLimit::ASSUMED);
        assert_eq!(
            (e.io_percent, e.sharing, e.paused, e.per_runner()),
            (40, Sharing::Fixed, true, (8, 24))
        );
    }

    /// Apply writes what the 0.4 dialog's OK wrote, through the same validation; Pause flips
    /// only `paused` and leaves pending edits pending; Revert reloads the file.
    #[test]
    fn apply_pause_and_revert() {
        let base = crate::state::temp_base("settings-panel");
        let mut panel = SettingsPanel::load(&base);
        panel.vm = VmLimit::ASSUMED;
        assert_eq!(panel.changes(), 0);
        panel.linux = 2;
        panel.io_percent = 55;
        panel.sharing = Sharing::Fixed;
        assert_eq!(panel.changes(), 3);
        let edit = panel.edit();
        assert_eq!(edit.validate(&VmLimit::ASSUMED), Ok(()));
        assert!(panel.apply(&base));
        assert_eq!(settings::read_settings(&base), edit);
        assert_eq!(panel.changes(), 0);
        assert_eq!(panel.edit(), panel.stored, "nothing pending after Apply");

        // A pending edit survives Pause, which rewrites only `paused` (as `toggle_pause` does,
        // without its real-VM check).
        let pause = |paused| {
            let s = Settings {
                paused,
                ..settings::read_settings(&base)
            };
            settings::write_settings(&base, &s, &VmLimit::ASSUMED).unwrap();
        };
        panel.linux = 3;
        pause(true);
        panel.reload(&base);
        assert!(panel.stored.paused);
        assert_eq!(panel.stored.runner_count, 2);
        assert_eq!((panel.linux, panel.changes()), (3, 1));
        assert!(panel.edit().paused, "Apply keeps the stored paused");

        // With nothing pending the inputs follow the file.
        panel.revert();
        pause(false);
        panel.reload(&base);
        assert!(!panel.stored.paused);
        assert_eq!((panel.linux, panel.changes()), (2, 0));

        // A VM too small for one CPU per runner: the same validation refuses, nothing is written.
        panel.vm = VmLimit {
            cpus: 3,
            gib: 80,
            assumed: false,
        };
        assert!(panel.edit().validate(&panel.vm).is_err());
        assert!(!panel.apply(&base));
        assert!(panel.write_error.is_some());
        assert_eq!(settings::read_settings(&base), panel.stored);
        assert_eq!(panel.stored.runner_count, 2);
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn not_running_unless_the_manager_has_slots() {
        let a = applied(Some(2), Some(8), None);
        let snap = |status| Snapshot {
            applied: a,
            ..Snapshot::bare(status)
        };
        for live in [
            Status::Starting,
            Status::Idle,
            Status::Running("job".into()),
            Status::Draining,
        ] {
            assert_eq!(running_now(&snap(live)), Some(a));
        }
        for idle in [
            Status::NotInstalled,
            Status::Unknown,
            Status::Off,
            Status::Paused,
            Status::Error("x".into()),
        ] {
            assert_eq!(running_now(&snap(idle)), None);
        }
    }

    #[test]
    fn each_profile_shows_its_part_of_the_caps() {
        let vm = VmLimit::ASSUMED;
        let e = edited(&Settings::default(), 3, 2, false, &vm);
        assert_eq!(
            profile_lines(&e, &vm, Os::Linux),
            ("5 CPU 14.3 GiB".into(), "15/26 CPU \u{b7} 43/72 GiB".into())
        );
        assert_eq!(
            profile_lines(&e, &vm, Os::Windows),
            (
                "5.5 CPU 14.5 GiB".into(),
                "11/26 CPU \u{b7} 29/72 GiB".into()
            )
        );
        let e = edited(&Settings::default(), 3, 0, false, &vm);
        assert_eq!(
            profile_lines(&e, &vm, Os::Windows),
            ("-".into(), "0/26 CPU \u{b7} 0/72 GiB".into())
        );
        assert_eq!(host_line(), "keeps 2 CPU 8 GiB");
    }

    #[test]
    fn apply_writes_the_windows_count_and_linux_part() {
        let base = crate::state::temp_base("settings-panel-windows");
        let mut panel = SettingsPanel::load(&base);
        panel.vm = VmLimit::ASSUMED;
        (panel.linux, panel.windows) = (3, 2);
        assert_eq!(panel.changes(), 2);
        assert!(panel.apply(&base));
        let s = settings::read_settings(&base);
        assert_eq!(
            (
                s.runner_count,
                s.windows_runner_count,
                s.job_cpus,
                s.job_memory_gib
            ),
            (3, 2, 15, 43),
            "runner_count is the Linux count; the totals are Linux's part"
        );
        assert_eq!(panel.windows(), 2);
        panel.windows = 0;
        panel.revert();
        assert_eq!((panel.linux, panel.windows, panel.changes()), (3, 2, 0));
        std::fs::remove_dir_all(&base).unwrap();
    }
}
