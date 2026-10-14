//! `--settings` mode: a small egui window in its own process, so it never shares the
//! tray's tao event loop. Its inputs are the runner count, the IO cap and the sharing mode;
//! CPUs and memory per runner derive from the caps. The file stores per-runner x runners.

use crate::settings::{self, HOST_CPUS, HOST_GIB, IO_PERCENT, RUNNERS, Settings, Sharing, VmLimit};
use crate::state::{self, Applied, Status};
use eframe::egui;
use std::path::PathBuf;
use std::time::SystemTime;

struct Dialog {
    base: PathBuf,
    runners: u32,
    paused: bool,
    io_percent: u32,
    sharing: Sharing,
    /// `running now: …` for the IO cap and the sharing mode, from `status.json`.
    running_io: String,
    running_sharing: String,
    /// The stored file differs from what OK would write (not divisible, or not derived).
    rewrites: bool,
    /// What the manager runs right now; `None` when it has no runner slots.
    running: Option<Applied>,
    /// `owner/name · job` while a job runs.
    running_job: Option<String>,
    vm: VmLimit,
    write_error: Option<String>,
}

pub fn run(base: PathBuf) -> eframe::Result {
    let stored = settings::read_settings(&base);
    let snap = state::read_status(&base, SystemTime::now());
    let vm = VmLimit::read();
    let running = running_now(snap.clone());
    let dialog = Dialog {
        runners: stored.runner_count,
        paused: stored.paused,
        io_percent: stored.io_percent,
        sharing: stored.sharing,
        running_io: running_io(running.is_some(), snap.job_io_mbps),
        running_sharing: running_sharing(running.is_some(), snap.sharing.as_deref()),
        rewrites: stored != edited(&stored, stored.runner_count, stored.paused, &vm),
        running,
        running_job: snap.running_job(),
        vm,
        write_error: None,
        base,
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title(format!("Settings \u{b7} {}", crate::version()))
            .with_inner_size([560.0, 360.0])
            .with_resizable(false)
            .with_minimize_button(false)
            .with_maximize_button(false)
            .with_window_level(egui::WindowLevel::AlwaysOnTop),
        centered: true,
        ..Default::default()
    };
    eframe::run_native(
        "aap-runner-settings",
        options,
        Box::new(move |_| Ok(Box::new(dialog))),
    )
}

/// What OK writes: the derived limits with the IO cap and sharing mode from `keep`.
fn edited(keep: &Settings, runners: u32, paused: bool, vm: &VmLimit) -> Settings {
    Settings {
        io_percent: keep.io_percent,
        sharing: keep.sharing,
        ..Settings::derived(runners, paused, vm)
    }
}

/// `running now: 88 MiB/s per job` (status `job_io_mbps`; docker reads "mb" as MiB).
fn running_io(running: bool, mbps: Option<f64>) -> String {
    match (running, mbps) {
        (false, _) => NOT_RUNNING.into(),
        (true, Some(v)) => format!("running now: {v:.0} MiB/s per job"),
        (true, None) => "running now: unknown".into(),
    }
}

fn running_sharing(running: bool, sharing: Option<&str>) -> String {
    match (running, sharing) {
        (false, _) => NOT_RUNNING.into(),
        (true, Some(s)) => format!("running now: {s}"),
        (true, None) => "running now: unknown".into(),
    }
}

fn derived_row(ui: &mut egui::Ui, label: &str, value: u32, now: String) {
    ui.label(label);
    ui.label(format!("{value} (derived)"));
    ui.label(now);
    ui.end_row();
}

/// The applied limits while the manager has runner slots (starting, idle, running, draining).
fn running_now(snap: state::Snapshot) -> Option<Applied> {
    matches!(
        snap.status,
        Status::Starting | Status::Idle | Status::Running(_) | Status::Draining
    )
    .then_some(snap.applied)
}

const NOT_RUNNING: &str = "running now: not running";

fn running_runners(running: Option<Applied>) -> String {
    match running {
        None => NOT_RUNNING.into(),
        Some(a) => a.runner_count.map_or("running now: unknown".into(), |n| {
            format!("running now: {n}")
        }),
    }
}

/// `running now: <per runner> per runner (<total> total)` from the supervisor's reported totals.
fn running_per_runner(running: Option<Applied>, total: fn(&Applied) -> Option<u32>) -> String {
    let Some(a) = running else {
        return NOT_RUNNING.into();
    };
    match (total(&a), a.runner_count) {
        (Some(t), Some(r)) if r > 0 => format!("running now: {} per runner ({t} total)", t / r),
        (Some(t), _) => format!("running now: {t} total"),
        _ => "running now: unknown".into(),
    }
}

impl eframe::App for Dialog {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ui, |ui| {
            let running = self.running;
            let vm = self.vm;
            let (cap_cpus, cap_gib) = vm.cap();
            let keep = Settings {
                io_percent: self.io_percent,
                sharing: self.sharing,
                ..Settings::default()
            };
            let edit = edited(&keep, self.runners, self.paused, &vm);
            let (each_cpus, each_gib) = edit.per_runner();
            egui::Grid::new("settings")
                .num_columns(3)
                .spacing([16.0, 8.0])
                .show(ui, |ui| {
                    ui.label("Runners");
                    ui.add(egui::DragValue::new(&mut self.runners).range(RUNNERS));
                    ui.label(running_runners(running));
                    ui.end_row();
                    derived_row(
                        ui,
                        "CPUs per runner",
                        each_cpus,
                        running_per_runner(running, |a| a.job_cpus),
                    );
                    derived_row(
                        ui,
                        "Memory GiB per runner",
                        each_gib,
                        running_per_runner(running, |a| a.job_memory_gib),
                    );
                    ui.label("IO cap %");
                    ui.add(egui::DragValue::new(&mut self.io_percent).range(IO_PERCENT));
                    ui.label(&self.running_io);
                    ui.end_row();
                    ui.label("Sharing");
                    egui::ComboBox::from_id_salt("sharing")
                        .selected_text(self.sharing.word())
                        .show_ui(ui, |ui| {
                            for s in [Sharing::Slice, Sharing::Fixed] {
                                ui.selectable_value(&mut self.sharing, s, s.word());
                            }
                        });
                    ui.label(&self.running_sharing);
                    ui.end_row();
                    ui.label("Paused");
                    ui.checkbox(&mut self.paused, "");
                    ui.end_row();
                });
            if let Some(job) = &self.running_job {
                ui.label(format!("Running now: {job}"));
            }
            ui.add_space(6.0);
            // `edit` is from before the grid: a change shows on the next frame, which egui
            // paints right after the input event.
            ui.label(format!("Each runner: {each_cpus} CPUs, {each_gib} GiB"));
            ui.label(format!(
                "Total: {} CPUs, {} GiB (cap {cap_cpus} / {cap_gib} \u{f7} {})",
                edit.job_cpus, edit.job_memory_gib, edit.runner_count
            ));
            ui.label(format!(
                "Cap: {cap_cpus} CPUs, {cap_gib} GiB (VM {}/{}{} minus {HOST_CPUS} CPUs and {HOST_GIB} GiB for the host)",
                vm.cpus,
                vm.gib,
                if vm.assumed { " assumed," } else { "" }
            ));
            if self.rewrites {
                ui.label("Stored totals differ from these values; OK rewrites them.");
            }
            ui.label(
                "Your values apply when the runner restarts (after running jobs finish, or on Resume).",
            );
            let invalid = edit.validate(&vm).err();
            if let Some(e) = invalid.as_ref().or(self.write_error.as_ref()) {
                ui.colored_label(ui.visuals().error_fg_color, e);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(invalid.is_none(), egui::Button::new("OK"))
                    .clicked()
                {
                    match settings::write_settings(&self.base, &edit, &vm) {
                        Ok(()) => ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close),
                        Err(e) => self.write_error = Some(format!("Could not save: {e}")),
                    }
                }
                if ui.button("Cancel").clicked() {
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                }
            });
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn applied(runners: Option<u32>, cpus: Option<u32>) -> Applied {
        Applied {
            runner_count: runners,
            job_cpus: cpus,
            job_memory_gib: None,
        }
    }

    #[test]
    fn running_now_shows_per_runner_and_total() {
        let cpus = |a| running_per_runner(Some(a), |a| a.job_cpus);
        assert_eq!(
            cpus(applied(Some(2), Some(8))),
            "running now: 4 per runner (8 total)"
        );
        assert_eq!(
            cpus(applied(Some(3), Some(25))),
            "running now: 8 per runner (25 total)"
        );
        assert_eq!(cpus(applied(None, Some(24))), "running now: 24 total");
        assert_eq!(cpus(applied(Some(0), Some(24))), "running now: 24 total");
        assert_eq!(cpus(applied(Some(2), None)), "running now: unknown");
        assert_eq!(running_per_runner(None, |a| a.job_cpus), NOT_RUNNING);
        assert_eq!(
            running_runners(Some(applied(Some(2), None))),
            "running now: 2"
        );
        assert_eq!(
            running_runners(Some(applied(None, None))),
            "running now: unknown"
        );
        assert_eq!(running_runners(None), NOT_RUNNING);
    }

    #[test]
    fn running_now_io_and_sharing() {
        assert_eq!(
            running_io(true, Some(87.6)),
            "running now: 88 MiB/s per job"
        );
        assert_eq!(running_io(true, None), "running now: unknown");
        assert_eq!(running_io(false, Some(1.0)), NOT_RUNNING);
        assert_eq!(running_sharing(true, Some("fixed")), "running now: fixed");
        assert_eq!(running_sharing(false, Some("fixed")), NOT_RUNNING);
        let vm = VmLimit::ASSUMED;
        let keep = Settings {
            io_percent: 40,
            sharing: Sharing::Fixed,
            ..Settings::default()
        };
        let e = edited(&keep, 3, true, &vm);
        assert_eq!(
            (e.io_percent, e.sharing, e.paused, e.per_runner()),
            (40, Sharing::Fixed, true, (8, 24))
        );
    }

    #[test]
    fn not_running_unless_the_manager_has_slots() {
        let a = applied(Some(2), Some(8));
        let snap = |status| state::Snapshot {
            applied: a,
            ..state::Snapshot::bare(status)
        };
        for live in [
            Status::Starting,
            Status::Idle,
            Status::Running("job".into()),
            Status::Draining,
        ] {
            assert_eq!(running_now(snap(live)), Some(a));
        }
        for idle in [
            Status::NotInstalled,
            Status::Unknown,
            Status::Off,
            Status::Paused,
            Status::Error("x".into()),
        ] {
            assert_eq!(running_now(snap(idle)), None);
        }
    }
}
