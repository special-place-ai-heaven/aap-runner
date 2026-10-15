# aap-runner-tray

Windows tray front-end for the self-hosted runner. The window only reads and writes JSON files in
`C:\ProgramData\aap-runner` (writes only under
`inbox\`, including `inbox\jobs\`) and opens the logs folder. It never runs `wsl.exe`. GitHub setup is the one place that calls the public GitHub API, and it sends no credentials.
The same exe has an elevated `--helper` mode (below) that shells out to the existing PowerShell install scripts.

## Files (under `C:\ProgramData\aap-runner`, created by the install script)

Trust split: the tray writes only under `inbox\`; everything it reads from the root is
admin-written.

| File | Writer | Content |
|---|---|---|
| `inbox\state.json` | tray (atomic: `.tmp` then rename) | `{"desired":"on"}` or `{"desired":"off"}` |
| `inbox\settings.json` | tray (atomic) | `{"runner_count":1..5,"job_cpus":1..28,"job_memory_gib":1..80,"paused":false}` |
| `inbox\tray.log` | tray, appended if `inbox\` exists | one line per failed write/spawn |
| `inbox\jobs\<id>.json` | tray | schema 1 request: `{"schema":1,"id":"<16 hex>","verb":"verify"|"repair"}`. The elevated helper reads it. |
| `jobs\<id>\status.json` | elevated helper | schema 1: `state` is `queued`, `running`, `passed`, `failed`, or `rejected`, plus `step` and `exit_code` |
| `jobs\<id>\log.txt`, `exit.txt` | elevated helper | live log and the process exit code |
| `status.json` | supervisor, never the tray | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"…","updated":"<RFC3339>","detail":"…","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/…/actions/runs/N"}` (the last five optional; `repo` and `run_url` may be `""`) |
| `logs\` | supervisor | opened by "Open logs" via `C:\Windows\explorer.exe` (absolute path) |

- `inbox\` missing: `Not installed`; Start/Stop/Restart, Pause/Resume and Settings are disabled.
- `status.json` missing, unparseable, larger than 64 KiB (not read), or `updated` older than
  3 minutes: `Unknown (supervisor not running)`.
- `settings.json` missing, unparseable, out of range, or with fewer than 1 CPU / 1 GiB per runner:
  defaults `1 runner x 26 CPUs x 72 GiB / not paused`.
- 1 to 5 runners. `job_cpus` and `job_memory_gib` are the pool caps, not per job: the manager divides
  them by `runner_count` and rounds down to a whole CPU and whole MiB. The window's main input is
  Runners. Each runner's share of the caps is shown to one decimal (26 / 13 / 8.7 / 6.5 / 5.2 CPUs and
  72 / 36 / 24 / 18 / 14.4 GiB for 1 / 2 / 3 / 4 / 5 runners on a 28 / 80 VM). 24 cores and 72 GiB over
  5 runners is 4.8 cores and 14.4 GiB. The file stores the caps.
- Host caps: the VM size comes from `[wsl2]` `processors=` / `memory=` in `%USERPROFILE%\.wslconfig`
  (`GB`/`G`/`MB`/`M`; missing file or key: 28 CPUs / 80 GiB, shown as "assumed"). Totals may use at
  most VM minus 2 CPUs and VM minus 8 GiB (26 / 72 on a 28 / 80 VM).
- The tray never writes a file that breaks these rules: runners 1..5, totals in range, totals within
  the caps, and at least 1 CPU and 1 GiB per runner. This also covers Pause/Resume, so a hand-edited
  file above the cap must be fixed in the window first.

## Menu

State line (with applied limits when reported, e.g. `Idle · 2 runners · 24 cpu · 72 GiB total`; same text
as the tooltip), Open job, Start, Stop, Restart, Pause/Resume, Settings…, GitHub setup…, Verify install, Repair install, Open logs, version, Quit.
Left click on the icon opens the same window.

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
- GitHub setup… opens the same window with the checklist in place of the runner cards (`--github`).
- Quit closes the tray and the window it opened. It does not touch any file. If the tray process is gone without that (a crash), the window sees `aap-runner-tray.lock` free on its 5 s poll and closes. Single instance per user (file locks in `%TEMP%`).
- Tooltip: `AAP Runner: <state line> · v<version> (<commit>)`.
- While a job runs the state line reads `Running <repo short name> · <job>` (the part of `repo` after
  the slash), or `Running job <job>` when `repo` is empty.
- Open job (directly under the state line) is enabled only when `run_url` matches
  `^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$`, checked again on click;
  it opens the URL in the default browser via `C:\Windows\explorer.exe <url>`. Nothing else is opened.
- Version: `AAP Runner v0.5.0 (abcdef12)` (Cargo version, short HEAD stamped by `build.rs`, `local`
  without git) as a disabled item above Quit, in the tooltip, the window title and the error panel. `--version`
  prints it to stdout and exits 0 (GUI-subsystem exe: capture it, e.g. `& .\aap-runner-tray.exe --version | Write-Output`).

## Window (`--dashboard`, `--settings`, `--github`)

One egui window in its own process (`current_exe()`), one at a time (file lock in `%TEMP%`). Quit kills that process; otherwise it exits when the tray lock is not held. No tabs:
a fixed 260 px settings column on the left, a 1 px border, and the observability column on the right.
Default 760 x 760, resizable, minimum 680 x 460, placed bottom-right in the work area. Left click on the
tray icon opens it (or closes it when it is the active window). The layout is the "Single-view layout"
addendum of the design doc.

- **Left column:** `Power On/Off` (the desired state from `inbox\state.json`), `Start`/`Stop` and
  `Pause`/`Resume` (immediate, as in the menu; Pause rewrites only `paused`). Then the edits: Runners
  `1 | 2 | 3 | 4 | 5`, `Each 8.7 CPU 24 GiB` (derived), `Total 26/26 CPU · 72/72 GiB` against the caps, IO cap
  0..100 % in steps of 5, Sharing `Slice | Fixed`. Each has a muted `now …` line from `status.json`
  (`now -` when nothing runs). While edits differ from `inbox\settings.json`: `N changes not applied`,
  a cap error inline, and Apply (disabled on an error; writes schema 2 atomically, as the old dialog's
  OK did) and Revert (reloads the file). Open logs is pinned at the bottom.
- **Right column:** only observed values. A pinned header row (symbol, state, `N/M busy`, `All OK` or
  the `1 problem` button), pool bars, `IO … MiB/s` and `sampled N s ago`, one compact card per runner
  (state and elapsed; `title · repo` on one line with the full text in a tooltip and a copy button;
  CPU and Mem bars side by side), and the last 60 minutes. It scrolls at small sizes.
- **Error panel:** replaces the right column's cards, with `< Back to runners` on top. It opens by itself
  when the state enters an error class; the `1 problem` button, an error symbol, `--dashboard --problem`
  and a left click in an error state reopen it. It holds the one-liner, raw detail and since, the class's
  primary action and Copy diagnostics, the last 20 log lines, the last 10 problems, and version, paths,
  Verify install, and Repair install. An old manager's primary action is Repair install.
- **Keyboard:** Tab runs down the left column, then the right. F6 jumps to the first control of the other
  column. Esc leaves the error panel, then closes the window. `--settings` puts the focus on Start/Stop;
  with a problem the initial focus is the problem button.
- A second request (menu item, icon click, another `--settings`) writes `status`, `settings`, `github` or
  `diagnostics` to `%TEMP%\aap-runner-tray\view.request` and focuses the open window, which takes the file.

## GitHub setup

The menu item and `--github` swap the right column for a checklist. The left column stays the settings column. The input is an org slug or `owner/repo` (a `https://github.com/` prefix is stripped). The tray calls the public API (`GET /users/<owner>`, and `GET /repos/<owner>/<repo>` when a repo was given) with no token. The answer is cached in `%LOCALAPPDATA%\aap-runner\github-setup.json` (schema 1: the text, the group name, the manual ticks, and the resolved account). If `LOCALAPPDATA` is missing or empty, that file is placed under the temp directory instead. `history.json` stays in `%TEMP%`.

The lookup runs when Enter is pressed or the field loses focus, not on each keystroke. A submit while a lookup is running is kept and runs when that lookup finishes; only the latest of those submits is looked up. A 404, a rate limit, and a body that is too large or not UTF-8 are remembered for that text, so submitting it again does not call GitHub. A network error is retried after 5 s, then 10, 20, and 40, and only for the text that failed. Done ticks stay until a lookup resolves to a different account than the saved one. Checking, and a failed lookup, replace a saved account on the checklist, so a previous success does not keep Next enabled.

Rows are `checking`, met, unmet, or blocked. A row the app cannot see yet has a Done box. `rows` checks that row itself once an App id, installation id, or key file is supplied; this page passes those empty until the identity page (M3). The runner-group row always says to tick Allow public repositories. The create-app link passes that row's permissions as URL parameters (`public=false`, webhook off, self-hosted runners write, actions read). A user account is unmet (`Only organizations are supported; <login> is a user account.`) and the later rows stay blocked. A private repository still resolves the owner and does not block the later rows; the repository is marked unverifiable. Next stays disabled until every row is met, then the page returns to the runners after 2 s.

The workflow box is:

```
runs-on: {group: aap-crrr, labels: [self-hosted, linux]}
```

## Elevated helper

`aap-runner-tray.exe --helper <verb> <id>` with `<verb>` `verify` or `repair` and `<id>` 16 lowercase hex digits.
The menu items write `inbox\jobs\<id>.json` and start that command through ShellExecute `runas` (one UAC prompt).
The helper accepts only schema 1 plus that verb and id. A path in the file is rejected. Every directory it uses is
under `C:\ProgramData\aap-runner` or a fixed install path (`C:\wsl`, the work VHDX, the two task names). A junction
on the way is refused. `AAP_FAKE_BASE` is not consulted.

The tray exe and its folder must be owned by SYSTEM, Administrators, or TrustedInstaller. Any other SID is refused if an allow ACE on the exe or the folder itself grants write-data, append, write-attributes, delete, delete-child, write-DAC, write-owner, GENERIC_WRITE, or GENERIC_ALL, and any ACE that is not a plain allow or deny is refused. The window then says to move the exe. The first-run wizard (M4) must install it to an admin-only folder. Repair reads `status.json` before it starts, again before the VHDX remount, and again before `schtasks /End`. It refuses `starting`, `running`, and `draining`. A missing, unreadable, or unparseable `status.json` also refuses unless the `AAP-CRRR-Supervisor` task does not exist. An `updated` timestamp older than 180 s, or a status file with no `updated` at all, is not trusted; the task state is used instead. Repair also refuses when `wsl --list --running --quiet` lists `aap-runner`. That list only sees the distros of the account that approves the UAC prompt. Elevation and install refuse a UNC or mapped-drive path: the final path from `GetFinalPathNameByHandleW` (with `VOLUME_NAME_DOS`) must resolve to a fixed local drive. A plain `C:\\...` path satisfies the check; UNC and network-redirected paths do not. An ancestor is refused when its owner is not SYSTEM, Administrators, or TrustedInstaller, or when an ACE is not a plain allow or deny. Parents of the exe folder are checked the same way as the installer ancestor walk (delete, delete-child, write-DAC, write-owner, or generic all for a non-admin SID). The exe is opened and elevated at the path `GetFinalPathNameByHandleW` returns, so a link is not what gets the prompt. This gate stops another account from swapping the exe. It does not stop malware that is already running as the same user.

`verify` runs `install-host.ps1 -DryRun`, `install-supervisor.ps1 -DryRun`, the two scheduled-task queries, and
`systemctl is-active` for sysbox and the manager. `repair` runs `lock-acl.ps1` on `C:\wsl` and the work-disk files,
reinstalls the supervisor task, remounts the VHDX, and restarts `AAP-CRRR-Supervisor`. The scripts are compiled into
the exe and written under `jobs\<id>\scripts` before they run. The window tails `log.txt`.

The window finds the current job from `%TEMP%\aap-runner-tray\helper.json` (schema 1, id, verb, optional error). The tray only accepts a result whose `id` was issued by this process; a file left by a previous run is ignored.
The helper does not read that file. The supervisor does not read it either.

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
