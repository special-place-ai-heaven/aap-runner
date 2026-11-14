# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Note: recorded as `web` only because the schema has no desktop value. This is a native desktop app (Rust, egui window plus a tray icon) for Windows and Linux, not a website. Current work is improving that GUI.

Cross-platform is non-negotiable (owner): the tray must work on both Windows and Linux, and its frontend must look the same on both. Today's implementation is Windows-only (raw Win32 pump, `src/win.rs`); the Linux tray does not exist yet.

## Users

The owner/operator of a Windows PC that hosts the runners. They are a technical person who installs it once through the first-run wizard, then glances at it in the tray to see whether the pool is up and busy, and occasionally resizes, pauses, verifies or repairs it. (Confirmed by the owner.)

## Product Purpose

Run ephemeral self-hosted GitHub Actions runners on a Windows PC. Each job runs in a fresh Sysbox container inside a locked-down WSL 2 distro, and the runner registers through a GitHub App. The tray is the only user surface: it shows runner state and writes the supervisor's inbox. Success is "informative at a glance": the owner can tell in under two seconds whether it is working, how busy it is and whether anything is wrong, and can click an error to see what it is.

## Positioning

A no-token, no-`wsl.exe` tray front-end over a locked-down distro, with a fresh container for every job. The GitHub App private key lives only inside the distro, and the tray cannot touch it. (Confirmed by the owner.)

## Operating Context

- Three parts: the distro manager (`distro/`), a PowerShell host supervisor (`supervisor/`) and the Rust tray (`crates/tray/`). The tray only reads and writes JSON files under `C:\ProgramData\aap-runner` (writes only under `inbox\`).
- One egui window in its own process: a fixed 260 px settings column on the left, observability on the right (header, one card per runner, last 60 minutes), an error panel, GitHub setup, Identity and a first-run wizard.
- Polls `status.json` every 5 s. Follows the Windows app theme (dark and light).
- Runs only while the installing user is logged on. Binaries are not code-signed.

## Capabilities and Constraints

- Linux profile in two tiers, up to 2 heavy and 10 light runners (settings schema 4; before it 0..5 untiered), and Windows profile 0..5. No Windows backend exists yet, so a Windows count is shown as "not installed", drawn as an outline in its picker, and starts nothing. The interim Windows runner on this PC has its own card; when the supervisor controls it, the Windows row is a 0 / 1 switch for it and Off, Pause and 0 stop it after its current job (older supervisors: it is only shown).
- Pool caps (CPU, memory, IO cap, sharing) are edited in the window, applied atomically, and bounded by the host VM minus a reserve.
- Actions (the owner controls everything from the tray): Power On/Off, Start/Stop, Pause/Resume, Apply/Revert, Verify, Repair, Open logs, Open job, GitHub setup, Identity.
- The tray never runs `wsl.exe`, holds no token, and never shows a console window. Every elevated action goes through one UAC prompt to the helper mode of the same exe.
- Install (owner requirement): the initial install is a single file. On Windows the exe is the sole binary. The user puts it in an `aap-runner` folder and runs it; install, setup and run all happen from there, and every other folder and file is created as needed. Linux follows the same model and is expected to be easier. The current installer copies the exe to `%ProgramFiles%\aap-runner` and stages PowerShell scripts; the owner's target is one self-contained file.
- The tray looks identical on Windows and Linux: same layout, symbols, colours and behaviour; only OS integration (tray icon, autostart, elevation) may differ.
- Interface contracts (`status.json`, `settings.json`, `inbox\*`) are versioned in `crates/tray/README.md`; a GUI change that touches them also updates the contract doc and the other sides' tests.
- Window size is bounded: 760 x 760 default and minimum height. The twelve Linux tiles (one fixed height, busy or idle), one Windows card and the 60-minute chart fit without scrolling in the default window, and the left column has no scroll area.

## Brand Commitments

- Name: AAP Runner. Icon: a monochrome slab "R" drawn in code (`crates/tray/src/mark.rs`) that stays exactly as drawn; state overlays sit clear of it.
- Linux is green and Windows is blue, with painted OS glyphs and no image assets. Usage bars stack a green Linux segment then a blue Windows segment.
- One symbol per state, the same in the tray, header and cards; shape carries the meaning and colour only adds to it. Symbols are painted, never font glyphs or emoji.
- Numbers and bars over prose. (From the owner's brief in `docs/tray-dashboard-design.md`.)

## Evidence on Hand

- `docs/images/tray.png`: screenshot of the current window.
- `docs/tray-dashboard-design.md`: owner brief, state symbol table and colours, tray icon layouts.
- `crates/tray/README.md`: full behaviour of the window, menu, wizard and helper.
- No user research, usage data or testimonials exist. Do not invent any.

## Product Principles

1. Glanceable first: state, load and problems are readable without hovering or clicking.
2. Trust is visible: the tray stays a thin, unprivileged view, and the UI never implies it holds secrets or runs jobs itself.
3. Honest about what does not exist: unavailable things (the Windows backend) are shown as not installed, never as running.
4. The tray is the whole product surface: no consoles, no scripts handed to the owner.
5. Fixed, predictable layout over scrolling and tabs.

## Accessibility & Inclusion

Keyboard operable: Tab down the left column then the right, F6 jumps between columns, Esc leaves the error panel then closes the window. Both Windows light and dark themes must work. State must never be conveyed by colour alone.
