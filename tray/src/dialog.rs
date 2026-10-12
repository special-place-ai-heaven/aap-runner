//! `--settings` mode: a small egui window in its own process, so it never shares the
//! tray's tao event loop.

use crate::settings::{self, CPUS, MEMORY_GIB, RUNNERS, Settings};
use crate::state::{self, Applied};
use eframe::egui;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::time::SystemTime;

struct Dialog {
    base: PathBuf,
    edit: Settings,
    applied: Applied,
    write_error: Option<String>,
}

pub fn run(base: PathBuf) -> eframe::Result {
    let edit = settings::read_settings(&base);
    let applied = state::read_status(&base, SystemTime::now()).applied;
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AAP runner settings")
            .with_inner_size([420.0, 210.0])
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
        Box::new(move |_| {
            Ok(Box::new(Dialog {
                base,
                edit,
                applied,
                write_error: None,
            }))
        }),
    )
}

fn row(ui: &mut egui::Ui, label: &str, v: &mut u32, r: RangeInclusive<u32>, applied: Option<u32>) {
    ui.label(label);
    ui.add(egui::DragValue::new(v).range(r));
    ui.label(applied.map_or("applied: n/a".into(), |n| format!("applied: {n}")));
    ui.end_row();
}

impl eframe::App for Dialog {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ui, |ui| {
            let a = self.applied;
            egui::Grid::new("settings")
                .num_columns(3)
                .spacing([16.0, 8.0])
                .show(ui, |ui| {
                    row(
                        ui,
                        "Runners",
                        &mut self.edit.runner_count,
                        RUNNERS,
                        a.runner_count,
                    );
                    row(
                        ui,
                        "CPUs per job",
                        &mut self.edit.job_cpus,
                        CPUS,
                        a.job_cpus,
                    );
                    row(
                        ui,
                        "Memory per job (GiB)",
                        &mut self.edit.job_memory_gib,
                        MEMORY_GIB,
                        a.job_memory_gib,
                    );
                    ui.label("Paused");
                    ui.checkbox(&mut self.edit.paused, "");
                    ui.end_row();
                });
            ui.add_space(6.0);
            ui.label("Applied after running jobs finish.");
            let invalid = self.edit.validate().err();
            if let Some(e) = invalid.as_ref().or(self.write_error.as_ref()) {
                ui.colored_label(ui.visuals().error_fg_color, e);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(invalid.is_none(), egui::Button::new("OK"))
                    .clicked()
                {
                    match settings::write_settings(&self.base, &self.edit) {
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
