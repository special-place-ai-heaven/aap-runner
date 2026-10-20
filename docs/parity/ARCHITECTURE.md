# Parity architecture (frozen by P02)

Revision 2, 2026-10-20 (ledger item P02.2; revision 1, P02, 2026-10-19). This document freezes
the components, trust boundaries, data flows, state machines and failure handling that every
later parity item builds on. The machine-checkable shapes live in [`parity/contracts/`](../../parity/contracts/README.md);
`python -B -I parity/contracts/validate.py` checks every example and negative fixture.

Every rule below carries one marker:

- **DECIDED**: frozen. A later item that needs a change files a ledger revision first.
- **CANDIDATE (D2)**: the chosen mechanism, not yet proven. It stays a candidate until the
  lab plan in [guest-transport.md](../../parity/contracts/guest-transport.md#lab-proof-plan-p021-executed-for-p08-p10-p11)
  passes in an owner-authorized disposable lab (gate D2). Gate D2's owner inputs are met: the lab
  host is this machine with Hyper-V enabled, and the owner provided a Windows Server 2025
  Evaluation ISO (180-day) and the dedicated volume `E:` and approved the lab budget on 2026-10-20
  ([README](../../parity/contracts/README.md#resolved-2026-10-20)). Before the first VM, the
  Windows image builder (P06) must be merged and the elevated step that creates the internal
  switch and NAT must run.
- **RESOLVED 2026-10-19**: the owner decisions this item first left open (labels, image volume,
  distro uptime, reserve floor, D2 media). See
  [the contracts README](../../parity/contracts/README.md#resolved-2026-10-19). On 2026-10-20 the
  owner replaced the single image volume with configurable storage tiers
  ([README](../../parity/contracts/README.md#resolved-2026-10-20)).

Nothing here was provisioned, enabled or run against the live install. No VM was created.

## 1. Components and trust boundaries

| Component | Runs as | Trust | Owns | Never does |
|---|---|---|---|---|
| Tray (`crates/tray`) | the user, unelevated | user | the only user surface; writes `inbox\*.json`; reads `status.json` / `status.v5.json` | run `wsl.exe` or Hyper-V cmdlets, hold tokens or keys, open a console |
| Elevated helper (`--helper <verb> <id>`, existing) | Administrators via UAC | admin | install, identity, repair, verify; later image/backend preparation (P19) | gain a new verb without the existing request/ACL contract; persist a secret |
| Supervisor (`aap-runner-supervisor.ps1`, task `AAP-CRRR-Supervisor`) | the installing user, elevated, logon task, hidden | admin, in the user's logon session | allocator, backend providers, guest transport, status files | read anything but validated numbers and fixed words from the inbox; show a window |
| WSL control distro `aap-runner` | root inside the distro | control plane | GitHub App key (`/etc/aap-runner/app.pem`, root 0400), manager, legacy pool, **broker** | expose a network listener for the broker; accept a path or command from a caller |
| Broker (`/usr/local/sbin/aap-runner-broker`, P08) | root, one process per request | control plane | App JWT, installation token, JIT config minting, runner deregistration, lease ledger | run without a well-formed bounded request; log or persist registration material |
| Hyper-V backend (supervisor modules `backends/windows`, `backends/linux`) | inside the supervisor process | admin | VM create/boot/destroy (no reset), differencing disks, guest management sessions | reuse a VM or disk across reservations; mutate a base image |
| Guests (Windows Server 2025 / VS2026, Ubuntu 24.04) | guest Administrator / sudo | **untrusted** once a job starts | one Actions job | reach the host, the control distro, the LAN, another guest or a base image |
| Image catalog (`<base_root>\catalog.json` + images) | written by supervisor image-maintenance (P25) and P21 tooling | admin | immutable generations, hashes, provenance, rollback | change bytes of an approved generation |
| Legacy WSL/Sysbox pool | root inside the distro | control plane for the manager, untrusted for jobs | existing ephemeral container runners | run autonomously beside new profiles (adopted into the allocator, DECIDED) |

DECIDED: no new elevation path, no named-pipe service, no Rust service rewrite, no autologon,
no owner-password storage, no silent update, no Authenticode requirement. The only
user-visible prompt is UAC for the existing elevated helper. No component opens a visible
console or window: Hyper-V and `wsl.exe` calls run inside the hidden supervisor; new
processes the supervisor starts use the same hidden, absolute-path pattern as today.

```mermaid
flowchart LR
  subgraph User["User session, unelevated"]
    T[Tray]
  end
  subgraph Admin["Admin: hidden supervisor task"]
    S[Supervisor loop]
    A[Allocator]
    P[Backend providers]
    X[Guest transport]
    S --> A
    S --> P
    P --> X
  end
  subgraph Ctl["WSL control distro, root"]
    B[Broker]
    M[Legacy manager and pool]
    K[(App key)]
    B --- K
    M --- K
  end
  subgraph Guests["Disposable guests, untrusted"]
    W[Windows VM]
    L[Ubuntu VM]
  end
  CAT[(Image catalog)]
  GH[GitHub]
  T -- "inbox json files" --> S
  S -- "status json files" --> T
  T -- "UAC: helper verbs" --> H[Elevated helper]
  S -- "wsl.exe stdin and stdout" --> B
  S -- "limits.conf, drain" --> M
  X -- "PowerShell Direct" --> W
  X -- "SSH over hvsocket" --> L
  CAT --> P
  B -- "App JWT, JIT config" --> GH
  W -- "one job" --> GH
  L -- "one job" --> GH
  M --> GH
```

Trust boundaries, each with its rule:

1. **Tray to supervisor** (DECIDED, existing): files in the user-writable `inbox\`, read once,
   bounded to 4096 bytes, strictly parsed; the supervisor never writes there.
2. **Supervisor to control distro** (DECIDED): one `wsl.exe -d aap-runner -u root --exec <fixed path>`
   per broker call, request on stdin, response on stdout, both bounded. No arguments carry data.
3. **Supervisor to guest** (CANDIDATE D2): PowerShell Direct (Windows) and SSH over hvsocket
   (Linux); no network path, a fixed command set, bounded hostile-safe replies.
4. **Guest to the world** (CANDIDATE D2 for the mechanism, DECIDED for the rule): internet egress
   only; the host, the WSL distro, the LAN and other guests are unreachable, mirroring today's
   Sysbox network evidence (`distro/README.md`, Evidence).
5. **Catalog to provider** (DECIDED): a provider boots only a catalog generation in state
   `active` for production admissions, or `candidate` for certification runs (P24 certifies a
   candidate before it can be approved), whose base hash matches on every create.
6. **Owner to storage roots** (DECIDED, 2026-10-20): the roots come only from the admin-only
   storage document that the elevated helper writes, never from the inbox; each root passes the
   ProgramData trust checks at install, at every supervisor start and before every `create`, or
   the VM profiles stay off.

## 2. Allocator and capacity (contract: [allocator.md](../../parity/contracts/allocator.md))

DECIDED:

- One allocator inside the supervisor owns all five slots, for every backend, including the
  legacy WSL pool. Its state is `C:\ProgramData\aap-runner\capacity\allocator.json` (admin-only:
  owner Administrators, SYSTEM and Administrators full control, protected DACL, no other ACE, so no
  reader can hold `allocator.lock`), rewritten by atomic rename with a strictly increasing
  `revision`.
- Two live controls: Linux 0-5 and Windows 0-5, Linux + Windows in 1..5. 0 + 0 is not a
  setting; "off" is `inbox\state.json`. Linux 0 means the legacy pool is drained and stopped (the
  manager accepts only 1..5); Windows 0 means no Windows VM is admitted.
- The host reserve (10 %, owner-confirmed minimum) is never handed out. `share_mode: even` gives
  every runner `floor(pool / (linux + windows))` (today's tray rule); `per_profile` gives each
  profile its configured percent and each runner `floor(profile cap / profile count)`. The owner's
  example, 2 Windows = 30 %, 3 Linux = 60 %, 10 % host, is the per-profile fixture.
- Admission (`creating`, `ready`, `busy`, and a heartbeat quarantine, which may still run its
  job, are the admitted states) checks the per-runner share and
  the profile cap, counting each VM's measured memory overhead against its profile share. The
  pool check, the per-volume disk budgets of the storage tiers and the IO budget count **every
  live** reservation, including draining and quarantined ones, so a resize admits the other
  profile only into what the draining overhang leaves free.
- A reservation is acquired and persisted **before** any VM create, legacy slot start or
  registration. Its `lease_generation` is the slot's counter (`slot_generations`), incremented
  before each new reservation of that slot.
- Heartbeat (one rule everywhere): a validated guest `status` reply, or for a legacy slot the
  manager's slot entry in a fresh `status.json` (sample age <= 90 s), sets `heartbeat_at` at most
  every 30 s. Three missed intervals move `ready`/`busy` to `quarantined` (kind `heartbeat`),
  capacity held. A later validated heartbeat returns the slot to `busy` or `ready`. A heartbeat quarantine leads to destroy only when the broker reports the runner `offline` or `absent` and not busy, or the job is known to have ended. A VM whose runner GitHub reports `busy` is never destroyed; once `lease_wall_clock_hours` (default 6) have passed since the reservation's `acquired_at`, the slot is only flagged in status for the owner.
  A running job is never cancelled by this rule. A hostile guest reply is immediate and final from any guest
  state, a heartbeat or crash quarantine included: the kind becomes `hostile_guest`, then
  `deleting`.
- Only `reconciled` with a teardown proof frees a slot: VM and disks observed absent (or, for a
  legacy slot, the manager reporting the slot gone) and the runner deregistered, removed by
  GitHub, or never registered (create/boot failure).
- Legacy slots are adopted first: before the first VM reservation the allocator records one
  `wsl-legacy` reservation per configured legacy slot and sets `legacy_adopted`. From then on the
  supervisor writes `AAP_RUNNER_COUNT` from the Linux legacy reservations, so the legacy pool can
  never run five beside Windows. It writes `AAP_JOB_CPUS`/`AAP_JOB_MEMORY` as the minimum of the
  setting and the Linux cap, and legacy reservations record exactly what `limits.conf` grants, so
  the legacy pool cannot eat the host reserve.
- The always-on WSL control VM's measured memory (`control_distro_mem_gib`) and every VM's
  measured overhead come off the pool before any runner share.
- The allocator lock is an exclusive lock file in the admin-only capacity folder with a bounded
  wait that fails visibly (status `error`), not a named mutex.
- Nothing admitted is ever evicted (allocator.md, Resize and host measurement). A smaller count
  drains the excess (`resize_waits`); a host measurement that no longer holds the live
  reservations is stored clamped to them (`pool_over_live`), so nothing more is admitted. In
  `even` mode a count increase lowers every share, so every admitted runner drains, the legacy
  pool with a full stop and start (an open owner decision). An unknown clone or scratch folder
  blocks admission, and a provider's inventory listing is complete or throws (allocator.md,
  Reconcile).
- Provider rules (allocator.md): `JobRunning` comes from the broker's record of the job GitHub
  assigned, never from the guest; a heartbeat is bound to its reservation by the host-side channel,
  not by an id in the guest payload; the `hostile_guest` reason is a fixed host code, never guest
  text; legacy status is only as trustworthy as root in the control distro.

```mermaid
stateDiagram-v2
  [*] --> creating: reserve slot (persisted first)
  creating --> ready: VM booted, runner listening
  creating --> deleting: create or boot failed
  ready --> busy: job assigned
  ready --> draining: drain, pause, resize down, generation retire
  busy --> draining: drain, pause, resize down (job keeps running)
  busy --> collecting: job finished or cancelled by GitHub
  draining --> collecting: job finished, or idle runner released
  collecting --> deleting: evidence collected
  deleting --> reconciled: teardown proof observed
  creating --> quarantined: crash or uncertainty
  ready --> quarantined: 3 heartbeats missed
  busy --> quarantined: 3 heartbeats missed
  quarantined --> busy: validated heartbeat, job running
  quarantined --> ready: validated heartbeat, listening
  quarantined --> quarantined: hostile reply in a heartbeat or crash quarantine (kind hostile_guest)
  quarantined --> deleting: runner offline and not busy, job ended, or kind hostile_guest
  busy --> deleting: hostile guest reply only (immediate, final, any guest state)
  busy --> ready: legacy pool slot only, next job (never hyperv-vm)
  deleting --> quarantined: teardown failed after retries
  quarantined --> reconciled: reconcile observes absence
  reconciled --> [*]: slot free
```

`draining` from `busy` waits for the job (graceful, never cancelled). Off, pause and resizing
never cancel a running job (existing rule, kept). `draining` always passes through `collecting`
before `deleting`.

## 3. Backend lifecycle (contract: [backend-lifecycle.md](../../parity/contracts/backend-lifecycle.md))

DECIDED: every provider implements `create, boot, ready, run_one, drain, collect, destroy,
reconcile` with idempotency key `<reservation_id>/<lease_generation>/<op>`. Each op writes an
`intent` journal record before acting and a `done`/`failed` record after. Recovery after a crash
replays the journal: an op with intent but no outcome is re-run idempotently (create looks up the
named VM first; destroy treats "absent" as done). One job per VM, then destroy. **`reset` is
forbidden** (security review M3): destroying the VM is the control that removes every copy of the
runner credential.

VM files (DECIDED): `New-VM -Path` points inside the reservation's folder under `clone_root`;
checkpoints are disabled; `AutomaticStopAction TurnOff`; `AutomaticStartAction Nothing`; enhanced
session and the Guest Service Interface are off. The teardown proof covers the VM's configuration, saved-state and
checkpoint paths as well as its disks.

Storage tiers (DECIDED, owner 2026-10-20; contract: backend-lifecycle.md, Storage tiers). There is
no hard-coded image root. The installer and the owner choose `base_root` (catalog, base
generations, installation media copies), `clone_root` (per-reservation differencing disks, seed
media and VM files), `scratch_root` (per-reservation job scratch disks) and optionally
`staging_root` (P03 acquisition and image builds; default `<base_root>\staging`). The roots may
share one volume or use several; the owner decided that nothing for the Windows runner lives on
the NVMe system volume. They are kept in an admin-only storage document that only the elevated
helper writes; the supervisor never takes a path from the user-writable inbox. There are no
defaults: without a valid storage document the VM profiles stay disabled.

Root protection (DECIDED, security review H3, per root): at install, at every supervisor start
and before every `create`, each root independently passes the owner, ACL, reparse-point and
ancestor checks that `install-supervisor.ps1` runs on `C:\ProgramData\aap-runner`, on a fixed
drive and on the volume recorded for it; any failure disables the VM profiles and shows the tier
and reason in status. The capacity folder, `storage.json`, `clone_root` and `scratch_root` are
admin-only: owner Administrators, SYSTEM and Administrators full control, a protected DACL and no
other ACE, not even read. `D:\` fails the ancestor check (Everyone full control) and is never
used; the owner locked `E:\` to Administrators on 2026-10-20
([README, Resolved 2026-10-20](../../parity/contracts/README.md#resolved-2026-10-20)). Whether a
root on `E:` passes is shown by running the check (P19, P02.1), not by this note. No item
changes a partition, a volume or a volume root's ACL. Approved artifact hashes are pinned outside
every root (admin-only data folder and the P24 certificate), and every `create` re-hashes the
base against that pin.

DECIDED disk layout (no drive letter is fixed; the `X:`, `Y:` and `Z:` paths in fixtures are
synthetic):

```text
<base_root>\catalog.json
<base_root>\<profile>\<image_version>-aap.<n>\base.vhdx   one folder per generation, read-only, never moves
<base_root>\media\                                        verified installation media copies (P06 input)
<staging_root>\   (default <base_root>\staging)           P03 acquisition, P06/P07 build staging
<clone_root>\<reservation_id>\os.avhdx                    differencing child of its base
<clone_root>\<reservation_id>\seed.iso                    Linux cloud-init seed, if used
<clone_root>\<reservation_id>\   (New-VM -Path)           VM configuration and runtime files
<scratch_root>\<reservation_id>\scratch.vhdx              job scratch, per reservation
```

Rollback is catalog state only (`retired` plus the profile's `rollback` pointer); no file moves,
so a differencing child's recorded parent path stays valid. VM names are
`aap-<w|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>` (create precedes any lease);
the broker registers the runner under the same name.

Budgets are **measured** per generation and tier (base size; clone and scratch peaks and the caps
admission counts; staging; replacement; rollback; boot memory overhead) and stored as a `budget`
record with an evidence reference. Admission refuses a profile whose generation has no measured
budget, and counts each reservation's clone and scratch caps on the volume of that tier, above the
volume's free-space floor. The scratch cap is the VHDX maximum size; the clone cap is enforced by
sampling at every heartbeat and destroying a VM that passes it. Sizing evidence from the hosted
Windows image at job start (run 39303666617): `C:` 127,436,206,080 bytes used and 33,031,553,024
free (about 160 GB), `D:` 3.2 GB used and 157.9 GB free, 4 vCPU and 16 GiB. Planning estimate:
130-140 GB per base generation plus build headroom, 20-50 GB per running job, plus one rollback
generation. The 60 GiB Linux work-disk default is not a Windows budget.

```mermaid
sequenceDiagram
  participant A as Allocator
  participant P as Provider
  participant H as Hyper-V
  participant J as Journal
  A->>A: reserve slot, persist (creating)
  A->>P: create(key)
  P->>J: intent create
  P->>H: New-VHD -Differencing, New-VM (fixed name)
  P->>J: done create (vm_id)
  P->>H: Start-VM (boot)
  P->>P: ready: guest transport probe
  A->>A: ready
  P->>P: run_one: lease, deliver JIT, start runner
  A->>A: busy then collecting
  P->>P: release_request (lease id), then Stop-VM, Remove-VM, delete clone and scratch (destroy)
  P->>J: done destroy (absent observed)
  A->>A: reconciled with teardown proof
```

## 4. Registration broker (contract: [broker.md](../../parity/contracts/broker.md))

DECIDED: the App key stays root-only in the control distro. The broker is a fixed-path root
program in that distro, invoked once per request by the supervisor. It accepts only
`lease_request`, `release_request` and `status_request` documents: no path, no command, no label,
no runner name, no runner id, no URL. Every teardown sends `release_request` with the lease id
only (`already_gone` counts as proof); the broker resolves the runner from its own ledger. It derives the runner name and labels from the slot, lease generation and its own
root-only profile table: Windows `self-hosted,Windows,X64,aap-win25-vs2026`, Ubuntu
`self-hosted,Linux,X64,aap-ubuntu-24.04`, group `aap-crrr` (owner, 2026-10-19). The legacy pool
keeps its current labels. Access note (security review M1): WSL sessions belong to the user's
SID and `wsl.exe` needs no elevation, so any process of the operator account can run the broker and
read `app.pem`; replay, lease-limit and ledger rules are integrity controls, not access control.
DECIDED: the control distro and its keep-alive run whenever
Linux + Windows >= 1, so the broker is reachable; the supervisor makes no `wsl.exe` call only
while both counts are 0 or desired is off. One lease id issues at most one JIT config, ever (replay refused).

DECIDED: VM guests get **JIT runner configuration** from
`POST /orgs/{org}/actions/runners/generate-jitconfig` (GitHub REST, "Create configuration for a
just-in-time runner for an organization"; body `name`, `runner_group_id`, `labels`, optional
`work_folder`; response `runner` and `encoded_jit_config`). A registration token is **not**
one-use: GitHub documents only that it "expires after one hour". Registration tokens remain
only in the legacy pool's existing flow.

DECIDED (delivery): no copy of the JIT config exists outside the runner's own root directory
and processes, and destroying the VM is the control. It never appears in argv, script text, a
host file, the inbox, a status file, an image or a log; the supervisor reads at most 20 KiB of
broker stdout and never logs it, not even on a refusal. It travels broker stdout -> supervisor memory -> management channel -> guest agent
memory -> the runner's environment as `ACTIONS_RUNNER_INPUT_JITCONFIG`. In `actions/runner`
(`src/Runner.Listener/CommandSettings.cs`, `main` at `7ce71e54a9affe1daae918a3e2350c1543dfa240`,
read 2026-10-19) every `ACTIONS_RUNNER_INPUT_<arg>` variable is read as that argument, removed
from the process environment, and `jitconfig` is in the runner's secret list, so its value is
registered with the secret masker. The documented `./run.sh --jitconfig <value>` form puts the
secret in argv and is forbidden here. CANDIDATE (D2): that the pinned runner release behaves this
way end to end, that the guest leaves no copy, and that an unused JIT runner is removed (GitHub
documents "If JIT runners never run a job, they will automatically be removed"; timing
unspecified, so the provider deregisters explicitly through `release_request`).

```mermaid
sequenceDiagram
  participant S as Supervisor
  participant B as Broker (root, WSL)
  participant G as GitHub
  participant V as Guest agent
  participant R as Actions runner
  S->>B: stdin lease_request (bounded)
  B->>B: validate, check lease ledger and replay
  B->>G: App JWT, installation token
  B->>G: POST generate-jitconfig (name, group id, labels)
  G-->>B: runner id, encoded_jit_config
  B->>B: ledger: lease issued (no secret)
  B-->>S: stdout lease_response with jit_config
  S->>V: deliver_registration over management channel
  V->>R: start runner with ACTIONS_RUNNER_INPUT_JITCONFIG
  R->>G: one job
  S->>B: status_request while quarantined (runner online or offline)
  S->>B: release_request at every teardown (lease id only)
```

## 5. Guest management transport (contract: [guest-transport.md](../../parity/contracts/guest-transport.md))

CANDIDATE (D2):

- **Windows**: PowerShell Direct (`Invoke-Command -VMId`, `New-PSSession -VMId`). Microsoft
  documents it runs "regardless of network configuration", needs the VM to run locally, a Hyper-V
  administrator on the host and valid guest credentials.
- **Linux**: OpenSSH over a Hyper-V socket (`AF_VSOCK` in the guest, `CONFIG_VSOCKET` and
  `CONFIG_HYPERV_VSOCKETS`; host service GUID registered under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`).
  Fallback candidate: SSH on a per-clone isolated internal switch.
- Per-clone identity: VM id (Hyper-V GUID) plus the fixed VM name pattern. Per-clone credential:
  a random Windows local admin password or Linux ed25519 key generated by the supervisor for that
  reservation only, injected before first boot, never in a base image, discarded at destroy.
- Replay: every command carries reservation id, lease generation, a sequence number and a nonce;
  the host raises the sequence number on every send and never reuses one, the guest agent accepts
  only a number strictly greater than the last it accepted (gaps allowed, so a lost reply or failed
  probe never wedges the channel) and echoes the nonce and number, and accepts
  `deliver_registration` once per boot.
- Hostile replies: bounded size, strict schema, printable ASCII diagnostics, time-limited; a
  violation sends the slot straight to `deleting` with code `hostile_guest`.
- Wire framing: Windows runs each command in a short-lived hidden child process (job object
  with memory, CPU and time caps, machine `PSModulePath`) that takes the envelope and payload on
  stdin and hands them to the remote runspace through the PowerShell API (`[powershell]::Create()`
  with `AddParameter` or stream input, never a local cmdlet parameter that event 4103 would log),
  where one fixed script feeds
  `C:\Program Files\aap-guest\agent.ps1` on stdin; the child discards every non-output stream and
  returns one bounded string; Linux uses an SSH forced command `/usr/local/libexec/aap-guest/agent`
  over vsock port 5222 (host service GUID `00001466-facb-11e6-bd58-64006a7986d3`), stdin = envelope
  line then exactly `payload_bytes` bytes, stdout = one reply line. Limits and timeouts:
  guest-transport.md, Wire framing.
- Network: the enforcement shape is DECIDED (no External or Default switch; DHCP guard and router
  guard on, MAC spoofing off; extended port ACLs denying the host vEthernet addresses, private,
  link-local, CGNAT, multicast and ULA ranges, the LAN IPv6 prefix and other clones; enhanced
  session and Guest Service Interface off; host ports blocked on the guest vEthernet). The
  mechanism (internal switch per profile with NAT, or an internal switch per guest; a private switch has no host adapter and is not viable) is CANDIDATE D2,
  owned by the P10.0 guest network module. The lab proves internet egress works and every denied
  path fails, over IPv4 and IPv6.

```mermaid
sequenceDiagram
  participant P as Provider
  participant D as Clone disk (offline)
  participant V as Guest
  P->>P: generate per-clone credential (memory only)
  P->>D: inject credential (unattend or seed), before first boot
  P->>V: boot
  P->>V: probe (vm_id, seq 1, nonce)
  V-->>P: guest_reply ready (bounded, validated)
  P->>V: deliver_registration (seq 2, payload in session)
  V-->>P: listening
  loop heartbeat
    P->>V: status
    V-->>P: busy or job_done
  end
  P->>V: collect, shutdown
  P->>P: destroy VM and clone, drop credential
```

## 6. Image catalog (contract: [image-catalog.md](../../parity/contracts/image-catalog.md))

DECIDED: generations are immutable and identified as `<profile>/<image_version>-aap.<n>`,
anchored to the P01 baselines (Windows `aee0669` / `20261007.264.1`, Ubuntu `7e7dc1b` /
`20261012.334.1`) and their `inventory.json` hashes. One `active` generation per profile;
the previous one is `retired` and kept as the single rollback generation. New admissions use the
active generation; running jobs finish on theirs. A `quarantined` generation is never re-activated.
The live supervisor refuses, and admits nothing from, a catalog at its configured `base_root` whose scope is not `live`. Lab catalogs never live under the live base root. A catalog at that path that says `lab` (or anything but `live`) disables the VM profiles, with the reason in status. Defense in depth: each entry in the admin-only `C:\ProgramData\aap-runner\capacity\approved-images.json` pins the generation's artifact hashes **and** carries the reference to the owner's `live_activation` record; the live supervisor admits an `active` generation only when the catalog and that entry both have it.

Acceptance input from P05: a Ubuntu generation is approved only when P07 and P11 match the hosted
kernel, `read_ahead_kb` and mount options, or a reviewed allowlist entry justifies each difference
(image-catalog.md).

```mermaid
stateDiagram-v2
  [*] --> candidate: assembled, hashed, secret-scanned
  candidate --> approved: certificate and approver recorded
  candidate --> quarantined: failed test, tamper, secret found
  approved --> active: atomic pointer switch for new admissions
  approved --> quarantined
  active --> retired: newer generation activated (kept as rollback)
  active --> quarantined: post-activation failure
  retired --> active: rollback switch
  retired --> [*]: rollback window ends, deleted by owner P25
  quarantined --> [*]: deleted after evidence kept
```

## 7. Cache (contract: [cache-qualification.md](../../parity/contracts/cache-qualification.md))

DECIDED: zccache 1.15.6 (tag `1.15.6`, commit `15ec9537`) replaces sccache entirely. Each compiler
and invocation on each platform is `qualified` (with evidence) or `direct` (no wrapper). No sccache
fallback, binary, variable or format reuse. Native `cl.exe`/`link.exe` start `direct` (the pinned
feature matrix marks them partial). Isolated cache roots per trust namespace (the repository plus
the job's trust class: only push or schedule on the default branch with the
repository as head repository is trusted, every other event or ref is untrusted, including
workflow_dispatch and a tag push whose head_sha is not reachable from the default branch; a root is
shared only among jobs whose writers are at least as trusted as every reader, and an untrusted job
gets only its private per-job root; no shared root when the class is not known from GitHub before
the root is attached) and copy or reflink delivery by default;
hardlink delivery and cross-trust sharing stay off until P04/P13 prove them.

```mermaid
flowchart LR
  J[Job compiler call] --> Q{mode for compiler and invocation on this platform}
  Q -- qualified --> Z[zccache wrapper, isolated root, daemon retention]
  Q -- direct --> C[native compiler, no wrapper]
  Z -- daemon failure --> C
```

## 8. Status and settings (contract: [status-settings.md](../../parity/contracts/status-settings.md))

DECIDED: existing files stay compatible. `inbox\settings.json` schema 2 and `status.json`
schema 4 keep their meaning. The supervisor adds `status.v5.json` beside `status.json` (the
current tray reports any `status.json` schema above 4 as an error, so schema 5 must not replace
it). The tray writes `settings.json` schema 3 only after `status.v5.json` lists 3 in
`settings_schemas`; until then it keeps the Windows count in its tray-local file.
`status.v5.json` also reports the storage tiers (root, volume free space, floor, state); the tray
shows them and never changes them, and settings schema 3 carries no path.

```mermaid
flowchart TB
  T[Tray] -- "schema 2, or 3 once advertised" --> I[inbox settings.json]
  I --> S[Supervisor]
  S --> S4[status.json schema 4, legacy pool view]
  S --> S5[status.v5.json: profiles, slots, generations, cache, storage]
  S5 -- "settings_schemas lists 3" --> T
  S4 --> T
  TL[(tray-local windows-runners.json)] <--> T
```

## 9. Evidence and cleanup (contract: [evidence-cleanup.md](../../parity/contracts/evidence-cleanup.md))

DECIDED: every accepted result is one evidence-bundle record; every merged item gets a cleanup
receipt in the shape P00 writes (automated) or the coordinator's manual shape, both with an
independent verifier and observed absence. See [WORKTREES.md](WORKTREES.md).

```mermaid
flowchart LR
  W[Worker] --> E[evidence-bundle records]
  E --> V[Independent verifier at exact head]
  V --> M[Agent merge]
  M --> C[Cleanup per WORKTREES.md]
  C --> R[cleanup receipt, verifier is not the actor]
  R --> N[Barrier opens, next claim]
```

## 10. Failure handling at every boundary

| Boundary | Failure | Required behaviour |
|---|---|---|
| Tray -> inbox | invalid, oversized, future schema | supervisor logs one warning, keeps last valid settings (existing rule) |
| Supervisor crash | any point | on restart: reload allocator, replay journals, reconcile; no slot freed without proof |
| Allocator write | crash mid-write | atomic rename; the previous revision stays authoritative |
| Admission | sixth slot, over share, unmeasured budget, legacy not adopted | refuse; nothing created, nothing registered |
| Broker call | wsl fails, timeout, malformed reply, `refused` | no registration; slot goes `deleting`; retry only with a new lease id |
| GitHub API | 404/409/422/rate limit | broker returns `refused` with a reason; no partial runner left (delete by id if one was created) |
| VM create/boot | Hyper-V error, timeout | journal `failed`; destroy; reconciled after absence observed |
| Guest transport | auth fails, no reply | bounded retries, then the heartbeat rule above |
| Guest transport | hostile reply | immediate `deleting` with `hostile_guest`; final, never back to service |
| Heartbeat | 3 missed (90 s) | `quarantined` (kind `heartbeat`), capacity held; back to `busy`/`ready` on a validated heartbeat; destroy only once GitHub reports the runner offline and not busy, or the job ended; a busy runner past `lease_wall_clock_hours` is held and flagged, never destroyed |
| Job | cancelled, failed, timed out | normal: `collecting` then `deleting` |
| Teardown | VM or disk will not go | three retries over 15 s, then `quarantined`; capacity held; status shows it |
| Unknown VM `aap-*` on the host | no journal | reconcile quarantines it in a free slot or refuses admission until resolved; never adopted silently |
| Image | hash mismatch, quarantined generation | refuse create; status shows the generation state |
| Storage root or volume | a trust check fails, the volume changed or is missing | VM profiles `available: false` with tier and reason; no admission; nothing created or repaired; a reservation whose disks are gone is quarantined (`crash`) until reconcile observes absence |
| Storage volume | free space below the floor | no new VM admission; running VMs continue within their admitted caps |
| Clone growth | clone folder passes `clone_gib_max`, or Hyper-V pauses the VM for lack of space | destroy (`fatal`, journaled); the job fails |
| Control distro down | no broker | VM profiles report `available: false`; running guests finish their jobs |

## 11. Responsibilities by later item

| Contract | Writer | Readers |
|---|---|---|
| allocator | P09 | P10, P11, P12, P16, P20, P22 |
| backend-lifecycle | P10, P11; storage document P19 | P09, P12, P19, P20, P22, P25 |
| broker | P08 | P10, P11, P14, P15, P16, P26 |
| guest-transport | P10, P11 host side; P14, P15 guest agent; lab proof P08/P10/P11 | P22, P26 |
| image-catalog | P21, P25 | P06, P07, P10, P11, P12, P19, P20, P24 |
| cache-qualification | P04 | P13, P14, P15, P16, P20, P22, P24 |
| status-settings | P12 (supervisor and docs), P20 (tray) | P19, P22 |
| evidence-cleanup | P05, P00 | every item, P24, P26, P28 |

## 12. Hardening notes

- Hyper-V core scheduler on (`bcdedit /set hypervisorschedulertype core`, checked, not changed, by
  the installer preflight); nested virtualization off for guests by default.
- Runner self-update: the actions-runner overlay is valid for one boot only; GitHub's support
  window for runner versions sets the rebuild deadline, so P25 rebuilds the overlay inside it.
- Cache trust namespace: the repository plus the job's trust class. Trusted only for `push` or
  `schedule` on the default branch with the repository as head repository; `workflow_dispatch`
  (an untrusted same-repository job with `actions: write` can dispatch with attacker-chosen
  inputs), `pull_request`, `pull_request_target`, `workflow_run`, `issue_comment`, `merge_group`,
  other branches, tags whose `head_sha` is not reachable from the default branch, and unknown
  events are untrusted. The class is bound from GitHub's record of the assigned job (matched by
  `runner_id` and `runner_group_id`, exactly one match) before any shared root attaches, never from
  the guest; when that record is unavailable or ambiguous the job gets no shared root, and an
  untrusted job gets only its private per-job root. The namespace key is the repository id, the
  trust class, the zccache version and the toolchain digest.
- Relative disk paths have exact forms, relative to their tier root: `<generation_id>/base.vhdx`
  (base_root), `<reservation_id>/os.avhdx` and `<reservation_id>/seed.iso` (clone_root),
  `<reservation_id>/scratch.vhdx` (scratch_root); `validate.py` enforces them.
- Storage roots are absolute drive-letter folders below the volume root, never UNC or device
  paths, never nested, each on its recorded volume; set only through the elevated helper, never
  from the inbox. No VM file uses Hyper-V's default host folders.
- Approved image hashes, guest credentials and SSH keys live only in Administrators/SYSTEM folders
  with inheritance off and no operator entry.

## References

- GitHub REST, self-hosted runners (JIT config, registration token expiry): <https://docs.github.com/en/rest/actions/self-hosted-runners?apiVersion=2022-11-28>
- GitHub, remove runners (JIT runners run one job; unused JIT runners are removed automatically): <https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/remove-runners>
- actions/runner `CommandSettings.cs` (environment input, secret masking): <https://github.com/actions/runner/blob/7ce71e54a9affe1daae918a3e2350c1543dfa240/src/Runner.Listener/CommandSettings.cs>; secret argument list in `src/Runner.Common/Constants.cs` at the same commit. Latest release on 2026-10-19: v2.338.0.
- PowerShell Direct: <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct>
- Hyper-V sockets, Linux `AF_VSOCK` guests: <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/make-integration-service>
- P01 baselines: [parity/baselines/README.md](../../parity/baselines/README.md); zccache pin: [parity/baselines/zccache.md](../../parity/baselines/zccache.md)
