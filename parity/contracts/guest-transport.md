# Guest management transport contract (version 1)

Owners: P10/P11 (host side), P14/P15 (guest agent). The lab proof below is the single-owner ledger
child **P02.1**, which gates P10/P11 fan-out. Readers: P08, P22, P26. Schema:
[`guest-transport.schema.json`](guest-transport.schema.json) (`host_cmd` envelope and the only
`guest_reply` the host accepts). Fixtures: `fixtures/guest-transport/`.

**Status: CANDIDATE (D2).** Every mechanism here is the chosen candidate, not a proven one. No VM
was created for this contract. P10 and P11 may implement against simulated providers only until
P02.1 passes.

## Envelope (DECIDED, transport-independent)

The host sends only these commands: `probe`, `deliver_registration`, `start_runner`, `status`,
`collect`, `shutdown`. Each carries `vm_id`, `reservation_id`, `lease_generation`, `seq`, a fresh
128-bit `nonce`, `payload_bytes` (non-zero only for `deliver_registration`) and `expires_at` (at
most 120 s ahead). There is no command that runs caller-supplied code, takes a path, or returns a
file.

Sequence rule: one counter per boot for all command classes, starting at 1 with the first `probe`,
+1 per command, never reset within a boot, at most 2^31-1. A VM boots once per reservation (one
job per VM), so a new counter only ever starts with a new VM and a new `lease_generation`. One-shot
classes, accepted once per boot: `deliver_registration`, `start_runner`, `shutdown`. Repeatable:
`probe` (until `ready`), `status`, `collect`. Heartbeats every 30 s cannot exhaust the counter.

The guest agent (P14/P15, baked into the image) is a fixed program. It refuses a command whose
`vm_id` is not its own (read from the hypervisor, not from disk), whose `lease_generation` differs
from the first one it saw this boot, whose `seq` is not exactly previous + 1, whose `nonce` was
seen, whose one-shot class already ran, or that has expired. It deletes its own bootstrap material
(credential, seed, unattend file) before it answers `listening`.

The host accepts one `guest_reply` per command: the exact schema, `seq`, `nonce`, `vm_id`,
`reservation_id` and `lease_generation` echoed, `diag` printable ASCII up to 512 characters.
A timeout or disconnect is a failed guest (bounded retries, then the allocator heartbeat rule).
More data, extra fields, a wrong echo or a non-printable byte is a **hostile guest**: the provider
journals `hostile_guest` and the slot goes straight to `deleting`, final. The host never
evaluates, imports or opens anything the guest returns; job summaries come from `collect` as the
same bounded JSON.

## Wire framing (DECIDED shape; CANDIDATE D2 until proven)

| Item | Windows | Linux |
|---|---|---|
| Channel | PowerShell Direct session `New-PSSession -VMId <id> -Credential <per-clone>` | OpenSSH over `AF_VSOCK` port **5222**; host service GUID **`00001466-facb-11e6-bd58-64006a7986d3`** (VSOCK template with port 0x1466) |
| Agent entrypoint | `C:\Program Files\aap-guest\agent.ps1`, Administrators-only ACL, in the image | `/usr/local/libexec/aap-guest/agent`, root 0755, in the image |
| Invocation | one fixed script block in the session: `$input` lines piped to `& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File 'C:\Program Files\aap-guest\agent.ps1'`; the envelope and payload are the session's `-ArgumentList`, written to the child's stdin, never to its command line | `authorized_keys` entry `restrict,command="/usr/local/libexec/aap-guest/agent"` for the per-clone key; the client runs no remote command |
| Request | stdin: the envelope as one JSON line (`\n`-terminated), then exactly `payload_bytes` bytes | same |
| Reply | stdout: exactly one JSON line; stderr discarded (read at most 4 KiB, never parsed) | same |
| Host-side handling | the script block returns the stdout line as one `[string]`; the host checks length before parsing | the relay reads at most 8193 bytes from stdout |

Limits: envelope line at most 1024 bytes; payload at most 16384 bytes; reply at most 8192 bytes.
Timeouts per command (initial values, tuned only with P02.1 evidence): `probe` 30 s, repeated
until the boot deadline (15 min from `Start-VM`, Windows first boot runs specialize);
`deliver_registration` 30 s; `start_runner` 60 s; `status` 15 s; `collect` 60 s; `shutdown` 30 s.
Session setup counts against each command's timeout.

## Windows candidate: PowerShell Direct

Documented requirements (Microsoft, "Virtual machine automation and management using
PowerShell"): host and guest Windows 10/Server 2016 or later, VM running locally, caller is a
Hyper-V administrator, valid guest user credentials, at least one configured user profile in the
guest. It works "regardless of network configuration".

- **Credential bootstrap**: the image has no usable password. At `create` the provider generates
  a random 32-character local administrator password, held only in supervisor memory, and writes
  it into the clone before first boot. Two sub-candidates, chosen by P02.1: (a) an `unattend.xml`
  in the offline differencing disk (specialize pass), which the guest agent deletes at first boot;
  (b) a Hyper-V Data Exchange (KVP) host-to-guest item read once by the agent and deleted. The
  credential is never in the base image, catalog, journal, status or logs, and dies with the clone.
- **Per-clone identity**: the Hyper-V VM id recorded at `create`, plus the VM name. `-VMId`
  addressing targets one partition on the hypervisor bus; there is no network name to spoof.
- **Host to guest auth**: the per-clone credential. Guest Administrator can read its own
  credential; that is accepted because it opens nothing but that guest.
- **Guest to host**: nothing; PowerShell Direct is host-initiated.
- **Residual risks to prove**: remoting deserializes guest output in the elevated supervisor; the
  script block must return one string and the host must bound and time-limit every call. Guest
  PowerShell logging (script block, module, transcription) must not capture the payload.

## Linux candidate: OpenSSH over a Hyper-V socket

Kernel `CONFIG_VSOCKET=y`, `CONFIG_HYPERV_VSOCKETS=y` (Microsoft, "Make your own integration
services"). The host service GUID above is registered once under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`
by the installer through the existing elevated helper (P19). A host-side relay in the supervisor
module bridges the Windows OpenSSH client (`ProxyCommand`-style stdin/stdout) to an `AF_HYPERV`
socket addressed by VM id and that GUID. Fallback candidate if the relay is not qualified: SSH on
a per-clone private switch.

- **Credential bootstrap**: per-clone ed25519 client key pair generated by the supervisor; the
  public key goes into a per-clone cloud-init NoCloud seed (`clones\<id>\seed.iso`) or KVP; the
  private key lives in a per-reservation file under an Administrators-only folder, deleted at
  destroy. The image has no authorized key and password login is disabled.
- **Host key pinning**: the guest generates its host key at first boot and publishes the
  fingerprint through KVP (guest-to-host pool). The provider pins it before the first SSH command
  (`StrictHostKeyChecking yes`, a per-clone known_hosts file).
- **Auth, replay, cleanup**: as the envelope rules; the forced command makes the key unable to
  open a shell.

## Guest network attachment (CANDIDATE D2)

Rule (DECIDED): guests reach the internet (GitHub, package registries, DNS) and nothing else on
the machine or the LAN.

Candidate mechanism: one Hyper-V **internal** switch per profile (`aap-guests-win`,
`aap-guests-linux`), each with its own private subnet and a `New-NetNat` instance for internet
egress. Host firewall rules (Windows Firewall / WFP, created by the installer through the existing
helper, P19) deny traffic from the guest subnets to every host address, the WSL subnet, the LAN
(RFC 1918, link-local, IPv6 ULA and link-local) and the other profile's subnet, with explicit
allows only for NAT egress and DNS to configured public resolvers. Hyper-V port ACLs
(`Add-VMNetworkAdapterExtendedAcl`) on each guest adapter deny traffic to other guests on the same
switch except the gateway. Alternative candidate: one private switch per guest with a per-guest
NAT. P02.1 picks one with evidence.

## What is never supplied to a guest (DECIDED)

The App key, an installation token, a registration token, any owner credential, a host share,
the WSL distro, the inbox, or a reusable secret. Guests receive only their per-clone credential
(useless elsewhere) and one JIT config.

## Lab proof plan (P02.1; executed for P08, P10, P11)

P02.1 is a single-owner ledger child that gates P10/P11 fan-out (the coordinator adds it to the
ledger). Preconditions: gate D2 granted. State on 2026-10-19: lab host is this machine (Hyper-V
enabled); Windows media is the owner-provided Windows Server 2025 Evaluation ISO (180-day);
Ubuntu 24.04 media from the official release; the compute and storage budget on this host must be
measured and approved by the owner before the first VM. Also required: a **lab GitHub App** and a
**test org and repository** authorized for the lab, so no step uses the production App, key or
org. P00 manifest registration of every VM id, switch and disk before creation; synthetic secrets
only (a marker such as `SYNTHETIC-JIT-MARKER-<random>`) except the lab App's own JIT configs in
step 6. No live install, `C:\wsl`, `C:\ProgramData\aap-runner` or live distro is touched.

| # | Step | Oracle (pass means) |
|---|---|---|
| 1 | Build a minimal Windows Server 2025 guest and Ubuntu 24.04 guest from lawful media; no credential in the image; record base hashes | images boot; a scan of the sealed base for the synthetic marker and any password finds nothing |
| 2 | Create two differencing clones of each; inject distinct per-clone credentials offline (Windows: unattend sub-candidate a, then KVP sub-candidate b; Linux: seed ISO, then KVP) | each clone accepts only its own credential; the base disk hash is unchanged after both clones ran |
| 3 | PowerShell Direct `probe` through the agent entrypoint, by VM id | reply validates against the schema; echo fields match; works with the clone's network adapter disconnected |
| 4 | Linux SSH over vsock port 5222 through the relay, `probe` with the pinned host key | connects with networking disabled; a changed host key is refused; the key cannot open a shell |
| 5 | `deliver_registration` with the synthetic marker, then `start_runner` against a stub runner that records how it received input | stub sees the marker only in `ACTIONS_RUNNER_INPUT_JITCONFIG`; marker absent from guest argv (process list sampled during start), guest event logs (PowerShell 4103/4104, transcription), files, journald, the host log, supervisor log, status files and evidence |
| 6 | Real runner (pinned release) with a JIT config from the lab App for the test repo | runner takes one job and exits; the registration disappears; reusing the JIT config is rejected by GitHub; an unused JIT runner is deleted by `release_request` |
| 7 | Network, positive | from each guest: DNS resolves `github.com`; HTTPS to `github.com`, `api.github.com` and one package registry per OS succeeds |
| 8 | Destroy each clone | VM, clone and scratch folders and per-clone credential files observed absent; base unchanged |

Negative tests (each must fail closed, and the provider must journal the stated code):

| Case | Expected |
|---|---|
| Wrong credential, credential of another clone | auth refused; `failed` |
| Command with wrong `vm_id`, stale `lease_generation`, repeated or skipped `seq`, reused `nonce`, expired, second one-shot command | guest refuses; host records `refused` and does not proceed |
| Hostile guest replies: 100 MB output, 10 000-level nested object, extra fields, control bytes, wrong echo, never answers, closes mid-reply | host stays responsive, each call ends within its timeout; wrong shape or content gives `hostile_guest` and immediate `deleting`; silence gives `timeout`; no host file written from guest data |
| Guest Administrator / root connects to every host address (all ports incl. 445, 3389, 5985), the WSL distro, `192.168.1.1` and the LAN, the other profile's subnet, another guest on the same switch, `fd00:aaaa::1`, or the hvsocket service of another VM | all fail (same oracle shape as today's Sysbox evidence) while step 7 still passes |
| Guest tries to open a session to the host over hvsocket or PowerShell Direct | impossible or refused |
| Supervisor killed between each command | restart reconciles from the journal; no second registration; no orphan VM |

Evidence: one evidence-bundle record per step and case, plus the P00 cleanup receipt listing every
lab VM id and switch observed absent. Until steps 1-8 and every negative case pass, this contract
stays CANDIDATE.
