# Windows guest agent and job bootstrap (ledger item P14)

The program inside every Windows runner clone that answers the host's management commands
([guest-transport.md](../../parity/contracts/guest-transport.md), version 1), prepares the clone for its one job and
starts the Actions runner. The host side is [supervisor/backends/windows](../../supervisor/backends/windows) (P10); the
image is [images/windows](../../images/windows) (P06) plus overlays (P21). What other items must wire is in
[INTEGRATION.md](INTEGRATION.md).

**Status: authored against fakes only.** No VM, PowerShell Direct session, scheduled task, disk or runner was touched.
The real behaviour is proven in the lab (P02.1, P22). The agent refuses every command until it can read its VM id from
the hypervisor, which the merged P10 backend currently switches off (INTEGRATION.md, contract defect 1).

| File | What it is |
|---|---|
| `AapGuestAgent.psm1` | Everything: the wire, the refusals, the agent's state, the bootstrap, the launcher, the overlay install |
| `agent.ps1` | The agent entrypoint, `C:\Program Files\aap-guest\agent.ps1`: one command per process, no arguments |
| `launch.ps1` | The runner launcher, run once per boot as the scheduled task `aap-guest-runner` |

## How it works

`psdirect-call.ps1`'s fixed remote script starts `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
"C:\Program Files\aap-guest\agent.ps1"` for every command and writes the envelope line, a newline and exactly
`payload_bytes` bytes to its stdin; the agent writes one reply line to stdout and exits. Every agent process is new, so
what it must remember between commands lives in `%ProgramData%\aap-guest\state.json` (SYSTEM, Administrators and the job
user), held open without sharing while a command is accepted. The file is born whole (written aside, then moved in) and
each save writes over the old bytes before cutting the file to length, so a save that dies half-way leaves a file that
does not parse (`error`, nothing accepted), never one that reads as a fresh boot.

| Step | What the agent does |
|---|---|
| Read | stdin as bytes: an optional UTF-8 BOM, one line of printable ASCII up to 1024 bytes ending in LF (reading stops at the first other byte or at byte 1025), then exactly `payload_bytes` bytes. The envelope is parsed strictly: the ten keys of `host_cmd` once each, flat scalars, every value in its schema range. Anything else: no reply, exit 2 (the host sees a failed guest) |
| Own VM id | Hyper-V's host-to-guest intrinsic item `VirtualMachineId` (`HKLM\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters`). Missing: `refused` (`own vm id unavailable from the hypervisor`); another id: `refused`. Neither touches the disk |
| Busy | another agent process holds the state file for 2 s: nothing is accepted; a `probe` hears `booting`, anything else `error` (`agent busy`) |
| Refuse | in this order: a `reservation_id` or `lease_generation` other than the first accepted this boot, a `seq` not strictly greater than the last accepted one (gaps are fine), a nonce already accepted, a full nonce store (8192, 68 h of heartbeats), a second `deliver_registration`, `start_runner` or `shutdown`, a command expired by more than 5 s, an `expires_at` more than 120 s (the contract's bound) plus 5 s ahead, a payload on anything but `deliver_registration` (or none on it). A refused command changes nothing |
| Accept | record reservation, generation, `seq`, nonce and one-shot class before acting, so a command that crashes half-way is never accepted twice; an unreadable or oversized state file answers `error` and accepts nothing |
| Reply | the eleven `guest_reply` fields with the request's echo; `diag` printable ASCII, at most 400 characters, no quote or backslash, anything token- or key-shaped redacted |

Who may send commands at all is the transport's boundary: the per-clone PowerShell Direct credential (guest-transport.md).
Anyone holding it can run any command in the guest anyway; the rules above keep one sender's commands in order and
bound to one reservation, they do not authenticate a second one.

| Command | Answer |
|---|---|
| `probe` | `booting` until Windows Setup reports `IMAGE_STATE_COMPLETE`, and while an earlier probe's bootstrap still runs; then the bootstrap below, `ready` (or `error`/`failed`, final). After `ready`: `ready` |
| `deliver_registration` | in `ready` only, a payload of base64 text only: written to `<runner root>\.aap-jit` (the runner root's ACL), `registered` |
| `start_runner` | in `registered` only, with no bootstrap file left: records the request with a deadline (now + 40 s), starts the launcher task and waits for it, then `listening` (or `busy`) if Runner.Listener runs and the JIT file is gone. Otherwise `error`, and a cancel mark, so a launcher that comes late starts no runner on a VM the host is giving up |
| `status` | `listening`, `busy` (a `Runner.Worker` runs under the runner root), `job_done` (with the exit code the launcher recorded, believed only while the recorded runner, by pid, start time and path, no longer runs) or `failed` |
| `collect` | as `status`, and `diag` carries the cache state (`Get-AapZcState`) |
| `shutdown` | `shutting_down`, then `shutdown.exe /s /t 5`. The host never sends it today |

### Bootstrap (the first `probe` after Setup)

It runs with the state file released, under its own lock (`bootstrap.lock`), so a bootstrap longer than one probe's
30 s never locks the next probe out: that probe answers `booting` until the first one is done or gone.

1. The agent runs as the job user `runneradmin`, a local administrator (the per-clone answer file made it, and PowerShell
   Direct logs on with it). Anything else: `failed`.
2. Every answer file that carried the per-clone password is deleted: `*unattend*` anywhere under `C:\Windows\Panther`
   (links removed as entries, never entered), `*unattend*.xml` in `System32\Sysprep` and at the system drive's root.
3. The image's defaults are what a fresh job step finds, as on hosted runners; the agent adds nothing to them. It refuses
   an image without `ImageOS`, `ImageVersion` or `AGENT_TOOLSDIRECTORY` (or without that tool cache folder, which the
   `setup-*` actions read and install other versions into), and one whose default machine or user `PATH` carries
   `cl.exe`: compilers come from a per-job developer environment (VsDevCmd), never from a global PATH. A PATH entry on a
   drive the guest lacks is skipped.
4. `D:` is the scratch disk. P10 creates it new for every reservation and formats it NTFS offline without a drive letter,
   so Windows normally mounts it as `D:` and the agent only checks it (NTFS, fixed, not the boot disk). That `D:` is
   trusted, contents and all, only because the disk is new per reservation; it is never a disk a job ran on. If `D:` is
   missing, exactly one disk besides the boot and system disk with at most one data partition is made `D:`: initialized
   if RAW, partitioned or re-lettered, formatted (`Temporary Storage`) unless already NTFS; an unformatted `D:` is
   formatted. Each step resumes where a killed probe stopped. None or several candidate disks: `failed`. The disk's size
   is not checked (no seed carries it; INTEGRATION.md).
5. The actions-runner overlay (`C:\Program Files\aap-guest\runner`) is copied to `D:\actions-runner` through
   `D:\actions-runner.partial`, file by file, each file landing under its own name only once complete, so a copy a killed
   probe cut short resumes; its `_work` and `_diag` grow on the scratch disk, not on the clone disk the host caps.
6. The cache job root `D:\aap-cache` is created. Both roots: SYSTEM, Administrators and the job user, inheritance off.

### The runner

`start_runner` registers and starts the task `aap-guest-runner`: the job user, logon type S4U (no password stored),
highest privileges, priority 4 (a task's default 7 is below normal), no time limit. A task gets a fresh logon
environment (the machine and user variables, as a service or a new logon would) and does not belong to the PowerShell
Direct session, which ends after every command. `launch.ps1` then:

1. starts the per-job cache (`Initialize-AapZcJob -InstallDir "C:\Program Files\aap-guest\cache" -JobRoot D:\aap-cache`)
   from that environment, before the JIT config is read, so the cache daemons never hold it; a cache that fails leaves
   the compilers running directly;
2. reads `.aap-jit`, overwrites it with zeros, deletes it;
3. stops if `start_runner` gave up (its cancel mark, or its deadline passed, or it never asked);
4. starts `D:\actions-runner\bin\Runner.Listener.exe run` (no shell, no window) with its own environment, minus every
   inherited `ACTIONS_RUNNER_INPUT_*` and what Windows PowerShell put into it (`PSExecutionPolicyPreference`, its
   rewritten `PSModulePath`, which goes back to the logon value: the user's if set, else the machine's), plus
   `AAP_ZC_STATE`, `CMAKE_C_COMPILER_LAUNCHER` and `CMAKE_CXX_COMPILER_LAUNCHER` from the cache's `state\runner.env`
   (printable values; no other name), plus `ACTIONS_RUNNER_INPUT_JITCONFIG`. So job steps see the execution policy and
   module path a hosted job sees;
5. records `running` (pid and start time) in `%ProgramData%\aap-guest\launch.json`, waits for the runner's one job and
   records `exited` with its exit code.

### Trust after the start

The job user is an elevated administrator, as on hosted runners. Once `start_runner` returned, the job can rewrite the
agent's state, its module and entrypoint, `launch.json` and the task, so every later reply (`status`, `collect`,
`shutdown`) is job-authored however well its envelope echoes. The agent still bounds and filters what it reads (64 KiB
records, fixed phases, the runner matched by pid, start time and path, no unfiltered text), but its post-start replies
are hints. The host's authority on the job is the broker's status of the runner; it never bases VM reuse, cache
promotion (`collect`) or VM lifetime on a guest reply (there is no reuse: destroy is the only way a VM leaves).

### Secrets

The JIT config travels supervisor stdin, call child, remote runspace, agent stdin, agent memory (a byte array, checked
byte by byte, never turned into text), `<runner root>\.aap-jit`, launcher memory, Runner.Listener's environment. It is
never a command's parameter (module logging, event 4103), argv, script text or a reply, and every byte array that held
it is cleared. The per-clone password lives only in the answer files, which the first `probe` after Setup deletes.
Nothing the agent writes outside the runner root carries either. What survives in the guest after that is the runner's
own credential files in its root, as on hosted runners, and whatever a dump of Runner.Listener would hold (dumps are for
P21 to switch off); destroying the VM is the control (guest-transport.md, JIT secrecy rule).

## Tests

`tests/guests/windows`, Pester 5.7.1 on Windows PowerShell 5.1 and PowerShell 7: temp folders stand in for `C:\Windows`,
`C:\`, `D:\` and the install folder, scriptblocks for the registry, disks, the scheduled task, Runner.Listener and
zccache. Every reply goes through the host's own `Test-AapWinReply`. One test runs the real `agent.ps1` in a Windows
PowerShell child the way the remote script does (stdin through `BaseStream`, no BOM).

```powershell
Invoke-Pester -Path tests/guests/windows                          # both editions
pwsh -File tests/guests/windows/Invoke-AapGuestMutations.ps1     # every '# check:' must make a tagged test fail an assertion
```

## What is not done

- No real run: PowerShell Direct, the scheduled task's environment and lifetime, Storage cmdlets on the scratch disk and
  the pinned runner's JIT handling are proven only by P02.1 and P22.
- `bind_cache` (shared cache roots) is not in the contract, so no shared root is ever bound (private roots only).
- No native launcher for `RUSTC_WRAPPER` (guests/cache INTEGRATION.md, gap G3): rustc builds uncached.
- Crash dumps of the runner are not switched off here (P21, INTEGRATION.md).
