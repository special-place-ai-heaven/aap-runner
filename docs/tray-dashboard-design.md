# AAP Runner: tray status dashboard (M1 UI)

Read on 2026-10-14: `tray/README.md`, `tray/src/{dialog,state,mark,main}.rs`, `tray/Cargo.toml`, `windows/aap-runner-supervisor.ps1`,
`windows/install-supervisor.ps1` (ACLs) and `tray-launcher-plan.md`. Nothing in the repo was changed.

Constraints carried over:
- eframe 0.36.2 (glow, accesskit, default_fonts), tray-icon 0.26, `windows` 0.62, and a raw Win32 pump in the tray process.
- The tray never talks to GitHub and writes only under `inbox\`.
- The monochrome R stays exactly as `mark.rs` draws it.

Owner brief: informative at a glance. Numbers and bars over prose. One symbol per state, the same everywhere.
Click an error to see what it is.

## 1. At a glance, three levels

1. **Tray icon (no hover).** The R plus a state symbol and 0-3 busy bars in the free strip to its right (section 2).
   A hollow R means the system is not up: Off, Not installed, Supervisor down. A solid R means it is up.
2. **Tooltip (hover), one line, at most 127 UTF-16 units.** This is the `NOTIFYICONDATA` limit. Job titles are cut with an ellipsis to fit.
   - Running: `AAP Runner · 2/3 busy · 14 cores · 41 GiB · Workspace, Backend Tests`.
     Cores and GiB are the sampled pool use. They are omitted when there is no sample.
   - Other states: `AAP Runner · Idle · 0/3 busy`, `AAP Runner · Error · Runner service keeps stopping`,
     `AAP Runner · Paused · 1 job finishing`.
   - The version moves out of the tooltip. It stays in the menu and the window title.
3. **Window header (under 2 s).** Row 1 answers "is it working, how busy, anything wrong".
   It shows the 24 px state symbol and state word, then `2/3 busy`.
   The right end shows either `All OK` (muted) or `1 problem`, which is a red button with the Error symbol that opens the error panel.
   Rows 2-3 are the pool bars for Cores and Memory, with numbers. All of this comes before any card.
4. **Card (no hover).** Row 1 shows the 20 px state symbol, the state word and the elapsed time.
   Row 2 is the job title, wrapping to two lines before an ellipsis. Below that are the repo and the bars.
   Nothing that tells state or job lives only in a tooltip.

## 2. State symbols (one per state, used in tray, header and cards)

The shape carries the meaning. Colour only adds to it, and only in the window. The tray icon stays monochrome in the existing two inks.

| State | Tray R | Symbol | Label | Dark | Light |
|---|---|---|---|---|---|
| Off | hollow | ring | Off | `#9A9CA2` | `#6B6E75` |
| Not installed | hollow | dash | Not installed | `#9A9CA2` | `#6B6E75` |
| Supervisor down (stale/missing status) | hollow | question mark | Service not running | `#FF7070` | `#C62828` |
| Starting | solid | three stacked dots | Starting | `#6CB4FF` | `#0B63C4` |
| Idle | solid | filled dot | Idle | `#ECECEE` | `#1A1A1A` |
| Running | solid | play triangle | Running | `#4CC38A` | `#1A7F4B` |
| Draining | solid | hourglass | Draining | `#E8B04A` | `#8A5A00` |
| Paused | solid | two bars | Paused | `#9A9CA2` | `#6B6E75` |
| Error | solid | exclamation | Error | `#FF7070` | `#C62828` |

### Tray icon layout

- **The badge strip.** At 16 px the R spans columns 1-10. Column 11 stays empty, so `mark.rs`'s no-touch rule holds.
  The badge strip is columns 12-15:
  - the symbol takes rows 0-6 (4 × 7);
  - busy bars are 4 × 2 at rows 14-15, 11-12 and 8-9, filled bottom-up, one per busy runner.
- **Other sizes.** Hand-tune 20 px (strip columns 15-19) and 24 px (columns 18-23) the same way. 32 px is 16 doubled, as today.
- **Code changes.** This replaces the five-value `Badge` enum with a `(state symbol, busy count)` pair.
  Extend the existing tests `every_badge_differs_and_overlays_never_touch_the_r` and the two-ink test to all 9 × 4 combinations.

16 × 16 sketches (`#` = ink), generated and checked by script for distinctness and for no contact with the R.
Busy bars are shown only in the Running and Draining examples.

```
Off                Not installed      Service not running
................   ................   .............##.
.########....##.   .########.......   .########...#..#
.#......##..#..#   .#......##..####   .#......##.....#
.#..#######.#..#   .#..#######.####   .#..#######...#.
.#..#...#.#..##.   .#..#...#.#.....   .#..#...#.#..#..
.#..#...#.#.....   .#..#...#.#.....   .#..#...#.#.....
.#..#######.....   .#..#######.....   .#..#######..#..
.#......##......   .#......##......   .#......##......
.#..###.#.......   .#..###.#.......   .#..###.#.......
.#..#.###.......   .#..#.###.......   .#..#.###.......
.#..#..###......   .#..#..###......   .#..#..###......
.#..#..###......   .#..#..###......   .#..#..###......
.#..#...###.....   .#..#...###.....   .#..#...###.....
.#..#...#.#.....   .#..#...#.#.....   .#..#...#.#.....
.####...###.....   .####...###.....   .####...###.....
................   ................   ................

Starting           Idle               Running, 2 busy
.............##.   ................   ............#...
.########.......   .########....##.   .########...##..
.#########...##.   .#########..####   .#########..###.
.##########.....   .##########.####   .##########.####
.####...###..##.   .####...###..##.   .####...###.###.
.####...###.....   .####...###.....   .####...###.##..
.##########.....   .##########.....   .##########.#...
.#########......   .#########......   .#########......
.########.......   .########.......   .########.......
.####.###.......   .####.###.......   .####.###.......
.####..###......   .####..###......   .####..###......
.####..###......   .####..###......   .####..###..####
.####...###.....   .####...###.....   .####...###.####
.####...###.....   .####...###.....   .####...###.....
.####...###.....   .####...###.....   .####...###.####
................   ................   ............####

Draining, 1 busy   Paused             Error
............####   ............#..#   .............##.
.########...#..#   .########...#..#   .########....##.
.#########...##.   .#########..#..#   .#########...##.
.##########..##.   .##########.#..#   .##########..##.
.####...###.#..#   .####...###.#..#   .####...###.....
.####...###.####   .####...###.#..#   .####...###..##.
.##########.....   .##########.#..#   .##########..##.
.#########......   .#########......   .#########......
.########.......   .########.......   .########.......
.####.###.......   .####.###.......   .####.###.......
.####..###......   .####..###......   .####..###......
.####..###......   .####..###......   .####..###......
.####...###.....   .####...###.....   .####...###.....
.####...###.....   .####...###.....   .####...###.....
.####...###.####   .####...###.....   .####...###.....
................   ................   ................
```

### Window symbols

- **Sizes.** 24 px in the header and 20 px in cards. Each is followed by its label in the state colour, and the symbol is drawn in that colour too.
- **Drawing.** Paint them with `ui.painter()`, never with a font glyph or emoji. `s` is the size and the stroke is `max(1.5, s/12)`.

| Symbol | Shape |
|---|---|
| ring | circle, r = 0.38s, stroke only |
| dash | rect 0.6s × 0.16s, centred |
| question | circle stroke r = 0.42s with "?" in 0.6s semibold Segoe UI inside |
| dots | three filled circles r = 0.09s, stacked |
| filled dot | filled circle, r = 0.32s |
| play | filled triangle pointing right, 0.6s tall |
| hourglass | two filled triangles meeting at the centre, top and bottom bars |
| pause | two filled rects 0.18s × 0.6s, 0.16s apart |
| exclamation | filled circle r = 0.42s with a vertical bar and a dot cut out in the card colour |

## 3. Window

- **Process.** `aap-runner.exe --dashboard` runs as its own process with its own lock, like `--settings`.
  - The tray's Win32 pump cannot host an eframe loop.
  - Left click on the tray icon spawns the window, or focuses it if it is already open.
  - When the state is Error or Service not running, left click opens it with the error panel shown.
  - Right click keeps the menu, and "Open dashboard" is added at the top of it.
- **Size and placement.** 440 px wide. Height fits the content: about 400 / 510 / 620 px for 1 / 2 / 3 runners, set with `ViewportCommand::InnerSize`.
  - It is placed bottom-right in the work area (`SPI_GETWORKAREA`) with a 12 px margin. It is not resizable and its position is not remembered.
  - It is a normal window, not always on top. It does not close on focus loss, because a job link moves focus to the browser.
  - It closes with the title-bar button, Esc, or a left click on the tray icon while it is focused.
  - The title is `AAP Runner · v0.4.0 (abcdef12)`, from `crate::version()`.
- **Empty states.** Each one gets one message line and one action button. The header row stays, so the symbol is always visible.

| State | Body | Action |
|---|---|---|
| Not installed | "AAP Runner is not installed on this PC." | none until M4 ("Set up") |
| Off | "Runners are off. No jobs are taken." | Start runners |
| Starting | Cards with empty tracks | none |
| Paused | Cards stay visible. The line reads "Paused · 1 job finishing" (or "no jobs"). | Resume |
| Error / Service not running | The error panel (section 5) replaces the cards | the class's primary action |

## 4. Layout (12 px window padding)

1. **Header.** Row 1 is described in section 1, step 3.
   - Rows 2-3 are pool bars: `Cores` and `Memory`. Each has a 56 px label, a 240 px track and right-aligned numbers.
   - The numbers are `14.2 / 24` and `41 / 72 GiB`. The caps are `job_cpus` and `job_memory_gib`.
   - Row 4 is muted text: `IO 88 / 200 MiB/s` on the left and `sampled 23 s ago` on the right.
2. **Cards,** one per slot (1-5), 8 px apart.
   - **Row 1:** `Runner 1` (13 semibold), the 20 px symbol and label, and the elapsed time right-aligned (`12m 04s`, `1h 03m`).
   - **Row 2:** the job title as a link, up to two lines, then a 24 × 24 copy button.
   - **Row 3:** the repo short name, muted.
   - **Rows 4-5:** Cores and Memory bars against this slot's share. The share is the pool cap divided by `runner_count`.
   - **Idle card:** the title row reads "Waiting for a job" and the bars sit at 0.
3. **History, "Last 60 min".** Two strips 28 px tall. Each has 60 one-minute columns, a 1 px cap line and a `cap 24` label.
   - A missing minute is a gap, never zero. Hovering a column shows `14:32 · 18.4 cores · 52 GiB`.
   - A text line underneath reads `Peak 24.1 cores at 14:12 · 66 GiB at 14:40`.
4. **Action row.** `Pause`/`Resume`, `Stop`/`Start` and `Settings…` on the left, `Open logs` on the right.
   - Each one does exactly what its menu item does today.
   - Stop's tooltip reads "Stops after running jobs finish".

### Links

- **Target.** The title opens `job_url` when it passes a new `valid_job_url` check, `^https://github\.com/O/R/actions/runs/\d+/job/\d+$`.
  Otherwise it opens `run_url` when it passes `valid_run_url`. Otherwise the title is plain text.
- **Open path.** Re-check on click, then open through `C:\Windows\explorer.exe`.
- **Copy button.** It copies the same URL with `ctx.copy_text` and shows "Copied" for 1.5 s.

## 5. Error panel

- **Opening it.** Click the Error or Service-not-running symbol in the header, the `1 problem` button, or a card symbol when `slots[].state` is `error`.
  Left-clicking the tray icon in an error state also opens it. It replaces the cards area, and Esc returns to the cards.
- **Contents, top to bottom:**
  1. **Summary.** The symbol, the class's plain one-liner (16 semibold) and the state colour.
  2. **Technical line.** The raw `detail` in 12 px monospace, selectable.
  3. **When.** `Since 14:02 (38 min)`. This is the timestamp of the last `status error job= <detail>` line in `supervisor.log`.
     If that line is missing, use the first time the tray saw the error.
  4. **Buttons.** One primary button for the class (filled, accent), then `Copy diagnostics` and `Open logs`.
  5. **"Last 20 log lines".** A fixed-height scroll area of 20 rows in 12 px monospace, with no wrapping.
     - Read the last 64 KiB of `logs\supervisor.log`. The operator has inherited ReadAndExecute on it, set by `Get-AapDataDirAcl`.
     - Keep the lines that match the class's keywords plus every `WARN` line, and fall back to the plain last 20 lines.
     - The manager journal is already in this log, because `Invoke-AapUnitStart` appends the last 5 journal lines.
     - If the file cannot be read, show "Log not readable" and keep Open logs.
  6. **"Recent problems".** The last 10 error transitions: time, class one-liner, and cleared time or "now".
- **Recent-problems storage.** The tray process keeps them in memory, appending one entry when the state enters a class and stamping it when it leaves.
  It mirrors them into the history file (section 8).
- **Copy diagnostics.** It copies plain text to the clipboard: version, local time, `status.json` verbatim, class, detail, the 20 log lines and the recent-problems list.
  It never includes `manager.conf` or the key, and the tray never reads them.

| Class | Matched on (`detail`, regex) | One-liner | Primary action |
|---|---|---|---|
| mount task failed | `^(could not start \S+:.*\|\S+ still \S+ after \d+ s\|\S+ LastTaskResult -?\d+); retry in \d+ s$` | The work disk could not be attached. Next try in 60 s. | Retry now |
| manager predates supervisor | equals `$AapOldManager` and the last `WARN probe exit N` has N = 1 | The runner software inside WSL is older than this app. | Repair (M2); Open logs until then |
| probe failed | equals `$AapOldManager` and the last `WARN probe exit N` has N ≠ 1 (for example -1 timeout or 2 missing file) | WSL did not answer the version check. | Retry now |
| manager restart loop | `^sysbox=\S+ manager=\S+; restart \d+ failed; retrying every \d+ s$` | The runner service keeps stopping (5 restarts). | Retry now |
| limits refused | `^limits \S+ refused: ` (in error or paused) | The new limits were rejected. The previous limits stay in use. | Settings… |
| supervisor not running | tray-derived: `status.json` missing or `updated` older than 180 s | The background service is not running. Last update 4 min ago. | Restart service |
| drain timeout | log line `drain timeout after \d+ s` (not a status today) | A job was stopped after the 6 h drain limit. | Open logs |
| other | any other `error` detail | the detail itself | Open logs |

Actions that need new work:
- **Retry now.** The tray writes `inbox\state.json` as `{"desired":"on","retry":<unix s>}`.
  The supervisor resets `OnFailures`/`Failures` and runs the next step immediately when `retry` changes. This is new supervisor code.
- **Restart service.** This runs `schtasks /run /tn AAP-CRRR-Supervisor`. **Unverified:** whether a non-elevated owner may start that task.
  Test it on Fresh. If it is refused, the action becomes Repair (M2).
- **Drain timeout.** It is detected from the log, so it lands in Recent problems as a past event and not as a current state.
  If the owner wants it on the icon, the supervisor would need to write it into `detail`.

## 6. Visual system

- **Theme.** Follow Windows with `ThemePreference::System`.
- **Contrast.** The ratios below were computed against the card colour. Text is at least 5.0. Bar fills are at least 3.2 against the track.

| Token | Dark | Light |
|---|---|---|
| bg / card | `#1E1F22` / `#26272B` | `#F5F5F7` / `#FFFFFF` |
| border (1 px) | `#3A3B40` | `#D6D7DB` |
| text / muted | `#ECECEE` (12.7) / `#A6A8AD` (6.3) | `#1A1A1A` (17.4) / `#5C5F66` (6.4) |
| link, focus, used fill | `#6CB4FF` (6.8; 5.0 vs track) | `#0B63C4` (5.8; 4.6 vs track) |
| track | `#3A3C42` | `#E3E4E8` |
| over share | `#E8B04A` (5.6 vs track) | `#B26E00` (3.2 vs track) |

The state colours are in section 2's table.

- **Bars.** 8 px tall with a 2 px radius. The track is the share and the fill is `min(used, share)`.
  - Use above the share adds a 6 px over-share segment at the right end.
  - The number then reads `9.4 / 8 over share` in the over-share colour, so the colour never stands alone.
  - With no sample, or a sample older than 150 s, only the track is drawn, with "no sample" in muted text.
- **Type.** Load `segoeui.ttf` and `seguisb.ttf` from `C:\Windows\Fonts`, falling back to egui's default fonts. The digits are tabular.
  Sizes: header state 16 semibold; slot name 13 semibold; body and numbers 13; captions and tooltips 12; monospace 12.
- **Spacing and edges.** The spacing scale is 4/8/12/16. Card padding is 12 × 10. Corners have a 4 px radius.
  Borders are 1 px. Shadows are off (`Shadow::NONE`), with no gradients and no transparency.
- **Motion.** Bars move with `animate_value_with_time(id, v, 0.15)`. The first paint is static.
  When `SPI_GETCLIENTAREAANIMATION` is off, the duration is 0. Nothing pulses or spins.

## 7. Interaction and accessibility

- **Tab order.**
  1. The header problem button.
  2. Each card's job link, then its copy button.
  3. History has no stops; its text line is the equivalent.
  4. The action row.
  In the error panel the order is the primary action, Copy diagnostics, Open logs, then the log area. Enter and Space activate. Esc backs out, then closes.
- **Focus.** The ring is 2 px in the focus colour, offset 2 px, and is never removed.
- **Targets.** Buttons are at least 24 px tall and the copy button is 24 × 24.
- **Screen readers.** Bars and symbols carry accesskit labels, for example "Runner 1, Running" and "Runner 1 cores 6.2 of 8".
- **Refresh.**
  - Every 5 s: re-read `status.json`, plus the log tail while the error panel is open.
  - Every 1 s: repaint for elapsed times and "sampled N s ago".
  - Usage numbers and history move only when `sampled_at` advances, about once a minute.

## 8. Data contract (`status.json`; every new field optional)

| Field | Unit | Status |
|---|---|---|
| `state`, `job`, `updated`, `detail`, `runner_count`, `job_cpus`, `job_memory_gib`, `repo`, `run_url` | text, RFC 3339, count, cores, GiB | exists, parsed today |
| `job_io_mbps`, `sharing` | MiB/s (docker reads "mb" as MiB), `slice`/`fixed` | in the manager, copied through in M1 |
| `schema` | int | new (M1) |
| `sampled_at`; `pool.cpu_cores`, `pool.mem_gib`, `pool.io_mbps` | RFC 3339; cores, GiB, MiB/s (float) | **new** |
| `slots[]`: `slot`, `state` (`idle\|running\|draining\|starting\|error`), `job`, `repo`, `run_url`, `job_url`, `started_at`, `cpu_cores`, `mem_gib` | int, enum, text, RFC 3339, float | **new** |

- **Fallback.** A missing `slots[]` gives one card built from today's fields.
- **History and Recent problems** live in the tray process: 60 samples of `(sampled_at, cores, GiB)` plus 10 error transitions.
  The tray mirrors them to `%TEMP%\aap-runner-tray\history.json` with `write_atomic`, because the window is a separate process.
  `// ponytail: per-user temp mirror, lost on reboot; move into status.json if the owner misses it.`

## 9. Mockups (dark; `#` used, `-` free, `!` over share)

```
+--------------------------------------------------+
| AAP Runner · v0.4.0 (abcdef12)               [x] |
+--------------------------------------------------+
| |> Running   3/3 busy                     All OK |
| Cores  ##################------    18.6 / 24     |
| Memory #############-----------    41 / 72 GiB   |
| IO 88 / 200 MiB/s               sampled 23 s ago |
| +----------------------------------------------+ |
| | Runner 1        |> Running           12m 04s | |
| | Build and test (ubuntu-latest)        [copy] | |
| | Agent_Army_Professionals                     | |
| | Cores  ############--------      6.2 / 8     | |
| | Memory #######-------------      9.1 / 24 GiB| |
| +----------------------------------------------+ |
| | Runner 2        |> Running            3m 41s | |
| | lint / clippy                         [copy] | |
| | symforge                                     | |
| | Cores  ####----------------      2.0 / 8     | |
| | Memory ####----------------      4.3 / 24 GiB| |
| +----------------------------------------------+ |
| | Runner 3        X  Draining          1h 03m  | |
| | Release build (windows-cross), finishing     | |
| | before stop                           [copy] | |
| | terminal-commander                           | |
| | Cores  ###################!  9.4 / 8 over    | |
| | Memory ####################   24 / 24 GiB    | |
| +----------------------------------------------+ |
| Last 60 min                                      |
| Cores  _.-=##=-..__.-==###==-.._.-=##=-.  cap 24 |
| Memory ..--=======-----=========----===   cap 72 |
| Peak 24.1 cores at 14:12 · 66 GiB at 14:40       |
| [Pause] [Stop] [Settings…]           [Open logs] |
+--------------------------------------------------+
```

```
+--------------------------------------------------+
| AAP Runner · v0.4.0 (abcdef12)               [x] |
+--------------------------------------------------+
| O  Off                                    All OK |
|                                                  |
|        Runners are off. No jobs are taken.       |
|                                                  |
|                 [ Start runners ]                |
|                                                  |
| [Settings…]                          [Open logs] |
+--------------------------------------------------+
```

```
+--------------------------------------------------+
| AAP Runner · v0.4.0 (abcdef12)               [x] |
+--------------------------------------------------+
| !  Error   0/3 busy                [! 1 problem] |
| ------------------------------------------------ |
| !  The runner service keeps stopping (5 restarts)|
| sysbox=active manager=failed; restart 5 failed;  |
| retrying every 300 s                             |
| Since 14:02 (38 min)                             |
| [ Retry now ]  [Copy diagnostics]    [Open logs] |
| Last 20 log lines                                |
| +----------------------------------------------+ |
| |14:31:02 unhealthy: sysbox=active manager=fa..| |
| |14:31:04 aap-runner-manager is failed after s..| |
| |...                                           | |
| +----------------------------------------------+ |
| Recent problems                                  |
| 14:02  now    Runner service keeps stopping      |
| 09:15  09:16  Work disk could not be attached    |
| [Pause] [Stop] [Settings…]                       |
+--------------------------------------------------+
```

The Service-not-running variant is the same panel. Its header symbol is `?`, its one-liner is "The background service is not running.
Last update 4 min ago.", its primary action is `Restart service`, and its log area shows the tail of `supervisor.log`.

## 10. Do not build

- A charts crate, a web view, or HTML. Bars, strips and symbols are about 150 lines of `Painter` calls.
- Coloured tray icons. The tray stays two-ink monochrome, and the symbol shape carries the state.
- Gradients, glass, shadows, emoji or icon fonts.
- Notifications beyond the existing error toast.
- Re-run or cancel for GitHub jobs. Those need GitHub access, which the tray does not have.
- An in-window log viewer beyond the 20-line tail. That is what Open logs is for.
- Remembered position, resizing, more than 5 cards, or faked per-second usage.

## Single-view layout

Owner change: no tabs, one window. It supersedes sections 3-4 where they conflict, and today's separate `--settings` dialog is retired.
`--settings` and the menu's "Settings…" open this same window. Palette, type, spacing, symbols and motion are as above.

- **Size.** Default 760 × 760, resizable, minimum 680 × 460, no maximum. Same bottom-right placement.
- **Columns.** The left column is a fixed 260 px. A 1 px border separates it from the right column, which fills the rest (at least 396 px).
  At the minimum size the right column scrolls vertically (`ScrollArea`) under a pinned header row.
- **Compact cards.** Three rows per card: symbol, state and elapsed; job title and repo on one line with an ellipsis and the full text in a tooltip; then the Cores and Memory bars side by side.
  With 5 runners the whole view fits at 760 × 760 without scrolling.

**Left column, top to bottom:**
1. **Power.** `Power  On`/`Off` is the desired state from `inbox\state.json`. The right column shows the actual state, so the two never repeat each other.
   Below it are `Start`/`Stop` and `Pause`/`Resume`. They act immediately, as the menu does.
   Pause rewrites the stored file with only `paused` flipped, so pending edits stay pending.
2. **Runners.** A segmented control `1 | 2 | 3`. Under each setting a muted "now …" line shows the applied value from `status.json`, or `-` when nothing runs.
3. **Each and total.** `Each 8 CPU 24 GiB` is derived as in today's dialog, with its own "now" line. Below it: `Total 24/26 CPU · 72/72 GiB` against the cap.
4. **IO cap.** A `DragValue` from 0 to 100, in steps of 5, followed by `%`. The "now" line shows `job_io_mbps` in MiB/s.
5. **Sharing.** A segmented control `Slice | Fixed`. Its tooltip reads "Slice: idle share can be borrowed. Fixed: hard limit per runner." It has a "now" line.
6. **Apply / Revert.** Shown only while the edited values differ from `inbox\settings.json`, under the line `2 changes not applied`.
   - Apply keeps today's OK rules: a cap error appears inline above it, and Apply is disabled while there is an error.
   - Revert reloads the file.
7. **Open logs,** pinned at the bottom.

**Right column:** the header row (symbol, state, `N/M busy`, `All OK` or `1 problem`), the pool bars, `IO … MiB/s` with `sampled N s ago`, the compact cards and the history strip.
The right column shows only observed values and has no inputs except links, copy buttons and the problem button.

**Diagnostics: option (b).** The right column swaps to the error panel from section 5, with `< Back to runners` at its top.
- An error leaves the cards empty, because the pool is down. Swapping therefore shows the panel at full height, including the 20-line log, without hiding anything useful.
- Option (a) would squeeze the panel into a few rows at 520 px. Option (c) would starve both columns below the 680 px minimum.
- It opens automatically when the state enters an error class, and `1 problem` reopens it after Back.

**Keyboard.** Tab goes left column top to bottom, then right column:
- Left: Start/Stop, Pause/Resume, Runners (arrow keys inside the segmented control), IO cap, Sharing, Apply, Revert, Open logs.
- Right: problem button, then each card's link and copy button. In the error panel: Back, the primary action, Copy diagnostics, the log area.
- F6 moves focus to the first control of the other column (`memory.request_focus`). Esc first leaves the error panel, then closes the window.
- The initial focus is the problem button when there is an error, otherwise nothing, so the first Tab lands on Start/Stop.

Dark, 3 runners (`|>` running, `X` draining, `!` over share):

```
+------------------------------------------------------------------+
| AAP Runner · v0.4.0 (abcdef12)                             [_][x]|
+----------------------+-------------------------------------------+
| Power  On            | |> Running  3/3 busy             All OK   |
| [Stop]  [Pause]      | Cores  ##############----   18.6 / 24     |
|                      | Memory ##########--------   41 / 72 GiB   |
| Runners [1][2][3]    | IO 88 / 200 MiB/s      sampled 23 s ago   |
|            now 3     | Runner 1  |> Running            12m 04s   |
| Each    8 CPU 24 GiB | Build and test · Agent_Army_Profess...    |
|    now  8 CPU 24 GiB | CPU ######--  6.2/8  Mem ###----  9/24    |
| Total  24/26 CPU     | Runner 2  |> Running             3m 41s   |
|        72/72 GiB     | lint / clippy · symforge                  |
| IO cap  [ 40 ] %     | CPU ##------  2.0/8  Mem #------  4/24    |
|    now 200 MiB/s     | Runner 3  X  Draining            1h 03m   |
| Sharing [Slice|Fixed]| Release build (windows-cross) · termi...  |
|    now Slice         | CPU #######!  9.4/8  Mem ######- 20/24    |
|                      | Last 60 min                               |
| 2 changes not applied| Cores  _.-=##=-..__.-==###==-..  cap 24   |
| [Apply]  [Revert]    | Memory ..--=======----======---  cap 72   |
|                      | Peak 24.1 cores 14:12 · 66 GiB 14:40      |
|                      |                                           |
|                      |                                           |
|                      |                                           |
| [Open logs]          |                                           |
+----------------------+-------------------------------------------+
```

Dark, error (the right column has swapped to Diagnostics):

```
+------------------------------------------------------------------+
| AAP Runner · v0.4.0 (abcdef12)                             [_][x]|
+----------------------+-------------------------------------------+
| Power  On            | !  Error  0/3 busy        [! 1 problem]   |
| [Stop]  [Pause]      | < Back to runners                         |
|                      | !  The runner service keeps stopping      |
| Runners [1][2][3]    |    (5 restarts)                           |
|            now 0     | sysbox=active manager=failed; restart 5   |
| Each    8 CPU 24 GiB | failed; retrying every 300 s              |
|    now  -            | Since 14:02 (38 min)                      |
| Total  24/26 CPU     | [Retry now] [Copy diagnostics]            |
|        72/72 GiB     | Last 20 log lines                         |
| IO cap  [ 40 ] %     | .....................................     |
|    now -             | :14:31:02 unhealthy: sysbox=active m.:    |
| Sharing [Slice|Fixed]| :14:31:04 aap-runner-manager is fail.:    |
|    now -             | :...                                 :    |
|                      | :....................................:    |
|                      | Recent problems                           |
|                      | 14:02  now    Runner service stopping     |
|                      | 09:15  09:16  Work disk not attached      |
|                      |                                           |
|                      |                                           |
|                      |                                           |
| [Open logs]          |                                           |
+----------------------+-------------------------------------------+
```
