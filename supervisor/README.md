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
  on while draining undrains instead.
- **While Off** it makes no `wsl.exe` call, so Vmmem can exit.
- **Old manager:** before its first `--drain`, `--undrain` or
  `--check-limits` call, the supervisor greps the installed manager for
  `--undrain`. An older manager ignores unknown flags and would start a full
  pool instead, so when the grep fails no manager flag is ever used. The
  status is `error` until `install-host.ps1` from this branch is re-run. On
  still starts the units with `systemctl`, settings are ignored, and Off
  terminates the distro without a drain, ending any running job.
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
| `inbox\settings.json` | tray or you | `{"runner_count":1-5,"job_cpus":1-28,"job_memory_gib":1-80,"paused":true\|false}`. All four keys, whole numbers, a real boolean. Schema 2 adds optional `"schema":2`, `"io_percent":0-100` (whole number) and `"sharing":"slice"\|"fixed"`; a file without them (schema 1) is still read. Anything else logs one warning and the last valid settings stay. Missing means no override and not paused. |
| `status.json` | supervisor | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"","updated":"<RFC3339>","detail":"","runner_count":N,"job_cpus":N,"job_memory_gib":N,"repo":"owner/name","run_url":"https://github.com/owner/name/actions/runs/ID"}`. The three numbers are what the manager reports as applied, or null. `repo` and `run_url` are the running job's, copied from the manager only when they match `owner/name` and `https://github.com/owner/name/actions/runs/<digits>` exactly, else empty. Both are empty while off or paused. Schema 4 writes `"schema":4` and adds `"work_disk_gib"`, `"work_disk_free_gb"`, `"work_disk_floor_gb"` and `"cleaning":true|false` (null and false unless the manager is idle, running, or draining; a schema 3 manager file still reads; a size outside 0-1024 is null). Schema 3 fields: `"sampled_at":"<RFC3339>"\|null`, `"pool":{"cpu_cores","mem_gib","io_mbps"}`, `"slots":[{"slot","state","job","repo","run_url","job_url","started_at","cpu_cores","mem_gib"}]`, `"job_io_mbps"` and `"sharing":"slice"\|"fixed"\|null`. They are copied from the manager only while it reports idle, running or draining; otherwise `slots` is `[]` and the rest null. Every value is re-checked: numbers in range (cores 0-1024, GiB 0-4096) else null, `repo` and `run_url` as above, `job_url` as `https://github.com/owner/name/actions/runs/<digits>/job/<digits>`, slot `state` one of idle, running, draining, starting, error, else empty. At most 5 slots. The manager's unix-second times are written as RFC 3339 UTC. An older manager without a `slots` list gives `[]`. Rewritten at least every 60 s. The tray calls it stale after 180 s. |
| `logs\supervisor.log` | supervisor | One line per event, rotated to `.1` at 5 MB. |
| `inbox\jobs\<id>.json` | tray | Schema 1: `{"schema":1,"id":"<16 lowercase hex>","verb":"verify"|"repair"}`, or with `"verb":"identity"` plus exactly `org`, `app_id`, `installation_id` (numbers), `group`, `labels`, and `key_path` (see `crates/tray/README.md`, Identity). Nothing else is accepted. The supervisor does not read it. |
| `jobs\<id>\` | elevated helper | `status.json` (schema 1: `queued`, `running`, `passed`, `failed`, or `rejected`), `log.txt`, `exit.txt`. Admin-owned. The tray reads them. The supervisor does not. |

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
behaviour.
