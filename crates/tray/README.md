# aap-runner-tray

Windows tray front-end for the self-hosted runner. It only reads and writes JSON files in
`C:\ProgramData\aap-runner` (writes only under
`inbox\`) and opens the logs folder. It never runs `wsl.exe`, never talks to GitHub, needs no token and no elevation.

## Files (under `C:\ProgramData\aap-runner`, created by the install script)

Trust split: the tray writes only under `inbox\`; everything it reads from the root is
admin-written.

| File | Writer | Content |
|---|---|---|
| `inbox\state.json` | tray (atomic: `.tmp` then rename) | `{"desired":"on"}` or `{"desired":"off"}` |
| `inbox\settings.json` | tray (atomic) | `{"runner_count":1..3,"job_cpus":1..28,"job_memory_gib":1..80,"paused":false}` |
| `inbox\tray.log` | tray, appended if `inbox\` exists | one line per failed write/spawn |
| `status.json` | supervisor, never the tray | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"…","updated":"<RFC3339>","detail":"…","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/…/actions/runs/N"}` (the last five optional; `repo` and `run_url` may be `""`) |
| `logs\` | supervisor | opened by "Open logs" via `C:\Windows\explorer.exe` (absolute path) |

- `inbox\` missing: `Not installed`; Start/Stop/Restart, Pause/Resume and Settings are disabled.
- `status.json` missing, unparseable, larger than 64 KiB (not read), or `updated` older than
  3 minutes: `Unknown (supervisor not running)`.
- `settings.json` missing, unparseable, out of range, or with fewer than 1 CPU / 1 GiB per runner:
  defaults `1 runner x 26 CPUs x 72 GiB / not paused`.
- 1 to 3 runners. `job_cpus` and `job_memory_gib` are pool totals, not per job: the manager divides
  them by `runner_count`. The window's main input is Runners. CPUs and memory per runner are derived:
  `floor(cpu_cap / runners)` and `floor(mem_cap / runners)` (26 / 13 / 8 CPUs and 72 / 36 / 24 GiB for
  1 / 2 / 3 runners on a 28 / 80 VM). It writes per-runner x runners (26/72, 26/72, 24/72), so the
  totals always divide evenly.
- Host caps: the VM size comes from `[wsl2]` `processors=` / `memory=` in `%USERPROFILE%\.wslconfig`
  (`GB`/`G`/`MB`/`M`; missing file or key: 28 CPUs / 80 GiB, shown as "assumed"). Totals may use at
  most VM minus 2 CPUs and VM minus 8 GiB (26 / 72 on a 28 / 80 VM).
- The tray never writes a file that breaks these rules: runners 1..3, totals in range, totals within
  the caps, and totals divisible by `runner_count`. This also covers Pause/Resume, so a hand-edited
  file above the cap must be fixed in the window first.

## Menu

Open dashboard, state line (with applied limits when reported, e.g. `Idle · 2 runners · 24 cpu · 72 GiB total`; same text
as the tooltip), Open job, Start, Stop, Restart, Pause/Resume, Settings…, Open logs, version, Quit.

- Dark menu: the menu follows the Windows app theme (HKCU `...\Themes\Personalize` `AppsUseLightTheme`).
  Before the menu is built the tray calls uxtheme's `SetPreferredAppMode(AllowDark)` (ordinal 135),
  `AllowDarkModeForWindow` (133) on tray-icon's hidden window, `RefreshImmersiveColorPolicyState` (104) and
  `FlushMenuThemes` (136), and sets `DWMWA_USE_IMMERSIVE_DARK_MODE` on that window. These exports are
  undocumented but stable since Windows 10 1809 and are loaded by ordinal from System32 (`src/win.rs`); if any
  is missing nothing is changed and the menu stays light. The theme is re-read every 2 s and the calls repeat
  when it flips; the menu itself is not rebuilt.

- Polls `status.json` every 5 s. Restart writes `off`, waits up to 15 min for `state: off`, then writes `on`.
- Pause/Resume flips `paused` in `settings.json`; the label follows the file.
- Settings… opens the window (or focuses it) with the focus on the settings column (see Window).
- Quit closes the tray only; it does not touch any file. Single instance per user (file locks in `%TEMP%`).
- Tooltip: `AAP Runner: <state line> · v<version> (<commit>)`.
- While a job runs the state line reads `Running <repo short name> · <job>` (the part of `repo` after
  the slash), or `Running job <job>` when `repo` is empty.
- Open job (directly under the state line) is enabled only when `run_url` matches
  `^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$`, checked again on click;
  it opens the URL in the default browser via `C:\Windows\explorer.exe <url>`. Nothing else is opened.
- Version: `AAP Runner v0.5.0 (abcdef12)` (Cargo version, short HEAD stamped by `build.rs`, `local`
  without git) as a disabled item above Quit, in the tooltip, the window title and the error panel. `--version`
  prints it to stdout and exits 0 (GUI-subsystem exe: capture it, e.g. `& .\aap-runner-tray.exe --version | Write-Output`).

## Window (`--dashboard`, `--settings`)

One egui window in its own process (`current_exe()`), one at a time (file lock in `%TEMP%`). No tabs:
a fixed 260 px settings column on the left, a 1 px border, and the observability column on the right.
Default 760 x 520, resizable, minimum 680 x 460, placed bottom-right in the work area. Left click on the
tray icon opens it (or closes it when it is the active window). The layout is the "Single-view layout"
addendum of the design doc.

- **Left column:** `Power On/Off` (the desired state from `inbox\state.json`), `Start`/`Stop` and
  `Pause`/`Resume` (immediate, as in the menu; Pause rewrites only `paused`). Then the edits: Runners
  `1 | 2 | 3`, `Each 8 CPU 24 GiB` (derived), `Total 24/26 CPU · 72/72 GiB` against the caps, IO cap
  0..100 % in steps of 5, Sharing `Slice | Fixed`. Each has a muted `now …` line from `status.json`
  (`now -` when nothing runs). While edits differ from `inbox\settings.json`: `N changes not applied`,
  a cap error inline, and Apply (disabled on an error; writes schema 2 atomically, as the old dialog's
  OK did) and Revert (reloads the file). Open logs is pinned at the bottom.
- **Right column:** only observed values. A pinned header row (symbol, state, `N/3 busy`, `All OK` or
  the `1 problem` button), pool bars, `IO … MiB/s` and `sampled N s ago`, one compact card per runner
  (state and elapsed; `title · repo` on one line with the full text in a tooltip and a copy button;
  CPU and Mem bars side by side), and the last 60 minutes. It scrolls at small sizes.
- **Error panel:** replaces the right column's cards, with `< Back to runners` on top. It opens by itself
  when the state enters an error class; the `1 problem` button, an error symbol, `--dashboard --problem`
  and a left click in an error state reopen it. It holds the one-liner, raw detail and since, the class's
  primary action and Copy diagnostics, the last 20 log lines, the last 10 problems, and version, paths and
  a disabled Verify button (M2).
- **Keyboard:** Tab runs down the left column, then the right. F6 jumps to the first control of the other
  column. Esc leaves the error panel, then closes the window. `--settings` puts the focus on Start/Stop;
  with a problem the initial focus is the problem button.
- A second request (menu item, icon click, another `--settings`) writes `status`, `settings` or
  `diagnostics` to `%TEMP%\aap-runner-tray\view.request` and focuses the open window, which takes the file.

## Icon (after Fathom's `mark.rs`)

- Tray: a monochrome slab **R** drawn in code (`src/mark.rs`), hand-tuned at 16/20/24 px, 32 = 16
  doubled; the size follows `GetDpiForSystem` (16 at 100 %, 20 at 125 %, 24 at 150 %, 32 at 200 %).
  Ink is white on a dark taskbar and `#1a1a1a` on a light one (HKCU `...\Themes\Personalize`
  `SystemUsesLightTheme`, re-read every 2 s).
- State overlay, clear of the R: off/unknown/not installed = outlined R, starting/idle/draining =
  solid R, running = dot bottom-right, paused = short bar right, error = dot top-right.
- Exe icon: the same R, white on a graphite tile, in `assets/aap-runner-tray.ico` (16/24/32/48/64/256),
  embedded by `build.rs` via `embed-resource` (needs the Windows SDK resource compiler). After changing
  the glyph run `cargo run --example gen_ico`; a test fails if the committed `.ico` is stale.
- Event loop: a raw Win32 `PeekMessageW` pump on the main thread drives `tray-icon` (no tao); the
  Win32 calls live in `src/win.rs`.

## Build

Standalone crate, not part of the repository's root workspace. The repo's `.cargo/config.toml`
puts build output in the root `target/`.

```
cd crates/tray
cargo build --release
cargo test
```

The release binary is copied by hand to `C:\TOOLS\git_runner\aap-runner-tray.exe`. No autostart is registered by this crate.
