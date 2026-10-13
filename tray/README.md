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
| `status.json` | supervisor, never the tray | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"…","updated":"<RFC3339>","detail":"…","runner_count":N,"job_cpus":N,"job_memory_gib":N}` (the last three optional) |
| `logs\` | supervisor | opened by "Open logs" via `C:\Windows\explorer.exe` (absolute path) |

- `inbox\` missing: `Not installed`; Start/Stop/Restart, Pause/Resume and Settings are disabled.
- `status.json` missing, unparseable, larger than 64 KiB (not read), or `updated` older than
  3 minutes: `Unknown (supervisor not running)`.
- `settings.json` missing, unparseable, out of range, or with fewer than 1 CPU / 1 GiB per runner:
  defaults `1 runner x 26 CPUs x 72 GiB / not paused`.
- 1 to 3 runners. `job_cpus` and `job_memory_gib` are pool totals, not per job: the manager divides
  them by `runner_count`. The dialog's only input is Runners. CPUs and memory per runner are derived:
  `floor(cpu_cap / runners)` and `floor(mem_cap / runners)` (26 / 13 / 8 CPUs and 72 / 36 / 24 GiB for
  1 / 2 / 3 runners on a 28 / 80 VM). It writes per-runner x runners (26/72, 26/72, 24/72), so the
  totals always divide evenly.
- Host caps: the VM size comes from `[wsl2]` `processors=` / `memory=` in `%USERPROFILE%\.wslconfig`
  (`GB`/`G`/`MB`/`M`; missing file or key: 28 CPUs / 80 GiB, shown as "assumed"). Totals may use at
  most VM minus 2 CPUs and VM minus 8 GiB (26 / 72 on a 28 / 80 VM).
- The tray never writes a file that breaks these rules: runners 1..3, totals in range, totals within
  the caps, and totals divisible by `runner_count`. This also covers Pause/Resume, so a hand-edited
  file above the cap must be fixed in the dialog first.

## Menu

State line (with applied limits when reported, e.g. `Idle · 2 runners · 24 cpu · 72 GiB total`; same text
as the tooltip), Start, Stop, Restart, Pause/Resume, Settings…, Open logs, Quit.

- Polls `status.json` every 5 s. Restart writes `off`, waits up to 15 min for `state: off`, then writes `on`.
- Pause/Resume flips `paused` in `settings.json`; the label follows the file.
- Settings… starts its own exe (`current_exe()`) with `--settings`: a small egui window in its own process (one at a
  time) with Runners and Paused as inputs and the derived CPUs and memory per runner (read-only); a "running now" column from
  `status.json` (`running now: 4 per runner (8 total)`, or `running now: not running` when the
  state is off, paused, error, unknown or not installed); "Each runner: 8 CPUs, 24 GiB" and "Total: 24 CPUs, 72 GiB (cap 26 / 72 ÷ 3)"
  lines and the cap line; and OK/Cancel. OK is disabled with an inline error above a cap. A stored file that differs
  from what OK would write (not divisible, or not derived) loads floored, with a note that OK
  rewrites it.
- Quit closes the tray only; it does not touch any file. Single instance per user (file locks in `%TEMP%`).
- Tooltip: `AAP Runner: <state line> · v<version> (<commit>)`.
- Version: `AAP Runner v0.2.0 (abcdef12)` (Cargo version, short HEAD stamped by `build.rs`, `local`
  without git) as a disabled item above Quit, in the tooltip and the Settings title. `--version`
  prints it to stdout and exits 0 (GUI-subsystem exe: capture it, e.g. `& .\aap-runner-tray.exe --version | Write-Output`).

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
cd ops/self-hosted-runner/tray
cargo build --release
cargo test
```

The release binary is copied by hand to `C:\TOOLS\git_runner\aap-runner-tray.exe`. No autostart is registered by this crate.
