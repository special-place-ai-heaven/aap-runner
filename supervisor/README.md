# aap-runner host supervisor (Windows)

`aap-runner-supervisor.ps1` turns the `aap-runner` WSL distro on and off,
pauses it, and changes its limits from small files that the tray (or a person)
writes. It runs as task `AAP-CRRR-Supervisor`, as the installing user, at
logon. SYSTEM cannot start a WSL distro (`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`),
so this is not a service. The script header lists the WSL facts this design
rests on.

**Logoff and shutdown stop the runner by design, and the next logon resumes
it.** The only reason is that WSL sessions belong to the logon session
(github.com/microsoft/WSL, LxssUserSessionFactory.cpp).

- **On:** runs the existing `AAP-CRRR-Mount-Work-Disk` task, starts a hidden
  `wsl.exe -d aap-runner --exec /bin/sleep infinity` that keeps the distro
  alive, runs `aap-runner-manager --undrain`, then
  `systemctl start sysbox aap-runner-manager`.
- **Health, every 60 s while On:** checks both units. If one is down it
  restarts them with backoff 10, 30, 60, 120, then 300 s. After 5 restarts
  without 10 healthy minutes the status is `error`, and it keeps retrying.
  A failed On sequence (mount task) has its own backoff with the same steps.
  A new `retry` in `inbox\state.json` resets both and tries again at once.
  Each tick also sets the `vmmemWSL` process to BelowNormal priority, so games
  and other interactive apps win CPU contention against CI jobs.
- **Off:** runs `aap-runner-manager --drain`, waits up to 6 h for the manager
  to exit after its job, then `wsl.exe --terminate aap-runner`. Flipping back to
  on while draining undrains instead. A job still running after the 6 h is
  never ended: the distro stays up, the status stays `draining`, and the next
  tick drains and waits again. Desired is read once more right before the
  terminate; on again there undrains instead.
- **While Off** it makes no `wsl.exe` call, so Vmmem can exit. Desired off is
  the only case: Linux + Windows is at least 1, and while On the distro runs
  even with Linux at 0, because the broker (and the App key) live there.
- **Old manager:** before its first `--drain`, `--undrain` or
  `--check-limits` call, the supervisor greps the installed manager for
  `--undrain`. An older manager ignores unknown flags and would start a full
  pool instead, so when the grep fails no manager flag is ever used. The
  status is `error` until `install-host.ps1` from this branch is re-run. On
  still starts the units with `systemctl`, settings are ignored, and Off
  cannot drain: it terminates the distro only once the manager is provably
  idle (its unit inactive, or its `status.json` says `idle` with every slot
  idle); a running job or an unreadable status keeps the distro up
  (`draining`) and the next tick looks again. A job the old manager starts
  right after that idle read still ends with the distro (it cannot be told
  to stop taking jobs).
- **After every `systemctl start`** it checks `is-active` and logs the last
  5 journal lines of a unit that did not come up.

## Contracts

The supervisor runs elevated and the tray does not, so the data folder is
split by trust:

- **`C:\ProgramData\aap-runner`** is owned by Administrators. SYSTEM and
  Administrators have full control, and the installing user can only read.
  The supervisor writes `status.json` and `logs\` here.
- **`C:\ProgramData\aap-runner\inbox`** is the only place the user can write.
  The user can create and delete files there but not folders, so no junction
  can be made inside it. The tray writes `state.json`, `settings.json` and
  `tray.log` there.
- **`inbox\jobs`** is created by the installer (and by the elevated helper)
  with that same ACL. The tray writes one request file per action,
  `inbox\jobs\<id>.json`. The supervisor does not read it. A junction there
  is refused like any other reparse point under the data folder.
- **The supervisor only reads `inbox\`.** It opens each file once and reads
  at most 4097 bytes; more than 4096 is refused. It never creates, renames or
  deletes anything there, so a planted link cannot redirect an elevated write.

| File | Writer | Content |
|---|---|---|
| `inbox\state.json` | tray or you | `{"desired":"on"}` or `{"desired":"off"}`, optionally with `"retry":<unix seconds>`. Anything else in `desired` counts as off and logs one warning. A `retry` larger than the last one seen (a whole number) resets the On and restart backoffs and runs the next attempt now. It logs `retry requested`. Nothing else is read from it. |
| `inbox\settings.json` | tray or you | `{"runner_count":1-5,"job_cpus":1-28,"job_memory_gib":1-80,"paused":true\|false}`. All four keys, whole numbers, a real boolean. Schema 2 adds optional `"schema":2`, `"io_percent":0-100` (whole number), `"sharing":"slice"\|"fixed"` and `"windows_runner_count":0-4` (whole number, `runner_count` plus it at most 5); a file without them (schema 1) is still read. In schema 1 and 2 `windows_runner_count` is validated when present and never applied, and `runner_count` stays the Linux count: they mean Linux `runner_count`, Windows 0, even shares, reserve 10. Schema 3 (only with the capacity module, see Capacity) has exactly the keys of [`settings-v3.schema.json`](../parity/contracts/settings-v3.schema.json): `runner_count` (Linux) and `windows_runner_count` 0-5 each and 1-5 together, `job_cpus`, `job_memory_gib`, `paused`, `io_percent`, `sharing`, `host_reserve_percent` 10-90, `share_mode` `even` (both shares null) or `per_profile` (shares 0-90, shares plus reserve 100, a share 0 exactly when its count is 0), `linux_backend` `wsl-legacy` or `hyperv-vm` (refused unless an Ubuntu generation is active) and `lease_wall_clock_hours` 1-72. A `schema` above the newest one this supervisor accepts (2 without the capacity module, 3 with it) is refused, the last valid settings stay, and the status `detail` names it until a valid file arrives. Anything else logs one warning and the last valid settings stay. Missing means no override and not paused. |
| `status.json` | supervisor | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"","updated":"<RFC3339>","detail":"","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/owner/name/actions/runs/ID"}`. The three numbers are what the manager reports as applied, or null. `repo` and `run_url` are the running job's, copied from the manager only when they match `owner/name` and `https://github.com/owner/name/actions/runs/<digits>` exactly, else empty. Both are empty while off or paused. Schema 4 writes `"schema":4` and adds `"work_disk_gib"`, `"work_disk_free_gb"`, `"work_disk_floor_gb"` and `"cleaning":true|false` (null and false unless the manager is idle, running, or draining; a schema 3 manager file still reads; a size outside 0-1024 is null). Schema 3 fields: `"sampled_at":"<RFC3339>"\|null`, `"pool":{"cpu_cores","mem_gib","io_mbps"}`, `"slots":[{"slot","state","job","repo","run_url","job_url","started_at","cpu_cores","mem_gib"}]`, `"job_io_mbps"` and `"sharing":"slice"\|"fixed"\|null`. They are copied from the manager only while it reports idle, running or draining; otherwise `slots` is `[]` and the rest null. Every value is re-checked: numbers in range (cores 0-1024, GiB 0-4096) else null, `repo` and `run_url` as above, `job_url` as `https://github.com/owner/name/actions/runs/<digits>/job/<digits>`, slot `state` one of idle, running, draining, starting, error, else empty. At most 5 slots. The manager's unix-second times are written as RFC 3339 UTC. An older manager without a `slots` list gives `[]`. Rewritten at least every 60 s. The tray calls it stale after 180 s. |
| `status.v5.json` | supervisor | Schema 5, [`status-v5.schema.json`](../parity/contracts/status-v5.schema.json), written in the same tick as `status.json` with the same atomic rename. `status.json` keeps schema 4 and describes the legacy pool only; `status.v5.json` has the overall `state` (`running` also when only a VM slot is busy), the `detail` as one line of printable ASCII (at most 300), `settings_schemas` (`[1,2]` without the capacity module, `[1,2,3]` with it), `applied_settings_schema` (null until a valid file was read), `capacity` (5 slots, used, free, reserve, share mode, host), exactly two `profiles` (Linux then Windows: backend, count, share, per-runner and profile caps from the allocator, `image_generation` and `generation_state`, cache state `unknown` until the guests report it, `available` and the reason when not), up to five `slots` (one per live allocator reservation, each with its profile, OS, backend and lifecycle; a legacy slot carries the job, repo and URLs of the manager slot it is accounted as), `storage` and `legacy_pool` (the schema 4 numbers, null while Linux runs on VMs). Without the capacity module the slots are the manager's and the Windows profile is `backend: none`. Every value comes from a check in this script, the allocator's validated state, or the storage document the backends validated; times are UTC with a `Z`. |
| `logs\supervisor.log` | supervisor | One line per event, rotated to `.1` at 5 MB. |
| `inbox\jobs\<id>.json` | tray | Schema 1: `{"schema":1,"id":"<16 lowercase hex>","verb":"verify"|"repair"}`, or with `"verb":"identity"` plus exactly `org`, `app_id`, `installation_id` (numbers), `group`, `labels`, and `key_path` (see `crates/tray/README.md`, Identity). Nothing else is accepted. The supervisor does not read it. |
| `jobs\<id>\` | elevated helper | `status.json` (schema 1: `queued`, `running`, `passed`, `failed`, or `rejected`), `log.txt`, `exit.txt`. Admin-owned. The tray reads them. The supervisor does not. |
| `jobs\install\state.json` | elevated install helper | Schema 1 first-run checkpoint: `step` (`install` or `done`), `phase` (`host`, `identity`, `supervisor`, `start`, `done`), `job_id`, identity fields excluding the key path, and `runner_count`, `job_cpus`, `job_memory_gib`, `work_disk_gib`. Admin-owned; only the wizard reads it. |
| `config.json` | elevated install helper | Schema 1 installed identity (`org`, `app_id`, `installation_id`, `group`, `labels`) and `work_disk_gib`; no key or key path. Written before first supervisor startup. |

First-run `install` requests use schema 2 and the identity request fields plus
`runner_count` (1..5), `job_cpus` (runner count..28), `job_memory_gib` (runner
count..80), and `work_disk_gib` (60..512), all whole JSON numbers. Other verbs
keep their schema 1 contract. The helper revalidates every field, uses the
identity verb's checked key handle, and calls `install-host.ps1 -FreshInstall`
with the fixed operator distro `Ubuntu-24.04`. First install keeps the current
manager defaults: group `aap-crrr`, labels `self-hosted,linux,crrr`. The fresh-install plan refuses
an enabled/active manager or a staging upgrade. With no protected checkpoint,
an existing distro or supervisor refuses installation. A checkpoint can resume
only the original sizing; completed host phases are skipped. Identity can be
corrected until App authentication succeeds, so a wrong App or installation id
can be fixed and retried without reinstalling the host. Later phases bind the
authenticated identity too. The helper independently probes that the manager
remains inactive before it resumes mutations.

The install helper writes the initial settings and `desired: on` only after
identity and sizing validation and supervisor registration, then starts the
supervisor task. These writes are atomic renames from protected staging, never
opens of existing inbox targets; inbox file permissions remain operator
modifiable. A protected install lock serializes retries. If a crash occurs
after task startup, the next helper acknowledges the running task without
replaying installation. Per-job logs and exit codes use the existing contract.

While On, `inbox\settings.json` is read every 5 s:

- **Limits change:** the supervisor writes `/etc/aap-runner/limits.conf` in
  the distro (`AAP_RUNNER_COUNT`, `AAP_JOB_CPUS`, `AAP_JOB_MEMORY`, plus
  `AAP_JOB_IO_PERCENT` and `AAP_POOL_SHARING` when settings.json sets them)
  and runs `aap-runner-manager --check-limits`. A change to any of the five
  counts. If the check
  refuses, the previous file is put back and the status shows the reason
  until the settings change. If it passes, the manager drains, finishes its
  running jobs, and restarts with the new limits. After a supervisor start, a
  limits.conf that already has exactly this content counts as applied.
- **`paused: true`:** the manager drains and stops after its jobs. The distro
  and sysbox stay up and the status is `paused`. `paused: false` starts it
  again. Off wins over paused.

## Capacity

With `capacity\AapCapacity.psm1` beside the script (P19 deploys `capacity\`,
`broker\`, `backends\` and `network\` there, admin-only), the P09 allocator
(`C:\ProgramData\aap-runner\capacity`, [`allocator.md`](../parity/contracts/allocator.md))
holds every slot of every backend. The supervisor imports the module only when
its own folder and everything below it (the modules import each other by
relative path) are owned by SYSTEM, Administrators or TrustedInstaller, are no
reparse point and give nobody else write, delete, re-permission or
take-ownership rights, and every folder above it, up to the drive root, is no
reparse point, has an admin owner and lets nobody else delete, re-permission
or take it over (install-supervisor.ps1's ancestor rule); otherwise, and
without the module (today's install,
which copies only the script), it is the schema 2 supervisor described above:
legacy pool only, settings 1 and 2, and `status.v5.json` with the Windows
profile `none`.

- **Start of an On session:** create the allocator state once, with the
  measured host (logical CPUs, RAM, 2 GiB for the control VM until P22
  measures it, IO 0 until measured, the storage volumes only while every tier
  is trusted), never over an existing state or the remains of a lost one
  (`invalid_state`: status `error`, the owner restores it). Then reconcile
  before any admission, and again every 10 minutes.
- **Every 5 s:** the two counts, the shares, the reserve, the Linux backend
  and the active generations go to the allocator; `resize_waits` and
  `pool_over_live` keep the last applied settings and lead the `detail`.
  Lowering a count never cancels a job: the excess drains. While a legacy
  drain waits (limits, Pause, Linux 0, Off), the counts still go to the
  allocator and a Pause still drains the VM slots; nothing is admitted.
- **Legacy pool:** adopted once from the manager's fresh `status.json` sample
  (one reservation per running slot). A pool too big for the Linux profile is
  first shrunk to the allocator's target through `limits.conf`. After that a
  new Linux slot is granted before the manager runs it, and `limits.conf`
  says the granted slots and their totals, never above the settings' totals
  (shares win; the settings stay the maximum). No granted slot (Linux 0, or
  Linux on VMs): the manager is drained, waits for its jobs, and stays
  stopped; no `limits.conf` with 0 is written, the distro, sysbox and the
  keep-alive stay up, and the status is `idle` with `legacy pool stopped` in
  the `detail`. In `even` mode a count increase lowers every share, so the
  legacy pool is stopped and started again with the new grants. Raised
  `job_cpus` or `job_memory_gib` reach a granted legacy slot only with its next
  grant; until then the `detail` starts with `grant_waits`.
- **Heartbeats:** each health tick's manager sample is the legacy heartbeat.
- **VM profiles:** a profile on `hyperv-vm` admits a slot (one per tick, on
  the active generation's measured budget) only while its backend context,
  trusted `ok` storage, no host problem, an approved active generation and
  measured IO exist; `unavailable_reason` says which is missing. Every live VM
  slot gets one backend step per tick, also while the legacy manager drains;
  a failing step is logged and retried. Today no backend context is built:
  the P10.0 host network module, the catalog reader (P21) and the
  `approved-images.json` pins (P24) do not exist yet.
- **Pause and Off** admit nothing and move every ready or busy VM slot to
  `draining`; a busy one keeps its job, the backend tears it down after. Off
  waits for the VM slots (and the manager) before `wsl.exe --terminate`,
  because the broker that releases their runners lives in the distro; desired
  on again during that wait undoes the drain. Every VM slot counts until it is
  reconciled, also one whose backend is not loaded: nothing here can stop
  its runner or tear it down, so it holds Off until that backend is loaded,
  and the `detail` names the profile and the count (`no backend loaded for
  ...`); Pause marks such a slot `draining` but cannot stop it either. After
  6 h with a VM slot still live, or while the allocator state cannot be read
  (with a backend loaded or anything in the capacity folder), Off never
  terminates: the distro stays up, the status stays `draining`, and the next
  tick tries again. Today no backend context exists, so no VM slot can be
  admitted and none of this holds Off on the live install.

The GitHub App id, the key and the runner labels are not read from the
inbox by the supervisor. They live in `/etc/aap-runner/manager.conf` and
`app.pem` inside the distro, root-only. The tray's identity page changes them
through the elevated helper's `identity` verb (`installer/helper-run.ps1`):
it re-checks every field, opens the request and the key once each, and refuses a
key whose final path is not a plain file under the requesting user's profile
(a reparse point, more than one hard link, not a PEM private key, or 16 KiB or more). It refuses before
`wsl` when desired is not exactly `on` or the status is `draining`, `paused`, `starting`, or `error`
(`pool is <state>; retry when idle or running`, or `pool is off` when desired
is not on). It streams the key from that same handle into one `wsl -d aap-runner -u
root` call. The script writes both files as `.tmp`, has the manager check the new
conf (including `AAP_GITHUB_APP_PRIVATE_KEY_PATH=/etc/aap-runner/app.pem`), drains
before the swap only when the start argument is `idle` or `running` and the unit
is active, copies the old key to `app.pem.bak`, moves the new key then the conf,
and restores the backup if the conf move fails. `--undrain` and `systemctl start`
run only in that idle or running case after a finished drain. The helper logs the
non-secret fields and `key installed: 1 file, N bytes`, and prints `PASS identity`
only when that line was copied, never the key.

## Install and uninstall

From an elevated PowerShell in this folder:

```powershell
.\install-supervisor.ps1 -DryRun     # plan only, no changes
.\install-supervisor.ps1             # checks, folders, ACLs, state.json, script, task
'{"desired":"on"}' | Set-Content -Encoding ascii C:\ProgramData\aap-runner\inbox\state.json
Start-ScheduledTask AAP-CRRR-Supervisor
```

If the tray exe exists (`-TrayExe`, default
`%ProgramFiles%\aap-runner\aap-runner-tray.exe`), the installer also adds the Run
value `AAP-Runner-Tray` for the installing user, so the tray starts at the
next logon. It writes under `HKEY_USERS\<SID>` of that user, not the elevated
session's HKCU; on Fresh both are the same account. A missing exe is skipped
with an INFO line, and the tray is never started by the installer.

Before it changes anything, the installer walks `C:\ProgramData\aap-runner`
without following links. It refuses if any item is a junction or symlink, or
if anything outside `inbox\` is not owned by Administrators, SYSTEM or
TrustedInstaller. The refusal names the item and the command that fixes it,
and `-DryRun` runs the same checks. The script goes to
`C:\wsl\aap-runner-supervisor`, which inherits the SYSTEM and Administrators
only ACL that `install-host.ps1` puts on `C:\wsl`. The copy is refused unless
that folder has only those entries. It is also refused if any folder above it,
up to `C:\`, is a junction or symlink, is not owned by SYSTEM, Administrators, or TrustedInstaller, has no DACL, has an ACE that is not a plain allow or deny, or lets anyone else delete, re-permission or take ownership of it. Create-folder rights on a parent are still allowed. The script folder, the data folder, and the tray exe must be on a fixed local drive: a UNC path or a mapped drive is refused, using the final path from `GetFinalPathNameByHandleW` (folders too, so a junction onto another drive is judged by its target).

The installer does not start the task. The initial state is off, and a
supervisor that starts with desired off drains and terminates a running
`aap-runner`. Write on first if the runner should keep running.

```powershell
.\uninstall-supervisor.ps1 -DryRun
.\uninstall-supervisor.ps1
```

Uninstall stops and removes the task, and deletes the copied script and the
tray Run value. It writes nothing under `C:\ProgramData\aap-runner`, because it
runs elevated and `inbox\` is user-writable. The folder stays. The distro keeps
running until logoff or `wsl.exe --terminate aap-runner`.

## Flip by hand and read the logs

```powershell
'{"desired":"off"}' | Set-Content -Encoding ascii C:\ProgramData\aap-runner\inbox\state.json
'{"runner_count":2,"job_cpus":8,"job_memory_gib":32,"paused":false}' |
    Set-Content -Encoding ascii C:\ProgramData\aap-runner\inbox\settings.json
Get-Content C:\ProgramData\aap-runner\status.json
Get-Content -Wait -Tail 20 C:\ProgramData\aap-runner\logs\supervisor.log
```

Use `Set-Content`, not `Out-File` or `>`. Windows PowerShell 5.1 writes
those as UTF-16, which the supervisor reads but other tools may not.

## Residual risk

The task runs elevated in the operator's own logon session, with the
operator's environment block. UAC is not a security boundary, so a process
running as the operator can still reach this elevated one, for example
through a debugger or input injection. SYSTEM would avoid that but cannot
start a WSL distro. To keep the exposure small, the task, the supervisor and
the installer call `powershell.exe`, `wsl.exe` and `schtasks.exe` by their
literal `C:\Windows\System32` paths, not through `%SystemRoot%` or `PATH`.
They take only validated numbers and fixed words from the inbox.

## Tests

`supervisor.Tests.ps1` needs Pester 5. Windows ships 3.4; do not replace it:

```powershell
Save-Module Pester -RequiredVersion 5.7.1 -Path $env:TEMP\pester5
Import-Module $env:TEMP\pester5\Pester\5.7.1\Pester.psd1
Invoke-Pester -Path .\supervisor.Tests.ps1 -Output Detailed
```

Run it under `powershell.exe -ExecutionPolicy Bypass` and `pwsh`. Everything
that touches the host is mocked, so the tests prove the logic, not the live
behaviour. The capacity tests run the real allocator in a test folder (relaxed
trust), a fake legacy manager and a fake VM backend, and check every
`status.v5.json` they write with `parity/contracts/validate.py` (`python` on
`PATH`). `tests/supervisor/Invoke-AapSupervisorMutations.ps1` turns each
`# check:` condition in the script off in turn and fails unless a tagged test
catches it.
