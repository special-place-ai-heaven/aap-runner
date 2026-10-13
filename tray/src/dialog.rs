//! `--settings` mode: a small egui window in its own process, so it never shares the
//! tray's tao event loop. It edits per-runner values; the file stores per-runner x runners.

use crate::settings::{self, HOST_CPUS, HOST_GIB, RUNNERS, Settings, VmLimit};
use crate::state::{self, Applied};
use eframe::egui;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::time::SystemTime;

struct Dialog {
    base: PathBuf,
    runners: u32,
    cpus: u32,
    gib: u32,
    paused: bool,
    /// The loaded totals did not divide by the runner count.
    not_divisible: bool,
    applied: Applied,
    vm: VmLimit,
    write_error: Option<String>,
}

pub fn run(base: PathBuf) -> eframe::Result {
    let stored = settings::read_settings(&base);
    let (cpus, gib) = stored.per_runner();
    let dialog = Dialog {
        runners: stored.runner_count,
        cpus,
        gib,
        paused: stored.paused,
        not_divisible: !stored.is_divisible(),
        applied: state::read_status(&base, SystemTime::now()).applied,
        vm: VmLimit::read(),
        write_error: None,
        base,
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AAP runner settings")
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

fn row(ui: &mut egui::Ui, label: &str, v: &mut u32, r: RangeInclusive<u32>, applied: String) {
    ui.label(label);
    ui.add(egui::DragValue::new(v).range(r));
    ui.label(applied);
    ui.end_row();
}

/// `applied: <per runner> (<total>)` from the supervisor's reported totals.
fn applied_per_runner(total: Option<u32>, runners: Option<u32>) -> String {
    match (total, runners) {
        (Some(t), Some(r)) if r > 0 => format!("applied: {} ({t})", t / r),
        (Some(t), _) => format!("applied: n/a ({t})"),
        _ => "applied: n/a".into(),
    }
}

impl eframe::App for Dialog {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ui, |ui| {
            let a = self.applied;
            let vm = self.vm;
            let (cap_cpus, cap_gib) = vm.cap();
            egui::Grid::new("settings")
                .num_columns(3)
                .spacing([16.0, 8.0])
                .show(ui, |ui| {
                    let runners_applied =
                        a.runner_count.map_or("applied: n/a".into(), |n| format!("applied: {n}"));
                    row(ui, "Runners", &mut self.runners, RUNNERS, runners_applied);
                    row(
                        ui,
                        "CPUs per runner",
                        &mut self.cpus,
                        1..=cap_cpus.max(1),
                        applied_per_runner(a.job_cpus, a.runner_count),
                    );
                    row(
                        ui,
                        "Memory GiB per runner",
                        &mut self.gib,
                        1..=cap_gib.max(1),
                        applied_per_runner(a.job_memory_gib, a.runner_count),
                    );
                    ui.label("Paused");
                    ui.checkbox(&mut self.paused, "");
                    ui.end_row();
                });
            ui.add_space(6.0);
            let edit = Settings::from_per_runner(self.runners, self.cpus, self.gib, self.paused);
            ui.label(format!(
                "Total: {} CPUs, {} GiB of cap {cap_cpus} / {cap_gib}",
                edit.job_cpus, edit.job_memory_gib
            ));
            ui.label(format!(
                "Cap: {cap_cpus} CPUs, {cap_gib} GiB (VM {}/{}{} minus {HOST_CPUS} CPUs and {HOST_GIB} GiB for the host)",
                vm.cpus,
                vm.gib,
                if vm.assumed { " assumed," } else { "" }
            ));
            if self.not_divisible {
                ui.label("Stored totals were not divisible; OK rewrites them.");
            }
            ui.label("Applied after running jobs finish.");
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
    use super::applied_per_runner;

    #[test]
    fn applied_shows_per_runner_and_total() {
        assert_eq!(applied_per_runner(Some(24), Some(2)), "applied: 12 (24)");
        assert_eq!(applied_per_runner(Some(25), Some(3)), "applied: 8 (25)");
        assert_eq!(applied_per_runner(Some(24), None), "applied: n/a (24)");
        assert_eq!(applied_per_runner(Some(24), Some(0)), "applied: n/a (24)");
        assert_eq!(applied_per_runner(None, Some(2)), "applied: n/a");
    }
}
