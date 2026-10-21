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

**Status:** interface, order, declaration (static guest addressing, no Allow by default but the
source pin), read-back, switches and failure codes DECIDED (coordinator, 2026-10-21). The
enforcement shape is guest-transport.md's (DECIDED), tightened here (both directions, no Allow by
default, the source pin; [Rules and weights](#rules-and-weights)). The mechanism (one internal
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

Whether a VM exists is Hyper-V's answer for its id. Only Hyper-V's definitive "not found" means
the VM is gone; any other error (the service does not answer, access denied, a timeout) means the
module cannot look, and the call throws and changes nothing. No call ever frees a live VM's
address on a guess.

### Attach

- Precondition: the VM exists and is Off, and it has no network adapter or only the one its
  record names (an unfinished Attach of the same VM, or the re-Attach before every start). A VM
  in any other state, or with an adapter the record does not name, is refused.
- It refuses (throws, changes nothing) when the VM's switch carries a VM the
  [Switches](#switches-decided) rule forbids beside it.
- Allocation and intent, under the journal lock ([Journal](#journal-and-reconcile-decided)):
  Attach reads every record (one it cannot read makes it throw, since the address that record
  holds is unknown), checks the Switches rule, allocates the VM's address (least recently used),
  and writes the VM's record (state `attaching`) naming the declaration and everything it is about
  to create, renamed into place before the lock is released. When every usable address of the
  subnet but the gateway is held, it throws `AAP_NetworkUntrusted: no free address on <switch>`
  before writing any record: fail closed, and the consumer tears the VM down.
- Then the act: one adapter on the VM's switch ([Switches](#switches-decided)), DHCP guard On,
  router guard On, MAC address spoofing Off, port mirroring None, the VLAN mode Untagged, the storm
  limit 100, no legacy port ACL, the extended port ACLs of [Rules and weights](#rules-and-weights);
  then the record says `attached`.
- Returns the **declaration** (`host_network_attach`), all a guest's network is:
  - `vm_id`, `vm_name`, `profile`;
  - `subnet`: its switch's, IPv4 `/16` to `/30` and private (inside `10.0.0.0/8`,
    `172.16.0.0/12`, `192.168.0.0/16` or `100.64.0.0/10`: the fixed ranges a NAT routes unicast
    in);
  - `gateway`: the host's vEthernet address on that switch, a usable address of the subnet
    (neither its network nor its broadcast address);
  - `address`: the VM's static address, a usable address of the subnet other than the gateway that
    no other record on the switch holds (Attach allocates it; the record keeps it until Detach);
  - `resolvers`: one or two IPv4 addresses for DNS, each public (global unicast: outside every
    fixed range, which also holds `0.0.0.0/8`, `127.0.0.0/8` and `240.0.0.0/4`, so reached through
    NAT and the source pin with no other Allow) or the private resolver's address below;
  - `endpoints`: the narrowed exceptions it allowed, **none by default** (DECIDED, coordinator,
    2026-10-21; there is no `gateway` or `dhcp` endpoint). The one kind there is: DNS to **one
    private resolver address** the owner chose, as up to two endpoints `{ address, protocol, port }`
    with that same address, `UDP` and `TCP`, port `53`. The address is private, outside the subnet,
    never the gateway or another guest (Verify check 5 refuses one inside any of the host's
    addresses or vEthernet prefixes), and one of `resolvers`: no exception for an address the guest
    is not told to use.

  Its keys are the schema's; serialized, it validates.
- **No DHCP.** The guest learns its address, gateway and resolvers only from the declaration, which
  its consumer writes into the guest's seed or answer file before the first start
  ([Consumer obligations](#consumer-obligations-decided)). Nothing on the host serves DHCP or DNS
  to guests; DHCP guard stays On so that no guest can act as a server for its neighbours.
- Idempotent: a repeated Attach for the same VM (a retry after a crash, and the re-Attach while the
  VM is Off before every start) completes what the record names and returns the record's
  declaration unchanged, address included, from the module's own journal. It never declares
  anything else for a VM it has a record for. Consumers keep no copy of the declaration between
  starts.
- Throws on any failure. A failed Attach keeps its record, so Detach and the reconcile clean up.

### Verify

- Read-only: never changes the host or the journal. It may be called at any time.
- Returns the **problem list**: zero or more strings written to the output stream, each one
  printable line of at most 200 characters, at most 64. Empty means every check below holds. It
  throws only when it cannot look: Hyper-V does not answer, a record it cannot read (check 1 reads
  them all), or a partial host discovery: nothing, no gateway, or no address of a host interface
  that is not a vEthernet adapter (check 5).
- Checks, against the record and what Hyper-V and the host report now:
  1. The VM exists, its record is `attached` and names the same `VmName` and `Profile`, and no
     other record on its switch holds its address.
  2. Exactly one adapter, on the VM's switch, which exists with type `Internal`; DHCP guard On,
     router guard On, MAC address spoofing Off, port mirroring None, VLAN mode Untagged or Access,
     storm limit 100, and no legacy port ACL (`Get-VMNetworkAdapterAcl` lists none).
  3. The switch's other VMs: none beside a build VM; beside a runner clone, runner clones of its
     profile only ([Switches](#switches-decided)).
  4. For each fixed range, an unscoped Deny in each direction, Inbound and Outbound, the outbound
     one above the source pin where the pin covers the range (every IPv4 range).
  5. Host-specific targets, discovered now: every unicast address of every host interface,
     vEthernet adapters included (IPv4 and IPv6; loopback excluded), the on-link IPv4 prefix of
     every vEthernet adapter (the guest and build switches', WSL's NAT, any other), and every LAN
     IPv6 prefix (the on-link prefix of each global unicast IPv6 address on a host interface that is
     not a vEthernet adapter). A discovery without the declaration's gateway, or without at least
     one address of a host interface that is not a vEthernet adapter (the LAN card's), is a throw:
     Verify cannot look, and an empty or partial list never passes. Verify always passes the
     targets to the shared check as `-HostDeny` and the LAN addresses as `-HostLan`; it never calls
     the check without them (P10.0's tests assert it). Each target lies inside an unscoped Deny in
     each direction (outbound, above the source pin), and no declared endpoint lies inside one, so
     a private resolver is never one of the discovered targets: the host's addresses, the WSL
     distro's prefix or another aap subnet. What discovery does not see is not covered
     ([Limitations](#limitations), Scope). A public IPv4 address among the targets (outside every
     fixed range) is itself a problem ([Limitations](#limitations)).
  6. Every Allow is the source pin, exactly once, or exactly one declared endpoint (its address,
     its protocol, its remote port, and the guest's address as local address), and every endpoint
     has an Allow in each direction; with no endpoint declared, the source pin is the only Allow.
     Every rule is stateless with isolation id 0.
  7. Weights, one per rule class: the catch-all deny below the source pin, the source pin below
     every Deny it must not lift (check 4 and 5), every endpoint's Allow above every Deny of its
     direction whose range contains its address.
  8. The VM's switch: its enabled extensions are the default set P19 recorded for it, and no HNS
     network uses it (D2: the set itself is the lab's).

  Checks 2 to 7 are the shared check's `Get-AapHostNetworkAdapterProblems` with `-HostDeny` set to
  check 5's targets: the module and its consumers run the same code.

### Detach

- Precondition: the VM is gone (Hyper-V's definitive "not found"). Callers remove the VM, then
  Detach. While a VM with that id exists, or while Hyper-V cannot say, Detach throws and changes
  nothing: the order is enforced, not assumed.
- Under the journal lock, it uses only the VM's record, found by the VM's id, never the live
  adapter and never a bare name. It removes, newest first, what the record names beyond the VM's
  own adapter (which went with the VM): a per-guest switch, its NAT, its host firewall rules (the
  per-guest candidate, D2; nothing for the per-profile candidate), each by the name the record
  holds. Each removal is idempotent (absent is done). The record goes last; its address goes to the
  end of the released list.
- Every name a record holds ends in its own VM id (`aap-guest-<vm_id>`, `aap-guest-block-<vm_id>`;
  schema pattern `aap-<words>-<vm_id>`), so a record can never name another VM's object or a host
  rule such as `FPS-SMB-In-TCP`. A record with a name that does not end in its own VM id, or that
  names a switch P19 owns (`aap-guests-*`, `aap-build-*`), is not the module's to remove: it counts
  as unreadable.
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
- P19 also unbinds the Link-Layer Topology Discovery mapper and responder, LLDP, File and Printer
  Sharing (`ms_server`) and Client for Microsoft Networks (`ms_msclient`) from every aap vEthernet
  adapter, records each switch's enabled extensions (Verify check 8), and never creates an HNS
  network (Docker, WSL, containers) on an `aap-*` switch.
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
  what carries a private address: a neighbour's own packets redirected to the poisoner (private
  source, dropped by the poisoner's inbound denies) and whatever the poisoner addresses to a
  neighbour (private destination, dropped by its outbound denies); the source pin stops it sending
  with a neighbour's address. What the internet sends a neighbour through the host's NAT has a
  public source: once the host's ARP entry for the neighbour points at the poisoner, the poisoner
  receives it, and can read or drop it. A hostile job beside a build could read or withhold what
  the build downloads, which ends up in every clone's base image, and a build VM runs
  internet-sourced installers as root; so a build VM gets a segment of its own. Clones: Open
  points, 1.

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
- **One module-wide lock**: `lock` in the folder, opened exclusively (no sharing); a holder that
  dies releases it. It is held for every record write and every read of all records: Attach from
  reading the records until its intent record is renamed into place, and again for its final
  write; Verify while it reads the records; Detach and the reconcile for each record they remove.
  Not taken within 30 seconds: the call throws. Two processes therefore never allocate from the
  same view of the records, and no reader lists the folder while a rename hides a record's name.
- **Allocation, least recently used**: `released.json` lists the addresses Detach freed, the
  longest released first. Attach takes an address no record holds: one never released (lowest
  first), else the one released longest ago. An address freed a moment ago may still sit in a
  neighbour's or the host's ARP cache and the NAT's connection table; reusing it last keeps a new
  guest from inheriting traffic meant for the old one. It is written exactly like a record: to a
  temporary name in the same folder, flushed, and renamed over the old file, under the lock.
- **An unreadable `released.json`** (not a JSON list of IPv4 addresses) fails closed: Attach and
  Detach throw `AAP_NetworkUntrusted: released.json is unreadable` and change nothing; Verify does
  not read it. Nothing rebuilds it silently. Only the module's **recovery op** (an owner's explicit
  step outside `Attach`, `Detach` and `Verify`, never called by a consumer) rebuilds it: under the
  lock, from every record (one it cannot read makes it throw), it writes each switch's addresses
  that no record holds, lowest first; the old order is lost, so addresses freed shortly before the
  damage may be reused sooner.
- Reconcile, each time the module is constructed and before it serves a call: a record whose VM
  Hyper-V definitively does not have is detached; a record of an existing VM stays (its consumer
  owns it, and Verify judges it before any start); when Hyper-V cannot say, the reconcile stops
  and every call throws until it can. An unreadable record stays and is reported; while it is
  there, every Attach and every Verify throw (they read every record), and so does every call for
  that VM id, until an owner looks; Detach of other VMs goes on. Records are per VM id and VM ids
  are never reused, so two processes meet only on the lock and on a removed VM, where Detach and
  the reconcile are both idempotent. This is the "module's own reconcile" P06 relies on for a
  crashed run's attachment. An address is free again only when no record holds it, so a crashed
  Attach's address stays taken until its record is detached.
- Collision recovery: two records holding one address on a switch (a hand-edited journal, a bug)
  make Verify report it for both VMs, so neither starts; their consumers tear them down, and Detach
  frees the address.

## Rules and weights

Enforcement shape: guest-transport.md, Guest network attachment (DECIDED), applied here in both
directions. Hyper-V semantics: the Microsoft documentation cited below, and this host's Hyper-V
module read by reflection; every point marked D2 is confirmed only by the lab.

- "Larger weight values apply first, and once an ACL entry applies to a packet, other entries are
  no longer relevant for that packet" (`Add-VMNetworkAdapterExtendedAcl`, `-Weight`). A packet no
  rule matches passes; the documentation implies it and internet egress depends on it (D2).
- `Direction` is `Inbound` or `Outbound`, seen from the VM; an extended port ACL has no `Both`. For
  an inbound packet the remote address and port are its source, for an outbound one its
  destination; the local address is the VM's side (outbound, the packet's source).
- An address field takes one address, a prefix, `0.0.0.0/0` (all IPv4), `::/0` (all IPv6) or `ANY`;
  a port field one port or a range; `Protocol` `TCP`, `UDP` or an IP protocol number.
- A rule also has `Stateful` (a stateful Allow admits the return traffic of what it allowed, which
  the rule list does not show) and `IsolationID` (a rule for one isolation network only). The
  legacy port ACLs (`Add-VMNetworkAdapterAcl`) are a second list beside the extended one.

The module writes only these rules, all stateless, all with isolation id 0, and no legacy port ACL:

- **Catch-all deny**: Outbound, `0.0.0.0/0`, unscoped, weight 1.
- **Source pin**: Outbound Allow, remote `0.0.0.0/0`, local address the declared `address` as `/32`,
  protocol and ports unrestricted, weight 5. With the catch-all below it, an IPv4 packet the guest
  sends with any other source address is dropped.
- **Fixed denies**, unscoped (local address, protocol, local port and remote port all unrestricted),
  each range Inbound and Outbound, weight 10: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `169.254.0.0/16`, `100.64.0.0/10`, `224.0.0.0/4`, `ff00::/8`, `fe80::/10`, `fc00::/7`, the IPv4
  limited broadcast `255.255.255.255/32` (adopted 2026-10-21: without DHCP nothing needs it, and it
  reaches the host's vEthernet adapter and every neighbour), `0.0.0.0/8`, `127.0.0.0/8`,
  `240.0.0.0/4` and `::/0` (adopted 2026-10-21: guests have and need no IPv6; it also covers every
  IPv6 form of an IPv4 address, IPv4-mapped, NAT64, Teredo and 6to4, and every IPv6 prefix of the
  host and the LAN). The one copy in code is the shared check's (`Get-AapHostNetworkFixedDeny`);
  the module writes from it and `validate.py` reads it from there.
- **Endpoint allows**, none by default. For each declared endpoint and nothing else, one in each
  direction, weight 20: its address alone (`/32`), its protocol, its port as the remote port
  (outbound the destination port, inbound the source port of the reply), and the declared
  `address` as local address (`/32`); the local port unrestricted.
- **Host-specific denies**: none. Every target Verify check 5 discovers on a host it certifies lies
  in a fixed range (private IPv4, link-local, `127.0.0.0/8`, `::/0`); check 5 proves it each time.
- **Weights**: a weight per rule class, catch-all < source pin < fixed denies < endpoint allows (1,
  5, 10, 20; any values in that order conform). Rules sharing a weight share a class and an action,
  so no packet's fate depends on how Hyper-V orders a tie.
- **Storm limit** 100 broadcast, multicast and unknown-unicast packets per second (`StormLimit`;
  enough for ARP, D2).

Why the source pin (adopted 2026-10-21): a rule matches the remote address only. Without the pin a
guest can send to a public destination with a forged source, a LAN device's or the host's LAN
address; the host forwards it and the owner's router translates it, so the guest speaks to the
internet as someone else, and a TCP reply to a neighbour's address lands on the switch it shares.
The pin outweighs the catch-all and nothing else: every fixed deny outweighs it, so it never opens
a private range.
Why both directions: inbound, the remote address is the source. A VM that poisons its neighbours'
ARP caches receives their packets, whose sources are private addresses, and its own inbound denies
drop them; the same denies stop packets from neighbours and from the host's other addresses
reaching it. Outbound denies stop it addressing them. Neither stops what the internet sends a
neighbour (a public source) once the host's ARP cache points at the poisoner: hence a build VM's
own switch ([Switches](#switches-decided)) and Open points, 1.
Why unscoped: a Deny narrowed to TCP, to port 1, to one local address or to one isolation network
does not deny the range.
Why no other Allow (DECIDED, coordinator, 2026-10-21): a port ACL matches a packet's IP header. A
routed packet's destination is the far host; only its frame goes to the gateway's MAC address, and
ARP is not IP. So internet egress needs no Allow for the gateway, public resolvers lie outside every
denied range, and with static addressing nothing needs DHCP. An Allow for the gateway or any other
address of the host would open the host's ports to the guest at the IP level, and an Allow for a
range, for an address nobody declared, or wider than its endpoint's protocol and port would open a
hole that no check of the denies can see. The one exception is DNS to one private resolver the
owner chose, narrowed to its address, port 53 over UDP and TCP, and the guest's own address.

Not the module's: the Guest Service Interface and Key-Value Pair Exchange are turned off by the
consumers' `NewVm` and read back there; Enhanced Session Mode is a host setting (P19 sets it, the
backends check it); the host firewall rules that block the host's listening ports on the guest
vEthernet adapters are P19's (guest-transport.md). Since no Allow names an address of the host,
those rules are a second barrier, not the only one.

## Limitations

- **Scope of the guarantee.** A guest reaches the internet through the host's NAT, sends only from
  its own address (the source pin), and reaches none of the denied ranges in either direction: the
  private, CGNAT, link-local, loopback, reserved, multicast and broadcast IPv4 ranges and all IPv6,
  which covers the host's and the LAN's private addresses and every discovered host target. The
  contract does **not** block: LAN or routed targets on public addresses (the guest's traffic to
  them leaves through NAT like any internet traffic); a hairpin through the owner's router to the
  owner's own public address and from there to its port forwards; or a host address outside every
  fixed range, which makes the host not certified rather than covered. A host interface that comes
  up after Verify (a VPN adapter, say) is checked only at the next Verify (Consumer obligations, 3).
  These are residuals and lab items, not guarantees; a host with a public IPv4 address stays not
  certified.
- **A host with a public IPv4 address** (owner decision queued, 2026-10-21). The fixed ranges cover
  private IPv4 and all IPv6; a LAN, or any host interface, on public IPv4 addresses is outside the
  enforcement shape, and guests could reach it through NAT. Exact condition: check 5's targets
  include every unicast IPv4 address of every host interface; one outside every fixed range makes
  the shared check report `the host's <address> is public IPv4, outside the enforcement shape: not
  certified`, so Verify fails and nothing with an adapter starts on that host until the owner
  decides. A deny the module writes for it does not lift the condition. Consumers' read-backs do
  not see the host's addresses and do not report it. The same holds for Azure's WireServer,
  `168.63.129.16`, a public address the fixed ranges do not cover: it matters only on a host that
  is itself an Azure VM, which is not certified.
- **NAT side effects** (lab): guests share the owner's public IPv4 address, so what a hostile job
  sends to the internet is seen as the owner's (abuse reports, rate limits, reputation); a guest
  that connects to the owner's own public address may reach the LAN through the router's hairpin
  and port forwards; LAN devices can reach a guest subnet only through a route to the host, which
  nothing creates, and WinNAT maps nothing inbound (the module and P19 add no static mapping).
- **ICMP from private hops**: the inbound denies drop an ICMP error whose source is private (the
  owner's router answering "fragmentation needed"), so path MTU discovery through such a hop fails
  (lab).

## Shared check (DECIDED)

`supervisor/network/AapHostNetworkCheck.psm1`: pure (no Hyper-V, file, registry or network call;
a test allows only its own functions and the pipeline cmdlets, a list of method names, of type
names and of `New-Object` arguments, no command or member named by a value and no
`$ExecutionContext` or `$Host`, and proves it catches injected probes), Windows PowerShell 5.1 and
PowerShell 7, every result a list of problem lines (printable, at most 200 characters, at most 64;
capped once where the result leaves the module), none meaning the check holds.

| Function | Use |
|---|---|
| `Get-AapHostNetworkDeclarationProblems -Request <the request> -Declaration <Attach's value>` | the declaration check; any line is `AAP_NetworkInvalid` |
| `Get-AapHostNetworkAdapterProblems -Declaration <declaration> -Adapters <read-back> [-HostDeny <targets> -HostLan <addresses>]` | the read-back; any line is `AAP_NetworkUntrusted`. It re-checks the declaration first. `-HostDeny` is check 5's targets and `-HostLan` the discovered addresses of host interfaces that are not vEthernet adapters, for the module's Verify; given, the targets must be non-empty, hold the declaration's gateway and at least one of the `-HostLan` addresses; consumers pass neither |
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
not `$true` or `'on'`); a rule without all ten fields or with any other field, with another
action or direction, stateful, with an isolation id other than 0, a weight that is not an Int32 or
a remote address that is not one address or prefix in canonical text (the address as .NET
prints it, so IPv6 in lower case; no host bits under the prefix, no zero-padded prefix length) is
a problem and counts for nothing; the check never throws on what a read-back holds. A field is unrestricted
only when it reads `''`, `*` or `ANY` (any case), or, for a local address, the wildcard of the
remote address's family (D2: which one Hyper-V shows for an unset field; the check narrows to that
form once the lab has seen it).

Tests: `tests/network/AapHostNetworkCheck.Tests.ps1`, a failing case for every rule and every
field, and a parity test: on every `attach-*` fixture the check judges as `validate.py` does (the
Python reference predicate, which reads the fixed and private ranges from this module), and for a
semantic refusal it names the same field; `tests/common/Invoke-AapHostNetworkMutations.ps1`
disables each of the check's `# check:` conditions in turn (68, the address arithmetic's guards
included) and requires a test to fail for each.

## Consumer obligations (DECIDED)

Order:

1. `NewVm` with no adapter, with `AutomaticStartAction` `Nothing` and checkpoints disabled (read
   back with the VM's configuration), then `Attach` and the declaration check; then, while the VM
   is Off, the guest's network written from the declaration into its seed or answer file:
   `address` with the subnet's prefix length, `gateway` as the default route, `resolvers` as its
   DNS servers, DHCP off (Linux: NoCloud `network-config` version 2 for a clone, the autoinstall
   `network` section for the Ubuntu build VM; Windows: the answer file's `Microsoft-Windows-TCPIP`
   and `Microsoft-Windows-DNS-Client` settings, or a first-boot step; D2); then `Verify` and the
   read-back.
2. Before every host-initiated power-on of a VM that has an adapter (`StartVm`, `RestartVm`), with
   the VM Off: `Attach` again (it returns the same declaration from the module's journal; the
   consumer keeps none), the declaration check, `Verify` and the read-back. A failure stops the
   start. `AutomaticStartAction` `Nothing` and disabled checkpoints are what make this the only way
   such a VM starts: the host never starts it on its own, and no checkpoint brings back an older
   adapter.
3. While a VM with an adapter runs: when the host's addresses change, `Verify` again (the backends
   and the builders watch the host's address changes, or poll at most every 60 seconds, D2), and a
   failure or a throw stops the VM (turned off, then the consumer's own failure path).
4. Teardown: stop, `RemoveVm`, then `Detach`, on every teardown attempt, also when Attach never ran
   or failed (Detach is then a no-op, or removes the record). A Detach that throws means the network
   is not proven detached: the backends count the teardown as not done (retry, then
   `teardown_failed`, capacity held); the builders report the failed cleanup and the reconcile
   removes the record once the VM is gone.
5. Verification and scanner VMs get no adapter and never reach the module; the builders read back
   zero adapters before they boot.
6. A sealed image carries no address: the builder removes the build VM's static network
   configuration before it seals (Ubuntu: the installer's netplan file; Windows: whatever
   generalize leaves, D2), so a clone's only addressing is its own seed or answer file.

**Declaration check** (`AAP_NetworkInvalid` when it fails):
`Get-AapHostNetworkDeclarationProblems -Request $req -Declaration $decl`. It requires the schema's
keys; `VmId`, `VmName` and `Profile` echoed; a runner clone or build VM of that profile; a private
subnet `/16` to `/30`; the gateway and the address usable addresses of it, the address not the
gateway; one or two resolvers, each public or the private resolver's address; and at most two
endpoints, one private IPv4 address outside the subnet and among the resolvers, `UDP` or `TCP`,
port 53.

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
        PortMirroringMode = [string]$n.PortMirroringMode; VlanMode = [string]$n.VlanSetting.OperationMode; StormLimit = [string]$n.StormLimit
        LegacyAcls = @(Hyper-V\Get-VMNetworkAdapterAcl -VMNetworkAdapter $n).Count
        # the other VMs with an adapter on the same switch; the host's own adapters are not VMs
        Peers = @(Hyper-V\Get-VMNetworkAdapter -All | Where-Object { $name -and -not $_.IsManagementOs -and $_.SwitchName -ceq $name -and $_.VMId -ne $vm.Id } |
            ForEach-Object { [string]$_.VMName })
        Acls = @(Hyper-V\Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $n | ForEach-Object {
            @{ Action = [string]$_.Action; Direction = [string]$_.Direction; RemoteAddress = [string]$_.RemoteIPAddress
               LocalAddress = [string]$_.LocalIPAddress; Protocol = [string]$_.Protocol; RemotePort = [string]$_.RemotePort
               LocalPort = [string]$_.LocalPort; Weight = $_.Weight; Stateful = [string]$_.Stateful; IsolationId = [string]$_.IsolationID } }) }
}
```

The check then requires (rules i to iv of the security review of P07, and round 5's reviews):

- exactly one adapter, on the VM's switch, type `Internal`; `DhcpGuard` and `RouterGuard` `On`,
  `MacAddressSpoofing` `Off`; `PortMirroringMode` `None`; `VlanMode` `Untagged` or `Access` (a trunk
  port reaches other VLANs, a private-VLAN promiscuous port every isolated one); `StormLimit` `100`;
  `LegacyAcls` `0`;
- `Peers` as Switches says;
- every rule exactly the ten fields above, `Stateful` `False`, `IsolationId` `0` (or empty);
- (i) for each fixed range an unscoped Deny in each direction, with exactly that range, the
  outbound one above the source pin for an IPv4 range;
- (ii) the source pin exactly once (Outbound Allow, remote `0.0.0.0/0`, local address the declared
  address, nothing else narrowed), above an unscoped Outbound Deny of `0.0.0.0/0`; no other Allow
  but the declared endpoints, so none when none is declared (the default): each exactly one
  endpoint (its one address, its protocol, its remote port and the declared address as local
  address; nothing else narrowed or widened), every endpoint allowed in each direction, and each
  above every Deny of its direction whose range contains its address. An extra Deny is tolerated
  (it only blocks more) unless it outweighs an endpoint's Allow;
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

- `New-AapFakeHostNetwork -Root <folder> -Vm <scriptblock>` returns `Attach`, `Detach` and `Verify`
  with the semantics above, strictly. `-Vm` answers what Hyper-V has for a VM id: `$null` only for
  a VM it definitively does not have, else `@{ State; Adapters }` (the VM's adapters the module did
  not make); it throws when it cannot look, and so does the call. Modelled: the request shape;
  Attach's preconditions (Off, no adapter of the consumer's); the journal lock (an exclusive
  `lock` file) around every record write and every read of all records; records written
  to a temporary name and renamed; every Attach and every Verify refused while any record is
  unreadable (a record naming a P19 switch, or a name without its own VM id, included); an
  unreadable `released.json` stopping Attach and Detach until `Repair-AapFakeHostNetworkReleased`
  (the recovery op) rebuilds it; least recently used allocation with
  exhaustion refused; intent before act; the same declaration on a repeated Attach; a second VM
  refused on a build switch; Detach refused while the VM exists or Hyper-V cannot say; the record
  removed by Detach and its address released; Verify computed from the records and the simulated
  host through the shared check (no knob sets its answer), with a held address reported and a
  host discovery without the gateway or a LAN address thrown.
  State lives only under `-Root` (`records\<vm id>.json`, `released.json`, `lock`, `host\<vm id>`,
  `knobs.json`), so a child process killed mid-step leaves the world its parent recovers from, and
  concurrent processes share it (a test attaches from six at once).
- `Get-AapFakeHostNetworkAdapter -Root -VmId` returns what Hyper-V would report for the VM, in the
  provider shape above (`Peers`: the other VMs with the module's adapter on the same switch), from
  Attach's act on, for the consumer's provider fake (`GetVmNetwork`, `GetVmConfig.Adapters`). It
  reads the records under the journal lock.
- `Set-AapFakeHostNetworkKnob -Root -Tamper <names> -Fail <names>`. Tampers change the simulated
  host, so Verify and the read-back both see them: `no-adapter`, `second-adapter`,
  `external-switch`, `other-switch`, `dhcp-guard-off`, `router-guard-off`, `mac-spoofing-on`,
  `port-mirroring`, `vlan-trunk`, `storm-limit-off`, `legacy-acl`, `foreign-peer` (a build VM
  beside the VM), `drop-fixed-deny` (outbound `10.0.0.0/8`), `drop-inbound-deny` (inbound
  `10.0.0.0/8`), `scoped-deny` (inbound `192.168.0.0/16` narrowed to TCP port 1), `stateful-rule`,
  `isolated-rule` (rule 1), `no-source-pin`, `pin-above-deny` (the pin at weight 50),
  `extra-allow` (an unnarrowed outbound Allow of the gateway, the old design), and three only
  Verify can see: `public-host` (the host gains `203.0.113.7`), `host-empty`, `host-no-gateway`
  and `host-no-lan` (a discovery that finds nothing, no gateway, or no LAN address: Verify
  throws). Faults:
  `Attach`, `Detach`, `Verify` (the op throws), `AttachAfterIntent` (Attach stops after its intent
  record) and `AttachAfterAct` (after the adapter exists, before the record says `attached`), as a
  crash would.
- `Get-AapFakeHostNetworkRecord -Root [-VmId]` returns the journal records.
- Fake host: the four switches with `172.31.250.0/24` (`aap-guests-win`), `172.31.251.0/24`
  (`aap-guests-linux`), `172.31.252.0/24` (`aap-build-win`) and `172.31.253.0/24`
  (`aap-build-linux`), each gateway at `.1` and no DHCP or DNS service; resolvers `192.0.2.53` and
  `198.51.100.53` (public documentation addresses); no endpoint, so the source pin is the only
  Allow; vEthernet addresses the four gateways, `172.29.16.1` and `2001:db8:5::1`, their IPv4
  prefixes and `172.29.16.0/20`; the LAN card's `192.168.1.10`; LAN IPv6 prefix
  `2001:db8:1::/64`. Not modelled: the journal
  folder's ACL, the reconcile, the switch extensions (check 8), and a removed VM's adapter, which
  stays visible as a peer until Detach (fail closed).

## Lab points (D2)

- Weights: that Hyper-V accepts several rules of one weight and direction (the module writes all
  denies of a direction at one weight; no outcome depends on their order); the accepted range (the
  cmdlet's Int32 `-Weight` has no range validation, read on this host's Hyper-V module 2.0.0.0);
  that a packet no rule matches passes.
- Read-back: the text `Get-VMNetworkAdapterExtendedAcl` shows for an unset address, port or protocol
  (the check accepts `''`, `*`, `ANY` and the family wildcard until then); whether a `/32` and an
  IPv6 range come back as written, the IPv6 one in lower case (the check refuses another case); `UDP` or `17`; `Stateful` as `False` and `IsolationID` as `0`;
  `StormLimit` as `100`; `Get-VMNetworkAdapterAcl` empty on a new adapter; and how a rule's
  direction is listed (the documentation says an entry "appears in both the inbound ACL and the
  outbound ACL"; the enum has only `Inbound` and `Outbound`). `VlanSetting.OperationMode` on
  `Get-VMNetworkAdapter`'s objects and `Get-VMNetworkAdapter -All` listing other VMs' adapters,
  stopped VMs included.
- Inbound semantics: that an inbound Deny matches on the source address, so a VM poisoning a
  neighbour's ARP cache receives none of the neighbour's own packets (negative case below).
- **Source pin**: a guest sends with the source address of a LAN device, of the host's LAN address,
  of another guest subnet's address, of a neighbour and `0.0.0.0`, to a public destination;
  expected: a capture on the host's LAN card sees none of them, and the guest's own traffic flows.
  Also that the local address of an outbound rule matches the packet's source.
- ARP passes the IP rules; internet egress and DNS to a public resolver need no Allow but the pin
  (a routed packet's destination is the far host); the multicast denies break nothing a statically
  addressed IPv4 guest needs; a port ACL matches `255.255.255.255/32` and `::/0` and so drops
  limited broadcasts and all IPv6 both ways; the private resolver exception reaches its address on
  port 53 and nothing else there (another port). Alternative for the exception, to compare: one
  stateful outbound Allow without an inbound Allow (the check refuses stateful rules until then).
- A UDP sweep from a guest to the host's vEthernet address and the broadcast and multicast groups
  on ports 137, 138, 1900, 3702, 5353 and 5355: no answer, and the host's services on those ports
  see nothing; the switch extensions P19 records (Verify check 8); the unbound LLTD, LLDP,
  `ms_server` and `ms_msclient`.
- ICMP: a path whose MTU is below the guest's, through a private hop (path MTU discovery with the
  inbound denies); NAT side effects ([Limitations](#limitations)): the router's hairpin from a
  guest to the owner's public address.
- **Addressing without DHCP**: that each guest takes its address, gateway and resolvers from its
  seed or answer file and from nothing else: Ubuntu 24.04 cloud-init NoCloud `network-config`
  version 2 on `hv_netvsc` (matched by driver, not by a MAC address Hyper-V may assign at first
  start), the Ubuntu installer's autoinstall `network` section during a build, Windows Server
  2025's answer file (`Microsoft-Windows-TCPIP` interface identifier, `Microsoft-Windows-DNS-Client`)
  or a first-boot step; that Windows Setup and the Ubuntu installer complete with it; that no DHCP
  client keeps asking; and that a sealed base carries no build address. P07's build guest assumes
  DHCP (autoinstall `dhcp4: true`, `AapUbuntuImage.psm1:337` at `e468e15`): that assumption is
  open until P07.1 writes the static network configuration from the declaration.
- Host address and prefix discovery, with WSL in NAT and in mirrored mode, the address-change
  notification Consumer obligations 3 relies on, and the public IPv4 condition
  ([Limitations](#limitations)).
- The four switches' subnets and NAT (one `NetNat` whose prefix covers all four subnets, or one per
  switch, within what WinNAT supports); per-profile switch or per-guest switch (P02.1); adapters and
  their ACLs vanish with `Remove-VM`.
- Negative case (in guest-transport.md's list since 2026-10-21): a guest poisons ARP for its
  switch's gateway, for a neighbour, and the host's entry for that neighbour. Expected: none of the
  neighbour's own packets reach the poisoner, nothing the poisoner addresses to it arrives, and
  nothing the poisoner sends with the neighbour's address leaves; what the internet sends the
  neighbour can reach the poisoner while they share a switch and the host's entry can be poisoned,
  which is why a build VM never shares one (Open points, 1 for clones).

## Open points

1. **Known residual (owner decision 8): two clones on one shared guest switch can poison each
   other's ARP**, and the host's entry for each other, so a hostile clone can receive what the
   internet sends its neighbour. **The Windows profile must not serve public repositories until a
   clone isolation control (permanent host neighbour entries with the source pin, or a switch per
   guest) is REQUIRED by this contract and proven in the D2 lab.** Until then this contract
   requires neither, and the check keeps refusing `VlanMode` `Private`.
   **Runner clones share their profile's switch** under the per-profile candidate: a D2 design
   decision for P02.1 (the build VM's own switch is decided above). The guards do not stop ARP
   poisoning between clones either: a clone that poisons the host's ARP entry for a neighbour
   receives what the internet sends that neighbour (the denies stop only what carries private
   addresses; the source pin stops it answering as the neighbour).
   - **Preferred closing control: a permanent host neighbour entry per guest address, with the
     source pin.** Attach gives the VM a static MAC address before its first start (from a range
     the module owns) and adds `New-NetNeighbor -State Permanent` for the guest's address and that
     MAC on the switch's vEthernet adapter; Detach removes it; Verify reads it back (and the
     adapter's MAC). The host then never learns a guest's address from ARP, so no clone can take a
     neighbour's traffic, and the pin stops it sending as one. Adopting it adds the MAC to the
     declaration and the record and the entry to Verify: a contract revision.
   - **The other complete option: one internal switch per guest** (Switches, per-guest candidate):
     no neighbour shares a segment. Choosing it later changes the check (the switch name per VM,
     `Peers` always empty) and needs a contract version bump.
   - **Private VLAN, isolated mode, is only an add-on**: it stops frames between isolated ports,
     but the host's vEthernet adapter is promiscuous by design, so an isolated clone still poisons
     the host's ARP entry for a neighbour. The lab's expected result for PVLAN alone is negative
     (the neighbour's internet traffic still reaches the poisoner).
   - **The check until the lab decides**: it keeps refusing `VlanMode` `Private` (fail closed).
   - **Lab questions**: does a permanent neighbour entry hold against gratuitous ARP and ARP
     replies from a guest (the host's cache keeps the entry; nothing reaches the poisoner); does a
     static MAC survive the VM's life and Windows Setup and cloud-init; does the per-guest switch
     scale to five runners per profile within WinNAT's limits; and, for PVLAN as an add-on, whether
     it works on an internal switch with the host's adapter promiscuous and WinNAT on top, how
     `Get-VMNetworkAdapterVlan` reports it, and whether WSL in mirrored mode changes any of it.
2. The ledger's P10.0 text says "per-guest private switch", against guest-transport.md's rule
   (internal switches only); the ledger job corrects it.

## Conformance of the consumers

As of origin/main `8752c0f` (the Windows paths unchanged since `01d159f`) and P07's draft at
`e468e15` (2026-10-21): four work items, P06.2, P07.1, P10.2 and P11.2. Every consumer drops its
own switch constant and deny list, calls the shared check, gives its guests static addressing from
the declaration instead of relying on DHCP, re-Attaches (VM Off) before every start instead of
keeping the declaration, verifies running guests again when the host's addresses change, and reads
back with the provider shape above, so its read-back now covers the source pin, `Stateful` and
`IsolationId` per rule, `LegacyAcls` and `StormLimit`.

| Item | Consumer | Changes needed |
|---|---|---|
| P06.2 | `images/windows` | Import the check after `TestRootTrust` passes for `supervisor\network` (add it to the preflight's folders, README.md:145-152); drop `$script:SwitchName` (`AapWinImage.psm1:27`, `:652`, `:989-990`, `:1054`: the build VM is on `aap-build-win`) and `$script:DenyRanges` (`:35`). `Connect-AapBuildNetwork` (`:816-822`): keep `$decl = & $Ctx.Network.Attach $net`, `Get-AapHostNetworkDeclarationProblems -Request $net -Declaration $decl` (`AAP_NetworkInvalid`), Verify unfiltered and a throw `AAP_NetworkUntrusted`. Static addressing: the build VM's answer file is written by `ApplyWindowsImage` (`:1066-1068`), before the VM exists; after Attach, write it again with `WriteOfflineFiles` (as `:855` does) carrying the declaration's address, prefix length, gateway and resolvers (`New-AapWinUnattend`, `:430-480`, gains `Microsoft-Windows-TCPIP` and `Microsoft-Windows-DNS-Client`), then Verify and the read-back before `StartVm` (`:1077`). `Assert-AapVmAdapters` (`:824-843`): for the build VM `Get-AapHostNetworkAdapterProblems -Declaration $decl -Adapters @(GetVmNetwork)`; the verification VM keeps its zero-adapter read-back (`:858`). `GetVmNetwork` (`AapWinImage.HyperV.psm1:260-273`): the provider read-back above. Attach again (VM Off), the declaration check, Verify and the read-back before `RestartVm` (`:786`); Verify again while the build VM runs when the host's addresses change. `RemoveVm` then `Detach` (`:1092-1093` swapped; `:1157` after `Remove-AapWinBuild`). The seal leaves no build address in the base (Consumer obligations, 6). INTEGRATION.md and README.md follow. Tests: `tests/images/windows/WinImageTestHelpers.ps1` replaces its own module (`:110-112`, the `NetProblems` and `NicEdit` knobs) with `New-AapFakeHostNetwork` and its `GetVmNetwork` (`:201`) with `Get-AapFakeHostNetworkAdapter`; `WinImage.Tests.ps1` (`:507-510`) expects Attach, the answer file rewrite, Verify and the read-back before `StartVm`, the re-Attach before `RestartVm`, one case per fake tamper and fault (`AttachAfterAct` included), and an answer file that carries the declaration's address, gateway and resolvers |
| P07.1 | `images/ubuntu-24.04` (PR #49) | A fourth variant today: `New-AapUbuntuHyperVProvider -GuestNetwork` (`AapUbuntuImage.HyperV.psm1:159-170`), a step called with `@{ VmId; SwitchName }` (`:244`) after `NewVm` connects `aap-guests-linux` itself and sets the guards (`:239-243`); its own read-back `Get-AapAdapterProblems` (`:99-114`, outbound only, no scope, allow, weight, mirroring or VLAN check; its `'Both'` never occurs) on its own list (`:25-28`). Instead: take the module as `-Network` on `Invoke-AapUbuntuImageBuild` like P06; `NewVm` removes the default adapter for every VM (`:245-246` today does it only without a switch) and connects nothing; after `NewVm` of the build VM (`AapUbuntuImage.psm1:701`): Attach, the declaration check, Verify and `Get-AapHostNetworkAdapterProblems` on a `GetVmNetwork` op with the provider read-back (replacing `:249-253`), and before each `StartVm` of the build VM (`:703`, `:710`) Attach again (VM Off), the declaration check, Verify and the read-back; Verify again while it runs when the host's addresses change; the scanner and verification VMs keep the zero-adapter read-back (`:101-103`). Static addressing: the build VM's seed is made before its VM (`New-AapGuest`, `AapUbuntuImage.psm1:687-695`) and its autoinstall `network` asks for DHCP (`:331-337`); make it after Attach instead, with the declaration's address, prefix length, gateway and resolvers as a static `network` (`dhcp4: false`), and give it to the VM before `:703`; the seal removes the installer's netplan file so a clone takes only its own seed's `network-config`. Drop `$script:SwitchName` (`HyperV.psm1:21`; `AapUbuntuImage.psm1:34`, `:237`, `:884-885`, `:952`: the build VM is on `aap-build-linux`). `RemoveVm` then `Detach` for the build VM (`:976`; `:844` in `Remove-AapUbuntuBuild`). INTEGRATION.md:76-83 (the shared-switch hazard, resolved by `aap-build-linux`), :104-120 (the adapter step, replaced by `-Network`; "Provide DHCP and DNS on the switch", :107-108, withdrawn) follow. Tests: `tests/images/ubuntu-24.04/UbuntuImage.Tests.ps1` drops `-GuestNetwork` (`:236`, `:245`, `:252`, `:1040`, `:1048`, `:1055`) for `-Network` with `New-AapFakeHostNetwork` and a `GetVmNetwork` fake from `Get-AapFakeHostNetworkAdapter`; seed tests require a static `network` (`dhcp4: false`) from the declaration and no `dhcp4: true`; one case per fake tamper and fault |
| P10.2 | `supervisor/backends/windows` | Import `..\..\network\AapHostNetworkCheck.psm1` beside capacity and broker (`AapWinBackend.psm1:32-33`); drop `$script:SwitchName` (`:37`). Create (`:975-978`): `Get-AapHostNetworkDeclarationProblems` (`AAP_NetworkInvalid`), Verify unfiltered and a throw `AAP_NetworkUntrusted`; no copy of the declaration in the reservation's journal. Static addressing: `WriteUnattend` (`:959`) runs before `NewVm` (`:965`) and Attach (`:975`); move it after Attach and give `Write-AapWinUnattend` (`:271-342`) the declaration's address, prefix length, gateway and resolvers, so each clone's answer file carries its own; a re-run of create re-attaches (the same declaration) and rewrites the file. `Assert-AapWinVmConfig -Adapters` (`:880-888`): `Get-AapHostNetworkAdapterProblems -Declaration $decl -Adapters $nics`. `GetVmConfig` adapters (`AapWinBackend.HyperV.psm1:105-109`): the provider read-back above (today MAC spoofing reads `-eq 'On'`, so an unknown value passes). Before boot's `StartVm` (`:1192`): Attach again (VM Off), the declaration check, Verify and the read-back. Running clones: Verify again when the host's addresses change, and a failure stops the clone into the backend's hostile or failed path. Destroy order (`:1083`, `:1087`) conforms. INTEGRATION.md follows. Tests: `tests/backends/windows/WinBackendTestHelpers.ps1` replaces its knob-driven module (`:198-209`: `NetSwitch`, `NetSwitchType`, `NetProblems`) with `New-AapFakeHostNetwork`, and `GetVmConfig.Adapters` (`:166`) with `Get-AapFakeHostNetworkAdapter`; `Create.Tests.ps1` requires the answer file after Attach with the declaration's addressing and a refused start for each fake tamper and fault; `Invoke-AapWinMutations.ps1` keeps a mutation per new check |
| P11.2 | `supervisor/backends/linux` | As P10.2: import beside capacity and broker (`AapLinBackend.psm1:37-38`); drop `$script:SwitchName` (`:41`); create (`:1081-1083`) checks the declaration and keeps no copy; `Assert-AapLinNetwork` (`:972-985`): Verify unfiltered (`:974` drops empty items today; its throw is already `AAP_NetworkUntrusted`), then the shared check instead of `:976-984`; `GetVmConfig` adapters (`AapLinBackend.HyperV.psm1:152-156`) the provider read-back (today the guards read as booleans). Static addressing: today the seed is built and read back (`:1055-1068`) before `NewVm` (`:1071`), and `NewVm` mounts it (`AapLinBackend.HyperV.psm1:138`, `Add-VMDvdDrive -Path $a.Seed`). Instead `NewVm` adds the one DVD drive empty (`Add-VMDvdDrive -VM $vm`, no `Seed` argument), and a new provider op `SetSeed @{ VmId; Seed }` sets that drive's path (`Hyper-V\Set-VMDvdDrive`), refusing a VM that is not Off or has another number of DVD drives. Create then runs `NewVm`, Attach and the declaration check, builds the seed (`New-AapLinSeed`, `:542`) with a `network-config` file (version 2, static from the declaration, matched by driver `hv_netvsc`) beside `user-data` and `meta-data`, writes and reads it back as today, calls `SetSeed`, then `Assert-AapLinVmConfig` (`:939`; it requires the seed as the one DVD), Verify and the read-back, and only then journals `done`. Crash and retry: a re-run of create finds the VM by the journal's id (`:1070-1076` skips `NewVm`), re-attaches (the same declaration), rebuilds the seed at the same path (the VM is Off, nothing holds the ISO) and calls `SetSeed` again (setting the same path is idempotent); a crash anywhere before `done` re-runs all of it, and destroy (`:1190`, `:1194`) removes the VM, then detaches. Before boot's `StartVm` (`:1335`): Attach again (VM Off), the declaration check, Verify and the read-back; running clones verified again when the host's addresses change, a failure stops the clone. INTEGRATION.md stops relying on Verify alone for the port ACLs, and withdraws "clones need DHCP and DNS on the switch" (`:101`). Tests: `tests/backends/linux/LinBackendTestHelpers.ps1` replaces its knob-driven module (`New-LinNetwork`, `:247`) with `New-AapFakeHostNetwork`, its provider fake's `GetVmConfig.Adapters` (`NewVm`, `:184`) with `Get-AapFakeHostNetworkAdapter`, and gains a `SetSeed` fake; `Create.Tests.ps1` requires the seed after Attach with a `network-config` carrying the declaration's address, gateway and resolvers, a refused start for each fake tamper and fault, and a crash between Attach and `SetSeed` that re-runs to one seed and the same declaration; `Invoke-AapLinMutations.ps1` keeps a mutation per new check |

## References

- `Add-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmnetworkadapterextendedacl>
  (`-Direction` Inbound and Outbound from the VM's perspective; remote address and port the source
  inbound, the destination outbound; address wildcards `0.0.0.0/0`, `::/0`, `ANY`; port ranges;
  `-Protocol` TCP, UDP or a number; `-Weight`; `-Stateful`, not used here)
- `Get-VMNetworkAdapterExtendedAcl`: <https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vmnetworkadapterextendedacl>
- Extended port ACLs (weights, stateful rules always allow): <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/create-security-policies-extended-port-access-control-lists>
- `Get-VMNetworkAdapterAcl` (the legacy port ACLs): <https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vmnetworkadapteracl>
- `New-NetNeighbor` (`-State Permanent`): <https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netneighbor>
- Read on this host, 2026-10-21, by reflection only (no VM, no change): Hyper-V module 2.0.0.0,
  `VMNetworkAdapterExtendedAclSetting` has `Action` (`Allow`, `Deny`), `Direction` (`Inbound`,
  `Outbound`; no `Both`), `LocalIPAddress`, `RemoteIPAddress`, `LocalPort`, `RemotePort`, `Protocol`
  (strings), `Weight` (Int32), `Stateful`, `IdleSessionTimeout`, `IsolationID`; the adapter's
  `DhcpGuard`, `RouterGuard` and `MacAddressSpoofing` are `OnOffState` (`On`, `Off`),
  `PortMirroringMode` is `None`, `Destination` or `Source`, and `VlanSetting.OperationMode` is
  `Untagged`, `Access`, `Trunk` or `Private`.
