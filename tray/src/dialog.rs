//! `--settings` mode: a small egui window in its own process, so it never shares the
//! tray's tao event loop. Its one input is the runner count; CPUs and memory per runner derive
//! from the caps. The file stores per-runner x runners.

use crate::settings::{self, HOST_CPUS, HOST_GIB, RUNNERS, Settings, VmLimit};
use crate::state::{self, Applied, Status};
use eframe::egui;
use std::path::PathBuf;
use std::time::SystemTime;

struct Dialog {
    base: PathBuf,
    runners: u32,
    paused: bool,
    /// The stored file differs from what OK would write (not divisible, or not derived).
    rewrites: bool,
    /// What the manager runs right now; `None` when it has no runner slots.
    running: Option<Applied>,
    vm: VmLimit,
    write_error: Option<String>,
}

pub fn run(base: PathBuf) -> eframe::Result {
    let stored = settings::read_settings(&base);
    let vm = VmLimit::read();
    let dialog = Dialog {
        runners: stored.runner_count,
        paused: stored.paused,
        rewrites: stored != Settings::derived(stored.runner_count, stored.paused, &vm),
        running: running_now(state::read_status(&base, SystemTime::now())),
        vm,
        write_error: None,
        base,
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title(format!("Settings \u{b7} {}", crate::version()))
            .with_inner_size([560.0, 300.0])
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
            let edit = Settings::derived(self.runners, self.paused, &vm);
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
                    ui.label("Paused");
                    ui.checkbox(&mut self.paused, "");
                    ui.end_row();
                });
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
    fn not_running_unless_the_manager_has_slots() {
        let a = applied(Some(2), Some(8));
        let snap = |status| state::Snapshot { status, applied: a };
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
