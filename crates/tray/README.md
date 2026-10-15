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
| `inbox\jobs\<id>.json` | tray | schema 1 request: `{"schema":1,"id":"<16 hex>","verb":"verify"|"repair"}`, or the `identity` request below. The elevated helper reads it. |
| `jobs\<id>\status.json` | elevated helper | schema 1: `state` is `queued`, `running`, `passed`, `failed`, or `rejected`, plus `step` and `exit_code` |
| `jobs\<id>\log.txt`, `exit.txt` | elevated helper | live log and the process exit code |
| `status.json` | supervisor, never the tray | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"…","updated":"<RFC3339>","detail":"…","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/…/actions/runs/N"}` (the last five optional; `repo` and `run_url` may be `""`). Schema 4 adds `work_disk_gib`, `work_disk_free_gb`, `work_disk_floor_gb` and `cleaning`; schema 3 still reads, with no disk sample and cleaning false. A schema above 4 is rejected. |
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
as the tooltip), Open job, Start, Stop, Restart, Pause/Resume, Settings…, GitHub setup…, Identity…, Verify install, Repair install, Open logs, version, Quit.
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
- Identity… opens the same window with the identity page in place of the runner cards (`--identity`).
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

## Window (`--dashboard`, `--settings`, `--github`, `--identity`)

One egui window in its own process (`current_exe()`), one at a time (file lock in `%TEMP%`). Quit kills that process; otherwise it exits when the tray lock is not held. No tabs:
a fixed 260 px settings column on the left, a 1 px border, and the observability column on the right.
Default 760 x 760, resizable, minimum 680 x 460, placed bottom-right in the work area. Left click on the
tray icon opens it (or closes it when it is the active window). The layout is the "Single-view layout"
addendum of the design doc.

- **Left column:** `Power On/Off` (the desired state from `inbox\state.json`), `Start`/`Stop` and
  `Pause`/`Resume` (immediate, as in the menu; Pause rewrites only `paused`). Then the edits: Runners
  `1 | 2 | 3 | 4 | 5`, `Each 8.7 CPU 24 GiB` (derived), `Total 26/26 CPU · 72/72 GiB` against the caps, IO cap
  0..100 % in steps of 5, Sharing `Slice | Fixed`. Each has a muted `now ·` line from `status.json`
  (`now -` when nothing runs). While edits differ from `inbox\settings.json`: `N changes not applied`,
  a cap error inline, and Apply (disabled on an error; writes schema 2 atomically, as the old dialog's
  OK did) and Revert (reloads the file). Below the settings: the pool bars (Cores, Memory, Disk with
  `N GiB free of M · floor P`, `IO · MiB/s`, `sampled N s ago`) with narrower tracks to fit the column width.
  Verify install, Repair install, and Open logs are pinned at the bottom.
- **Right column:** only observed values. A pinned header row (symbol, state, `N/M busy`, `All OK` or
  the `1 problem` button). Below the header (in every state including Off and Not installed): one
  status line for the current Verify/Repair job (format: `Verify · failed · exit 1` on failure,
  `Repair · running…` while active, `Verify · ok` on success; with a `· Open log`
  CollapsingHeader when log lines are available; log panel keyed on a fixed id, not the label text).
  Then one compact card per runner (state and elapsed; `title · repo` on one line with the full
  text in a tooltip and a copy button; CPU and Mem bars side by side). Five cards fit the default
  760 px window height without scrolling. The last 60 minutes follows below (scrolls at small sizes).
- **Error panel:** replaces the right column's cards, with `< Back to runners` on top. It opens by itself
  when the state enters an error class; the `1 problem` button, an error symbol, `--dashboard --problem`
  and a left click in an error state reopen it. It holds the one-liner, raw detail and since, the class's
  primary action and Copy diagnostics, the last 20 log lines, the last 10 problems, and version, paths,
  Verify install, and Repair install. An old manager's primary action is Repair install.
- **Keyboard:** Tab runs down the left column, then the right. F6 jumps to the first control of the other
  column. Esc leaves the error panel, then closes the window. `--settings` puts the focus on Start/Stop;
  with a problem the initial focus is the problem button.
- A second request (menu item, icon click, another `--settings`) writes `status`, `settings`, `github`, `identity` or
  `diagnostics` to `%TEMP%\aap-runner-tray\view.request` and focuses the open window, which takes the file.

## GitHub setup

The menu item and `--github` swap the right column for a checklist. The left column stays the settings column. The input is an org slug or `owner/repo` (a `https://github.com/` prefix is stripped). The tray calls the public API (`GET /users/<owner>`, and `GET /repos/<owner>/<repo>` when a repo was given) with no token. The answer is cached in `%LOCALAPPDATA%\aap-runner\github-setup.json` (schema 1: the text, the group name, the manual ticks, and the resolved account). If `LOCALAPPDATA` is missing or empty, that file is placed under the temp directory instead. `history.json` stays in `%TEMP%`.

The lookup runs when Enter is pressed or the field loses focus, not on each keystroke. A submit while a lookup is running is kept and runs when that lookup finishes; only the latest of those submits is looked up. A 404 is remembered for that text, so submitting it again does not call GitHub. A rate limit is remembered until the Retry-After (seconds or an HTTP-date) or X-RateLimit-Reset time, 60 s when neither is usable and at most 1 h, and the account row says try again at that time in local time; losing focus does not query again before then. A body that is too large or not UTF-8 is remembered for that text and is not retried as a network error. A network error is retried after 5 s, then 10, 20, and 40, and only for the text that failed. Done ticks stay until a lookup resolves to a different account than the saved one. Checking, and a failed lookup, replace a saved account on the checklist, so a previous success does not keep Next enabled.

Rows are `checking`, met, unmet, or blocked. A row the app cannot see yet has a Done box. `rows` checks that row itself once an App id, installation id, or key file is supplied: the identity page's valid App id ticks Create a GitHub App, its installation id ticks Install the app, and a key file that passes its checks ticks Private key. The last finished Verify's `app-token` row sets Create a GitHub App and Install the app to pass or fail (`The app did not authenticate.`); the runner-group row has no API check and stays a manual tick. Those values live in memory for the window's lifetime; the Done ticks stay on disk. The runner-group row always says to tick Allow public repositories. The create-app link passes that row's permissions as URL parameters (`public=false`, webhook off, self-hosted runners write, actions read). A user account is unmet (`Only organizations are supported; <login> is a user account.`) and the later rows stay blocked. A private repository still resolves the owner and does not block the later rows; the repository is marked unverifiable. Next stays disabled until every row is met; Next, or 2 s after the last row is met, opens the identity page.

The workflow box is:

```
runs-on: {group: aap-crrr, labels: [self-hosted, linux]}
```

## Identity

The menu item, `--identity`, and Next on the GitHub setup page swap the right column for the identity page. Rows, in order: Organization (read-only, the login the GitHub setup page resolved; every other row is blocked until there is one), App id, Installation id, Runner group (default `aap-crrr`), Labels (comma list, default `self-hosted,linux,crrr`, the line `manager.conf.example` ships), and Private key file (a text field plus Browse…, the classic Open dialog filtered to `*.pem`, started in `%USERPROFILE%\Downloads`). Each row is met, unmet with the exact reason, or checking; the key file is re-checked every 5 s and at once when the path changes. The checks are pure functions in `src/identity.rs`:

- An id is `[1-9][0-9]*` that fits a u64: no sign, no zero, no leading zero (`App id must be a positive integer`).
- Org and group are GitHub slugs: 1 to 39 of `[A-Za-z0-9-]`, no leading, trailing, or double hyphen.
- Labels are trimmed, empty items dropped, duplicates dropped, each `[a-z0-9-]+`, at least one.
- The key file is a regular file (`symlink_metadata`, and `FILE_ATTRIBUTE_REPARSE_POINT` on the file itself is refused), under `%USERPROFILE%` by canonical path, 1 to 16383 bytes, and its first line is exactly `-----BEGIN RSA PRIVATE KEY-----` or `-----BEGIN PRIVATE KEY-----` (CR stripped). Only the size and that first line are read, into a buffer zeroed before it is dropped. The window keeps the path and nothing else; folders on the way are left to the helper.

The typed text (ids, group, labels, key path; never the key) is `%LOCALAPPDATA%\aap-runner\identity.json` (schema 1), under the temp directory when `LOCALAPPDATA` is missing or empty. Apply is enabled only when every row is met and the pool gate is clear. `pool_block` disables Apply and the page shows the reason when desired is not exactly on (`pool is off; retry when idle or running`) or the status word is draining or paused (`pool is <state>; retry when idle or running`). It writes an `identity` request and starts the helper exactly as Verify does (same id, pointer, and job folder rules); the status line and log above the rows follow `jobs\<id>\`. The request is

```
{"schema":1,"id":"<16 hex>","verb":"identity","org":"acme","app_id":123,"installation_id":456,"group":"aap-crrr","labels":"self-hosted,linux,crrr","key_path":"C:\\Users\\me\\Downloads\\app.pem"}
```

exactly those nine fields: the ids are JSON numbers, the labels are the normalised comma list, and `key_path` is a plain `X:\...` path under 1 KiB with no `..` or quote. The manager accepts only the group `aap-crrr` and a label line of `self-hosted,linux,<base label>`; the helper has the manager check the new file before it replaces anything, so another value is refused there with the manager's reason in the log.

## Elevated helper

`aap-runner-tray.exe --helper <verb> <id>` with `<verb>` `verify`, `repair`, or `identity` and `<id>` 16 lowercase hex digits.
The menu items write `inbox\jobs\<id>.json` and start that command through ShellExecute `runas` (one UAC prompt).
The helper accepts only schema 1 plus that verb and id; `identity` must carry the nine fields above, each re-checked, and the other two verbs must carry nothing else. Every directory it uses is
under `C:\ProgramData\aap-runner` or a fixed install path (`C:\wsl`, the work VHDX, the two task names). A junction
on the way is refused. `AAP_FAKE_BASE` is not consulted.

The tray exe and its folder must be owned by SYSTEM, Administrators, or TrustedInstaller. Any other SID is refused if an allow ACE on the exe or the folder itself grants write-data, append, write-attributes, delete, delete-child, write-DAC, write-owner, GENERIC_WRITE, or GENERIC_ALL, and any ACE that is not a plain allow or deny is refused. The window then says to move the exe. The first-run wizard (M4) must install it to an admin-only folder. Repair reads `status.json` before it starts, again before the VHDX remount, and again before `schtasks /End`. It refuses `starting`, `running`, and `draining`. A missing, unreadable, or unparseable `status.json` also refuses unless the `AAP-CRRR-Supervisor` task does not exist. An `updated` timestamp older than 180 s, or a status file with no `updated` at all, is not trusted; the task state is used instead. Repair also refuses when `wsl --list --running --quiet` lists `aap-runner`. That list only sees the distros of the account that approves the UAC prompt. Elevation and install refuse a UNC or mapped-drive path: the final path from `GetFinalPathNameByHandleW` (with `VOLUME_NAME_DOS`) must resolve to a fixed local drive. A plain `C:\\...` path satisfies the check; UNC and network-redirected paths do not. An ancestor is refused when its owner is not SYSTEM, Administrators, or TrustedInstaller, or when an ACE is not a plain allow or deny. Parents of the exe folder are checked the same way as the installer ancestor walk (delete, delete-child, write-DAC, write-owner, or generic all for a non-admin SID). The exe is opened and elevated at the path `GetFinalPathNameByHandleW` returns, so a link is not what gets the prompt. This gate stops another account from swapping the exe. It does not stop malware that is already running as the same user.

`verify` runs `install-host.ps1 -DryRun`, `install-supervisor.ps1 -DryRun`, the two scheduled-task queries,
`systemctl is-active` for sysbox and the manager, and `aap-runner-manager --check-token` (`PASS app-token obtainable`
or `FAIL app-token exit N`: the manager mints one App installation token with the installed key and discards it;
the token never leaves the distro). The dry run gets `-WorkDiskGiB` from `AAP_WORK_DISK_GIB` in the
distro's `/etc/aap-runner/manager.conf` (read with one `wsl -d aap-runner` call); without a distro, from the VHDX
size rounded to GiB; with neither, `install-host.ps1` keeps its default. `repair` runs `lock-acl.ps1` on `C:\wsl` and the work-disk files,
reinstalls the supervisor task, remounts the VHDX, and restarts `AAP-CRRR-Supervisor`.

`identity` (`helper-run.ps1 -Verb identity -Id <id>`) reads `inbox\jobs\<id>.json` itself, re-checks every field with the rules above, and opens that request once (`CreateFileW` `GENERIC_READ`, `FILE_SHARE_READ` plus `FILE_SHARE_DELETE`, `OPEN_EXISTING`, `FILE_FLAG_OPEN_REPARSE_POINT` | `FILE_FLAG_BACKUP_SEMANTICS`). The JSON is at most 4096 bytes read from that handle, and the owner SID comes from `GetSecurityInfo` on the same handle, then `ProfileList`. It opens the key once the same way and checks that handle: a reparse point is `key file is a reparse point`, a directory is not a regular file, and `GetFinalPathNameByHandleW` (the `\\?\` prefix stripped) must be an `X:\...` path under the requester profile or the reason is `key file is not under <profile>`. Size comes from `GetFileSizeEx` (empty, or 16 KiB or more, refused). The PEM header is the first line from `ReadFile` on that handle; the buffer is cleared and the handle is seeked back to 0. The same handle is duplicated onto the one `wsl` stdin. There is no second open by name. Before `wsl`, `inbox\state.json` `desired` must be exactly `on` and `status.json` `state` must not be `draining` or `paused`, or the helper exits 2 with `pool is off; retry when idle or running` or `pool is <state>; retry when idle or running` and does not start `wsl`. Otherwise the observed status is a 6th argument, exactly `idle`, `running`, or `hold` (`hold` covers any other state, such as starting, error, or missing). Inside the distro the script writes `app.pem.tmp` (root, 0400) and `manager.conf.tmp` with `AAP_GITHUB_ORG`, `AAP_GITHUB_APP_ID`, `AAP_GITHUB_APP_INSTALLATION_ID`, `AAP_RUNNER_GROUP`, `AAP_RUNNER_LABELS`, and `AAP_GITHUB_APP_PRIVATE_KEY_PATH=/etc/aap-runner/app.pem` replaced in place (appended when missing) and every other line kept, then runs `AAP_MANAGER_CONF=manager.conf.tmp aap-runner-manager --check-limits`. Drain happens before the swap, and only when that 6th argument is `idle` or `running` and `systemctl is-active` is `active`. The loop count and sleep are `AAP_DRAIN_ITERS` (default 120) and `AAP_DRAIN_SLEEP` (default 5). On timeout it prints `FAIL pool did not drain in 10 min; retry when idle`, leaves the tmp files, does not swap, and exits 1. The swap copies an existing key to `app.pem.bak` (root, 0400), moves the new key into place, then moves the conf; if the conf move fails, the backup is moved back over the key (or the new key is removed when there was no backup). The backup is removed only after both moves succeed. `--undrain` and `systemctl start` run only when the 6th argument was `idle` or `running` and the drain finished; otherwise the new identity applies at the next start. The log carries `INFO identity org … app … installation … group … labels …`, `key installed: 1 file, N bytes`, `manager.conf updated: …`, the pool line, and `PASS identity` only when wsl exits 0 and a copied line starts with `key installed:` (exit 0 without that line is `FAIL identity key installed line missing`); never the key, the key path, or the conf. The scripts are compiled into
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

The release binary is copied by hand to `%ProgramFiles%\aap-runner\aap-runner-tray.exe` (the `install-supervisor.ps1 -TrayExe` default). No autostart is registered by this crate.
