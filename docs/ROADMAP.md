# Roadmap: finish the parity architecture

Owner decision, 2026-11-04: keep the frozen parity architecture ([ARCHITECTURE.md](parity/ARCHITECTURE.md))
and finish it, rather than move to a Windows service, a web UI or an outside runner manager.
The process model stays: the unprivileged tray is the only user surface, the hidden elevated
supervisor logon task owns every backend, and the WSL control distro keeps the App key and the
broker. A Windows service is out because SYSTEM cannot start a WSL distro
(`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`). A web page is out for now: a listener in a privileged
process is new attack surface and a second UI.

Each step lands on `main` through pull requests that merge only on green CI. The live install
changes only on the owner's word. Ledger items keep their closure rules in [LEDGER.md](parity/LEDGER.md).

## R1. Tiered Linux pool under the allocator, and the tray remake

Owner-approved 2026-11-04. One Linux backend with two tiers, slice sharing kept:

| Tier | Slots | Labels | Per slot |
|---|---|---|---|
| heavy | 0..2 | `self-hosted, linux, x64, fresh, heavy` | reservation 8 CPU / 20 GiB, may burst to the pool, 4x CPU weight |
| light | 0..10 | `self-hosted, linux, x64, fresh, light` | reservation 1 CPU / 3 GiB, hard cap 4 CPU / 8 GiB |

No workflow in any other repository changes: jobs asking for `heavy` get only heavy slots, every
other job may use any slot. Reservations total 70 GiB of the 72 GiB pool.

Tray (owner's brief): one count picker with a Light | Heavy toggle (light 0..10, heavy 0..2;
Windows keeps its own row); compact runner cards, all one fixed size, every slot always drawn,
disabled slots fully grey and dim; new painted heavy and light icons beside the Linux and Windows
glyphs; the Windows row states its real backend and the exact missing prerequisite instead of
"not installed".

Work, in order:

1. Contract revision: settings and status schemas gain the tiers (new settings schema, status
   slots carry a tier); the identity rule accepts the two label lines. Ledger record first.
2. Manager: two tiers with their own labels, limits and slot numbering.
3. Supervisor: validates and applies the new settings; keeps reading older files.
4. Tray: the new controls and cards, with tests for sizes and the dimmed state.
5. Ledger P16: the allocator adopts the Linux pool as its first backend.

## R2. Windows host mode (one working Windows runner soon)

The interim runner (`FRESH-win-interim`, `C:\aap-win-interim`) becomes a managed backend: the
supervisor starts and stops its existing limited, non-elevated logon task; each runner takes one
job and registers with a just-in-time config from the broker instead of a standing registration.
The tray shows the mode and one warning line: it runs unisolated on this PC (owner accepted
2026-10-20). Retired when R3 is certified.

Proof that the runner takes jobs at all: `.github/workflows/windows-interim-smoke.yml`
(manual dispatch only).

## R3. Isolated Windows VM backend (the target)

Disposable Hyper-V VMs from a sealed Windows Server 2025 image on the `E:` storage root. Done:
P06 image builder, P10 backend core, P14 guest bootstrap. Remaining: P02.1 lab proof (gate D2,
owner-authorized lab run), P10.0 real Hyper-V network module, P10.6 six-hour lifetime cap,
P19 installer and elevation, P20 tray controls and diagnostics, certification of an image
generation. The tray shows a prerequisite checklist (Hyper-V on, image certified, storage root,
switch and NAT) in the wizard style; when every row is met the mode turns on and R2 retires.

## R4. Tray on Linux hosts

The same tray binary on a Linux machine. The manager runs natively under systemd and reads the
same versioned status and inbox files. No WSL on that path, so the background part is a plain
system service.

## R5. Optional: read-only status page

Only if remote viewing is wanted: served by the unprivileged tray on 127.0.0.1 with a per-session
token, status only, no controls.

## Pool facts behind R1 (2026-11-04)

The 8-minute queue on [self-hosted, linux, x64, fresh] was a full pool, not a fault: all five
slots ran real jobs from symforge, terminal-commander and others, the manager was active and
replenishing after every job, and the pool used 4.3 of 26 cores and 5.8 of 72 GiB. Found on the
way, each its own change: runner 2.338.0 in the image downloads 2.338.2 on every job; PID 1 in
the container is `runuser`, so orphans are not reaped (`docker create --init`); no `jq` or
system Node in the image; `manager.sh` logs "wait: pid ... is not a child of this shell" at the
`docker start` pipeline.
