# aap-runner-tray

Windows tray front-end for the self-hosted runner. The window only reads and writes JSON files in
`C:\ProgramData\aap-runner` (writes only under
`inbox\`, including `inbox\jobs\`) and opens the logs folder. It never runs `wsl.exe`. GitHub setup is the one place that calls the public GitHub API, and it sends no credentials.
The same exe has an elevated `--helper` mode (below) that shells out to the existing PowerShell install scripts, and replaces the installed tray exe for `update`.
On a fresh PC it opens the first-run wizard. Per-user setup drafts are stored under
`%LOCALAPPDATA%\aap-runner`; they never authorize elevated actions.

## Files (under `C:\ProgramData\aap-runner`, created by the install script)

Trust split: the tray writes only under `inbox\`; everything it reads from the root is
admin-written.

| File | Writer | Content |
|---|---|---|
| `inbox\state.json` | tray (atomic: `.tmp` then rename) | `{"desired":"on"}` or `{"desired":"off"}` |
| `inbox\settings.json` | tray (atomic) | `{"runner_count":1..5,"job_cpus":1..28,"job_memory_gib":1..80,"paused":false}` plus schema 2 keys; `"windows_runner_count":0..4` is reserved for a tray with a Windows backend and never written by this one in schema 2. Schema 3 ([`settings-v3.schema.json`](../../parity/contracts/settings-v3.schema.json), every key) over a stored schema 3 file, or while a fresh `status.v5.json` lists 3 in `settings_schemas`, see below |
| `inbox\tray.log` | tray, appended if `inbox\` exists | one line per failed write/spawn |
| `inbox\jobs\<id>.json` | tray | schema 1 request: `{"schema":1,"id":"<16 hex>","verb":"verify"|"repair"}`, or the `identity` request below. Install uses schema 2 (First-run wizard); `update` is schema 1 plus `exe_path` and `sha256` (Tray update). The elevated helper reads it. |
| `jobs\<id>\status.json` | elevated helper | schema 1: `state` is `queued`, `running`, `passed`, `failed`, or `rejected`, plus `step` and `exit_code`; a passed `update` adds `sha256` (the installed exe) |
| `jobs\<id>\log.txt`, `exit.txt` | elevated helper | live log and the process exit code |
| `status.json` | supervisor, never the tray | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"…","updated":"<RFC3339>","detail":"…","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/…/actions/runs/N"}` (the last five optional; `repo` and `run_url` may be `""`). Schema 4 adds `work_disk_gib`, `work_disk_free_gb`, `work_disk_floor_gb` and `cleaning`; schema 3 still reads, with no disk sample and cleaning false. A schema above 4 is rejected. |
| `status.v5.json` | supervisor, never the tray | [`status-v5.schema.json`](../../parity/contracts/status-v5.schema.json): both profiles, every backend's slots, storage, the legacy pool. Read at most 64 KiB; missing, unparseable, stale (over 180 s old, or `updated` in the future), a `schema` other than 5, or not exactly the Linux and Windows profiles = not there, and the tray keeps to `status.json` and settings schema 2. A Windows profile with `backend: windows-host` (the interim runner on this PC) replaces the window's Windows "not installed" text, see below |
| `logs\` | supervisor | opened by "Open logs" via `C:\Windows\explorer.exe` (absolute path) |

- `inbox\` missing: `Not installed`; Start/Stop/Restart, Pause/Resume and Settings are disabled.
- `status.json` missing, or `updated` older than 3 minutes (or, for a file too large or not UTF-8,
  not modified for 3 minutes): `Unknown (supervisor not running)`; the error panel says the service
  is not running and offers Restart service.
- `status.json` fresh but unusable by this build (larger than 64 KiB, not valid JSON for this build, a
  bad `updated`, an unknown `state` word, or `updated` more than 3 minutes in the future, a stepped-back
  PC clock; up to 3 minutes of skew is accepted): `Unknown (status file unreadable)`; the error panel
  says the file could not be read and why, and offers Open logs, not Restart service. Copy diagnostics
  carries the reason.
- `settings.json` missing, unparseable, out of range, or with fewer than 1 CPU / 1 GiB per runner:
  defaults `1 runner x 26 CPUs x 72 GiB / not paused`.
- 1 to 5 runners. `job_cpus` and `job_memory_gib` are the pool caps, not per job: the manager divides
  them by `runner_count` and rounds down to a whole CPU and whole MiB. The window's main input is
  Runners. Each runner's share of the caps is shown to one decimal (26 / 13 / 8.7 / 6.5 / 5.2 CPUs and
  72 / 36 / 24 / 18 / 14.4 GiB for 1 / 2 / 3 / 4 / 5 runners on a 28 / 80 VM). 24 cores and 72 GiB over
  5 runners is 4.8 cores and 14.4 GiB. The file stores the caps.
- Two profiles, Linux and Windows, 0..5 each, at most 5 together and never 0 + 0. No Windows
  backend exists yet, so Linux keeps at least 1 (Windows at most 4) and the Windows count starts
  nothing. It is kept tray-local in `%LOCALAPPDATA%\aap-runner\windows-runners.json`
  (`{"schema":1,"windows_runner_count":N}`, atomic write, missing or invalid = 0), never in
  `inbox\settings.json`: a supervisor older than the key rejects the whole file, Pause included.
  So every `settings.json` this tray writes (Apply, Pause/Resume) is byte-identical to before,
  `runner_count` stays the Linux count, the totals ignore the Windows count, and a Windows-only
  edit writes nothing to `limits.conf` and restarts nothing. The schema 2 key
  `windows_runner_count` stays reserved: the supervisor validates it when present and never
  applies it, for a future tray with a Windows backend. With a backend, every runner gets
  `cap / (linux + windows)` floored to whole CPUs and GiB, whatever its OS, and Linux's totals are
  that times the Linux count (3 Linux + 2 Windows on 26 / 72 caps: 5 CPUs and 14 GiB each, Linux
  15 / 42). The window shows that even share for Windows now, marked prospective. With Windows 0
  the file is exactly what it was before.
- Settings schema 4 (R1 tiers, [`settings-v4.schema.json`](../../parity/contracts/settings-v4.schema.json)):
  over a stored valid schema 4 file, or while a fresh `status.v5.json` lists 4, Apply and
  Pause/Resume write schema 4 (`linux_light_count` 0..10, `linux_heavy_count` 0..2 instead of
  `runner_count`, every other schema 3 key kept as below; the totals stay as stored, they are the
  WSL pool totals and the supervisor refuses tiers whose heavy x 20 + light x 3 GiB exceed the memory total); never schema 3 or 2 over a stored schema 4
  file. Otherwise the tray writes exactly what it wrote before: the Light count is the schema 2/3
  Linux count (1..5 with Windows, at most 5 together) and a Heavy count is refused. A schema 3 file is
  carried into schema 4 (its Linux count as the light count) once `status.v5.json` lists 4.
- Settings schema 3: over a stored schema 3 file, or while a fresh `status.v5.json` lists 3 (a
  supervisor with the capacity module), Apply and Pause/Resume write schema 3 instead, with every
  key; never schema 2 over a stored schema 3 file, also while `status.v5.json` is stale (a
  supervisor restart or a long block), missing or newer. The keys the window has no control for
  yet (`linux_backend`, `host_reserve_percent`, `share_mode`, both shares,
  `lease_wall_clock_hours`) are kept from the stored schema 3 file, else taken from what
  `status.v5.json` reports (lease 6 h), and so is the Windows count until a schema 3 file is
  stored: the tray-local choice never reaches the supervisor. A stored schema 3 file shows its
  own two counts (Linux 0 allowed) and Apply writes the edited ones. Every write is checked
  against the schema it writes: a write that breaks a schema 3 rule (Linux plus Windows over 5,
  shares that no longer fit the counts), or a schema 2 write with Linux 0, is refused and the
  file stays. A stored schema 3 file that fails a schema 3 rule reads as the defaults, like any
  bad file.
- Host caps: the VM size comes from `[wsl2]` `processors=` / `memory=` in `%USERPROFILE%\.wslconfig`
  (`GB`/`G`/`MB`/`M`; missing file or key: 28 CPUs / 80 GiB, shown as "assumed"). Totals may use at
  most VM minus 2 CPUs and VM minus 8 GiB (26 / 72 on a 28 / 80 VM).
- The tray never writes a file that breaks these rules: runners 1..5, totals in range, totals within
  the caps, and at least 1 CPU and 1 GiB per runner. This also covers Pause/Resume, so a hand-edited
  file above the cap must be fixed in the window first.

## Menu

State line (with applied limits when reported, e.g. `Idle · 2 runners · 24 cpu · 72 GiB total`; same text
as the tooltip), Open job, Start, Stop, Restart, Pause/Resume, Settings…, GitHub setup…, Identity…, Verify install, Repair install, Update tray…, Open logs, version, Quit.
Left click on the icon opens the same window.

- Dark menu: the menu follows the Windows app theme (HKCU `...\Themes\Personalize` `AppsUseLightTheme`).
  Before the menu is built the tray calls uxtheme's `SetPreferredAppMode(AllowDark)` (ordinal 135),
  `AllowDarkModeForWindow` (133) on tray-icon's hidden window, `RefreshImmersiveColorPolicyState` (104) and
  `FlushMenuThemes` (136), and sets `DWMWA_USE_IMMERSIVE_DARK_MODE` on that window. These exports are
  undocumented but stable since Windows 10 1809 and are loaded by ordinal from System32 (`src/win.rs`); if any
  is missing nothing is changed and the menu stays light. The theme is re-read every 2 s and the calls repeat
  when it flips; the menu itself is not rebuilt.

- Polls `status.json` every 5 s. Restart writes `off`, waits up to 15 min for `state: off`, then writes `on`.
  It always ends with `on` unless the owner changed it meanwhile: a timeout, a write error or a status that
  turns Unknown also writes `on`, and the status line and tooltip then read `Restart timed out after 15 min;
  runners left on` (or the matching reason) for 5 min; an `on` read back during the wait (Start in the
  window) ends the wait with nothing more written; Quit (or the update hand-off) while a restart waits writes
  `on` first.
- A Start, Stop, Pause or Open logs that fails shows its reason the same way (status line and tooltip, 5 min)
  and in `inbox\tray.log`; nothing shows the unwritten value as the state.
- Pause/Resume flips `paused` in `settings.json`; the label follows the file. When `settings.json` exists but
  the tray rejects it (bad value, unknown key in schema 3/4, over 64 KiB) Pause/Resume writes nothing and says
  `settings.json is not valid; fix it in Settings first`; a missing file still pauses from the defaults.
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
  `Pause`/`Resume` (immediate, as in the menu; Pause rewrites only `paused`). Power flips only after
  the write succeeded; a failed Start/Stop/Pause/Open logs/job link shows its reason on the note line. Then the edits: Linux
  `Light | Heavy` (which tier the picker edits; Heavy is greyed with a tooltip until the tray may
  write settings schema 4) with a muted `now 3` from `status.json` (the tooltip has
  `now 3 · 8.7 CPU 24 GiB`), the one count picker under it, labelled with the tier's glyph and name
  (light `0 | 1 | … | 10`, heavy `0 | 1 | 2`; before schema 4 light cells above the budget the
  Windows row leaves are greyed as before), and one line `Each 8.7 CPU 24 GiB of 26/72` (each
  runner's share and the written totals; the tooltip shows the totals against the caps and that the
  host keeps 2 CPU 8 GiB), under schema 4 the tier table instead (`Each 1 CPU 3 GiB cap 4/8`,
  `Each 8 CPU 20 GiB may burst`); Windows
  `0 | … | 5` with one amber line `not installed · 5 CPU 14 GiB` (the prospective even share; the
  tooltip says it is prospective and that nothing starts; `interim runner · online`,
  `busy` or `stopped` instead while `status.v5.json` reports `backend: windows-host`,
  its tooltip the full name, the stopped reason and the warning
  `Unisolated: jobs run directly on this PC (owner accepted 2026-10-20).`,
  and a Windows card with the same state and warning in the room the Linux slots leave; the line is
  cut with an ellipsis rather than widen the column). While no Windows backend runs the count, the
  selected Windows cell is an outline in the Windows colour, not a filled cell: a filled cell is a
  count in force. The row's tooltip carries the full
  `Windows backend not installed — coming with the native Windows runner` note. Cells above the
  budget the other row leaves are greyed and inert (Linux 0 too, until a Windows backend exists).
  Each row label carries its OS glyph and colour. IO cap 0..100 % in steps of 5, Sharing
  `Slice | Fixed`. IO cap and Sharing have a muted `now ·` line from `status.json`
  (`now -` when nothing runs). While edits differ from `inbox\settings.json`: `N changes not applied`,
  a cap error inline, and Apply (disabled on an error; writes schema 2 atomically, as the old dialog's
  OK did) and Revert (reloads the file). Below the settings: the pool bars (Cores, Memory, Disk with
  `N GiB free of M · floor P` (`· cleaning` appended to caption when manager cleans),
  `IO cap N pool · M each` (both caps known),
  `IO cap N pool` / `IO cap M each` (one cap known), `sampled N s ago`) with narrower tracks.
  Cores and Memory draw whenever the (fresh) status carries a usage sample (`sampled_at` set);
  an old sample still draws and its `sampled N ago` caption turns the over colour after 150 s
  (`sampled_at` is the distro's clock, and a failed `docker stats` keeps the previous sample).
  Disk comes with the status itself, not the sample. `no sample` means no value at all.
  All rows are fixed height; there is no scroll area in the left column. The footer
  (Verify/Repair/Open logs) follows in the normal top-down flow after a fixed gap.
  `SIZE[1]` = `MIN_SIZE[1]` = 760 px = max(left worst case 760, tile grid right 596); a test keeps
  the left worst case at most 780 pt (1080p at 125 %);
  a new left-column row that does not fit grows SIZE[1], never adds a scrollbar.
- **Profile identity:** Linux is a Tux-style penguin glyph in green, Windows the four-pane window
  in blue (both painted, both themes; no image assets). The Linux tiers have their own painted
  glyphs beside the penguin, also green: a kettlebell for heavy, a feather for light (picker label
  and every tile). The glyph and colour mark the row labels,
  the header, the selected cell of each count row, and every card, which also has a 3 px left
  edge in its profile's colour. Every usage bar (pool Cores/Memory/Disk, card CPU/Mem, the
  60-minute Cores/Memory columns) stacks a green Linux segment then a blue Windows segment, with a
  `Linux`/`Windows` legend on the pool's `sampled` row and the `Last 60 min` title. All observed
  usage is the Linux manager's, so the Windows segment stays empty while no backend exists.
- **Right column:** only observed values. A pinned header row (symbol, state, `Linux N/M busy`, and
  `Windows N not installed` while Windows runners are chosen (`Windows interim online`, `busy` or
  `stopped` while `status.v5.json` reports the interim runner on this PC, with the warning as its
  tooltip), `All OK` or
  the `1 problem` button). Off shows no counts, except `Windows interim online` or `busy`: that
  runner is its own scheduled task and keeps taking jobs while the pool is off, so the Off page
  then reads `Linux runners are off.` with the interim runner's card under it, and
  `Runners are off. No jobs are taken.` only when it is stopped or absent. Below the header (in every state including Off and Not installed): one
  status line for the current Verify/Repair job (format: `Verify · failed · exit 1` on failure,
  `Repair · running…` while active, `Verify · ok` on success; with a `· Open log`
  CollapsingHeader when log lines are available; log panel keyed on a fixed id, not the label text).
  Then the Linux tiles, every slot always drawn, all one fixed size busy or idle (72 px, two per
  row, six rows; a test measures the drawn grid):
  `Heavy 1`, `Heavy 2`, `Light 1` … `Light 10`, each with the penguin and tier glyphs, state and
  elapsed on one row, `title · repo` (a link to the run, full text and URL in a tooltip, copy
  button) or `Waiting for a job` on the second (a chosen slot that no runner reports, as while the
  service is down or starting, reads `No status` and `Not reported by the service` instead: no
  waiting runner is claimed), and on the third the slot's sampled CPU and memory
  against its share, busy or idle: `1.0/8 cores · 5.2/20 GiB` (heavy: the 8 CPU / 20 GiB
  reservation; light: the 4 CPU / 8 GiB cap; untiered: the even share of the pool), `-` for a
  value docker left out, in the over colour past the share, `no sample` with no sample. A slot the manager gave up on (`state` `retired`) shows the error symbol and colour, the word `Retired` and `gave up; restarts with the pool` in place of the job row, with no occupancy row; any other unknown state word still shows `Starting`. A tile shows the status slot of the same number (status-settings.md Tiers: heavy 1..2,
  light 3..12 under settings schema 4; before it slot N is `Light N` and the heavy tiles show none;
  with no readable status there is no slot to map, and a stored schema 4 file names the tiles by tier).
  A tile no stored count chooses and no runner reports is fully grey and dim (`Not chosen`, or
  `Needs settings schema 4` on the heavy tiles before it). Then one `Windows 1`… placeholder per
  chosen Windows runner (unchanged, 102 px), `Not installed` and `Starts nothing`, never shown as
  running. The interim runner's card names a stored Windows count on its second line
  (`Interim runner on this PC · Windows count 2 starts nothing yet`). The tiles, one Windows card
  (the interim runner) and the last 60 minutes fit the default height with every slot busy; more
  Windows cards scroll.
- **Error panel:** replaces the right column's cards, with `< Back to runners` on top. It opens by itself
  when the state enters an error class; the `1 problem` button, an error symbol, `--dashboard --problem`
  and a left click in an error state reopen it. It holds the one-liner, raw detail and since, the class's
  primary action and Copy diagnostics, the last 20 log lines, the last 10 problems, and version, paths,
  Verify install, and Repair install. An old manager's primary action is Repair install. An unreadable status file's is Open logs.
- **Keyboard:** Tab runs down the left column, then the right. F6 jumps to the first control of the other
  column. Esc leaves the error panel, then closes the window. `--settings` puts the focus on Start/Stop;
  with a problem the initial focus is the problem button.
- A second request (menu item, icon click, another `--settings`) writes `status`, `settings`, `github`, `identity` or
  `diagnostics` to `%TEMP%\aap-runner-tray\view.request` and focuses the open window, which takes the file.
  Verify install, Repair install and a refused Update tray… from the menu add the job id: `status <id>` in that
  file, or `--job <id>` (16 lowercase hex) after `--dashboard` when the tray starts the window.

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

## First-run wizard (`--setup`)

When neither `inbox\` nor `config.json` exists, startup opens setup instead of the
tray. An unfinished install journal keeps setup available after installation has
created `inbox\`. Existing installations continue to open the tray normally.

The pages are Prerequisites, GitHub setup, Identity, Sizing, Install, and Done.
GitHub setup and Identity reuse the existing pages and validation. Every checklist
uses checking/met/unmet/blocked rows, refreshes facts every 5 seconds and after
Re-check/Fix, enables Next only when every row is met, and advances after 2 seconds
of continuously met rows. Editing inputs or requesting a re-check resets the timer.
Missing requirements show the exact item and a settings link, command, or correction
action. Commands are offered to the operator; the tray never runs `wsl.exe`.

Prerequisites collect Windows build, virtualization, WSL package version, registered
Ubuntu-24.04 WSL2 distro, disk policy, NAT configuration, free C: space, current-account
administrator membership/UAC availability, HTTPS reachability, and executable trust.
Operator-distro curl/jq/sha256sum availability is an explicit manual confirmation:
registry registration alone does not prove those tools exist. Ubuntu 26.04 is not
supported. Runners remain available only while the installing user is logged on.

Sizing selects the Linux runner count (same rule as the window), total CPUs and memory, and a
60..512 GiB work disk. While no Windows backend exists the Windows row is hidden and one line says
`Windows runners: available after the native Windows backend`; the draft's Windows count is held
at 0, so nothing chosen can be lost at install. The install request carries only the Linux count
and the totals.
Validation reserves the existing VM headroom and also bounds sizing by detected
physical resources. Disk space must cover the fixed work disk plus installation
headroom. The current backend requires runner group `aap-crrr` and labels
`self-hosted,linux,crrr` for first installation.

Install sends schema 2 with exactly the existing identity fields, `schema`, `id`,
`verb:"install"`, and integer `runner_count`, `job_cpus`, `job_memory_gib`, and
`work_disk_gib`. The key path is a picker result, not key contents. The elevated
helper revalidates every field and streams the key using the existing checked-handle
identity implementation. No key bytes enter a request, checkpoint, or log.

The install-only bootstrap permits a fixed local executable whose path passes the
current-user/admin ownership and other-user write exclusion checks. UAC must be
approved by the same administrator account; cross-account elevation is unsupported.
The helper creates or validates protected directories before staging any scripts,
copies the executable into the fixed protected Program Files directory, and refuses
an existing different executable rather than overwriting it. Verify/Repair/Identity
retain their stricter admin-only executable gate. All verbs validate protected job
directories before materializing scripts.

Installation shows helper status and a bounded live log tail, with failure details,
Retry, log access, and Copy diagnostics. The helper refuses an existing pool or
upgrade and serializes install mutations. Its stages install the host, apply and
authenticate identity, install the supervisor, write selected settings, and start
the supervisor. Done launches the protected installed tray.

Resume files have separate trust roles:

| File | Writer and purpose |
| --- | --- |
| `%LOCALAPPDATA%\aap-runner\jobs\install\state.json` | Unprivileged schema 1 draft: page, sizing, submitted state, job id, operator confirmation, and process identity. Missing/empty LOCALAPPDATA falls back to temp like GitHub setup. Process identity is a read-only liveness hint. |
| `C:\ProgramData\aap-runner\jobs\install\state.json` | Admin-owned schema 1 journal: validated sizing/identity, job id, and phase `host`, `identity`, `supervisor`, `start`, or `done`. Elevated resume trusts only this fixed protected journal. |
| `C:\ProgramData\aap-runner\config.json` | Admin-owned completed-install marker/configuration, with validated non-secret identity and sizing. |

Closing and reopening resumes the page or active helper job. A dead helper is
classified as interrupted across repeated refreshes, making recovery available
without launching a duplicate install. Identity can be corrected before authentication
succeeds; completed host sizing remains bound. No draft can assert successful install.

Owner verification requires a disposable Windows VM with Ubuntu-24.04; never test
fresh installation against the active pool. Launch from Downloads, complete the
checklists, select sizing, approve one UAC prompt, and observe progress. Close and
reopen during installation, then confirm the protected tray opens and Verify passes.
Exercise declined UAC, a wrong App id corrected on retry, and an interrupted helper.
Automated tests use injected facts, headless egui frames, and mocked PowerShell
actions; they do not prove a live first installation or UAC/ACL behavior.

M4 installs the current Linux backend. The required native Windows/Ubuntu hosted
runner parity and planned zccache migration are assessed separately in
[`docs/github-runner-parity-audit.md`](../../docs/github-runner-parity-audit.md).

## Elevated helper

`aap-runner-tray.exe --helper <verb> <id>` with `<verb>` `verify`, `repair`, `identity`, `install`, or `update` and `<id>` 16 lowercase hex digits; `update` takes a third argument, the expected sha256 (Tray update).
The menu items write `inbox\jobs\<id>.json` and start that command through ShellExecute `runas` (one UAC prompt).
The helper accepts only schema 1 plus that verb and id; `identity` must carry the nine fields above, each re-checked, `install` (schema 2) its fields from the First-run wizard, `update` the five fields under Tray update, and `verify` and `repair` nothing else. Every directory it uses is
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

`identity` (`helper-run.ps1 -Verb identity -Id <id>`) reads `inbox\jobs\<id>.json` itself, re-checks every field with the rules above, and opens that request once (`CreateFileW` `GENERIC_READ`, `FILE_SHARE_READ` plus `FILE_SHARE_DELETE`, `OPEN_EXISTING`, `FILE_FLAG_OPEN_REPARSE_POINT` | `FILE_FLAG_BACKUP_SEMANTICS`). The JSON is at most 4096 bytes read from that handle, and the owner SID comes from `GetSecurityInfo` on the same handle, then `ProfileList`. It opens the key once the same way and checks that handle: a reparse point is `key file is a reparse point`, a directory is not a regular file, and `GetFinalPathNameByHandleW` (the `\\?\` prefix stripped) must be an `X:\...` path under the requester profile or the reason is `key file is not under <profile>`. Size comes from `GetFileSizeEx` (empty, or 16 KiB or more, refused). The PEM header is the first line from `ReadFile` on that handle; the buffer is cleared and the handle is seeked back to 0. The same handle is duplicated onto the one `wsl` stdin. There is no second open by name. Before `wsl`, `inbox\state.json` `desired` must be exactly `on` and `status.json` `state` must not be `draining` or `paused`, or the helper exits 2 with `pool is off; retry when idle or running` or `pool is <state>; retry when idle or running` and does not start `wsl`. Otherwise the observed status is a 6th argument, exactly `idle`, `running`, or `hold` (`hold` covers any other state, such as starting, error, or missing). Inside the distro the script writes `app.pem.tmp` (root, 0400) and `manager.conf.tmp` with `AAP_GITHUB_ORG`, `AAP_GITHUB_APP_ID`, `AAP_GITHUB_APP_INSTALLATION_ID`, `AAP_RUNNER_GROUP`, `AAP_RUNNER_LABELS`, and `AAP_GITHUB_APP_PRIVATE_KEY_PATH=/etc/aap-runner/app.pem` replaced in place (appended when missing) and every other line kept, then runs `AAP_MANAGER_CONF=manager.conf.tmp aap-runner-manager --check-limits`. Drain happens before the swap, and only when that 6th argument is `idle` or `running` and `systemctl is-active` is `active`. The loop count and sleep are `AAP_DRAIN_ITERS` (default 120) and `AAP_DRAIN_SLEEP` (default 5). On timeout it prints `FAIL pool did not drain in 10 min; retry when idle`, leaves the tmp files, does not swap, and exits 1. The swap copies an existing key to `app.pem.bak` (root, 0400), moves the new key into place, then moves the conf; if the conf move fails, the backup is moved back over the key (or the new key is removed when there was no backup). The backup is removed only after both moves succeed. A drain that is still active after 10 min runs `--undrain`, deletes the `.tmp` files, and exits with `FAIL pool did not drain in 10 min; retry when idle`, which is the tray step. After a drain that does finish, the helper re-reads desired and status before `--undrain` and `systemctl start`; if desired is off or the status is draining or paused it skips the restart and prints `identity installed; pool left paused`. `starting` and `error` are refused. `off` and a missing status are allowed only while the unit is inactive. A key with more than one hard link is refused. The key handle is the child stdin (`CreateProcessW` / `STARTF_USESTDHANDLES`); `WSLENV` is removed for that child and for the direct `wsl.exe` calls. `--undrain` and `systemctl start` run only when the 6th argument was `idle` or `running` and the drain finished; otherwise the new identity applies at the next start. The log carries `INFO identity org … app … installation … group … labels …`, `key installed: 1 file, N bytes`, `manager.conf updated: …`, the pool line, and `PASS identity` only when wsl exits 0 and a copied line starts with `key installed:` (exit 0 without that line is `FAIL identity key installed line missing`); never the key, the key path, or the conf. The scripts are compiled into
the exe and written under `jobs\<id>\scripts` before they run. The window tails `log.txt`.

The window finds the current job from `%TEMP%\aap-runner-tray\helper.json` (schema 1, id, verb, optional error). The window only accepts a result whose `id` it issued itself or was handed by the tray that just launched the job (`--job <id>`, or the `view.request` file when the window is already open; an id that is not 16 lowercase hex is not adopted); a file left by a previous run is ignored. A launch refusal, and an Update tray… pre-check refusal (written as an `update` pointer with `error`), is shown that way. The exception is `update` (below): for 15 minutes after the pointer was written, the window shows an update job it did not issue, but only from a job folder, its ancestors and a `status.json` that are all admin-only (the same rule as install resume).
The helper does not read that file. The supervisor does not read it either.

## Tray update

Update tray… (tray menu) replaces `C:\Program Files\aap-runner\aap-runner-tray.exe` with a build the
owner picks: one UAC prompt, then one confirmation box, no console. Only the installed tray offers
it (the tray checks its own handle-resolved path first).

1. The tray shows the classic Open dialog (`*.exe`, started in `%USERPROFILE%\Downloads`) and runs
   the candidate checks of step 5 on the pick, so a refused location is reported before the prompt.
   It reads the file (at most 64 MiB), computes its SHA-256 (CNG), and writes
   `{"schema":1,"id":"<16 hex>","verb":"update","exe_path":"C:\\...\\aap-runner-tray.exe","sha256":"<64 lowercase hex>"}`
   (exactly these five fields) to `inbox\jobs\<id>.json`. If that write fails nothing is started.
2. It starts `--helper update <id> <sha256>` through `runas`: the expected hash is also on the
   elevated command line, and every other verb takes exactly `<verb> <id>`. Once the prompt is
   accepted it opens the window on Status (left running) and quits itself; a declined prompt leaves
   it running.
3. In `--helper` mode (every verb) the process first calls
   `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)` and exits 2 if that fails. Then, when it
   runs from the installed path, it deletes `aap-runner-tray.exe.prev`: the build that replaced it
   has started, so the old one is no longer kept as a startable fallback. A `.prev` still running
   (an old window) stays until the next elevated run.
4. The helper, before copying anything, refuses unless it runs from exactly
   `C:\Program Files\aap-runner\aap-runner-tray.exe` (handle-resolved, compared case-insensitively),
   that exe is admin-only and on a fixed local drive, and its folder and every ancestor pass the
   admin-only checks above. It re-validates the request: schema 1, the id and verb match the command
   line, no identity or sizing field, `sha256` is 64 lowercase hex and equal to the command line's,
   and `exe_path` is a plain `X:\...\*.exe` under 1 KiB made of letters, digits, space, `_`, `.`, `-`
   and `\` only (so no UNC, `\\?\`, `\\.\`, `/`, `:` after the drive (no alternate data stream),
   `..`, quote or control character), with no empty or trailing-dot/space component and no DOS
   device name (`CON`, `NUL`, `COM1`…).
5. It opens the candidate once (`FILE_FLAG_OPEN_REPARSE_POINT`, sharing read only) and checks that
   handle: not a reparse point, a regular file, one hard link, 1 byte to 64 MiB, and
   `GetFinalPathNameByHandleW` equal to the requested path on a fixed local drive. Then the
   installer's location rule, with the elevated token's user: the file's owner (read from the same
   handle) is that user or Administrators, no other SID has an allow ACE with write, append,
   write-attributes, delete, write-DAC, write-owner or generic write/all on it, its folder passes the
   same test, and no ancestor lets another SID delete, delete a child, or change its DACL or owner.
   A refusal says to keep the new build in a folder only you, SYSTEM and Administrators can
   change (for example `C:\aap-builds` with inheritance removed).
6. It copies from that handle, create-new, into `C:\Program Files\aap-runner\staging\<id>.exe`. The
   staging folder is created owned by Administrators with SYSTEM and Administrators ACEs only (no
   Users read ACE), and an existing one that grants any other SID anything is refused.
7. It hashes the staged copy, never the user's file, and refuses a mismatch with the command line's
   `sha256` (the reason names only the expected hash: `status.json` is readable by every user). The
   staged copy must be an x64 (`0x8664`) PE32+ executable, not a DLL, whose version resource has
   `ProductName` `aap-runner-tray`, `OriginalFilename` `aap-runner-tray.exe` and a `FILEVERSION`
   (set in `assets/aap-runner-tray.rc` from the Cargo version). Downgrade rule: a `FILEVERSION`
   lower than the installed exe's is refused; an equal one is allowed (commits between version bumps
   share a version); an installed exe without a version resource counts as 0.
8. It shows a Yes/No box (system-modal, topmost, set to the foreground, No is the default) with
   the candidate path, size and sha256. Only Yes continues; a box that cannot be shown, or no
   answer within 5 minutes, is No. While the job is running (the box may be open) the window waits
   up to 9 minutes (the 4-minute no-result bound plus the 5-minute box bound) before it restarts the
   tray; the watch itself lasts 15 minutes.
9. The staged copy gets the installed tray's ACL (SYSTEM and Administrators full, Users read and
   execute, not inherited) and must then pass the admin-only check. Swap: a stale `.prev` is deleted
   first (if that fails nothing changes); the installed exe is renamed to `.prev` (retried for up to
   30 s) and given a protected DACL with no execute right (SYSTEM and Administrators may read and
   delete it), so it cannot be started or elevated before step 3 deletes it; then the staged copy is
   renamed into place. If either fails the `.prev` is renamed back and gets the installed tray's ACL
   again.
   Windows can rename a running image, so a window still running the old build keeps running from
   `.prev`.
10. `status.json` ends `passed` with step `installed sha256 <hex>` and `"sha256":"<hex>"`, and the
    log says `PASS update installed sha256 <hex>`. A refusal (bad request or command line, wrong
    install path, location, link, bad hash, not a PE, wrong product, older version, No in the box) is
    `rejected` with the reason and the old build stays; a failed swap is `failed`. The staged copy is
    deleted on every path.
11. The window shows the job (Update · passed · installed sha256 …). While the pointer names an
    update written in the last 15 minutes it does not close for a missing tray. Once the job has
    finished either way, or after 4 minutes with no result, and while no tray holds the lock, it
    starts the installed tray once, with the same checks as the wizard's Done. If the window is
    closed before that, the tray comes back at the next logon.

Threat model. `C:\ProgramData\aap-runner\inbox` is user-writable, and the tray runs as the owner,
so any program running as the owner can start an update by itself: write a request and start
`--helper update <id> <sha256>` through `runas`. No race is needed. UAC then names the installed
tray, not the candidate. The helper's confirmation box, which shows the candidate path, size and
sha256 and defaults to No, is a speed bump, not a boundary: it is not on the secure desktop, so a
program running as you can cover or imitate it, or press Yes through an input route it can obtain
(UIAccess-style). Compare the hash with the build you made and answer Yes only for an update you
started, but do not rely on the box against malware already running as you. The real fix is
Authenticode signing, which needs a certificate (owner decision Q8).

The build's source tree and output folder must be private too (only you, SYSTEM and
Administrators can change them). Otherwise another account can plant the build before you copy it,
and "keep it in a private folder" only launders that file. Build into a private output folder
outside the profile with inheritance removed, for example a `CARGO_TARGET_DIR` of `C:\aap-builds`.

What the helper does prevent: another account cannot supply or swap the build, because the
candidate must be owned by the requesting user or Administrators, writable only by them, in a
folder only they can write, with no ancestor another account can replace, and with one hard link;
the file cannot change between the check and the install, because only the helper's admin-only copy
is hashed and installed; it installs only an x64 tray-named executable whose version is not lower,
only at the one fixed path, and only from the installed tray. The version-resource names are a guard
against picking the wrong file, not a trust check: anyone can set them.

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

The tray is a member of the repository's root Cargo workspace. Cargo puts build
output in the root `target/`.

```
cd crates/tray
cargo build --release
cargo test
```

First-run installation copies the binary to `%ProgramFiles%\aap-runner\aap-runner-tray.exe`
(the `install-supervisor.ps1 -TrayExe` default). The supervisor installer registers
autostart. Existing live installations are updated only by the owner after review, through
Update tray… (above).
