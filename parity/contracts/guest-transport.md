# Guest management transport contract (version 1)

Owners: P10/P11 (host side), P14/P15 (guest agent). The lab proof below is executed by
**P08, P10 and P11** once gate D2 is granted. Readers: P22, P26. Schema:
[`guest-transport.schema.json`](guest-transport.schema.json) (`host_cmd` envelope and the only
`guest_reply` the host accepts). Fixtures: `fixtures/guest-transport/`.

**Status: CANDIDATE (D2).** Every mechanism here is the chosen candidate, not a proven one. No VM
was created for this contract. Backend fan-out (P10, P11 implementation beyond simulation) waits
for the lab plan to pass.

## Envelope (DECIDED, transport-independent)

The host sends only these commands: `probe`, `deliver_registration`, `start_runner`, `status`,
`collect`, `shutdown`. Each carries `vm_id`, `reservation_id`, `lease_generation`, a `seq` that
increases by one per command for that boot, a fresh 128-bit `nonce`, `payload_bytes` (non-zero
only for `deliver_registration`) and `expires_at` (at most 120 s ahead). There is no command that
runs caller-supplied code, takes a path, or returns a file.

The guest agent (P14/P15, baked into the image) is a fixed script. It refuses a command whose
`vm_id` is not its own (read from the hypervisor, not from disk), whose `lease_generation` differs
from the first one it saw this boot, whose `seq` is not exactly previous + 1, whose `nonce` was
seen, or that has expired. It accepts `deliver_registration` once per boot and deletes its own
bootstrap material (credential, seed, unattend file) before it answers `listening`.

The host accepts one `guest_reply` per command: at most 8192 bytes, the exact schema, `seq`,
`nonce`, `vm_id`, `reservation_id` and `lease_generation` echoed, `diag` printable ASCII up to
512 characters. Anything else (more data, extra fields, wrong echo, a timeout, a disconnect) is a
hostile or failed guest: the provider journals `hostile_guest` or `timeout`, the slot goes
`quarantined`, then `deleting`. The host never evaluates, imports or opens anything the guest
returns; job summaries are fetched by `collect` as the same bounded JSON.

## Windows candidate: PowerShell Direct

Mechanism: `New-PSSession -VMId <id> -Credential <per-clone credential>`; commands are fixed
script blocks shipped with the supervisor module; the registration payload is passed with
`-ArgumentList` inside the session (serialized over VMBus by PowerShell remoting), never on a
process command line. Documented requirements (Microsoft, "Virtual machine automation and
management using PowerShell"): host and guest Windows 10/Server 2016 or later, VM running locally,
caller is a Hyper-V administrator, valid guest user credentials, at least one configured user
profile in the guest. It works "regardless of network configuration".

- **Credential bootstrap**: the image has no usable password. At `create` the provider generates
  a random 32-character local administrator password, held only in supervisor memory, and writes
  it into the clone before first boot. Two sub-candidates, chosen by the lab: (a) an `unattend.xml`
  in the offline differencing disk (specialize pass), which the guest agent deletes at first boot;
  (b) Hyper-V Data Exchange (KVP) host-to-guest item read once by the agent and deleted. The
  credential is never in the base image, catalog, journal, status or logs, and dies with the clone.
- **Per-clone identity**: the Hyper-V VM id (GUID) the provider recorded at `create`, plus the VM
  name. `-VMId` addressing targets one partition on the hypervisor bus; there is no network name
  to spoof.
- **Host to guest auth**: host proves itself with the per-clone credential; the guest proves it is
  the intended VM because only that partition is reachable by that VM id. Guest Administrator can
  read its own credential; that is accepted because the credential opens nothing but that guest.
- **Guest to host**: the guest cannot initiate anything to the host; PowerShell Direct is
  host-initiated.
- **Residual risks to prove**: PowerShell remoting deserializes guest output in the elevated
  supervisor. The provider must convert every reply to a bounded string before parsing and run
  each call under a timeout; the lab must show huge, deeply nested or type-confused output from a
  hostile guest cannot crash, hang or execute in the supervisor. PowerShell logging in the guest
  (script block, module, transcription) must not capture the payload.

## Linux candidate: OpenSSH over a Hyper-V socket

Mechanism: the guest `sshd` listens on `AF_VSOCK` (kernel `CONFIG_VSOCKET=y`,
`CONFIG_HYPERV_VSOCKETS=y`, Microsoft "Make your own integration services"); the host connects
with `AF_HYPERV` to the VM id and a service GUID derived from the VSOCK port template
`<port as 8 hex>-facb-11e6-bd58-64006a7986d3`, registered once under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices`
by the installer through the existing elevated helper (P19). A small host-side relay (supervisor
module) bridges the Windows OpenSSH client to that socket. Fallback candidate if the relay is not
qualified: SSH on a per-clone internal Hyper-V switch with no route to the host, LAN or other clones.

- **Credential bootstrap**: per-clone ed25519 client key pair generated by the supervisor; the
  public key goes into a per-clone cloud-init NoCloud seed (`clones\<id>\seed.iso`) or KVP; the
  private key lives in a per-reservation file under an Administrators-only folder, deleted at
  destroy. The image has no authorized key and password login is disabled.
- **Host key pinning**: the guest generates its host key at first boot and publishes the
  fingerprint through KVP (guest-to-host pool). The provider pins it before the first SSH command
  (`StrictHostKeyChecking yes`, a per-clone known_hosts file). No trust on first use over the wire.
- **Auth both ways, replay, cleanup**: as the envelope rules above; the forced command for the
  management key is the fixed guest agent, so the key cannot open a shell.

## What is never supplied to a guest (DECIDED)

The App key, an installation token, a registration token, any owner credential, a host share,
the WSL distro, the inbox, or a reusable secret. Guests receive only their per-clone credential
(useless elsewhere) and one JIT config.

## Lab proof plan (P08, P10, P11)

Preconditions: gate D2 granted in writing (lab host, Hyper-V, lawful Windows Server 2025 media and
activation, Ubuntu 24.04 media, compute/storage budget); a disposable lab host or an explicitly
approved budget on this host; P00 manifest registration of every VM id and disk before creation;
synthetic secrets only (a marker string such as `SYNTHETIC-JIT-MARKER-<random>`), never a real
App key or token. No live install, `C:\wsl`, `C:\ProgramData\aap-runner` or live distro is touched.

| # | Step | Oracle (pass means) |
|---|---|---|
| 1 | Build a minimal Windows Server 2025 guest and Ubuntu 24.04 guest from lawful media; no credential in the image; record base hashes | images boot; a scan of the sealed base for the synthetic marker and any password finds nothing |
| 2 | Create two differencing clones of each; inject distinct per-clone credentials offline (Windows: unattend sub-candidate a, then KVP sub-candidate b; Linux: seed ISO, then KVP) | each clone accepts only its own credential; the base disk hash is unchanged after both clones ran |
| 3 | PowerShell Direct `probe` to each Windows clone by VM id | reply validates against the schema; echo fields match; works with the clone's network adapter disconnected |
| 4 | Linux SSH over hvsocket `probe` with the pinned host key | connects with networking disabled; a changed host key is refused |
| 5 | `deliver_registration` with the synthetic marker, then `start_runner` against a stub runner that records how it received input | stub sees the marker only in `ACTIONS_RUNNER_INPUT_JITCONFIG`; marker absent from guest argv (process list sampled during start), guest event logs (PowerShell 4103/4104, transcription), files, journald, the host journal, supervisor log, status files and evidence |
| 6 | Real runner (pinned release, test org/repo authorized for the lab) with a real JIT config from a lab App | runner takes one job and exits; the registration disappears; reusing the same JIT config is rejected by GitHub; an unused JIT runner is deleted by `release_request` |
| 7 | Destroy each clone | VM, clone folder and per-clone credential files are observed absent; base unchanged |

Negative tests (each must fail closed, and the provider must journal the stated code):

| Case | Expected |
|---|---|
| Wrong credential, credential of another clone | auth refused; `failed` |
| Command with wrong `vm_id`, stale `lease_generation`, repeated `seq`, reused `nonce`, expired | guest refuses; host records `refused` and does not proceed |
| Second `deliver_registration` in one boot | refused |
| Hostile guest replies: 100 MB output, 10 000-level nested object, extra fields, non-ASCII control bytes, wrong echo, never answers, closes mid-reply | host stays responsive, each call ends within its timeout, slot `quarantined` with `hostile_guest` or `timeout`, no host file written from guest data |
| Guest Administrator / root tries to reach the host, the WSL distro, `192.168.1.1`, another clone, a host share, or the hvsocket service of another VM | all unreachable (same oracle shape as today's Sysbox evidence) |
| Guest tries to open a session to the host over hvsocket or PowerShell Direct | impossible or refused |
| Supervisor killed between each command | restart reconciles from the journal; no second registration; no orphan VM |

Evidence: one evidence-bundle record per step and case, plus the P00 cleanup receipt listing every
lab VM id observed absent. Until steps 1-7 and every negative case pass, this contract stays
CANDIDATE and P10/P11 may implement against simulated providers only.
