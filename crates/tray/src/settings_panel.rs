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
        let stored = settings::read_with_windows_choice(base);
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
        self.stored = settings::read_with_windows_choice(base);
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
            schema: self.stored.schema,
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
        // settings.json first (it never carries the Windows count without a backend), then the
        // tray-local Windows count.
        let written = settings::write_settings(base, &edit, &self.vm).and_then(|()| {
            if WINDOWS_BACKEND {
                Ok(())
            } else {
                settings::write_windows_choice(
                    &settings::windows_choice_path(base),
                    edit.windows_runner_count,
                )
            }
        });
        match written {
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
        let linux = linux_line(&edit, &vm);
        let windows = windows_line(&edit, self.windows, &vm);
        // A stored schema 3 file is the supervisor's word that it runs Windows: Linux may be 0.
        let backend = WINDOWS_BACKEND || self.stored.schema >= 3;
        let fits_linux = settings::count_range(Os::Linux, self.windows, backend);
        let fits_windows = settings::count_range(Os::Windows, self.linux, backend);
        ui.horizontal(|ui| {
            os_label(ui, p, Os::Linux);
            segmented(
                ui,
                p,
                &mut self.linux,
                &COUNTS,
                |n| fits_linux.contains(&n),
                p.os(Os::Linux),
                focus,
            );
        });
        ui.horizontal(|ui| {
            label(ui, "Each");
            ui.label(linux.each);
            ui.label(RichText::new(linux.total).color(p.muted).small());
        })
        .response
        .on_hover_text(linux.tip);
        now(
            ui,
            p,
            now_linux(running, snap.sharing.as_deref() == Some("fixed")),
        );
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            os_label(ui, p, Os::Windows);
            segmented(
                ui,
                p,
                &mut self.windows,
                &COUNTS,
                |n| fits_windows.contains(&n),
                p.os(Os::Windows),
                focus,
            )
            .on_hover_text(WINDOWS_INERT);
        });
        ui.horizontal(|ui| {
            label(ui, "Each");
            ui.label(RichText::new(windows.text).color(p.over).small());
        })
        .response
        .on_hover_text(windows.tip);
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
                p.accent,
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
                self.stored = settings::read_with_windows_choice(base);
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

/// Equal cells, the selected one filled with `selected_fill` (a profile colour or the accent);
/// cells `allowed` refuses are greyed and inert. Cells shrink to share the row width. Only the
/// selected cell is a Tab stop; Left and Right move the selection to an allowed neighbour while
/// it has focus. Returns the group's response.
fn segmented<T: Copy + PartialEq>(
    ui: &mut egui::Ui,
    p: &Palette,
    value: &mut T,
    options: &[(T, &str)],
    allowed: impl Fn(T) -> bool,
    selected_fill: egui::Color32,
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
                selected_fill
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

/// The Linux line: `Each 8.7 CPU 24 GiB of 26/72`, what each Linux runner gets of the written
/// totals; the tooltip has the totals against the caps and the host reserve.
struct LinuxLine {
    each: String,
    total: String,
    tip: String,
}

fn linux_line(edit: &Settings, vm: &VmLimit) -> LinuxLine {
    let (cap_cpus, cap_gib) = vm.cap();
    let n = edit.runner_count.max(1);
    let (cpus, gib) = (edit.job_cpus, edit.job_memory_gib);
    LinuxLine {
        each: format!(
            "{} CPU {} GiB",
            settings::one_decimal(settings::cpu_share(cpus, n, edit.sharing == Sharing::Fixed)),
            settings::share_text(gib, n)
        ),
        total: format!("of {cpus}/{gib}"),
        tip: format!(
            "Total {cpus}/{cap_cpus} CPU \u{b7} {gib}/{cap_gib} GiB against the caps. \
             The host keeps {HOST_CPUS} CPU {HOST_GIB} GiB for Windows and WSL."
        ),
    }
}

/// The Windows line: `not installed`, and with Windows runners chosen the prospective even
/// share each would get, `not installed · 5 CPU 14 GiB`. Prospective only: nothing is written
/// for Windows and the Linux pool keeps the whole caps while no backend exists.
struct WindowsLine {
    text: String,
    tip: String,
}

fn windows_line(edit: &Settings, windows: u32, vm: &VmLimit) -> WindowsLine {
    if windows == 0 {
        return WindowsLine {
            text: "not installed".into(),
            tip: WINDOWS_INERT.into(),
        };
    }
    let (cap_cpus, cap_gib) = vm.cap();
    let (cpus, gib) = settings::each_part(vm.cap(), edit.runner_count, windows);
    WindowsLine {
        text: format!("not installed \u{b7} {cpus} CPU {gib} GiB"),
        tip: format!(
            "Prospective, once the native Windows backend is installed: every runner gets \
             {cpus} CPU {gib} GiB, {} CPU {} GiB of {cap_cpus}/{cap_gib} for these {windows} \
             Windows runners. Today they start nothing and the Linux pool keeps the whole caps.",
            cpus * windows,
            gib * windows
        ),
    }
}

/// IO cap moves in steps of 5.
fn step5(v: u32) -> u32 {
    ((v + 2) / 5 * 5).min(*IO_PERCENT.end())
}

/// What Apply writes: the derived limits with the IO cap and sharing mode from `keep`.
fn edited(keep: &Settings, linux: u32, windows: u32, paused: bool, vm: &VmLimit) -> Settings {
    Settings {
        schema: keep.schema,
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

/// `now 3 · 4.8 CPU 14.4 GiB`: the applied Linux count and each runner's share, one line.
fn now_linux(running: Option<Applied>, fixed: bool) -> String {
    let (count, each) = (now_runners(running), now_each(running, fixed));
    match each.strip_prefix("now ") {
        Some(each) if count != NONE && each != "-" => format!("{count} \u{b7} {each}"),
        _ => count,
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
            let l = linux_line(&e, &vm);
            (l.each, l.total)
        };
        let of = || "of 26/72".to_string();
        assert_eq!(line(1), ("26 CPU 72 GiB".into(), of()));
        assert_eq!(line(2), ("13 CPU 36 GiB".into(), of()));
        assert_eq!(line(3), ("8.7 CPU 24 GiB".into(), of()));
        assert_eq!(line(4), ("6.5 CPU 18 GiB".into(), of()));
        assert_eq!(line(5), ("5.2 CPU 14.4 GiB".into(), of()));
        let tip = linux_line(&edited(&Settings::default(), 3, 0, false, &vm), &vm).tip;
        assert_eq!(
            tip,
            "Total 26/26 CPU \u{b7} 72/72 GiB against the caps. The host keeps 2 CPU 8 GiB \
             for Windows and WSL."
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
        assert_eq!(linux_line(&e, &vm).each, "4 CPU 14.4 GiB");
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

    /// A stored schema 3 file shows its own two counts (Windows only included), Linux 0 is a
    /// choice, and Apply keeps schema 3 with the edited Windows count.
    #[test]
    fn a_schema_three_file_shows_and_applies_its_counts() {
        let base = crate::state::temp_base("settings-panel-v3");
        std::fs::write(
            crate::state::inbox(&base).join("settings.json"),
            crate::state::fixture("settings-v3/valid/windows-only-even.json"),
        )
        .unwrap();
        settings::write_windows_choice(&settings::windows_choice_path(&base), 1).unwrap();
        let mut panel = SettingsPanel::load(&base);
        panel.vm = VmLimit::ASSUMED;
        assert_eq!((panel.linux, panel.windows, panel.changes()), (0, 2, 0));
        panel.windows = 3;
        assert!(panel.apply(&base), "{:?}", panel.write_error);
        let s = settings::read_settings(&base);
        assert_eq!(
            (s.schema, s.runner_count, s.windows_runner_count),
            (3, 0, 3)
        );
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
    fn windows_line_is_inert_with_a_prospective_even_share() {
        let vm = VmLimit::ASSUMED;
        let e = edited(&Settings::default(), 3, 2, false, &vm);
        assert_eq!(
            (e.job_cpus, e.job_memory_gib),
            (26, 72),
            "inert: Linux keeps the whole caps"
        );
        let l = linux_line(&e, &vm);
        assert_eq!(
            (l.each, l.total),
            ("8.7 CPU 24 GiB".into(), "of 26/72".into())
        );
        let w = windows_line(&e, 2, &vm);
        assert_eq!(w.text, "not installed \u{b7} 5 CPU 14 GiB");
        assert!(w.tip.starts_with("Prospective"), "{}", w.tip);
        assert!(w.tip.contains("10 CPU 28 GiB of 26/72"), "{}", w.tip);
        let w = windows_line(&e, 0, &vm);
        assert_eq!(
            (w.text.as_str(), w.tip.as_str()),
            ("not installed", WINDOWS_INERT)
        );
    }

    #[test]
    fn now_linux_joins_count_and_share() {
        let a = |r, c, g| {
            Some(Applied {
                runner_count: r,
                job_cpus: c,
                job_memory_gib: g,
            })
        };
        assert_eq!(
            now_linux(a(Some(5), Some(24), Some(72)), false),
            "now 5 \u{b7} 4.8 CPU 14.4 GiB"
        );
        assert_eq!(now_linux(a(Some(3), None, Some(72)), false), "now 3");
        assert_eq!(now_linux(a(None, Some(24), Some(72)), false), NONE);
        assert_eq!(now_linux(None, false), NONE);
    }

    /// A Windows-only Apply rewrites only `windows_runner_count`: the keys the supervisor
    /// applies keep their exact values while no Windows backend exists.
    #[test]
    fn apply_of_a_windows_only_change_keeps_the_linux_keys() {
        let base = crate::state::temp_base("settings-panel-windows");
        let file = crate::state::inbox(&base).join("settings.json");
        let mut panel = SettingsPanel::load(&base);
        panel.vm = VmLimit::ASSUMED;
        panel.linux = 3;
        assert!(panel.apply(&base));
        let before = std::fs::read_to_string(&file).unwrap();
        panel.windows = 2;
        assert_eq!(panel.changes(), 1);
        assert!(panel.apply(&base));
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            before,
            "settings.json is byte-identical: the count is kept tray-local"
        );
        assert_eq!(
            settings::read_windows_choice(&settings::windows_choice_path(&base)),
            2
        );
        assert_eq!(panel.windows(), 2);
        assert_eq!(
            SettingsPanel::load(&base).windows(),
            2,
            "read back on reopen"
        );
        panel.windows = 0;
        panel.revert();
        assert_eq!((panel.linux, panel.windows, panel.changes()), (3, 2, 0));
        std::fs::remove_dir_all(&base).unwrap();
    }
}
