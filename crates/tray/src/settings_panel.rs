//! The window's left column (the separate `--settings` dialog until 0.5.0): Power, then the
//! settings `inbox\settings.json` holds. Start/Stop and Pause/Resume act at once, as the menu
//! does; Runners, IO cap and Sharing are edits that Apply writes. CPUs and memory per runner
//! derive from the caps and the file stores per-runner x runners. Validation and the written
//! file are unchanged.

use crate::dashboard::{Palette, button, primary_button, ring, semibold};
use crate::mark::Sym;
use crate::settings::{self, IO_PERCENT, Settings, Sharing, VmLimit};
use crate::state::{Applied, Desired, Snapshot, Status};
use eframe::egui::{self, Align, FontId, Key, Layout, RichText, Sense, Stroke, StrokeKind, vec2};
use std::path::Path;

/// Left-column label width ("Runners", "Sharing").
const LABEL_W: f32 = 64.0;

const SHARING_TIP: &str = "Slice: idle share can be borrowed. Fixed: hard limit per runner.";

pub struct SettingsPanel {
    /// `settings.json` as last read.
    stored: Settings,
    runners: u32,
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
            runners: stored.runner_count,
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

    fn revert(&mut self) {
        self.runners = self.stored.runner_count;
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
        edited(&keep, self.runners, self.stored.paused, &self.vm)
    }

    /// Inputs that differ from the file.
    fn changes(&self) -> usize {
        [
            self.runners != self.stored.runner_count,
            self.io_percent != self.stored.io_percent,
            self.sharing != self.stored.sharing,
        ]
        .into_iter()
        .filter(|c| *c)
        .count()
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

    /// Draws the column. Open logs is pinned to the bottom.
    pub fn show(
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
        // Last in Tab order, pinned to the bottom of what is left.
        ui.with_layout(Layout::bottom_up(Align::Min), |ui| {
            let r = ui.add_enabled(base.join("logs").is_dir(), egui::Button::new("Open logs"));
            focus.track(ui, p, &r);
            if r.clicked() {
                crate::open_logs(base);
            }
        });
        focus
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
        let (cap_cpus, cap_gib) = vm.cap();
        // From before the inputs: a change shows on the next frame, which egui paints right
        // after the input event.
        let edit = self.edit();
        let (each_cpus, each_gib) = edit.per_runner();
        ui.horizontal(|ui| {
            label(ui, "Runners");
            segmented(
                ui,
                p,
                &mut self.runners,
                &[(1, "1"), (2, "2"), (3, "3")],
                focus,
            );
        });
        now(ui, p, now_runners(running));
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            label(ui, "Each");
            ui.label(format!("{each_cpus} CPU {each_gib} GiB"));
        });
        now(ui, p, now_each(running));
        ui.horizontal(|ui| {
            label(ui, "Total");
            ui.label(format!(
                "{}/{cap_cpus} CPU \u{b7} {}/{cap_gib} GiB",
                edit.job_cpus, edit.job_memory_gib
            ));
        });
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
                focus,
            )
            .on_hover_text(SHARING_TIP);
        });
        now(
            ui,
            p,
            now_sharing(running.is_some(), snap.sharing.as_deref()),
        );
        if self.edit() == self.stored && self.write_error.is_none() {
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
            ui.add(egui::Label::new(RichText::new(e).color(p.state(Sym::Error))).wrap());
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

/// A muted `now …` line, indented under the input.
fn now(ui: &mut egui::Ui, p: &Palette, text: String) {
    ui.horizontal(|ui| {
        ui.add_space(LABEL_W + ui.spacing().item_spacing.x);
        ui.label(RichText::new(text).color(p.muted).small());
    });
}

/// Equal cells, the selected one filled with the accent. Only the selected cell is a Tab stop;
/// Left and Right move the selection while it has focus. Returns the group's response.
fn segmented<T: Copy + PartialEq>(
    ui: &mut egui::Ui,
    p: &Palette,
    value: &mut T,
    options: &[(T, &str)],
    focus: &mut Focus,
) -> egui::Response {
    let on_accent = if p.dark {
        crate::dashboard::hex(0x1E1F22)
    } else {
        crate::dashboard::hex(0xFFFFFF)
    };
    let enabled = ui.is_enabled();
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 0.0;
        let mut ids = Vec::with_capacity(options.len());
        let mut focused = None;
        for (i, (v, text)) in options.iter().enumerate() {
            let selected = *value == *v;
            let color = if selected { on_accent } else { p.text };
            let galley =
                ui.painter()
                    .layout_no_wrap((*text).into(), FontId::proportional(13.0), color);
            let size = vec2((galley.size().x + 20.0).max(32.0), 24.0);
            let sense = if selected {
                Sense::click()
            } else {
                Sense::CLICK
            };
            let (rect, r) = ui.allocate_exact_size(size, sense);
            let fill = if selected {
                p.accent
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
                egui::WidgetInfo::selected(egui::WidgetType::RadioButton, enabled, selected, *text)
            });
            focus.track(ui, p, &r);
            if r.clicked() {
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
            };
            if let Some(j) = to {
                *value = options[j].0;
                ui.memory_mut(|m| m.request_focus(ids[j]));
            }
        }
    })
    .response
}

/// IO cap moves in steps of 5.
fn step5(v: u32) -> u32 {
    ((v + 2) / 5 * 5).min(*IO_PERCENT.end())
}

/// What Apply writes: the derived limits with the IO cap and sharing mode from `keep`.
fn edited(keep: &Settings, runners: u32, paused: bool, vm: &VmLimit) -> Settings {
    Settings {
        io_percent: keep.io_percent,
        sharing: keep.sharing,
        ..Settings::derived(runners, paused, vm)
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

/// `now 8 CPU 24 GiB`: the reported totals divided by the reported runner count.
fn now_each(running: Option<Applied>) -> String {
    let Some(a) = running else {
        return NONE.into();
    };
    match (a.job_cpus, a.job_memory_gib, a.runner_count) {
        (Some(c), Some(g), Some(r)) if r > 0 => format!("now {} CPU {} GiB", c / r, g / r),
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
        assert_eq!(now_each(a), "now 8 CPU 24 GiB");
        assert_eq!(
            now_each(Some(applied(Some(3), Some(25), Some(72)))),
            "now 8 CPU 24 GiB"
        );
        assert_eq!(now_each(Some(applied(Some(0), Some(24), Some(72)))), NONE);
        assert_eq!(now_each(Some(applied(Some(2), None, Some(72)))), NONE);
        assert_eq!(now_runners(Some(applied(None, None, None))), NONE);
        assert_eq!(now_runners(None), NONE);
        assert_eq!(now_each(None), NONE);
        assert_eq!(now_io(true, Some(199.6)), "now 200 MiB/s");
        assert_eq!(now_io(true, None), NONE);
        assert_eq!(now_io(false, Some(1.0)), NONE);
        assert_eq!(now_sharing(true, Some("slice")), "now Slice");
        assert_eq!(now_sharing(true, Some("")), NONE);
        assert_eq!(now_sharing(false, Some("fixed")), NONE);
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
        let e = edited(&keep, 3, true, &VmLimit::ASSUMED);
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
        panel.runners = 2;
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
        panel.runners = 3;
        pause(true);
        panel.reload(&base);
        assert!(panel.stored.paused);
        assert_eq!(panel.stored.runner_count, 2);
        assert_eq!((panel.runners, panel.changes()), (3, 1));
        assert!(panel.edit().paused, "Apply keeps the stored paused");

        // With nothing pending the inputs follow the file.
        panel.revert();
        pause(false);
        panel.reload(&base);
        assert!(!panel.stored.paused);
        assert_eq!((panel.runners, panel.changes()), (2, 0));

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
}
