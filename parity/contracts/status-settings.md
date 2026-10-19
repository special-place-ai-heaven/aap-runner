# Status and settings contract (settings schema 3 and status schema 5 drafts, revision 2)

Owners: **P12** (supervisor side, `supervisor/README.md`, both-side tests) and **P20** (tray).
Readers: P19, P22. Schemas: [`settings-v3.schema.json`](settings-v3.schema.json),
[`status-v5.schema.json`](status-v5.schema.json), [`tray-windows-choice.schema.json`](tray-windows-choice.schema.json).
These are DRAFTS frozen for shape: P12 lands them, updates the versioned contract docs
(`supervisor/README.md`, `crates/tray/README.md`) and both sides' tests in one PR, as CLAUDE.md requires.

Revision 2 (P02.2, 2026-10-20): `status.v5.json` reports the storage tiers; settings schema 3 is
unchanged and carries no path.

## What exists today (unchanged by P02)

- `inbox\settings.json` schema 2: `runner_count` 1..5 (the Linux count), `job_cpus` 1..28,
  `job_memory_gib` 1..80, `paused`, optional `schema` 2, `io_percent`, `sharing`, and the
  reserved `windows_runner_count` 0..4 with `runner_count` + it at most 5, validated and never
  applied. The current tray never writes `windows_runner_count`.
- `status.json` schema 4 (supervisor/README.md table). The current tray (`crates/tray/src/state.rs`)
  reports any `status.json` with `schema` above 4 as an error ("newer schema").
- Tray-local `%LOCALAPPDATA%\aap-runner\windows-runners.json`, schema 1,
  `{"schema":1,"windows_runner_count":0..4}`; the tray treats anything else as 0.
- Install journals (`jobs\install\state.json`, `config.json`) schema 1: unchanged.

## Settings schema 3 (DRAFT)

Same keys as schema 2 with the same meaning, plus `linux_backend`, `host_reserve_percent` (10..90),
`share_mode` (`even` | `per_profile`), `linux_share_percent`, `windows_share_percent`
(null in `even`). Every key is required in schema 3. Changes in range:

- `runner_count` (Linux) 0..5 and `windows_runner_count` 0..5, sum 1..5 (owner rule; schema 2's
  Windows 0..4 and Linux >= 1 existed only because no Windows backend did).
- `per_profile`: shares + reserve = 100; a profile with count 0 has share 0.
- `job_cpus`/`job_memory_gib` stay the legacy WSL pool totals. Precedence: shares win; the
  supervisor caps them to the Linux profile cap when it writes `limits.conf` and reports the
  applied values in `legacy_pool`. They are ignored while Linux is 0 or `linux_backend` is
  `hyperv-vm`.
- `lease_wall_clock_hours` (1..72, default 6), host cap per VM lease. Wall-clock rule (same text
  in allocator.md):
  `lease_wall_clock_hours` (default 6) counts from the reservation's `acquired_at`. Past it the
  slot is only flagged: `status.v5.json` `detail` names it for the owner. The wall clock never
  destroys a slot: a heartbeat-quarantined slot is destroyed only when GitHub reports its runner
  `offline` (or `absent`) and not busy, or the job is known to have ended; a runner GitHub reports
  `busy` is never destroyed, and its slot stays held and `cleanup_uncertain`.
- `linux_backend` (`wsl-legacy` default, or `hyperv-vm`) is supervisor-side: the tray offers no
  control for it and writes back the value `status.v5.json` reports. Only the cutover item (P27)
  flips it, and the supervisor refuses `hyperv-vm` (keeping the last valid settings) unless an
  Ubuntu generation is `active` in the catalog.

## Status schema 5 (DRAFT): a new file, not a new `status.json`

`C:\ProgramData\aap-runner\status.v5.json`, written by the supervisor in the same tick and with
the same atomic rename and validation rules as `status.json`. `status.json` keeps schema 4 and
its legacy-pool meaning so every installed tray keeps working. Content: overall `state`,
`settings_schemas` the supervisor accepts, `applied_settings_schema`, `capacity` (max 5, used,
free, reserve, share mode, host), exactly two `profiles` (OS, backend, count, share, per-runner
and profile caps, image generation and its state, cache state, availability), up to five `slots`
(profile, OS, backend, allocator lifecycle state, generation, job, repo, run and job URLs under
the existing strict patterns, usage), and `legacy_pool` (the schema 4 pool numbers). Every value
is re-validated before it is written, as today.

`generation_state` per profile, from the catalog and allocator (null exactly when
`image_generation` is null, for example the legacy pool):

| Catalog / allocator situation | `generation_state` |
|---|---|
| the profile's admissions use the catalog `active` generation and every live slot runs it | `active` |
| a newer generation is `active` while some live slots still run a `retired` one | `draining_old` |
| the `active` generation is flagged by P25 drift detection or is within the warning window before its evaluation expiry; admissions continue until replaced | `stale` |
| the generation reached its evaluation expiry: the catalog moves it to `quarantined` (never `active`) and admissions stop | `quarantined` |
| the profile's last generation was `quarantined` and no `active` one exists; no admissions | `quarantined` |

## Storage in status schema 5 (DRAFT, revision 2)

`status.v5.json` has a `storage` object built from the admin-only storage document
(backend-lifecycle.md, Storage tiers): `state`, `detail`, `volume_floor_gib` and, per tier
(`base`, `clone`, `scratch`, `staging`), the root, the free GiB of the volume that holds it and the
tier state. `unconfigured` means there is no storage document: no tiers and no floor. Otherwise all
four tiers are listed (`staging` with its effective root) and the overall state is the worst tier
state, in the order `missing`, `untrusted`, `low`, `ok`:

| Tier state | Meaning | Effect |
|---|---|---|
| `ok` | trust checks pass; free space at or above the floor | none |
| `low` | trust checks pass; free space below the floor | no new VM admission; running VMs continue within their admitted caps |
| `untrusted` | an owner, ACL, reparse, ancestor, drive-type or volume check fails; free space is reported when it can be read, otherwise null | VM profiles disabled |
| `missing` | the root or its recorded volume is absent; free space is null | VM profiles disabled |

While `storage.state` is not `ok`, every `hyperv-vm` profile reports `available: false` with the
reason. The tray shows the roots and free space and never changes them: the roots change only
through the elevated helper (a P19 verb, offered by the tray in P20) with the existing UAC prompt.
**Settings schema 3 carries no path.** `inbox\settings.json` is user-writable and the supervisor
reads only validated numbers and fixed words from it (`supervisor/README.md`); a root there would
let any process of the operator steer where the elevated supervisor writes and deletes.

## Allocator reasons in status detail (DECIDED, P09 review 2026-10-20)

When the allocator holds back, the top-level `detail` of `status.v5.json` starts with a fixed
reason word followed by a short ASCII explanation: `resize_waits` (a smaller count waits for its
running jobs to drain) or `pool_over_live` (a host measurement no longer holds the live
reservations; the stored host is clamped and nothing more is admitted). See allocator.md, Resize
and host measurement.

## Supervisor states and control distro uptime (DECIDED, owner 2026-10-19)

The WSL control distro and its keep-alive child run whenever desired is on and
Linux + Windows >= 1, because the broker (and the App key) live there. With Linux at 0 and
Windows >= 1 the distro still runs, the legacy manager is drained and stopped, and VM slots use
the broker. The existing rule "while Off the supervisor makes no `wsl.exe` call, so Vmmem can
exit" holds only when desired is off or both counts are 0. P12 writes this into
`supervisor/README.md` and its Pester tests.

## Compatibility rules (DECIDED)

| Writer / reader | Rule |
|---|---|
| New tray, old supervisor | no `status.v5.json`, so the tray writes schema 2 and keeps the Windows count tray-local (P20.0 behaviour) |
| New tray, new supervisor | tray writes schema 3 only when `status.v5.json` is fresh (180 s) and lists 3 in `settings_schemas`; then it stops reading its tray-local file and may delete it |
| Old tray, new supervisor | old tray reads schema 4 `status.json` and writes schema 2; supervisor keeps accepting 1 and 2 forever (`settings_schemas` must contain 2) |
| Downgrade of the supervisor | an old supervisor rejects schema 3 with one warning and keeps the last valid settings; the new tray sees no `status.v5.json` and writes schema 2 again |
| Unknown future schema | supervisor: settings with `schema` above its maximum are rejected, last valid settings kept, one warning, status `detail` names it. Tray: `status.v5.json` with schema above 5 is ignored and the tray falls back to `status.json`; never shows readiness from a file it cannot read |
| Mixed state | schema 4 `status.json` describes the legacy pool only; Windows and VM slots appear only in `status.v5.json` |

## Negative fixtures

Settings: 3 + 3, 0 + 0, schema 4, a string count, reserve 5, shares summing to 95, a share for a
zero count. Status: six slots, a Windows slot labelled Linux, a non-GitHub run URL, schema 6, a
supervisor that stops accepting schema 2, a VM profile available while storage is untrusted, a
tier below the floor reported `ok`, a UNC root, unconfigured storage that lists tiers, a tier
listed twice or not at all, a `missing` tier with free space, a tier above the floor reported
`low`, and an overall `ok` beside a `low` tier. Valid storage examples: unconfigured (VM profile
unavailable), and `missing` with an `untrusted` tier that reports free space and one that cannot.
Tray-local: count 5, schema 2, a string, a missing count.
