# Host network module contract (version 1)

Owner: **P10.0** (the ledger's "guest network module": it runs on the host and owns every guest
network attachment). Consumers: P06 and P07 (image builders, build VM only), P10 and P11 (VM
backends); P12 builds the module once and hands it to the backends; P19 creates the switches, NAT,
host firewall rules and the module's journal folder. Schema:
[`host-network-module.schema.json`](host-network-module.schema.json) (`host_network_attach`, the
Verify problem list, `host_network_record`). Fixtures: `fixtures/host-network-module/`. Shared
check, the one implementation of the declaration check and the read-back for every consumer and
the module's own Verify:
[`supervisor/network/AapHostNetworkCheck.psm1`](../../supervisor/network/AapHostNetworkCheck.psm1).
Shared strict fake for the consumers' tests:
[`tests/common/AapHostNetworkFake.psm1`](../../tests/common/AapHostNetworkFake.psm1).

**Status:** interface, order, declaration (static guest addressing, no Allow by default),
read-back, switches and failure codes DECIDED (coordinator, 2026-10-21). The enforcement shape is
guest-transport.md's (DECIDED), tightened here (both directions, no Allow by default;
[Rules and weights](#rules-and-weights)). The mechanism (one internal switch per profile with NAT,
or one internal switch per guest) and every point marked **D2** stay CANDIDATE until P02.1. No
module exists yet, and the merged consumers do not conform yet
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
- It refuses (throws, changes nothing) when the VM's switch carries a VM the
  [Switches](#switches-decided) rule forbids beside it.
- Intent before act: before it changes anything, Attach writes the VM's journal record (state
  `attaching`) naming the declaration, with the address it allocates, and everything it is about
  to create. Then it adds one adapter on the VM's switch ([Switches](#switches-decided)), sets DHCP
  guard On, router guard On, MAC address spoofing Off, port mirroring None and the VLAN mode
  Untagged, writes the port ACLs ([Rules and weights](#rules-and-weights)) and sets the record to
  `attached`.
- Returns the **declaration** (`host_network_attach`), all a guest's network is:
  - `vm_id`, `vm_name`, `profile`;
  - `subnet`: its switch's, IPv4 `/16` to `/30` and private (inside `10.0.0.0/8`,
    `172.16.0.0/12`, `192.168.0.0/16` or `100.64.0.0/10`: a fixed range that is neither link-local
    nor multicast nor broadcast);
  - `gateway`: the host's vEthernet address on that switch, a usable address of the subnet
    (neither its network nor its broadcast address);
  - `address`: the VM's static address, a usable address of the subnet other than the gateway that
    no other record on the switch holds (Attach allocates it; the record keeps it until Detach);
  - `resolvers`: one or two IPv4 addresses for DNS, each public (outside every fixed range, so
    reached through NAT with no Allow) or the address of an endpoint on port 53;
  - `endpoints`: the narrowed exceptions it allowed, **none by default** (DECIDED, coordinator,
    2026-10-21; there is no `gateway` or `dhcp` endpoint). The one kind there is: DNS to one
    private resolver the owner chose, as at most two entries `{ address, protocol, port }` with
    the same address, one private IPv4 address outside the subnet (never the gateway or another
    guest; Verify check 5 refuses one of the host's own addresses), `UDP` and `TCP`, port `53`.

  Its keys are the schema's; serialized, it validates.
- **No DHCP.** The guest learns its address, gateway and resolvers only from the declaration, which
  its consumer writes into the guest's seed or answer file before the first start
  ([Consumer obligations](#consumer-obligations-decided)). Nothing on the host serves DHCP or DNS
  to guests; DHCP guard stays On so that no guest can act as a server for its neighbours.
- Idempotent: a repeated Attach for the same VM (a retry after a crash) completes what the record
  names and returns the record's declaration unchanged, address included. It never declares
  anything else for a VM it has a record for.
- Throws on any failure. A failed Attach keeps its record, so Detach and the reconcile clean up.

### Verify

- Read-only: never changes the host or the journal. It may be called at any time.
- Returns the **problem list**: zero or more strings written to the output stream, each one
  printable line of at most 200 characters, at most 64. Empty means every check below holds. It
  throws only when it cannot look.
- Checks, against the record and what Hyper-V and the host report now:
  1. The VM exists, and its record is `attached` and names the same `VmName` and `Profile` (a
     record it cannot read is a throw: it cannot look).
  2. Exactly one adapter, on the VM's switch, which exists with type `Internal`; DHCP guard On,
     router guard On, MAC address spoofing Off, port mirroring None, VLAN mode Untagged or Access.
  3. The switch's other VMs: none beside a build VM; beside a runner clone, runner clones of its
     profile only ([Switches](#switches-decided)).
  4. For each fixed range, an unscoped Deny in each direction, Inbound and Outbound.
  5. Host-specific targets, discovered now: every unicast address of every host interface,
     vEthernet adapters included (IPv4 and IPv6; loopback and link-local excluded, a fixed range
     covers link-local), and every LAN IPv6 prefix (the on-link prefix of each global unicast IPv6
     address on a host interface that is not a vEthernet adapter). Each lies inside an unscoped
     Deny in each direction, and no declared endpoint lies inside one. A public IPv4 address among
     them (outside every fixed range) is itself a problem ([Limitations](#limitations)).
  6. Every Allow names exactly one declared endpoint (its address, its protocol and its remote
     port), and every endpoint has an Allow in each direction; with no endpoint declared, there is
     no Allow at all.
  7. Every Allow's weight is greater than the weight of every Deny of its direction whose range
     contains its address.

  Checks 2 to 7 are the shared check's `Get-AapHostNetworkAdapterProblems` with `-HostDeny` set to
  check 5's targets: the module and its consumers run the same code.

### Detach

- Precondition: the VM is gone. Callers remove the VM, then Detach. While a VM with that id exists,
  Detach throws and changes nothing: the order is enforced, not assumed.
- It uses only the journal record, never the live adapter. It removes, newest first, what the
  record names beyond the VM's own adapter (which went with the VM): a per-guest switch, its NAT,
  its host firewall rules (the per-guest candidate, D2; nothing for the per-profile candidate). Each
  removal is idempotent (absent is done). The record goes last, and with it the VM's address.
- Idempotent: no record means nothing to do, and success (never attached, already detached).
- A record it cannot read, or one naming another `VmName` or `Profile`, makes it throw; the record
  stays.

## Switches (DECIDED)

| VM | Switch (per-profile candidate) |
|---|---|
| runner clone `aap-w-*` | `aap-guests-win` |
| runner clone `aap-l-*` | `aap-guests-linux` |
| build VM `aap-wbuild-*` | `aap-build-win` |
| build VM `aap-lbuild-*` | `aap-build-linux` |
| verification and scanner VMs | none: no adapter, read back as zero adapters |

- All four are Internal switches, each with its own private subnet, the host's vEthernet address
  on it as gateway, NAT for internet egress and the host firewall rules of guest-transport.md, and
  no DHCP or DNS service. **P19 creates them**; the module never creates or removes them, and its
  Verify (check 2) and every read-back fail while a switch is missing or not Internal. Under the
  per-guest candidate (D2) every VM gets its own internal switch instead, which Attach creates and
  Detach removes, and the rule below holds by construction. A private switch is never used: it has
  no host adapter, so no NAT egress (guest-transport.md). The names are D2 with the mechanism.
- **Hard rule: a build VM never shares a switch.** While a build VM has an adapter, no other VM has
  one on its switch; no runner clone is ever on a build switch or admitted beside a build VM, and a
  build VM is never on a guest switch. Until P19 has created the build switches, no build VM is
  attached at all (Attach and Verify fail on the missing switch): builds never fall back to a guest
  switch. Enforced three times, each fail closed: Attach refuses, Verify check 3 reports it, and
  every consumer's read-back reports it (`Peers`, Consumer obligations), so a clone does not start
  beside a build VM even if a builder bypassed the module.
- Why: DHCP guard drops DHCP server messages from the VM, router guard drops its router
  advertisements and redirects, MAC spoofing Off pins its source MAC; **none of them filters ARP**.
  On a shared switch a VM can poison its neighbours' and the host's ARP caches. The denies stop
  only what carries a private address: a neighbour's own packets redirected to the poisoner
  (private source, dropped by the poisoner's inbound denies) and whatever the poisoner addresses to
  a neighbour (private destination, dropped by its outbound denies). What the internet sends a
  neighbour through the host's NAT has a public source: once the host's ARP entry for the
  neighbour points at the poisoner, the poisoner receives it and can send with the neighbour's
  address. A hostile job beside a build could read or alter what the build downloads, which ends
  up in every clone's base image, and a build VM runs internet-sourced installers as root; so a
  build VM gets a segment of its own.

## Journal and reconcile (DECIDED)

- An admin-only folder of the module's own (owner Administrators, SYSTEM and Administrators only,
  protected DACL, no reparse point; P19 creates it, default `C:\ProgramData\aap-runner\network\`, a
  parameter so tests and the lab use their own). The module checks it whenever it is constructed;
  an untrusted folder makes every call throw.
- One file per VM, `<vm_id>.json`, `host_network_record`: `state` (`attaching`, `attached`), the
  `declaration` (with the allocated address), and `created` (`adapter`, plus `switch`, `nat`,
  `firewall_rule` for the per-guest candidate, by name). Written to a temporary name, flushed and
  renamed over the old file, so a crash leaves the old or the new record, never a torn one. Never
  a secret.
- Reconcile, each time the module is constructed and before it serves a call: a record whose VM no
  longer exists is detached; a record of an existing VM stays (its consumer owns it, and Verify
  judges it before any start); an unreadable record stays, is reported, and every call for that VM
  id throws until an owner looks. Records are per VM id and VM ids are never reused, so two
  processes using the module meet only on a removed VM, where Detach and the reconcile are both
  idempotent. This is the "module's own reconcile" P06 relies on for a crashed run's attachment.
  An address is free again only when no record holds it, so a crashed Attach's address stays taken
  until its record is detached.

## Rules and weights

Enforcement shape: guest-transport.md, Guest network attachment (DECIDED), applied here in both
directions. Hyper-V semantics: the Microsoft documentation cited below, and this host's Hyper-V
module read by reflection; every point marked D2 is confirmed only by the lab.

- "Larger weight values apply first, and once an ACL entry applies to a packet, other entries are
  no longer relevant for that packet" (`Add-VMNetworkAdapterExtendedAcl`, `-Weight`). A packet no
  rule matches passes; the documentation implies it and internet egress depends on it (D2).
- `Direction` is `Inbound` or `Outbound`, seen from the VM; an extended port ACL has no `Both`. For
  an inbound packet the remote address and port are its source, for an outbound one its
  destination; the local address is the VM's side.
- An address field takes one address, a prefix, `0.0.0.0/0` (all IPv4), `::/0` (all IPv6) or `ANY`;
  a port field one port or a range; `Protocol` `TCP`, `UDP` or an IP protocol number.

The module writes only these rules, all stateless:

- **Fixed denies**, unscoped (local address, protocol, local port and remote port all unrestricted),
  each range Inbound and Outbound: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `169.254.0.0/16`, `100.64.0.0/10`, `224.0.0.0/4`, `ff00::/8`, `fe80::/10`, `fc00::/7` and the
  IPv4 limited broadcast `255.255.255.255/32` (adopted 2026-10-21: without DHCP nothing needs it,
  and it reaches the host's vEthernet adapter and every neighbour). The one
  copy in code is the shared check's (`Get-AapHostNetworkFixedDeny`); the module writes from it and
  `validate.py` reads it from there.
- **Host-specific denies**, the same shape, both directions: enough to satisfy Verify check 5; an
  address as `/32` or `/128`, a prefix as the host reports it.
- **Allows**, none by default. For each declared endpoint and nothing else, one in each direction:
  its address alone (`/32`), its protocol, and its port as the remote port (outbound the
  destination port, inbound the source port of the reply); the local address and the local port
  unrestricted.
- **Weights**: every Allow above every Deny of its direction whose range contains its address. The
  module uses 10 for denies and 100 for allows; any values in that order conform. Equal weights are
  never relied on (how Hyper-V orders a tie, and whether it accepts two rules of one weight and
  direction, is undocumented, D2).

Why both directions: inbound, the remote address is the source. A VM that poisons its neighbours'
ARP caches receives their packets, whose sources are private addresses, and its own inbound denies
drop them; the same denies stop packets from neighbours and from the host's other addresses
reaching it. Outbound denies stop it addressing them. Neither stops what the internet sends a
neighbour (a public source) once the host's ARP cache points at the poisoner: hence a build VM's
own switch ([Switches](#switches-decided)) and Open points, 1.
Why unscoped: a Deny narrowed to TCP, to port 1 or to one local address does not deny the range.
Why no Allow by default (DECIDED, coordinator, 2026-10-21): a port ACL matches a packet's IP header. A routed packet's destination is
the far host; only its frame goes to the gateway's MAC address, and ARP is not IP. So internet
egress needs no Allow for the gateway, public resolvers lie outside every denied range, and with
static addressing nothing needs DHCP. An Allow for the gateway or any other address of the host
would open the host's ports to the guest at the IP level, and an Allow for a range, for an address
nobody declared, or wider than its endpoint's protocol and port would open a hole that no check of
the denies can see. The one exception is DNS to a private resolver the owner chose, narrowed to
its address and port 53 over UDP and TCP.

Not the module's: the Guest Service Interface and Key-Value Pair Exchange are turned off by the
consumers' `NewVm` and read back there; Enhanced Session Mode is a host setting (P19 sets it, the
backends check it); the host firewall rules that block the host's listening ports on the guest
vEthernet adapters are P19's (guest-transport.md). Since no Allow names an address of the host,
those rules are a second barrier, not the only one.

## Limitations

- **A host with a public IPv4 address** (owner decision queued, 2026-10-21). The fixed ranges cover
  private IPv4 and check 5 the LAN's IPv6 prefixes; a LAN, or any host interface, on public IPv4
  addresses is outside the enforcement shape, and guests could reach it through NAT. Exact
  condition: check 5's targets include every unicast IPv4 address of every host interface; one
  outside every fixed range makes the shared check report `the host's <address> is public IPv4,
  outside the enforcement shape: not certified`, so Verify fails and nothing with an adapter
  starts on that host until the owner decides. A deny the module writes for it does not lift the
  condition. Consumers' read-backs do not see the host's addresses and do not report it.

## Shared check (DECIDED)

`supervisor/network/AapHostNetworkCheck.psm1`: pure (no Hyper-V, file, registry or network call;
a test enforces it), Windows PowerShell 5.1 and PowerShell 7, every result a list of problem lines
(printable, at most 200 characters, at most 64), none meaning the check holds.

| Function | Use |
|---|---|
| `Get-AapHostNetworkDeclarationProblems -Request <the request> -Declaration <Attach's value>` | the declaration check; any line is `AAP_NetworkInvalid` |
| `Get-AapHostNetworkAdapterProblems -Declaration <declaration> -Adapters <read-back> [-HostDeny <targets>]` | the read-back; any line is `AAP_NetworkUntrusted`. It re-checks the declaration first. `-HostDeny` is check 5's targets, for the module's Verify; consumers do not pass it |
| `Get-AapHostNetworkSwitchName -VmName <name>` | the VM's switch (table above), `''` for a VM that gets none |
| `Get-AapHostNetworkFixedDeny` | the fixed ranges, for the module to write |

Location: beside where the P10.0 module will live. Not `images/common`: that is P03's verified
artifact acquisition, the supervisor does not deploy it, and the builders already depend on the
supervisor side (the module they take as `-Network` is P10.0's). The backends import it as they
import `capacity` and `broker` (`..\..\network\AapHostNetworkCheck.psm1`); the builders import
`..\..\supervisor\network\AapHostNetworkCheck.psm1` only after their admin-only folder check has
passed for `supervisor\network`, as they treat `images\common` today. P19 deploys the folder with
the supervisor, admin-only.

Fail closed: a read-back or declaration field that is missing is never read as unset, and a list
field (`resolvers`, `endpoints`) that is not a list is a problem; values compare exactly (`'On'`,
not `$true` or `'on'`); a rule without all eight fields, with another action or direction, a weight
that is not an Int32 or a remote address that is not one address or prefix in canonical text (no
host bits under the prefix) is a problem and counts for nothing. A field is unrestricted only when
it reads `''`, `*` or `ANY` (any case), or, for a local address, the wildcard of the remote
address's family (D2: which one Hyper-V shows for an unset field; the check narrows to that form
once the lab has seen it).

Tests: `tests/network/AapHostNetworkCheck.Tests.ps1`, a failing case for every rule and every
field, and a parity test: on every `attach-*` fixture the check judges as `validate.py` does (the
Python reference predicate, which reads the fixed ranges from this module);
`tests/common/Invoke-AapHostNetworkMutations.ps1` disables each of the check's `# check:`
conditions in turn (45) and requires a test to fail for each.

## Consumer obligations (DECIDED)

Order:

1. `NewVm` with no adapter, then `Attach` and the declaration check; then, while the VM is Off,
   the guest's network written from the declaration into its seed or answer file: `address` with
   the subnet's prefix length, `gateway` as the default route, `resolvers` as its DNS servers, DHCP
   off (Linux: NoCloud `network-config` version 2 for a clone, the autoinstall `network` section
   for the Ubuntu build VM; Windows: the answer file's `Microsoft-Windows-TCPIP` and
   `Microsoft-Windows-DNS-Client` settings, or a first-boot step; D2); then `Verify` and the
   read-back.
2. Before every host-initiated power-on of a VM that has an adapter (`StartVm`, `RestartVm`):
   `Verify` and the read-back again, with the declaration kept from Attach. A failure stops the
   start.
3. Teardown: stop, `RemoveVm`, then `Detach`, on every teardown attempt, also when Attach never ran
   or failed (Detach is then a no-op, or removes the record). A Detach that throws means the network
   is not proven detached: the backends count the teardown as not done (retry, then
   `teardown_failed`, capacity held); the builders report the failed cleanup and the reconcile
   removes the record once the VM is gone.
4. Verification and scanner VMs get no adapter and never reach the module; the builders read back
   zero adapters before they boot.
5. A sealed image carries no address: the builder removes the build VM's static network
   configuration before it seals (Ubuntu: the installer's netplan file; Windows: whatever
   generalize leaves, D2), so a clone's only addressing is its own seed or answer file.

**Declaration check** (`AAP_NetworkInvalid` when it fails):
`Get-AapHostNetworkDeclarationProblems -Request $req -Declaration $decl`. It requires the schema's
keys; `VmId`, `VmName` and `Profile` echoed; a runner clone or build VM of that profile; a private
subnet `/16` to `/30`; the gateway and the address usable addresses of it, the address not the
gateway; one or two resolvers, each public or an endpoint's address; and at most two endpoints,
both one private IPv4 address outside the subnet, `UDP` or `TCP`, port 53.

**Read-back** (`AAP_NetworkUntrusted` when it fails), from Hyper-V through the consumer's own
provider, never through the module:
`Get-AapHostNetworkAdapterProblems -Declaration $decl -Adapters @(<provider read-back>)`. The
provider reports each adapter of the VM as Hyper-V shows it, under `Set-StrictMode -Version 2` so a
misspelt property throws instead of reading as unset:

```powershell
foreach ($n in @(Hyper-V\Get-VMNetworkAdapter -VM $vm)) {
    $name = ''; $type = ''
    if ($n.SwitchId) { $sw = Hyper-V\Get-VMSwitch -Id $n.SwitchId -ErrorAction Stop; $name = [string]$sw.Name; $type = [string]$sw.SwitchType }
    @{  SwitchName = $name; SwitchType = $type
        DhcpGuard = [string]$n.DhcpGuard; RouterGuard = [string]$n.RouterGuard; MacAddressSpoofing = [string]$n.MacAddressSpoofing
        PortMirroringMode = [string]$n.PortMirroringMode; VlanMode = [string]$n.VlanSetting.OperationMode
        # the other VMs with an adapter on the same switch; the host's own adapters are not VMs
        Peers = @(Hyper-V\Get-VMNetworkAdapter -All | Where-Object { $name -and -not $_.IsManagementOs -and $_.SwitchName -ceq $name -and $_.VMId -ne $vm.Id } |
            ForEach-Object { [string]$_.VMName })
        Acls = @(Hyper-V\Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $n | ForEach-Object {
            @{ Action = [string]$_.Action; Direction = [string]$_.Direction; RemoteAddress = [string]$_.RemoteIPAddress
               LocalAddress = [string]$_.LocalIPAddress; Protocol = [string]$_.Protocol; RemotePort = [string]$_.RemotePort
               LocalPort = [string]$_.LocalPort; Weight = $_.Weight } }) }
}
```

The check then requires (rules i to iv of the security review of P07):

- exactly one adapter, on the VM's switch, type `Internal`; `DhcpGuard` and `RouterGuard` `On`,
  `MacAddressSpoofing` `Off`; `PortMirroringMode` `None`; `VlanMode` `Untagged` or `Access` (a trunk
  port reaches other VLANs, a private-VLAN promiscuous port every isolated one);
- `Peers` as Switches says;
- (i) for each fixed range an unscoped Deny in each direction, with exactly that range;
- (ii) no Allow but the declared endpoints, so none when none is declared (the default): each Allow
  exactly one endpoint (its one address, its protocol and its remote port; nothing else narrowed or
  widened), every endpoint allowed in each direction, and each Allow's weight above every Deny of
  its direction whose range contains its address. An extra Deny is tolerated (it only blocks more)
  unless it outweighs an endpoint's Allow;
- (iii) and (iv) above: mirroring, VLAN, and the fixed ranges kept in the check alone.

The host-specific targets are Verify's alone: only the module knows the host.

**Verify output**: every object Verify writes is a problem; consumers do not drop empty or `$null`
items (a module that writes anything on success fails closed). A throw is a problem.

| Code | When |
|---|---|
| `AAP_NetworkUnavailable` | no module given (`-Network` absent): nothing is attached, built or created |
| `AAP_NetworkInvalid` | the module lacks `Attach`, `Detach` or `Verify` as a scriptblock, or the declaration check reports a line |
| `AAP_NetworkUntrusted` | Attach throws; Verify reports a problem or throws; the read-back reports a line |

Fail closed everywhere: no VM with an adapter starts after any of these, and the create or build
that met one is torn down (`RemoveVm`, then `Detach`).

## Shared fake for consumer tests

[`tests/common/AapHostNetworkFake.psm1`](../../tests/common/AapHostNetworkFake.psm1) stands in for
the module in the P06, P07, P10 and P11 suites (Pester 5, Windows PowerShell 5.1 and PowerShell 7).
Its tests are `tests/common/AapHostNetworkFake.Tests.ps1`; `Invoke-AapHostNetworkMutations.ps1
-Target fake` disables each of its checks in turn.

- `New-AapFakeHostNetwork -Root <folder> -VmExists <scriptblock>` returns `Attach`, `Detach` and
  `Verify` with the semantics above, strictly: the request shape, intent before act, each VM the
  lowest free address of its switch's subnet (held from the intent record until Detach), the same
  declaration on a repeated Attach, a second VM refused on a build switch, Detach refused while
  `VmExists` says the VM is there, the record removed by Detach, and Verify computed from the
  record and the simulated host through the shared check (no knob sets its answer).
  State lives only under `-Root` (`records\<vm id>.json`, `knobs.json`), so a child process killed
  mid-step leaves the world its parent recovers from.
- `Get-AapFakeHostNetworkAdapter -Root -VmId` returns what Hyper-V would report for the VM, in the
  provider shape above (`Peers`: the other attached records on the same switch), for the
  consumer's provider fake (`GetVmNetwork`, `GetVmConfig.Adapters`).
- `Set-AapFakeHostNetworkKnob -Root -Tamper <names> -Fail <names>`. Tampers change the simulated
  host, so Verify and the read-back both see them: `no-adapter`, `second-adapter`,
  `external-switch`, `other-switch`, `dhcp-guard-off`, `router-guard-off`, `mac-spoofing-on`,
  `port-mirroring`, `vlan-trunk`, `foreign-peer` (a build VM beside the VM), `drop-fixed-deny`
  (outbound `10.0.0.0/8`), `drop-inbound-deny` (inbound `10.0.0.0/8`), `scoped-deny` (inbound
  `192.168.0.0/16` narrowed to TCP port 1), `extra-allow` (an unnarrowed outbound Allow of the
  gateway, the old design), and two only Verify can see: `drop-host-deny` and `public-host` (the
  host gains `203.0.113.7`). Faults: `Attach`, `Detach`, `Verify` (the op throws) and
  `AttachAfterIntent` (Attach stops after its intent record, as a crash would).
- `Get-AapFakeHostNetworkRecord -Root [-VmId]` returns the journal records.
- Fake host: the four switches with `172.31.250.0/24` (`aap-guests-win`), `172.31.251.0/24`
  (`aap-guests-linux`), `172.31.252.0/24` (`aap-build-win`) and `172.31.253.0/24`
  (`aap-build-linux`), each gateway at `.1` and no DHCP or DNS service; addresses from `.2`;
  resolvers `192.0.2.53` and `198.51.100.53` (public documentation addresses); no endpoint, so no
  Allow; vEthernet addresses the four gateways, `172.29.16.1` and `2001:db8:5::1`; LAN IPv6 prefix
  `2001:db8:1::/64`. Not modelled: the VM's power state, the journal folder's ACL and the
  reconcile.

## Lab points (D2)

- Weights: the order of equal weights and whether two rules of one weight and direction are
  accepted; the accepted range (the cmdlet's Int32 `-Weight` has no range validation, read on this
  host's Hyper-V module 2.0.0.0); that a packet no rule matches passes.
- Read-back: the text `Get-VMNetworkAdapterExtendedAcl` shows for an unset address, port or protocol
  (the check accepts `''`, `*`, `ANY` and the family wildcard until then); whether a `/32` and an
  IPv6 range come back as written; `UDP` or `17`; and how a rule's direction is listed (the
  documentation says an entry "appears in both the inbound ACL and the outbound ACL"; the enum has
  only `Inbound` and `Outbound`). `VlanSetting.OperationMode` on `Get-VMNetworkAdapter`'s objects and
  `Get-VMNetworkAdapter -All` listing other VMs' adapters, stopped VMs included.
- Inbound semantics: that an inbound Deny matches on the source address, so a VM poisoning a
  neighbour's ARP cache receives none of the neighbour's own packets (negative case below).
- ARP passes the IP rules; internet egress and DNS to a public resolver need no IP-level Allow (a
  routed packet's destination is the far host); the multicast denies break nothing a statically
  addressed IPv4 guest needs; a port ACL matches `255.255.255.255/32` and so drops limited
  broadcasts both ways; the private resolver exception reaches its address on port 53 and nothing
  else there (another port).
- **Addressing without DHCP**: that each guest takes its address, gateway and resolvers from its
  seed or answer file and from nothing else: Ubuntu 24.04 cloud-init NoCloud `network-config`
  version 2 on `hv_netvsc` (matched by driver, not by a MAC address Hyper-V may assign at first
  start), the Ubuntu installer's autoinstall `network` section during a build, Windows Server
  2025's answer file (`Microsoft-Windows-TCPIP` interface identifier, `Microsoft-Windows-DNS-Client`)
  or a first-boot step; that Windows Setup and the Ubuntu installer complete with it; that no DHCP
  client keeps asking; and that a sealed base carries no build address. P07's build guest assumes
  DHCP (autoinstall `dhcp4: true`, `AapUbuntuImage.psm1:337` at `e468e15`): that assumption is
  open until P07.1 writes the static network configuration from the declaration.
- Host address and LAN prefix discovery, with WSL in NAT and in mirrored mode, and the public IPv4
  condition ([Limitations](#limitations)).
- The four switches' subnets and NAT (one `NetNat` whose prefix covers all four subnets, or one per
  switch, within what WinNAT supports); per-profile switch or per-guest switch (P02.1); adapters and
  their ACLs vanish with `Remove-VM`.
- Negative case (in guest-transport.md's list since 2026-10-21): a guest poisons ARP for its switch's gateway,
  for a neighbour, and the host's entry for that neighbour. Expected: none of the neighbour's own
  packets reach the poisoner and nothing the poisoner addresses to it arrives; what the internet
  sends the neighbour can reach the poisoner while they share a switch, which is why a build VM
  never shares one (Open points, 1 for clones).

## Open points

1. **Runner clones share their profile's switch** under the per-profile candidate: a D2 design
   decision for P02.1 (the build VM's own switch is decided above). The guards do not stop ARP
   poisoning between clones either: a clone that poisons the host's ARP entry for a neighbour
   receives what the internet sends that neighbour and can send with its address (the denies stop
   only what carries private addresses).
   - **Preferred candidate: private VLAN, isolated mode.** Every clone port on `aap-guests-*` is a
     secondary VLAN in `Isolated` mode, the host's vEthernet adapter on that switch is
     `Promiscuous` for that primary and secondary VLAN, so clones cannot reach each other at layer
     2 (ARP included) and still reach the host side for NAT. Alternatives: one internal switch per
     guest; or static host neighbour entries for every guest (their addresses are the module's)
     plus an outbound deny of every source address but the guest's own.
   - **The check until the lab decides**: it keeps refusing `VlanMode` `Private` (fail closed).
   - **The rule if the lab confirms the preferred candidate**: on an `aap-guests-*` switch a clone's
     read-back must show `VlanMode` `Private`, `PrivateVlanMode` `Isolated`, `PrimaryVlanId` and
     `SecondaryVlanId` equal to the pair P19 records for that switch, and nothing else is accepted
     there (`Untagged`, `Access`, `Trunk`, `Community` and `Promiscuous` refused for a guest port);
     the provider read-back gains `PrivateVlanMode`, `PrimaryVlanId` and `SecondaryVlanId` (from
     `Get-VMNetworkAdapterVlan`), and Verify also checks the host's vEthernet adapter on the switch
     is `Promiscuous` with that primary VLAN and secondary list. Build switches keep `Untagged` (one
     VM, nothing to isolate from).
   - **Lab questions**: does a private VLAN work on an internal switch with the host's vEthernet
     adapter promiscuous and WinNAT on top (egress, DNS); does it stop ARP poisoning and every
     other frame between two isolated ports, the host's ARP entries included; how
     `Set-VMNetworkAdapterVlan -ManagementOS -Promiscuous` and `Get-VMNetworkAdapterVlan` report
     the host's adapter and a guest port; and whether WSL in mirrored mode changes any of it.
2. The ledger's P10.0 text says "per-guest private switch", against guest-transport.md's rule
   (internal switches only); the ledger job corrects it.

## Conformance of the consumers

As of origin/main `01d159f` (these paths unchanged at `f2a4d1b`) and P07's draft at `e468e15`
(2026-10-21): four work items, P06.2, P07.1, P10.2 and P11.2. Every consumer drops its own switch
constant and deny list, calls the shared check, and gives its guests static addressing from the
declaration instead of relying on DHCP.

| Item | Consumer | Changes needed |
|---|---|---|
| P06.2 | `images/windows` | Import the check after `TestRootTrust` passes for `supervisor\network` (add it to the preflight's folders, README.md:145-152); drop `$script:SwitchName` (`AapWinImage.psm1:27`, `:652`, `:989-990`, `:1054`: the build VM is on `aap-build-win`) and `$script:DenyRanges` (`:35`). `Connect-AapBuildNetwork` (`:816-822`): keep `$decl = & $Ctx.Network.Attach $net`, `Get-AapHostNetworkDeclarationProblems -Request $net -Declaration $decl` (`AAP_NetworkInvalid`), Verify unfiltered and a throw `AAP_NetworkUntrusted`. Static addressing: the build VM's answer file is written by `ApplyWindowsImage` (`:1066-1068`), before the VM exists; after Attach, write it again with `WriteOfflineFiles` (as `:855` does) carrying the declaration's address, prefix length, gateway and resolvers (`New-AapWinUnattend`, `:430-480`, gains `Microsoft-Windows-TCPIP` and `Microsoft-Windows-DNS-Client`), then Verify and the read-back before `StartVm` (`:1077`). `Assert-AapVmAdapters` (`:824-843`): for the build VM `Get-AapHostNetworkAdapterProblems -Declaration $decl -Adapters @(GetVmNetwork)`; the verification VM keeps its zero-adapter read-back (`:858`). `GetVmNetwork` (`AapWinImage.HyperV.psm1:260-273`): the provider read-back above. Verify and the read-back before `RestartVm` (`:786`). `RemoveVm` then `Detach` (`:1092-1093` swapped; `:1157` after `Remove-AapWinBuild`). The seal leaves no build address in the base (Consumer obligations, 5). INTEGRATION.md and README.md follow. Tests: `tests/images/windows/WinImageTestHelpers.ps1` replaces its own module (`:110-112`, the `NetProblems` and `NicEdit` knobs) with `New-AapFakeHostNetwork` and its `GetVmNetwork` (`:201`) with `Get-AapFakeHostNetworkAdapter`; `WinImage.Tests.ps1` (`:507-510`) expects Attach, the answer file rewrite, Verify and the read-back before `StartVm`, one case per fake tamper, and an answer file that carries the declaration's address, gateway and resolvers |
| P07.1 | `images/ubuntu-24.04` (PR #49) | A fourth variant today: `New-AapUbuntuHyperVProvider -GuestNetwork` (`AapUbuntuImage.HyperV.psm1:159-170`), a step called with `@{ VmId; SwitchName }` (`:244`) after `NewVm` connects `aap-guests-linux` itself and sets the guards (`:239-243`); its own read-back `Get-AapAdapterProblems` (`:99-114`, outbound only, no scope, allow, weight, mirroring or VLAN check; its `'Both'` never occurs) on its own list (`:25-28`). Instead: take the module as `-Network` on `Invoke-AapUbuntuImageBuild` like P06; `NewVm` removes the default adapter for every VM (`:245-246` today does it only without a switch) and connects nothing; after `NewVm` of the build VM (`AapUbuntuImage.psm1:701`): Attach, the declaration check, Verify and `Get-AapHostNetworkAdapterProblems` on a `GetVmNetwork` op with the provider read-back (replacing `:249-253`), again before each `StartVm` of the build VM (`:703`, `:710`); the scanner and verification VMs keep the zero-adapter read-back (`:101-103`). Static addressing: the build VM's seed is made before its VM (`New-AapGuest`, `AapUbuntuImage.psm1:687-695`) and its autoinstall `network` asks for DHCP (`:331-337`); make it after Attach instead, with the declaration's address, prefix length, gateway and resolvers as a static `network` (`dhcp4: false`), and give it to the VM before `:703`; the seal removes the installer's netplan file so a clone takes only its own seed's `network-config`. Drop `$script:SwitchName` (`HyperV.psm1:21`; `AapUbuntuImage.psm1:34`, `:237`, `:884-885`, `:952`: the build VM is on `aap-build-linux`). `RemoveVm` then `Detach` for the build VM (`:976`; `:844` in `Remove-AapUbuntuBuild`). INTEGRATION.md:76-83 (the shared-switch hazard, resolved by `aap-build-linux`), :104-120 (the adapter step, replaced by `-Network`; "Provide DHCP and DNS on the switch", :107-108, withdrawn) follow. Tests: `tests/images/ubuntu-24.04/UbuntuImage.Tests.ps1` drops `-GuestNetwork` (`:236`, `:245`, `:252`, `:1040`, `:1048`, `:1055`) for `-Network` with `New-AapFakeHostNetwork` and a `GetVmNetwork` fake from `Get-AapFakeHostNetworkAdapter`; seed tests require a static `network` (`dhcp4: false`) from the declaration and no `dhcp4: true`; one case per fake tamper |
| P10.2 | `supervisor/backends/windows` | Import `..\..\network\AapHostNetworkCheck.psm1` beside capacity and broker (`AapWinBackend.psm1:32-33`); drop `$script:SwitchName` (`:37`). Create (`:975-978`): keep the declaration, `Get-AapHostNetworkDeclarationProblems` (`AAP_NetworkInvalid`), Verify unfiltered and a throw `AAP_NetworkUntrusted`, the declaration kept in the reservation's journal for later starts. Static addressing: `WriteUnattend` (`:959`) runs before `NewVm` (`:965`) and Attach (`:975`); move it after Attach and give `Write-AapWinUnattend` (`:271-342`) the declaration's address, prefix length, gateway and resolvers, so each clone's answer file carries its own; a re-run of create re-attaches (the same declaration) and rewrites the file. `Assert-AapWinVmConfig -Adapters` (`:880-888`): `Get-AapHostNetworkAdapterProblems -Declaration $decl -Adapters $nics`. `GetVmConfig` adapters (`AapWinBackend.HyperV.psm1:105-109`): the provider read-back above (today MAC spoofing reads `-eq 'On'`, so an unknown value passes). Verify and the read-back before boot's `StartVm` (`:1192`). Destroy order (`:1083`, `:1087`) conforms. INTEGRATION.md follows. Tests: `tests/backends/windows/WinBackendTestHelpers.ps1` replaces its knob-driven module (`:198-209`: `NetSwitch`, `NetSwitchType`, `NetProblems`) with `New-AapFakeHostNetwork`, and `GetVmConfig.Adapters` (`:166`) with `Get-AapFakeHostNetworkAdapter`; `Create.Tests.ps1` requires the answer file after Attach with the declaration's addressing and a refused start for each fake tamper; `Invoke-AapWinMutations.ps1` keeps a mutation per new check |
| P11.2 | `supervisor/backends/linux` | As P10.2: import beside capacity and broker (`AapLinBackend.psm1:37-38`); drop `$script:SwitchName` (`:41`); create (`:1048-1050`) keeps and checks the declaration; `Assert-AapLinNetwork` (`:950-962`): Verify unfiltered (`:951`; its throw is already `AAP_NetworkUntrusted`), then the shared check instead of `:953-961`; `GetVmConfig` adapters (`AapLinBackend.HyperV.psm1:149-153`) the provider read-back. Static addressing: the seed is built before `NewVm` (`:1031-1038`) and Attach (`:1049`); build it after Attach with a `network-config` file (version 2, static from the declaration, matched by driver `hv_netvsc`) beside `user-data` and `meta-data` (`New-AapLinSeed`, `:541`), and give it to the VM before its first start. Verify and the read-back before boot's `StartVm` (`:1302`); destroy order (`:1157`, `:1161`) conforms. INTEGRATION.md stops relying on Verify alone for the port ACLs, and withdraws "clones need DHCP and DNS on the switch" (`:101`). Tests: `tests/backends/linux/LinBackendTestHelpers.ps1` replaces its knob-driven module (`:240-252`) with `New-AapFakeHostNetwork`, and `GetVmConfig.Adapters` (`:175`) with `Get-AapFakeHostNetworkAdapter`; `Create.Tests.ps1` requires the seed after Attach with a `network-config` carrying the declaration's address, gateway and resolvers, and a refused start for each fake tamper; `Invoke-AapLinMutations.ps1` keeps a mutation per new check |

## References

- `Add-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmnetworkadapterextendedacl>
  (`-Direction` Inbound and Outbound from the VM's perspective; remote address and port the source
  inbound, the destination outbound; address wildcards `0.0.0.0/0`, `::/0`, `ANY`; port ranges;
  `-Protocol` TCP, UDP or a number; `-Weight`; `-Stateful`, not used here)
- `Get-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vmnetworkadapterextendedacl>
- Extended port ACLs (weights, stateful rules always allow): <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/create-security-policies-extended-port-access-control-lists>
- Read on this host, 2026-10-21, by reflection only (no VM, no change): Hyper-V module 2.0.0.0,
  `VMNetworkAdapterExtendedAclSetting` has `Action` (`Allow`, `Deny`), `Direction` (`Inbound`,
  `Outbound`; no `Both`), `LocalIPAddress`, `RemoteIPAddress`, `LocalPort`, `RemotePort`, `Protocol`
  (strings), `Weight` (Int32), `Stateful`, `IdleSessionTimeout`, `IsolationID`; the adapter's
  `DhcpGuard`, `RouterGuard` and `MacAddressSpoofing` are `OnOffState` (`On`, `Off`),
  `PortMirroringMode` is `None`, `Destination` or `Source`, and `VlanSetting.OperationMode` is
  `Untagged`, `Access`, `Trunk` or `Private`.
