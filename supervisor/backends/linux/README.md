# Linux VM backend (ledger item P11)

The supervisor-side provider for `hyperv-vm` reservations of the Linux profile (Ubuntu 24.04 x64). It runs inside the
hidden, elevated supervisor and is the only code that drives Linux runner VMs. Contracts:
[backend-lifecycle.md](../../../parity/contracts/backend-lifecycle.md) (version 2),
[guest-transport.md](../../../parity/contracts/guest-transport.md) (version 1),
[allocator.md](../../../parity/contracts/allocator.md) (version 2) and [broker.md](../../../parity/contracts/broker.md)
(version 1). The image it clones is P07's ([images/ubuntu-24.04](../../../images/ubuntu-24.04), its INTEGRATION.md, P11
section). Its Windows twin is [../windows](../windows/README.md) (P10); this backend follows the same rules and every lesson
of P10's reviews, and differs only where a Linux guest differs. What other items must wire is in
[INTEGRATION.md](INTEGRATION.md).

**Status: authored against fakes only.** No VM, switch, disk, seed ISO, key pair or SSH session was created. The guest
transport is CANDIDATE (D2) until the lab proof P02.1 passes; the guest network is the P10.0 module, not built yet; this backend conforms to its contract,
[host-network-module.md](../../../parity/contracts/host-network-module.md) (P11.2).

| File | What it is |
|---|---|
| `AapLinBackend.psm1` | The lifecycle: `New-AapLinBackend`, `Invoke-AapLinStep`, the reconcile callbacks, the journal, the trust checks, the seed's content (`New-AapLinSeed`), the guest channel and its checks |
| `AapLinBackend.HyperV.psm1` | The production provider: every Hyper-V, CIM (Key-Value Pair Exchange), IMAPI2 (seed ISO), ssh-keygen and hash call, behind one hashtable of ops. NOT RUN |
| `hvsock-relay.ps1` | ssh.exe's ProxyCommand: one AF_HYPERV stream to the VM's runtime service, bytes both ways, only from inside the call child's job object. Only its argument checks, its job guard and its address layout have run |

## What differs from the Windows twin

| | Windows (P10) | Linux (P11) |
|---|---|---|
| Guest files in | answer file written offline into the mounted clone disk | **never**: the host never mounts a guest disk (Windows cannot read ext4; P07 decision 1). A host-built NoCloud seed ISO (`<clone>\seed.iso`, label `CIDATA`) carries only public material and is ejected and deleted after first boot |
| Credential | random password, in supervisor memory only | ed25519 key pair made by `ssh-keygen` straight into `<clone>\ssh\` (protected SYSTEM/Administrators DACL from its creation); the private key never enters this process; deleted with the clone |
| Channel | capped `psdirect-call.ps1` child, PowerShell Direct | capped `ssh.exe -F <clone>\ssh\ssh_config -T aap-guest` child; `hvsock-relay.ps1` as ProxyCommand (vsock 5222, service `00001466-facb-11e6-bd58-64006a7986d3`); forced command `/usr/local/libexec/aap-guest/agent` |
| Host key | (none) | the guest publishes its ed25519 host key through Key-Value Pair Exchange (guest to host) at first boot; it is pinned into `<clone>\ssh\known_hosts` before the first SSH command; a key of another shape is `hostile_guest` (`bad_host_key`) |
| After a supervisor restart | channel lost: a clone not running a job is destroyed | channel kept: key, pin and the `seq` mark persist in `<clone>\ssh\`, so probing, heartbeats and collect continue; a missing or damaged folder or mark fails closed exactly like the Windows twin |
| Disks | differencing `os.avhdx` + `scratch.vhdx` | differencing `os.avhdx` only (`scratch_gib` must be 0: a hosted Ubuntu job writes to its root file system, here the clone) |
| VM | generation 2, Secure Boot off, nested virtualization on, GSI and KVP off | generation 2, Secure Boot on with `MicrosoftUEFICertificateAuthority`, static memory, nested virtualization on, GSI off, **KVP on** (host-key pinning only) |

## How it works

`Invoke-AapLinStep -Backend $B -Reservation $r [-BaseSha256 <pin>]` does one step for one reservation, chosen by the
allocator state and the reservation's journal. The supervisor calls it for every live Linux VM reservation on every tick.

| Allocator state | Step |
|---|---|
| `creating` | **create**: trust-check the roots and the host (Enhanced Session Mode off, nobody but SYSTEM and Administrators in Hyper-V Administrators), check that the generation folder and `base.vhdx` are sealed read-only, re-hash the base against the pin through a read handle held until the differencing disk exists and its parent is checked, the clone folder, `os.avhdx`, a fresh key pair, `New-VM` with no network adapter and an empty DVD drive and its id journaled at once (or the VM whose id the journal already recorded), the per-clone `ssh_config`, P10.0's `Attach` (VM Off) and the shared declaration check, the seed ISO with the declaration's static addressing (`SetSeed` puts it in the DVD drive), read back and verify every VM setting, its disk and its DVD, then `Verify` and the read-back. Then **boot**: `Attach` again (VM Off; the same declaration), the declaration check, `Verify` and the read-back, then `Start-VM` (a VM found already running is verified instead), then **ready**: then **ready**: wait for the host key in KVP and pin it, `probe` until `ready` (at most 15 minutes after boot), eject and delete the seed, check no medium is left, `Set-AapSlotState ready` |
| `ready` | **run_one**: `Invoke-AapBrokerLease`, `deliver_registration` with the JIT config on the ssh child's stdin, `start_runner` (its success journaled) |
| `ready`, `busy`, `draining` | **heartbeat**, at most every 30 s per reservation: guest `status` over this VM's own channel, broker status for `JobRunning`, `Update-AapHeartbeat`. A runner that GitHub reports gone ends the job (`collecting`); a draining runner that is idle is stopped; a busy one is never touched |
| every state with a VM | **limits**, from the host, before anything else on every step, with or without a guest channel: `creating` while it probes, `ready`, `busy`, `draining`, `collecting`, every quarantine, and `deleting` (a drained VM kept for its pending release) before the once-a-minute retry gate; after a restart too. A paused VM, a clone folder over `clone_gib` (or one that cannot be measured), or a running VM whose network P10.0's `Verify` no longer accepts or cannot look at (at most every 30 s per reservation) destroys the VM (`fatal`), the slot held until the teardown proof |
| `collecting` | **collect**: the agent's bounded summary (returned as `Summary`, never written), then `deleting` |
| `deleting` | **destroy**: `Invoke-AapBrokerRelease` if a lease was ever asked for, `Stop-VM -TurnOff`, `Remove-VM`, P10.0 detach, delete the clone folder (disk, seed, VM files, key) and any scratch folder without following links, observe absence, `Complete-AapTeardown` |
| `quarantined` | `heartbeat`: a validated reply plus a broker answer returns it; `hostile_guest`, `teardown_failed`, or a destroy already journaled: destroy again; `crash`, `unknown_vm`: held |

There is no `reset`: destroy is the only way a VM leaves (security review M3).

### The journal is the state

`<JournalRoot>\<reservation_id>.jsonl` (production `C:\ProgramData\aap-runner\capacity\journal`, admin-only, created with
a protected DACL): one backend-lifecycle `op` record per line (`profile` `linux`; disks `base_ref`, `os_diff`, `seed`),
`intent` flushed to disk before every act, `done` or `failed` after. A supervisor killed at any point resumes from it:

| Crash after (backend-lifecycle.md) | What the next step does |
|---|---|
| reservation persisted, nothing journaled | create |
| `create` intent, before or after `New-VM` | re-runs create: reuses the disk it made and only the VM whose id the journal recorded right after `New-VM`, makes a fresh key pair and seed (the clone never booted), never a second VM. A VM found only by its name is destroyed, never adopted |
| `create` done, `boot` or `ready` in flight | re-probes over the kept channel, `seq` above the persisted mark; on the 15-minute deadline destroy. A lost key folder, or a missing or damaged mark: destroyed, never probed |
| lease asked for, not delivered | broker status: busy waits; anything else stops the runner and destroys, releasing the lease |
| runner started | heartbeats go on over the kept channel; never cancelled |
| `destroy` partial | destroy again; only observed absence completes it |
| journal unreadable (not JSON, another lease or profile, over 4 MiB) | `quarantined`, kind `crash` (`teardown_failed` when it was `deleting`), capacity held |

A torn last line is ignored when read and cut off before the next append. A teardown that keeps failing the same way
repeats neither its intent nor an identical failure record, so retries do not grow the journal toward its 4 MiB bound.
Facts the `op` schema has no field for ride in repeated `ready` `done` records with fixed details: the lease id
(`probe ready; seed ejected; lease l-...`, before the lease call), the broker's answer (`lease issued by the broker`,
`lease answer unreadable`) and the runner start (`runner started on the guest`).

One backend context belongs to one runspace. `Invoke-AapLinStep` holds `<JournalRoot>\<reservation_id>.lock`
(`FileShare.None`, deleted on close) for the whole step; a step that finds it held returns `held` / `step_in_progress`.

### The per-clone credential and seed

`ssh-keygen -t ed25519` writes `id_ed25519` and `id_ed25519.pub` into `<clone_root>\<rid>\ssh\`, a folder created with a
protected SYSTEM/Administrators DACL (an unelevated test run adds only its own SID). Only the public line comes back. The
private key is never read, logged, journaled or passed to a command: `ssh.exe` reads it through `IdentityFile`. It dies
with the clone folder.

The seed (`New-AapLinSeed`, written by the provider's `NewSeedImage` as ISO 9660 + Joliet labelled `CIDATA`):

- `user-data`: `hostname` (the VM name), `disable_root: false`, `ssh_pwauth: false`, `ssh_deletekeys: true`,
  `ssh_genkeytypes: [ed25519]`, the job user `runner` (uid 1001; groups `adm`, `users`, `docker`, `systemd-journal`;
  passwordless sudo; `lock_passwd: true`) as the only entry of `users` (so cloud-init's default user, uid 1000, is never
  created, and no account gets uid 1000), and root's `authorized_keys` with exactly one line:
  `restrict,command="/usr/local/libexec/aap-guest/agent" ssh-ed25519 <public> aap-management`.
- `meta-data`: a fresh `instance-id` (`aap-<rid hex>-<lease generation>-<random>`) and `local-hostname`.
- `network-config` (version 2): the static addressing from the declaration P10.0's `Attach` returned, once the shared
  check accepted it for this VM: the `address` with the subnet's prefix length, the `gateway` as default route, the
  `resolvers` as DNS servers, `dhcp4`, `dhcp6` and `accept-ra` off, no link-local addressing, on the one interface matched
  by driver `hv_netvsc`. Nothing on the host serves DHCP or DNS to guests (host-network-module.md, Attach). The
  declaration itself is never journaled or kept: every create run and every boot attaches again and gets the same one
  from the module's journal.

The writer takes only full blocks from IMAPI2's image stream (a short read fails the image instead of leaving stale bytes
in it) and reports the size and SHA-256 of what it wrote; create reads the file back through a read-only handle against
both before any VM gets it (`AAP_SeedInvalid`).

Never a private key, a JIT config, a registration token, a password or a host key. Once the guest answers its first probe
`ready`, the seed is ejected (`EjectSeed`), deleted, and the VM is checked to hold no medium; a failure destroys the clone
(never registered).

### The guest channel

Each command is one hidden `C:\Windows\System32\OpenSSH\ssh.exe -F "<clone>\ssh\ssh_config" -T aap-guest` with the
machine `PSModulePath`, inside a job object made before it starts under a random name (`aap-lin-call-<32 hex>`; 512 MiB,
CPU time and kill-on-close; the wall cap is the command's timeout plus 10 s, session setup included). ssh.exe is put in
the job just after it starts, so a child it made before then would be outside it. Its ProxyCommand, `hvsock-relay.ps1`
under Windows PowerShell, therefore talks to the guest only from inside that job: it gets the name in `AAP_RELAY_JOB`
(inherited through ssh.exe), opens the job and asks `IsProcessInJob`, closing the handle at once (one held from inside the
job would keep kill-on-close from firing), and outside it exits 4 before any socket exists; ssh.exe then fails (255) and
the command is a failed guest the next one retries. Its stdin carries the envelope line, then exactly the payload, written
to the pipe unbuffered (through the redirected stdin's own stream a JIT config would stay behind in that stream's private
4 KiB buffer, which nothing can zero); at most 8193 bytes of stdout are read; stderr is drained through a 4 KiB buffer and
dropped, never parsed.

`ssh_config` (security review M4): `User root`, `HostName <vm id>`, the relay by absolute path, `IdentityFile`,
`UserKnownHostsFile` (the pin) and an empty `GlobalKnownHostsFile` in the clone's ssh folder, `HostKeyAlias aap-guest`,
`HostKeyAlgorithms ssh-ed25519`, `StrictHostKeyChecking yes`, `UpdateHostKeys no`, `IdentitiesOnly yes`, `IdentityAgent
none`, public key only, `BatchMode yes`, `ForwardAgent no`, `ForwardX11 no`, `ClearAllForwardings yes`, `Tunnel no`,
`PermitLocalCommand no`, `RequestTTY no`, `EscapeChar none`, no control master, `LogLevel QUIET`. `-F` makes ssh.exe skip
the system-wide configuration. Paths are written with forward slashes and refused if they hold `%`, `"` or a control byte.

Nothing is sent before the host key is pinned or through a channel folder that is not a plain folder (`channel_unusable`,
a failed guest). `seq` grows by one per send and is never reused, also across a restart: the mark in `<clone>\ssh\seq` is
written (whole, flushed, swapped in) before the first send past it, in blocks of 1000; a send the mark does not cover is
never made. Create writes it as `0` with the key pair, so every channel has one: after a restart a missing mark is as
lost as a damaged one (nothing is sent; the guest is unreachable). The agent accepts any `seq` strictly greater than the
last one it accepted (guest-transport.md, Sequence rule), so a lost reply or an unreachable guest leaves a gap and never
wedges the channel.

Every reply is hostile input, checked in this order, each failure a fixed `hostile_guest` reason (guest text is never
kept):

| Code | Meaning |
|---|---|
| `oversized_reply` | more than 8192 bytes (one trailing newline allowed), or the read overflowed |
| `child_exit` | ssh.exe exited non-zero but not 255: the forced agent broke the contract |
| `non_printable` | a byte outside printable ASCII (a login banner before the reply included) |
| `bad_json` | not exactly one strict JSON object |
| `extra_fields` | a field missing or added (the 11 fields of `guest_reply`, case-sensitive) |
| `bad_value` | a field of the wrong type or value |
| `wrong_echo` | `vm_id`, `reservation_id`, `lease_generation`, `seq` or `nonce` not this command's own |
| `secret_value` | a token- or key-shaped `diag` |
| `bad_state` | a `guest_state` the command cannot produce |
| `bad_host_key` | the host key published in KVP is not one `ssh-ed25519` public key |

ssh.exe's own failure (exit 255: the relay could not connect or was outside its job, the pinned host key or the client
key was refused, the connection dropped mid-reply), a timeout or an empty reply is a **failed guest**, never a hostile
one: a guest that breaks its channel gains nothing it could not get by staying silent. A valid `refused` or `error` reply
stops the step it belongs to. A hostile reply is final: journaled `hostile_guest`, the slot straight to `deleting`, the VM
destroyed in the same step even when the allocator call fails.

Which reservation a heartbeat belongs to comes from the VM this process sent the command to; whether a job runs comes
from the broker's status of the runner, never from the guest.

### Teardown and the slot

As the Windows twin (its README, Teardown and the slot): the slot is freed only by `Complete-AapTeardown` with a `vm`
proof after the VM (by id and by name), the clone folder (with the key and seed) and any scratch folder are observed
absent on roots present on their recorded volumes, after the network detach succeeded, with a final runner proof
(`never_registered`, `true`, `github-removed`; `uncertain` holds the slot as `teardown_failed`; `pending` keeps it
`deleting`, retried at most once a minute). A drained VM whose release is pending is kept, held to every limit on every
step, flagged `drain_overdue` after 6 h, never destroyed for time; its release waits until the broker answers ok with the runner
not busy (busy, unavailable, a timeout or an unreadable reply keep it; an urgent teardown does not ask). Three tries 5 s apart, then `teardown_failed`, capacity
held. Deletes never follow a junction or symbolic link, and an ACL is never written through one.

### Trust checks

As the Windows twin: every tier root (base, clone, scratch) is a normalized folder on a fixed drive, no reparse point on
it or above it, ancestors owned by an admin that nobody else may delete or re-permission, the root owned by SYSTEM,
Administrators or TrustedInstaller with a protected DACL, on the recorded volume; `clone_root` and `scratch_root` (and the
journal and compile folders) admin-only; `base_root` may grant read only. The generation folder and `base.vhdx` carry P07's
sealed signature (admin owner, protected DACL, nothing but Virtual Machines read, ReadOnly). `Get-AapLinHostProblem`
reports Enhanced Session Mode not off (`AAP_EnhancedSession`) and any Hyper-V Administrator but SYSTEM and Administrators
(`AAP_HyperVAdmins`); create refuses either.

## Decisions taken here (for review)

1. **Nested virtualization is exposed** to Linux clones (`ExposeVirtualizationExtensions`), because hosted Ubuntu runners
   offer `/dev/kvm`; the same accepted hypervisor surface as the Windows twin (its INTEGRATION.md, follow-up e). The
   backend refuses a clone where it is off.
2. **Root receives the forced command** (`PermitRootLogin forced-commands-only`, P15's image part): the agent runs as root
   and starts the runner as `runner`; no separate management account, so no account but `runner` (uid 1001) is created.
3. **KVP is on** for Linux clones, for host-key pinning only (guest-transport.md, Linux candidate). If P02.1 picks another
   pinning path, `KeyValuePairExchange` and `GetHostKey` change together. host-network-module.md ("Not the module's")
   says the consumers' `NewVm` turns Key-Value Pair Exchange off; for Linux clones that contradicts guest-transport.md's
   Linux candidate, and this backend keeps it on (reported to the coordinator as a contract wording defect, P11.2).
4. **The channel survives a supervisor restart** (key, pin and seq mark on disk, as guest-transport.md keeps the Linux key
   in a per-reservation file); P10 request 3 asks the same for Windows.
5. **Mount options and read-ahead** (image-catalog.md, Acceptance input for P07 and P11): the backend attaches one SCSI
   disk, the image's own root file system, and passes nothing that changes how the guest mounts it, so the image's
   `fstab` options and udev read-ahead (P07 records them) are what the job sees. No job disk is attached or mounted by
   the host.
6. **A running clone is re-verified with `Verify` only** (accepted residual, P11.2 review): the backend keeps no copy of
   the declaration and the module gives one only to `Attach` of an Off VM, so while the VM runs nothing holds what the
   provider read-back would be judged against. The read-back (`Get-AapHostNetworkAdapterProblems` on the provider's
   adapters) runs at create and before every start; between starts the module's own `Verify` is the only check, at most
   every 30 s per reservation.

## Tests

`tests/backends/linux`, Pester 5.7.1 on Windows PowerShell 5.1 and PowerShell 7.5 or later, real temp folders, the real
allocator (`-RelaxedTrustForTests`) and broker client, file-backed fakes for Hyper-V, ssh-keygen, the seed writer, the
guest's first boot and its agent, the broker and the network (no Hyper-V, ssh, WSL or network call). `python` must be on
`PATH` (journal records and guest exchanges are checked with `parity/contracts/validate.py`).

| File | Covers |
|---|---|
| `Lifecycle.Tests.ps1` | one job end to end; boot and host-key deadline; lost replies; drain; heartbeat binding; the limits in every state and after a restart; two consecutive jobs on one slot observe nothing of each other |
| `Transport.Tests.ps1` | every reply check; ssh failures are failed guests; every hostile case end to end; bad host key; changed host key; pin first; the ssh_config hardening; the real capped child (overflow, stderr flood, hang, memory flood, grandchild, exit codes, stdin only, BOM-free stdin under three code pages, the payload unbuffered); the relay's arguments and address; its job guard (the call child's job named for it: inside, on to its socket; another job, another name for the same job, no name, a job it is not in: exit 4 and no socket; no handle kept on the job) |
| `Teardown.Tests.ps1` | release outcomes; a VM, key or folder that will not go; no slot reuse before the proof; links in clone folders |
| `Create.Tests.ps1` | untrusted roots; the base pin and seal; host settings; the seed's content and its network-config from the declaration (only dotted IPv4 and a prefix length reach its YAML, even past a looser shared check); key and seed failures; the ISO writer's full blocks and short reads; the seed read back (lost or stale bytes); re-run create; VM settings; the network against the shared strict fake (`tests/common/AapHostNetworkFake.psm1`): the create order (no seed at `NewVm`, `Attach`, seed, `SetSeed`, `Verify`), no copy of the declaration, every tamper and fault refused at create and before the start, a `$null` from `Verify`, the provider read-back, a refused declaration, a crash between `Attach` and the seed, the re-`Attach` before `Start-VM`, a running clone verified again; the provider's adapter-name rule; eject; the pin file; the storage document and context |
| `Recovery.Tests.ps1` | unreadable journals; hostile records; restart keeps the channel (probe, heartbeats, collect); a fresh channel's initial mark; missing or damaged seq mark and lost key folder; restart between delivery and start; JIT delivery rule; inventory and reconcile callbacks; orphans |
| `Crash.Tests.ps1` | a real process killed at every lifecycle boundary (24 points, plus a drain and a running job) and recovered: never a second VM or lease, no refused `seq`, no secret left |
| `Hygiene.Tests.ps1` | no JIT config or private key in any file; the private key never read; the JIT object never a command's parameter; antivirus patterns; AMSI compile; hidden children with no data on their command line; one `Add-Type`, under the admin-only `%TMP%` |
| `Invoke-AapLinMutations.ps1` | a control run, then disables each `# check:` (in `AapLinBackend.psm1`, `hvsock-relay.ps1` and `AapLinBackend.HyperV.psm1`) in turn; every check must make a test fail |

```powershell
Invoke-Pester -Path tests/backends/linux             # both hosts
pwsh -File tests/backends/linux/Invoke-AapLinMutations.ps1
```

## What is not done

- No real run: the production provider, ssh.exe through the relay, the IMAPI2 seed writer, the KVP read and the job
  object's limits on a real ssh session are proven only by P02.1 (lab) and P22. That ssh.exe passes `AAP_RELAY_JOB` on
  to its ProxyCommand is one of them: if it did not, every relay would refuse and no clone would get past its first probe
  (fail closed, seen at once).
- The guest network module (P10.0) does not exist; without it every create fails closed (`AAP_NetworkUnavailable`).
  Against it the backend follows the contract's consumer obligations; that cloud-init NoCloud takes the address from
  `network-config` on `hv_netvsc` with no DHCP client asking, and the provider's adapter read-back as Hyper-V really
  shows it, are lab points (P02.1).
- The guest agent, the sshd vsock socket and the KVP host-key publisher (P15) do not exist; the fake guest follows
  guest-transport.md and INTEGRATION.md, P15.
- `shutdown` is never sent: destroy turns the VM off.
