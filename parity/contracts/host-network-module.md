# Host network module contract (version 1)

Owner: **P10.0** (the ledger's "guest network module": it runs on the host and owns every guest
network attachment). Consumers: P06 and P07 (image builders, build VM only), P10 and P11 (VM
backends); P12 builds the module once and hands it to the backends; P19 creates the switches, NAT,
host firewall rules and the module's journal folder. Schema:
[`host-network-module.schema.json`](host-network-module.schema.json) (`host_network_attach`, the
Verify problem list, `host_network_record`, `host_network_readback`). Fixtures:
`fixtures/host-network-module/`. Shared strict fake for the consumers' tests:
[`tests/common/AapHostNetworkFake.psm1`](../../tests/common/AapHostNetworkFake.psm1).

**Status:** interface, order, declaration, read-back and failure codes DECIDED (coordinator,
2026-10-21). The enforcement shape is guest-transport.md's (DECIDED). The mechanism (one internal
switch per profile with NAT, or one internal switch per guest) and every point marked **D2** stay
CANDIDATE until P02.1. No module exists yet, and the merged consumers do not conform yet
([Conformance](#conformance-of-the-consumers)).

## Interface (DECIDED)

The module is one hashtable of three scriptblocks, `Attach`, `Detach` and `Verify`. Each takes one
hashtable with exactly these keys:

| Key | Value |
|---|---|
| `VmId` | the Hyper-V VM id, lowercase GUID text |
| `VmName` | a runner clone `aap-<w\|l>-<slot>-<lease_generation>-<8 hex>` (backend-lifecycle.md) or a build VM `aap-wbuild-<8 hex>` / `aap-lbuild-<8 hex>` (P06, P07). Verification and scanner VMs are never attached: they have no adapter |
| `Profile` | `windows` or `linux`, the profile the name's letter says |

Anything else is refused, and so is a `VmId` the journal records under another name or profile.
Every throw is `AAP_NetworkUntrusted: <detail>`, one printable line; consumers do not rely on the
code in a thrown message (Consumer obligations).

### Attach

- Precondition: the VM exists, is Off, and has no network adapter (consumers create VMs without
  one) or only the one an unfinished Attach of the same VM made.
- Intent before act: before it changes anything, Attach writes the VM's journal record (state
  `attaching`) naming the declaration and everything it is about to create. Then it adds one adapter
  on the profile's switch, sets DHCP guard On, router guard On and MAC address spoofing Off, writes
  the port ACLs ([Rules and weights](#rules-and-weights)) and sets the record to `attached`.
- Returns the **declaration** (`host_network_attach`): `vm_id`, `vm_name`, `profile`, the clone
  `subnet` and the `endpoints` it allowed, each `{ role, address }`: exactly one `gateway`, at most
  one `dhcp`, at most two `dns`, each address one IPv4 host address of the subnet (one address may
  serve several roles). Its keys are the schema's; serialized, it validates.
- Idempotent: a repeated Attach for the same VM (a retry after a crash) completes what the record
  names and returns the record's declaration unchanged. It never declares anything else for a VM it
  has a record for.
- Throws on any failure. A failed Attach keeps its record, so Detach and the reconcile clean up.

### Verify

- Read-only: never changes the host or the journal. It may be called at any time.
- Returns the **problem list**: zero or more strings written to the output stream, each one
  printable line of at most 200 characters, at most 64. Empty means every check below holds. It
  throws only when it cannot look.
- Checks, against the record and what Hyper-V and the host report now:
  1. The VM exists, and its record is `attached` and names the same `VmName` and `Profile` (a
     record it cannot read is a throw: it cannot look).
  2. Exactly one adapter, on the profile's switch (`aap-guests-win`, `aap-guests-linux`; D2),
     which exists with type `Internal`; DHCP guard On, router guard On, MAC spoofing Off.
  3. An unscoped outbound Deny for each fixed range, in exactly the text below.
  4. Host-specific denies, recomputed now: every unicast address on every Hyper-V vEthernet adapter
     of the host (IPv4 and IPv6; link-local excluded, a fixed range covers it) that is not a
     declared endpoint, every LAN IPv6 prefix (the on-link prefix of each global unicast IPv6
     address on a host interface that is not a vEthernet adapter) and the clone subnet each lie
     inside an unscoped outbound Deny.
  5. Every Allow is outbound and names one address, and the set of allowed addresses is exactly the
     set of declared endpoint addresses.
  6. Every Allow's weight is greater than every Deny's weight.

### Detach

- Precondition: the VM is gone. Callers remove the VM, then Detach. While a VM with that id exists,
  Detach throws and changes nothing: the order is enforced, not assumed.
- It uses only the journal record, never the live adapter. It removes, newest first, what the
  record names beyond the VM's own adapter (which went with the VM): a per-guest switch, its NAT,
  its host firewall rules (the per-guest candidate, D2; nothing for the per-profile candidate). Each
  removal is idempotent (absent is done). The record goes last.
- Idempotent: no record means nothing to do, and success (never attached, already detached).
- A record it cannot read, or one naming another `VmName` or `Profile`, makes it throw; the record
  stays.

## Journal and reconcile (DECIDED)

- An admin-only folder of the module's own (owner Administrators, SYSTEM and Administrators only,
  protected DACL, no reparse point; P19 creates it, default `C:\ProgramData\aap-runner\network\`, a
  parameter so tests and the lab use their own). The module checks it whenever it is constructed;
  an untrusted folder makes every call throw.
- One file per VM, `<vm_id>.json`, `host_network_record`: `state` (`attaching`, `attached`), the
  `declaration`, and `created` (`adapter`, plus `switch`, `nat`, `firewall_rule` for the per-guest
  candidate, by name). Written to a temporary name, flushed and renamed over the old file, so a
  crash leaves the old or the new record, never a torn one. Never a secret.
- Reconcile, each time the module is constructed and before it serves a call: a record whose VM no
  longer exists is detached; a record of an existing VM stays (its consumer owns it, and Verify
  judges it before any start); an unreadable record stays, is reported, and every call for that VM
  id throws until an owner looks. Records are per VM id and VM ids are never reused, so two
  processes using the module meet only on a removed VM, where Detach and the reconcile are both
  idempotent. This is the "module's own reconcile" P06 relies on for a crashed run's attachment.

## Rules and weights

Enforcement shape: guest-transport.md, Guest network attachment (DECIDED). Weight semantics: the
Microsoft documentation cited below; every point marked D2 is confirmed only by the lab.

Hyper-V extended port ACLs: "Larger weight values apply first, and once an ACL entry applies to a
packet, other entries are no longer relevant for that packet" (`Add-VMNetworkAdapterExtendedAcl`,
`-Weight`). `Direction` is seen from the VM: Outbound is what the guest sends, and its remote
address is the destination. A packet no rule matches passes; the documentation implies it (its
examples add an explicit low-weight Deny to block everything else) and internet egress depends on
it (D2, lab step 7).

The module writes only these rules, all stateless:

- **Fixed denies**, unscoped (no local address, port or protocol), outbound, each in exactly this
  text: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`,
  `224.0.0.0/4`, `ff00::/8`, `fe80::/10`, `fc00::/7`.
- **Host-specific denies**, unscoped, outbound: enough to satisfy Verify check 4; an address as
  `/32` or `/128`, a prefix as the host reports it.
- **Allows**: outbound Allows for the declared endpoint addresses and nothing else, each naming one
  address (alone or with `/32`). A rule may be narrowed to the endpoint's protocol and port, which
  only lets less through; one address may then have several rules.
- **Weights**: every Allow above every Deny. The module uses 10 for denies and 100 for allows; any
  values with that order conform. Equal weights are never relied on (how Hyper-V orders a tie is
  undocumented, D2).

Why: a gateway, DHCP or DNS endpoint lies in the clone subnet (and is usually the host's vEthernet
address there), so the subnet's Deny, a fixed range and the host-address Deny match it, and only an
Allow that outranks them makes it reachable.
An Allow for a range, or for an address nobody declared, would open a hole that no check of the
fixed denies can see; hence "exactly the declared endpoints, each one address, each above every
Deny".

Not the module's: the Guest Service Interface and Key-Value Pair Exchange are turned off by the
consumers' `NewVm` and read back there; Enhanced Session Mode is a host setting (P19 sets it, the
backends check it); the host firewall rules that block the host's listening ports on the guest
vEthernet adapters are P19's (guest-transport.md). Because the gateway is an allowed endpoint, those
firewall rules are the only barrier between a guest and the host's ports on the gateway address
(Open points, 1).

## Consumer obligations (DECIDED)

Order:

1. `NewVm` with no adapter, then `Attach`, the declaration check, `Verify`, the read-back.
2. Before every host-initiated power-on of a VM that has an adapter (`StartVm`, `RestartVm`):
   `Verify` and the read-back again. A failure stops the start.
3. Teardown: stop, `RemoveVm`, then `Detach`, on every teardown attempt, also when Attach never ran
   or failed (Detach is then a no-op, or removes the record). A Detach that throws means the network
   is not proven detached: the backends count the teardown as not done (retry, then
   `teardown_failed`, capacity held); the builders report the failed cleanup and the reconcile
   removes the record once the VM is gone.
4. Verification and scanner VMs get no adapter and never reach the module; the builders read back
   zero adapters before they boot.

**Declaration check** (`AAP_NetworkInvalid` when it fails): Attach's value has the schema's keys,
echoes `VmId`, `VmName` and `Profile`, and has 1 to 4 endpoints with roles `gateway`, `dhcp`, `dns`,
exactly one `gateway`, each one IPv4 host address of the declared `subnet`. The read-back then
allows nothing outside that subnet; which subnet the profile's switch has is the module's Verify.

**Read-back** (`AAP_NetworkUntrusted` when it fails), from Hyper-V through the consumer's own
provider, never through the module. The provider reports each adapter as
`@{ SwitchName; SwitchType; DhcpGuard; RouterGuard; MacAddressSpoofing; Acls }` and each rule as
`@{ Action; Direction; RemoteAddress; Scoped; Weight }`: `DhcpGuard` and `RouterGuard` are
`[string]$n.DhcpGuard -eq 'On'`, `MacAddressSpoofing` is `[string]$n.MacAddressSpoofing -ne 'Off'`
(an unknown value reads as on), `Scoped` is true unless the local address, local port, remote port
and protocol all read as unrestricted (`''`, `*`, `ANY`; D2), `Weight` is `[int]$_.Weight`. The
read-back passes only with:

- exactly one adapter, on the profile's switch, type `Internal`;
- `DhcpGuard` and `RouterGuard` the boolean true, `MacAddressSpoofing` the boolean false;
- for each fixed range an unscoped outbound Deny with exactly that `RemoteAddress` (compared
  lowercase);
- every rule's `Action` `Allow` or `Deny`;
- every Allow outbound and naming one address (IPv4 or IPv6, optionally `/32` or `/128`), and the set
  of allowed addresses equal to the set of declared endpoint addresses;
- an integer `Weight` on every rule, every Allow's above every Deny's.

The host-specific denies are Verify's alone: only the module knows the host. `validate.py`'s rule
for `host_network_readback` is the reference implementation of this list, and its fixtures are the
shared cases every consumer's implementation must agree with.

**Verify output**: every object Verify writes is a problem; consumers do not drop empty or `$null`
items (a module that writes anything on success fails closed). A throw is a problem.

| Code | When |
|---|---|
| `AAP_NetworkUnavailable` | no module given (`-Network` absent): nothing is attached, built or created |
| `AAP_NetworkInvalid` | the module lacks `Attach`, `Detach` or `Verify` as a scriptblock, or the declaration check fails |
| `AAP_NetworkUntrusted` | Attach throws; Verify reports a problem or throws; the read-back fails; the profile's switch is missing or not Internal |

Fail closed everywhere: no VM with an adapter starts after any of these, and the create or build
that met one is torn down (`RemoveVm`, then `Detach`).

## Shared fake for consumer tests

[`tests/common/AapHostNetworkFake.psm1`](../../tests/common/AapHostNetworkFake.psm1) stands in for
the module in the P06, P07, P10 and P11 suites (Pester 5, Windows PowerShell 5.1 and PowerShell 7).
Its tests are `tests/common/AapHostNetworkFake.Tests.ps1`; `Invoke-AapHostNetworkFakeMutations.ps1`
disables each of its checks in turn.

- `New-AapFakeHostNetwork -Root <folder> -VmExists <scriptblock>` returns `Attach`, `Detach` and
  `Verify` with the semantics above, strictly: the request shape, intent before act, the same
  declaration on a repeated Attach, Detach refused while `VmExists` says the VM is there, the record
  removed by Detach, and Verify computed from the record and the simulated adapter (no knob sets its
  answer, unlike the per-suite fakes it replaces).
  State lives only under `-Root` (`records\<vm id>.json`, `knobs.json`), so a child process killed
  mid-step leaves the world its parent recovers from.
- `Get-AapFakeHostNetworkAdapter -Root -VmId` returns what Hyper-V would report for the VM, in the
  provider shape above, for the consumer's provider fake (`GetVmNetwork`, `GetVmConfig.Adapters`).
- `Set-AapFakeHostNetworkKnob -Root -Tamper <names> -Fail <names>`. Tampers change the simulated
  host, so Verify and the read-back both see them: `no-adapter`, `second-adapter`,
  `external-switch`, `other-switch`, `dhcp-guard-off`, `router-guard-off`, `mac-spoofing-on`,
  `drop-fixed-deny`, `drop-host-deny` (only Verify can see it), `extra-allow`, `allow-weight` (allow
  weight equal to the deny weight). Faults: `Attach`, `Detach`, `Verify` (the op throws) and
  `AttachAfterIntent` (Attach stops after its intent record, as a crash would).
- `Get-AapFakeHostNetworkRecord -Root [-VmId]` returns the journal records.
- Fake host: `aap-guests-win` with `172.31.250.0/24` and `aap-guests-linux` with `172.31.251.0/24`,
  gateway, DHCP and DNS at `.1`; vEthernet addresses `172.31.250.1`, `172.31.251.1`, `172.29.16.1`,
  `2001:db8:5::1`; LAN IPv6 prefix `2001:db8:1::/64`. Not modelled: the VM's power state, the
  journal folder's ACL and the reconcile.

## Lab points (D2)

- Weights: the order of equal weights; the accepted range (the cmdlet's Int32 `-Weight` has no range
  validation, read on this host's Hyper-V module 2.0.0.0); that a packet no rule matches passes.
- Read-back: how `Get-VMNetworkAdapterExtendedAcl` reports an unset address, port or protocol
  (`''`, `*`, `ANY`); whether a `/32` comes back as written; the text form of IPv6 ranges; and the
  `Direction` of a rule ("If an ACL applies to both inbound and outbound packets, it appears in both
  inbound and outbound lists").
- ARP and the DHCP broadcast to `255.255.255.255` pass the IP rules; the multicast denies break
  nothing an IPv4 guest needs; egress needs no IP-level Allow to the gateway (Open points, 1).
- Host vEthernet and LAN prefix discovery, with WSL in NAT and in mirrored mode.
- DHCP and DNS on the internal switch: Windows NAT provides neither. P07's build guest uses DHCP
  (autoinstall `dhcp4: true`); the module declares `dhcp` and `dns` endpoints only where a server
  answers, or the guests get static addressing.
- Per-profile switch or per-guest switch (P02.1); adapters and their ACLs vanish with `Remove-VM`.

## Open points

1. **Gateway allow** (objection to the coordinator's decision, recorded, not applied): an unscoped
   Allow for the gateway lets a guest reach every port of the host's vEthernet address on its
   switch, so only P19's firewall rules protect the host's listening services there.
   guest-transport.md excepts only "the explicit DHCP and DNS endpoints" from the host vEthernet
   deny. Routing needs no IP-level Allow to the gateway (the guest reaches it at layer 2, and port
   ACLs filter IP). Recommendation: drop `gateway` from the allowed set, or narrow every Allow to its
   protocol and port (DHCP UDP 67; DNS UDP and TCP 53), which this contract already permits.
2. A LAN that uses public IPv4 addresses is not covered by the fixed ranges, and the enforcement
   shape names only the LAN's IPv6 prefix. Whether Verify check 4 adds the LAN's IPv4 prefixes is an
   owner decision.
3. The ledger's P10.0 text says "per-guest private switch"; guest-transport.md and ARCHITECTURE.md
   say a private switch is not viable and the alternative is an internal switch per guest.

## Conformance of the consumers

As of origin/main `01d159f` and P07's draft at `354d216` (2026-10-21):

| Consumer | Changes needed |
|---|---|
| P06 `images/windows` | Detach after `RemoveVm` (seal) and after `Remove-AapWinBuild` (failure path), not before; keep and check Attach's declaration; a thrown Verify is `AAP_NetworkUntrusted` and Verify output is not filtered; the read-back requires the allow set to equal the declared endpoints, outbound allows, and allows above denies (`GetVmNetwork` adds `Weight`); Verify and the read-back before every `RestartVm`; INTEGRATION.md and README.md follow this contract; tests use the shared fake |
| P10 `supervisor/backends/windows` | keep and check Attach's declaration; a thrown Verify is `AAP_NetworkUntrusted`, output not filtered; `GetVmConfig` adapters carry `Acls` with `Weight` and read MAC spoofing as on unless `Off`; the read-back of this contract, exactly one adapter; Verify and the read-back before boot's `StartVm`; INTEGRATION.md follows; tests use the shared fake |
| P11 `supervisor/backends/linux` | as P10 (its Verify throw is already `AAP_NetworkUntrusted`); INTEGRATION.md stops relying on Verify alone for the port ACLs |
| P07 `images/ubuntu-24.04` (draft PR #49) | take the module as `-Network` like P06; `NewVm` makes no adapter and never connects a switch itself; Attach, the declaration check, Verify and the read-back (`GetVmNetwork`) before each `StartVm` (the install boots twice); `RemoveVm` then `Detach`; scanner and verification VMs read back zero adapters |

## References

- `Add-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmnetworkadapterextendedacl>
- `Get-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vmnetworkadapterextendedacl>
- Extended port ACLs (weights, stateful rules always allow): <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/create-security-policies-extended-port-access-control-lists>
- Read on this host, 2026-10-21, by reflection only (no VM, no change): Hyper-V module 2.0.0.0,
  `VMNetworkAdapterExtendedAclSetting` has `Action` (`Allow`, `Deny`), `Direction` (`Inbound`,
  `Outbound`), `LocalIPAddress`, `RemoteIPAddress`, `LocalPort`, `RemotePort`, `Protocol`
  (strings), `Weight` (Int32), `Stateful`, `IdleSessionTimeout`, `IsolationID`; the adapter's
  `DhcpGuard`, `RouterGuard` and `MacAddressSpoofing` are `OnOffState` (`On`, `Off`).
