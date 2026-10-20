# Windows VM backend (ledger item P10)

The supervisor-side provider for `hyperv-vm` reservations of the Windows profile (Windows Server 2025 / VS2026). It runs
inside the hidden, elevated supervisor and is the only code that drives Windows runner VMs. Contracts:
[backend-lifecycle.md](../../../parity/contracts/backend-lifecycle.md) (version 2),
[guest-transport.md](../../../parity/contracts/guest-transport.md) (version 1),
[allocator.md](../../../parity/contracts/allocator.md) (version 2) and [broker.md](../../../parity/contracts/broker.md)
(version 1). What other items must wire is in [INTEGRATION.md](INTEGRATION.md).

**Status: authored against fakes only.** No VM, switch, disk or PowerShell Direct session was created. The guest
transport is CANDIDATE (D2) until the lab proof P02.1 passes; the guest network is the P10.0 module, not built yet.

| File | What it is |
|---|---|
| `AapWinBackend.psm1` | The lifecycle: `New-AapWinBackend`, `Invoke-AapWinStep`, the reconcile callbacks, the journal, the trust checks, the guest channel and its checks |
| `AapWinBackend.HyperV.psm1` | The production provider: every Hyper-V, Storage and hash call, behind one hashtable of ops. NOT RUN |
| `psdirect-call.ps1` | The capped call child: one guest command over PowerShell Direct per process. Only its input checks have run |

## How it works

`Invoke-AapWinStep -Backend $B -Reservation $r [-BaseSha256 <pin>]` does one step for one reservation, chosen by the
allocator state and the reservation's journal. The supervisor calls it for every live Windows VM reservation on every
tick.

| Allocator state | Step |
|---|---|
| `creating` | **create**: trust-check the roots, re-hash the base against the pin, the reservation folders, `os.avhdx` (differencing child of the base), `scratch.vhdx` (its maximum size inside `scratch_gib`), a fresh per-clone password written offline into the clone's answer file, `New-VM` (or the VM the journal already names), read back and verify every VM setting, attach the guest network and verify it. Then **boot**, then **ready** (`probe` until `ready`, at most 15 minutes after boot) and `Set-AapSlotState ready` |
| `ready` | **run_one**: `Invoke-AapBrokerLease`, `deliver_registration` with the JIT config on the call child's stdin, `start_runner` |
| `ready`, `busy`, `draining` | **heartbeat**: guest `status` over this VM's own channel, broker status for `JobRunning`, `Update-AapHeartbeat`, the clone cap and a paused VM. A runner that GitHub reports gone ends the job (`collecting`); a draining runner that is idle is stopped; a busy one is never touched |
| `collecting` | **collect**: the agent's bounded summary (returned as `Summary`, never written), then `deleting` |
| `deleting` | **destroy**: `Invoke-AapBrokerRelease` if a lease was ever asked for, `Stop-VM -TurnOff`, `Remove-VM`, P10.0 detach, delete both reservation folders without following links, observe absence, `Complete-AapTeardown` |
| `quarantined` | `heartbeat`: a validated reply returns it; `hostile_guest`, `teardown_failed`: destroy again; `crash`, `unknown_vm`: held |

There is no `reset`: destroy is the only way a VM leaves (security review M3).

### The journal is the state

`<JournalRoot>\<reservation_id>.jsonl` (production `C:\ProgramData\aap-runner\capacity\journal`, admin-only, created
with a protected DACL): one backend-lifecycle `op` record per line, `intent` flushed to disk before every act, `done` or
`failed` after. A supervisor killed at any point resumes from it:

| Crash after (backend-lifecycle.md) | What the next step does |
|---|---|
| reservation persisted, nothing journaled | create |
| `create` intent, before or after `New-VM` | re-runs create: reuses disks it made and the VM the journal names, writes a fresh credential (the clone never booted), never a second VM |
| `boot` or `ready` in flight | the credential died with the process: the clone cannot be probed, so it is destroyed (never registered) |
| lease asked for, not delivered | broker status: busy waits; anything else stops the runner and destroys, releasing the lease |
| runner busy | never cancelled: heartbeat quarantine (allocator), then destroy once the broker reports it offline or absent and idle |
| `destroy` partial | destroy again; only observed absence completes it |
| journal unreadable (not JSON, another lease, over 4 MiB) | `quarantined`, kind `crash`, capacity held |

A last line without its newline is a write the crash cut short and is ignored: an intent whose act never happened, or an
outcome whose act re-runs idempotently.

The lease id is generated and journaled in the `ready` record's `done` detail (`probe ready; lease l-...`), before the
lease call: the `op` schema has no lease field (see INTEGRATION.md, contract requests).

### The per-clone credential

A random 32-character password, generated at create, kept only in this process (`$B.Guests`), written once into the
offline clone disk (`Windows\Panther\unattend.xml`, user `runneradmin`), and passed to each call child on its stdin. It
is never in the journal, the allocator, a log or a result, and it is dropped at destroy. After a supervisor restart it
is gone, so the guest channel is gone; the backend then relies on the broker's view of the runner (table above).

### The guest channel

Each command is one hidden `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File psdirect-call.ps1` with a
fixed command line, the machine `PSModulePath`, inside a job object (512 MiB, CPU time and kill-on-close; the wall cap is
the command's timeout plus 10 s). Its stdin carries the VM id, the user, the password and the envelope, one per line,
then the payload. The child opens `New-PSSession -VMId`, runs one fixed script in the guest through
`[powershell]::Create()` with the envelope and payload as pipeline input, and writes the agent's one reply string; every
other stream and every host-UI call stays in the child. The supervisor reads at most 8193 bytes.

Every reply is hostile input. The checks, in order, and the fixed `hostile_guest` reason code each failure gets (the
`quarantine_reason`; guest text is never kept):

| Code | Meaning |
|---|---|
| `oversized_reply` | more than 8192 bytes (one trailing newline allowed), or the read overflowed |
| `child_exit` | the call child exited non-zero (deserialization failure, remote error, cap kill, more or less than one string) |
| `non_printable` | a byte outside printable ASCII |
| `bad_json` | not exactly one strict JSON object (duplicate keys, nesting, arrays, `\u` escapes, trailing text refused) |
| `extra_fields` | a field missing or added (the 11 fields of `guest_reply`, case-sensitive) |
| `bad_value` | a field of the wrong type or value |
| `wrong_echo` | `vm_id`, `reservation_id`, `lease_generation`, `seq` or `nonce` not this command's own |
| `secret_value` | a token- or key-shaped `diag` |
| `bad_state` | a `guest_state` the command cannot produce |

A timeout or an empty reply (the guest could not be reached) is a failed guest, not a hostile one; a valid `refused` or
`error` reply stops the step it belongs to. A hostile reply is final: the failed op is journaled with code
`hostile_guest`, the slot goes straight to `deleting` and the VM is destroyed in the same step, even when the allocator
call fails; the journal record keeps it final across a crash.

Which reservation a heartbeat belongs to comes from the VM this process sent the command to; whether a job runs comes
from the broker's status of the runner, never from the guest.

### Teardown and the slot

The slot is freed only by `Complete-AapTeardown` with a `vm` proof, after the VM (by id and by name) and both
reservation folders are observed absent (every VM file lives in the clone folder; the VM's settings are verified at
create) and the runner part is final:

| Release outcome | Runner proof |
|---|---|
| no lease ever asked for | `never_registered` |
| `deregistered` | `true` |
| `already_gone` | `github-removed` |
| `refused`/`not_found` for a lease this process saw `issued` or `bad_reply` | uncertain: `teardown_failed` quarantine, capacity held |
| `refused`/`not_found` otherwise, 15 minutes after the lease call | `never_registered` (no broker run can record it later) |
| `retry`, `unavailable`, `bad_reply`, other refusals | pending: the slot stays `deleting`; asked again at most once a minute |

The VM goes whatever the release answered. A VM or folder still there after three tries 5 s apart quarantines the slot
(`teardown_failed`, capacity held); the next steps try again. Deletes never follow a junction or symbolic link.

### Trust checks

Before every create, each tier root passes the rules of backend-lifecycle.md, Trust checks: a normalized folder on a
fixed drive, no reparse point on it or above it, ancestors owned by an admin that no one else may delete or
re-permission, the root owned by SYSTEM, Administrators or TrustedInstaller with a protected DACL, and the volume GUID the
storage document records. `clone_root` and `scratch_root` (and the journal folder) are admin-only: no ACE for any other
SID. `base_root` may grant read, never write or an inheritable ACE. The storage document is read at most 64 KiB, with the
root forms and nesting rules of `validate.py`.

## Tests

`tests/backends/windows`, Pester 5.7.1 on Windows PowerShell 5.1 and PowerShell 7.5 or later, real temp folders, the real
allocator (`-RelaxedTrustForTests`) and broker client, file-backed fakes for Hyper-V, the guest agent, the broker and the
network (no Hyper-V, WSL or network call). `python` must be on `PATH` (journal records and guest exchanges are checked
with `parity/contracts/validate.py`).

| File | Covers |
|---|---|
| `Lifecycle.Tests.ps1` | one job end to end; caps; boot deadline; drain; heartbeat binding; clone cap; paused VM; heartbeat quarantine recovery |
| `Transport.Tests.ps1` | every reply check; every hostile case end to end; hostile with a failing allocator; the real capped child (overflow, hang, memory flood, grandchild, exit code, stdin only) |
| `Teardown.Tests.ps1` | release outcomes; a VM or folder that will not go; no slot reuse before the proof; links in clone folders |
| `Create.Tests.ps1` | untrusted roots; the base pin; VM settings; switch and guards; network verification; storage document; offline disk helpers |
| `Recovery.Tests.ps1` | unreadable journals; lost credential; hostile records; restart with a busy runner; JIT delivery rule; inventory and reconcile callbacks; orphans |
| `Crash.Tests.ps1` | a real process killed at every lifecycle boundary (17 points) and recovered |
| `Hygiene.Tests.ps1` | no password or JIT config in any file; JIT never text; antivirus patterns; AMSI compile |
| `Invoke-AapWinMutations.ps1` | disables each `# check:` in turn; every check must make a test fail |

```powershell
Invoke-Pester -Path tests/backends/windows             # both hosts
pwsh -File tests/backends/windows/Invoke-AapWinMutations.ps1
```

## What is not done

- No real run: the production provider, the PowerShell Direct child's session and the job object's limits on a real
  PowerShell Direct call are proven only by P02.1 (lab) and P22.
- The guest network module (P10.0) does not exist; without it every create fails closed (`AAP_NetworkUnavailable`).
- The guest agent (`C:\Program Files\aap-guest\agent.ps1`, P14) does not exist; the fake agent in the tests follows
  guest-transport.md.
- `shutdown` is never sent: destroy turns the VM off.
