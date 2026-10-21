# Windows VM backend (ledger item P10)

The supervisor-side provider for `hyperv-vm` reservations of the Windows profile (Windows Server 2025 / VS2026). It runs
inside the hidden, elevated supervisor and is the only code that drives Windows runner VMs. Contracts:
[backend-lifecycle.md](../../../parity/contracts/backend-lifecycle.md) (version 2),
[guest-transport.md](../../../parity/contracts/guest-transport.md) (version 1),
[allocator.md](../../../parity/contracts/allocator.md) (version 2) and [broker.md](../../../parity/contracts/broker.md)
(version 1). What other items must wire is in [INTEGRATION.md](INTEGRATION.md).

**Status: authored against fakes only.** No VM, switch, disk or PowerShell Direct session was created. The guest
transport is CANDIDATE (D2) until the lab proof P02.1 passes; the guest network is the P10.0 module, not built yet:
the backend conforms to its contract, [host-network-module.md](../../../parity/contracts/host-network-module.md), and is
tested against the contract's shared strict fake.

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
| `creating` | **create**: trust-check the roots and the host (Enhanced Session Mode off, nobody but SYSTEM and Administrators in Hyper-V Administrators), check that the generation folder and `base.vhdx` are sealed read-only, re-hash the base against the pin through a read handle held until the differencing disk exists, the reservation folders, `os.avhdx` (differencing child of the base), `scratch.vhdx` (its maximum size inside `scratch_gib`), `New-VM` with no adapter and its id journaled at once (or the VM whose id the journal already recorded), read back and verify every VM setting, its disks and devices; then the guest network: `Attach` with the VM Off, the shared declaration check (`AAP_NetworkInvalid`), a fresh per-clone password and the declaration's static address, gateway and resolvers (DHCP off) written offline into the clone's answer file, `Verify` (every object it writes is a problem, a throw too) and the read-back of the adapter from Hyper-V through the provider against the declaration (`AAP_NetworkUntrusted`). No copy of the declaration is kept or journaled. Then **boot**: with the VM Off, `Attach` again (the module returns the same declaration), the declaration check, `Verify` and the read-back, then `Start-VM`. Then **ready** (`probe` until `ready`, at most 15 minutes after boot) and `Set-AapSlotState ready` |
| `ready` | **run_one**: `Invoke-AapBrokerLease`, `deliver_registration` with the JIT config on the call child's stdin, `start_runner` |
| `ready`, `busy`, `draining` | **heartbeat**, at most every 30 s per reservation: guest `status` over this VM's own channel, broker status for `JobRunning`, `Update-AapHeartbeat`. A runner that GitHub reports gone ends the job (`collecting`); a draining runner that is idle is stopped; a busy one is never touched |
| every state with a VM | **limits**, from the host on every step, with or without a guest channel, probing and `deleting` included (a drained VM kept for its pending release), before the once-a-minute retry gate: a paused VM or a clone folder over `clone_gib` (or one that cannot be measured) destroys the VM (`fatal`), the slot held until the teardown proof; and a running VM's network, `Verify` again at least every 60 s (the host's addresses may have changed), a problem or a throw destroys it the same way |
| `collecting` | **collect**: the agent's bounded summary (returned as `Summary`, never written), then `deleting` |
| `deleting` | **destroy**: `Invoke-AapBrokerRelease` if a lease was ever asked for, `Stop-VM -TurnOff`, `Remove-VM`, P10.0 detach, delete both reservation folders without following links, observe absence, `Complete-AapTeardown` |
| `quarantined` | `heartbeat`: a validated reply plus a broker answer returns it; `hostile_guest`, `teardown_failed`, or a destroy already journaled: destroy again; `crash`, `unknown_vm`: held. The limits apply here too |

There is no `reset`: destroy is the only way a VM leaves (security review M3).

### The journal is the state

`<JournalRoot>\<reservation_id>.jsonl` (production `C:\ProgramData\aap-runner\capacity\journal`, admin-only, created
with a protected DACL): one backend-lifecycle `op` record per line, `intent` flushed to disk before every act, `done` or
`failed` after. A supervisor killed at any point resumes from it:

| Crash after (backend-lifecycle.md) | What the next step does |
|---|---|
| reservation persisted, nothing journaled | create |
| `create` intent, before or after `New-VM` | re-runs create: reuses disks it made and only the VM whose id the journal recorded right after `New-VM`, writes a fresh credential (the clone never booted), never a second VM. A VM found only by its name (a crash between `New-VM` and its record) is destroyed, never adopted |
| `create` done, `boot` or `ready` in flight | the credential died with the process: the clone is never booted or probed, it is destroyed (never registered) |
| lease asked for, not delivered | broker status: busy waits; anything else stops the runner and destroys, releasing the lease |
| runner busy | never cancelled: heartbeat quarantine (allocator), then destroy once the broker reports it offline or absent and idle |
| `destroy` partial | destroy again; only observed absence completes it |
| journal unreadable (not JSON, another lease, over 4 MiB) | `quarantined`, kind `crash` (`teardown_failed` when it was `deleting`), capacity held |

A last line without its newline is a write the crash cut short. Reading ignores it (an intent whose act never happened,
or an outcome whose act re-runs idempotently); the next append cuts it off first, so a new record never joins it. A
teardown that keeps failing the same way (a pending release, a VM that will not go) continues its journaled intent and
does not repeat an identical failure record, so retries do not grow the journal toward its bound.

The lease id is generated and journaled in the `ready` record's `done` detail (`probe ready; lease l-...`), before the
lease call; the broker's answer is journaled right after the call as a repeated `ready` `done` (`lease issued by the
broker` or `lease answer unreadable`), so a restarted supervisor never takes a lost issued lease for one the broker never
recorded. The `op` schema has no lease field (see INTEGRATION.md, contract requests).

One backend context belongs to one runspace. `Invoke-AapWinStep` holds `<JournalRoot>\<reservation_id>.lock`
(`FileShare.None`, deleted on close) for the whole step, so steps of one reservation never overlap; a step that finds the
lock held returns `held` / `step_in_progress` at once.

### The per-clone credential

A random 32-character password, generated at create, kept only in this process (`$B.Guests`), written once into the
offline clone disk (`Windows\Panther\unattend.xml`, user `runneradmin`), and passed to each call child on its stdin,
unbuffered (with the JIT config), so no copy stays in a stream buffer nothing can zero. It
lives in an object whose only property is `Length` (`WriteTo(stream)`, `Clear()`, the broker's JIT config pattern), so it
is never a command's parameter value (module logging, event 4103), and it is zeroed at destroy. It is never in the
journal, the allocator, a log or a result. The clone disk is mounted with no drive letter at an access path inside the
admin-only reservation folder (the mount point itself is a reparse point by design; every folder below it must be
plain); the answer file and every folder created for it get a protected SYSTEM/Administrators DACL from their creation,
with no entry for the supervisor's own account (only an unelevated test run adds its own). After a supervisor restart it
is gone, so the guest channel is gone; the backend then relies on the broker's view of the runner (table above).

### The guest channel

Each command is one hidden `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File psdirect-call.ps1` with a
fixed command line, the machine `PSModulePath`, inside a job object (512 MiB, CPU time and kill-on-close; the wall cap is
the command's timeout plus 10 s). Its stdin carries the VM id, the user, the password and the envelope, one per line,
then the payload. The child opens `New-PSSession -VMId`, runs one fixed script in the guest through
`[powershell]::Create()` with the envelope and payload as pipeline input, and writes the agent's one reply string; every
other stream and every host-UI call stays in the child. The supervisor reads at most 8193 bytes. A PowerShell Direct
connection that drops mid-call is a failed guest (no reply), never a hostile one. `seq` grows by one per command and is
never reused, also after a send that timed out or failed; the agent accepts any `seq` strictly greater than the last one
it accepted (guest-transport.md, Sequence rule), so a
command the guest never saw or whose reply was lost leaves a gap and never wedges the channel. The job object type is
compiled once by `New-AapWinBackend` with `%TMP%` pointed at an admin-only `<JournalRoot>\compile` folder.

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

The VM goes whatever the release answered, except after a drain: a runner that was listening may still be listed, so
its VM stays until the release is final, and stays held to every limit on every step. Kept 6 h past the drain, it is
flagged (`waiting`/`drain_overdue`, journaled once), never destroyed for time. A hostile guest, a broken limit or a
failed op removes the VM in every case.
Absence counts only with both tier roots present on the volumes the storage document records, and only after the
network detach succeeded. A VM, network or folder still there after three tries 5 s apart quarantines the slot
(`teardown_failed`, capacity held); the next steps try again, at most once a minute. Deletes never follow a junction or
symbolic link, and an ACL is never written through one.

### Trust checks

Before every create, each tier root passes the rules of backend-lifecycle.md, Trust checks: a normalized folder on a
fixed drive, no reparse point on it or above it, ancestors owned by an admin that no one else may delete or
re-permission, the root owned by SYSTEM, Administrators or TrustedInstaller with a protected DACL, and the volume GUID the
storage document records. `clone_root` and `scratch_root` (and the journal folder) are admin-only: no ACE for any other
SID. `base_root` may grant read, never write or an inheritable ACE. The storage document is read at most 64 KiB, with the
root forms and nesting rules of `validate.py`. The generation folder and `base.vhdx` must carry P06's sealed signature:
an admin owner, a protected DACL, no allow entry for anyone but the admins and Virtual Machines (`S-1-5-83-0`, read
only), and the ReadOnly attribute on the file. `Get-AapWinHostProblem` reports Enhanced Session Mode that is not off
(`AAP_EnhancedSession`) and any member of Hyper-V Administrators but SYSTEM and Administrators (`AAP_HyperVAdmins`);
create refuses either.

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
| `Create.Tests.ps1` | untrusted roots; the base pin; VM settings; the guest network against the shared fake (order, every tamper and fault, a lying module's Verify and declaration, the re-Attach before boot); storage document; offline disk helpers (the answer file's static addressing) |
| `Recovery.Tests.ps1` | unreadable journals; lost credential; hostile records; restart with a busy runner; JIT delivery rule; inventory and reconcile callbacks; orphans |
| `Crash.Tests.ps1` | a real process killed at every lifecycle boundary (19 points, plus a drain) and recovered |
| `Hygiene.Tests.ps1` | no password or JIT config in any file; JIT never text; the password and answer-file bytes never a command's parameter (AST); antivirus patterns; AMSI compile |
| `Invoke-AapWinMutations.ps1` | disables each `# check:` (in `AapWinBackend.psm1` and `psdirect-call.ps1`) in turn; every check must make a test fail |

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
