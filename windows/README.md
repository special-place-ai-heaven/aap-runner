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
  Each tick also sets the `vmmemWSL` process to BelowNormal priority, so games
  and other interactive apps win CPU contention against CI jobs.
- **Off:** runs `aap-runner-manager --drain`, waits up to 6 h for the manager
  to exit after its job, then `wsl.exe --terminate aap-runner`. Flipping back to
  on while draining undrains instead.
- **While Off** it makes no `wsl.exe` call, so Vmmem can exit.

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
- **The supervisor only reads `inbox\`.** It opens each file once and reads
  at most 4097 bytes; more than 4096 is refused. It never creates, renames or
  deletes anything there, so a planted link cannot redirect an elevated write.

| File | Writer | Content |
|---|---|---|
| `inbox\state.json` | tray or you | `{"desired":"on"}` or `{"desired":"off"}`. Anything else counts as off and logs one warning. |
| `inbox\settings.json` | tray or you | `{"runner_count":1-4,"job_cpus":1-28,"job_memory_gib":1-80,"paused":true\|false}`. All four keys, whole numbers, a real boolean. Anything else logs one warning and the last valid settings stay. Missing means no override and not paused. |
| `status.json` | supervisor | `{"state":"off\|starting\|idle\|running\|draining\|paused\|error","job":"","updated":"<RFC3339>","detail":"","runner_count":N,"job_cpus":N,"job_memory_gib":N}`. The three numbers are what the manager reports as applied, or null. Rewritten at least every 60 s. The tray calls it stale after 180 s. |
| `logs\supervisor.log` | supervisor | One line per event, rotated to `.1` at 5 MB. |

While On, `inbox\settings.json` is read every 5 s:

- **Limits change:** the supervisor writes `/etc/aap-runner/limits.conf` in
  the distro and runs `aap-runner-manager --check-limits`. If the check
  refuses, the previous file is put back and the status shows the reason
  until the settings change. If it passes, the manager drains, finishes its
  running jobs, and restarts with the new limits.
- **`paused: true`:** the manager drains and stops after its jobs. The distro
  and sysbox stay up and the status is `paused`. `paused: false` starts it
  again. Off wins over paused.

The GitHub App id, the key and the runner labels cannot be changed from the
tray. They live in `/etc/aap-runner/manager.conf` and `app.pem` inside the
distro, root-only, and change only by editing those as root.

## Install and uninstall

From an elevated PowerShell in this folder:

```powershell
.\install-supervisor.ps1 -DryRun     # plan only, no changes
.\install-supervisor.ps1             # checks, folders, ACLs, state.json, script, task
'{"desired":"on"}' | Set-Content -Encoding ascii C:\ProgramData\aap-runner\inbox\state.json
Start-ScheduledTask AAP-CRRR-Supervisor
```

If the tray exe exists (`-TrayExe`, default
`C:\TOOLS\git_runner\aap-runner-tray.exe`), the installer also adds the Run
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
up to `C:\`, lets anyone else delete, re-permission or take ownership of it.

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
