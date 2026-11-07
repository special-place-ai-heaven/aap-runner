# Linux VM backend: integration requests (ledger item P11)

P11 owns only `supervisor/backends/linux/**` and `tests/backends/linux/**`. Nothing below is wired into the supervisor, the
installer, the guest image, the network or CI yet. How the backend works: [README.md](README.md). The Windows twin's
requests ([../windows/INTEGRATION.md](../windows/INTEGRATION.md)) apply here too where this file does not say otherwise.

## P12: supervisor

1. **Load.** `Import-Module <supervisor>\backends\linux\AapLinBackend.psm1`, then `AapLinBackend.HyperV.psm1` beside it.
   The backend imports `..\..\capacity\AapCapacity.psm1` and `..\..\broker\aap-broker.psm1` itself, and needs
   `hvsock-relay.ps1` beside it (`AAP_RelayMissing` otherwise).
2. **Build the context once per supervisor start:**

   ```powershell
   $L = New-AapLinBackend -Provider (New-AapLinHyperVProvider) -Network <P10.0 module's Attach/Detach/Verify>
   ```

   Same defaults and failures as `New-AapWinBackend` (`AAP_StorageMissing`, `AAP_StorageInvalid`, `AAP_JournalUntrusted`,
   `AAP_CompileUntrusted`): show the code in `status.v5.json` and keep the VM profiles off. It compiles its job object and
   ISO writer types once, with `%TMP%` at the admin-only `<JournalRoot>\compile`. Never pass `-RelaxedTrustForTests`.
   The Windows and Linux contexts share the journal folder and the storage document; keep them in the same runspace or
   one per runspace, never one context in two runspaces.
3. **Storage and host status.** `Get-AapLinStorageProblem` and `Get-AapLinHostProblem` as their Windows twins (the same
   roots and host settings: run one pair, show its lines once).
4. **Every tick**, for every live reservation with `profile` `linux` and `backend` `hyperv-vm`:

   ```powershell
   $res = Invoke-AapLinStep -Backend $L -Reservation $r -BaseSha256 <approved-images.json pin of $r.image_generation>
   ```

   Same contract as `Invoke-AapWinStep` (one runspace per context, the per-reservation step lock, `Action`/`Code`/`Summary`,
   exceptions are provider failures to log and retry). Linux adds `Action` `probing` with `Code` `host_key_pending`
   (first boot not finished) and the hostile code `bad_host_key`; a guest command that could not be sent is `Code`
   `channel_unusable`. A reservation stays in one context for its whole life; after a restart the new context rebuilds the
   guest channel from the clone's `ssh` folder by itself.
5. **Admission.** `Request-AapReservation -Profile linux -MemOverheadMib <budget> -CloneGib <clone_gib_max> -ScratchGib 0
   -IoMbps <io>`: the Linux profile has no scratch disk, and create refuses a reservation with `scratch_gib` other than 0
   (`AAP_BadRequest`). Initialize the allocator with `-LinuxBackend hyperv-vm` for this profile. Request no Linux VM while a
   storage or host problem is listed or the P10.0 module is missing.
6. **Reconcile.** One inventory for both profiles: `Get-AapLinInventory` and `Get-AapWinInventory` list the same VMs,
   folders and journals; pass either, never both. `-BrokerStatus` per reservation: `Get-AapLinBrokerStatus` for `linux`,
   `Get-AapWinBrokerStatus` for `windows` (the Linux one reads a journal with a `windows` record as unreadable and returns
   `$null`).
7. **Wall clock, pause, off, resize, unknown VMs**: as the Windows twin (its INTEGRATION.md, P12 items 7-9).
8. **Hard VM lifetime cap (P11.3, owner Q4; allocator.md L1 to L10; P12.3 wires it).** The backend enforces the cap
   itself on every step; the supervisor supplies its inputs and reports what it returns:

   ```powershell
   $L = New-AapLinBackend ... -CapHours <effective vm_lifetime_cap_hours, 1..6> -WatchdogClockPath <P10.7's lifetime-clock.json> `
       -ClockSafety <'' | 'host_reboot' | 'clock_unavailable'>   # L7, decided from the supervisor's own clock record at start
   $L.CapHours = <n>          # a settings change applies at the next step; anything outside 1..6 counts as 6
   Invoke-AapLinCapPass -Backend $L -Reservations <every live reservation>   # every tick, before any Invoke-AapLinStep (L3 rule 1)
   ```

   - **Decision**: `acquired_at` (persisted in allocator.json, so a restart decides again from it), the cap in force and
     the backend's true time: the wall clock, never moved back within one process (a boot-bound `Stopwatch` counter
     advances it while the wall clock is stepped back). Exactly the cap counts. Nothing from the guest, the broker or
     GitHub enters it. Across a restart with a clock stepped back the supervisor's `lifetime-clock.json` is the only
     source of true time: pass it as `-Clock` (a scriptblock returning that estimate) or the restart re-decides from the
     wall clock. `-ClockSafety` caps every reservation whose VM exists at this context's first look at it, with that
     trigger and the measured age (or `null`), never six invented hours.
   - **Result**: every step of a capped reservation returns `LifetimeCap` (the `lifetime_cap` evidence object of
     backend-lifecycle.schema.json: `cap_hours`, `started_utc`, `deadline_utc`, `elapsed_s`, `trigger`, `power_off_utc`,
     `reason` `vm_lifetime_cap`; `$null` while it cannot be formed honestly: no known start, or no power-off call that
     returned) and `Detail` (one bounded line: the error of a failed power-off, decision, allocator move or journal write,
     never swallowed). `Code` is `vm_lifetime_cap` once torn down, the ordinary teardown code while it waits
     (`release_pending`, `teardown_failed`, `retry_later`), `cap_breach` while the VM is not observed Off (report `error`,
     `vm_lifetime_cap: cap_breach:` in `detail`, block new VM starts, keep the slot held), `enforcement_unavailable` when
     the VM list or the decision itself failed (an unreadable start time, a failing clock, bad journal evidence: the VM
     is powered off by id or derived name all the same, and `Invoke-AapLinCapPass` goes on with the other
     reservations), `journal_unreadable` / `journal_unwritable` when only the journal failed (the VM is off). A start
     time ahead of true time is capped as `clock_unavailable` with no measured age. Fill the slot's `vm_lifetime_cap`
     object of `status.v5.json` from it and log one line per decision (reservation id, slot, the three times). An
     invalid `CapHours` counts as 6 and is warned once per value.
   - **Start gate**: `Action` `waiting` with `Code` `backstop_down` or `notes_unverified`; `Detail` names why:
     `unconfigured` (no or not an absolute normalized `-WatchdogClockPath`), `boot_id_unreadable`, `untrusted` (the
     record's folder fails the admin-only trust check or the file is writable by anyone else), `missing`, `invalid`
     (over 64 KiB, not JSON, not a schema 1 watchdog record, `latched` not a list of objects), `other_boot`, `stale` (older
     than 180 s or more than 60 s ahead), `breach` (the watchdog holds a `cap_breach`), `local_cap_breach` (this backend
     holds one). The reservation stays `creating`; report `backstop_down:`. Without a valid watchdog record nothing
     starts: no Linux VM boots before P10.7 is installed (B7, B8).
   - **Recovery (L6 d)**: a boot an earlier supervisor journaled and never finished, whose VM is not running now, is
     never started: it is given up (`boot` `failed` `retryable`) and destroyed.
   - **Not here**: the durable clock latch and its `enforcement_stage` (`lifetime-clock.json`, P12.3), the E2 stage
     (terminating the VM's `vmwp.exe`; `cap_breach` is reported right after a power-off that did not take), bounded and
     killable Hyper-V calls (L3: every provider call still runs in-process), and the allocator edges below. Safe to defer:
     no VM can start without a valid watchdog record.
   - **Allocator requests (AapCapacity.psm1, P12.3)**: L4 asks for one direct edge `ready|busy|draining|collecting ->
     deleting` with `cleanup_uncertain: true`; the backend walks the existing edges instead (`busy -> collecting ->
     deleting`). `quarantined` with kind `heartbeat` or `crash` cannot reach `deleting` outside reconcile, so for those
     the VM is powered off and torn down but the allocator state is left to reconcile.

## P15: Linux guest bootstrap and agent (what this backend expects of the image)

- **sshd on vsock 5222**, socket-activated (`ListenStream=vsock::5222`, `Accept=yes`, `sshd -i` per connection), with
  `PermitRootLogin forced-commands-only`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PubkeyAuthentication yes`, `AllowTcpForwarding no`, `PermitTunnel no`, `X11Forwarding no`, `PrintMotd no`,
  `PrintLastLog no`, no `Banner` (a banner or MOTD on stdout is `non_printable`, hostile), host key type ed25519 only.
- **Host key publication**: at first boot, after cloud-init generated `/etc/ssh/ssh_host_ed25519_key`, write the public
  key line's first two fields (`ssh-ed25519 AAAA...`, exactly that, no comment, no newline) as the guest-to-host KVP item
  `aap-ssh-host-key-ed25519` (pool 1, through `hv_kvp_daemon`, which the image must ship and enable). Never publish
  anything else there.
- **Agent** at `/usr/local/libexec/aap-guest/agent`, root 0755, the forced command of root's `authorized_keys` line that
  the seed writes (`restrict,command="/usr/local/libexec/aap-guest/agent" ssh-ed25519 ... aap-management`). stdin: the
  envelope line, a newline, then exactly `payload_bytes` bytes (tolerate a leading UTF-8 BOM). stdout: one reply line;
  exit 0 after every reply, a refusal included: any other exit is `child_exit`, hostile.
- The refusals of guest-transport.md, Envelope: own `vm_id` from the hypervisor (`/sys/class/dmi/id/product_uuid`, lower
  case), first `lease_generation`, `seq` strictly greater than the last accepted one (gaps are normal, including across a
  host supervisor restart, which continues above its persisted mark), fresh `nonce`, one-shot classes once, not expired.
  Echo the request's `nonce` and `seq`.
- Replies the backend accepts per command: as the Windows twin (its INTEGRATION.md, P14), `probe` `ready` only after
  first boot finished (cloud-init done, the host key published, the job user present, the post-generation scripts run).
- **Bootstrap material**: before answering `listening`, delete what the guest got for bootstrap: the JIT config wherever
  it was held, and the cloud-init seed's copies (`/var/lib/cloud/instance/user-data.txt` and the seed cache). The host
  ejects the seed after the first `ready` probe; nothing in it is secret, but nothing should keep it.
- Start `Runner.Listener run` as `runner` (uid 1001) with `ACTIONS_RUNNER_INPUT_JITCONFIG` in its environment only;
  `/etc/environment` loaded as the runner loads it; `loginctl enable-linger runner`; crash dumps off for the runner.
- **No account with uid 1000**: the seed creates only `runner`; the image must not ship one (P07's seal check removes the
  install user that had it). Do not re-enable cloud-init's default user.
- Mount options and read-ahead of the root file system come from the image (`fstab`, udev); the backend attaches only
  `os.avhdx` and changes neither.

## P14: Windows guest agent

Nothing new: the Linux backend shares no guest code with Windows. Keep the two agents' reply semantics identical (the
backend's reply checks are the same table).

## P19: installer and helper

- Deploy `supervisor\backends\linux\` (with `hvsock-relay.ps1`) beside `capacity\`, `broker\` and `backends\windows\`,
  Administrators/SYSTEM-only: whoever can write the module or the relay runs code in the elevated supervisor (the relay
  runs as ssh.exe's ProxyCommand under the supervisor's token).
- Register the runtime hvsocket service GUID `00001466-facb-11e6-bd58-64006a7986d3` (vsock 5222) under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices` (guest-transport.md),
  beside P07's build GUID.
- Check that the Windows OpenSSH client is present at `C:\Windows\System32\OpenSSH\ssh.exe` and `ssh-keygen.exe` (an
  optional Windows feature); without them every probe is a failed guest and every create fails (`AAP_KeyInvalid`).
- `clone_root` admin-only (no ACE for any other SID, not even read): it now holds each clone's private key.
- The supervisor's `TEMP`/`TMP` must be admin-only (as for P10).

## P10.0: the guest network module

The contract is [host-network-module.md](../../../parity/contracts/host-network-module.md) (version 1); this backend is
its P11.2 consumer. Requests are `@{ VmId; VmName; Profile = 'linux' }`; the clone's switch is `aap-guests-linux`, which
only the shared check names (`supervisor/network/AapHostNetworkCheck.psm1`, imported beside capacity and broker; the
backend keeps no switch name or deny list of its own). What the backend does:

- create: `NewVm` with no adapter and an empty DVD drive, `Attach` (VM Off), the shared declaration check
  (`AAP_NetworkInvalid`), the seed with the declaration's static addressing (`network-config`), `SetSeed`, the VM's
  settings, then `Verify` (every object it writes is a problem; a throw is `AAP_NetworkUntrusted`) and the read-back:
  the provider's `GetVmConfig.Adapters` in the contract's provider shape, judged by `Get-AapHostNetworkAdapterProblems`
  (the guards, mirroring, VLAN, storm limit, legacy ACLs, peers and every extended port ACL: the fixed denies both ways,
  the source pin, no other Allow). The backend no longer relies on `Verify` alone for the port ACLs.
- boot: `Attach` again with the VM Off (the same declaration; none is journaled or kept), the declaration check, `Verify`
  and the read-back, then `Start-VM`; any failure tears the clone down. A VM found already running (a crash after its
  start) is verified instead.
- a running clone: `Verify` at most every 30 s per reservation on every step (Consumer obligations 3, by polling); a
  problem or a throw destroys the clone. Accepted residual: `Verify` only, no read-back, while the VM runs (the module
  has no declaration then, and the backend keeps none); the read-back runs at create and at every boot.
- the seed: the declaration's values go into `network-config` unquoted, which is safe because the shared check accepts
  canonical IPv4 only; the backend checks again at that site that each is a dotted IPv4 address (the prefix length
  digits) and throws `AAP_NetworkInvalid` otherwise.
- destroy: `Remove-VM`, then `Detach`, on every attempt; a `Detach` that throws holds the slot (`teardown_failed`).
- the provider refuses to read adapters back when an `aap-guest-<id>` adapter sits on a VM other than the one it names,
  when such a name appears twice on the host, or when the clone's adapter has another name (net-sec round 7; the
  module's `Verify` throws on the same).

Guests get no DHCP or DNS service on the switch: the "Linux clones need DHCP and DNS" request is withdrawn (the
declaration's static addressing replaces it).

## P02.1: what the lab must show for this backend

- **Channel**: `ssh.exe -F <clone>\ssh\ssh_config -T aap-guest` through `hvsock-relay.ps1` reaches the agent over vsock
  5222 with the clone's network adapter disconnected; Win32-OpenSSH runs the quoted ProxyCommand without a shell and
  accepts forward-slash paths in `IdentityFile`/`UserKnownHostsFile`/`GlobalKnownHostsFile`; the key file's inherited
  SYSTEM/Administrators ACL passes ssh.exe's permission check; `-F` keeps the operator's `~\.ssh` out.
- **Relay**: the PowerShell `AapHvEndPoint` class connects an AF_HYPERV socket on Windows PowerShell 5.1 (the class's
  virtual `AddressFamily` and `Serialize` are what `Socket.Connect` calls); the pump ends when the guest closes and
  half-closes when ssh.exe closes stdin; the job object kills the relay with ssh.exe. Win32-OpenSSH starts the
  ProxyCommand with its own environment, so `AAP_RELAY_JOB` reaches the relay (otherwise every relay exits 4 and no clone
  passes its first probe), and the relay's in-memory P/Invoke type (Reflection.Emit, no compiler) runs under the host's
  antivirus; count how often a relay is started before ssh.exe's job assignment (each is one failed command).
- **Host key**: the KVP guest-to-host item appears in `Msvm_KvpExchangeComponent.GuestExchangeItems` as the provider reads
  it; a changed host key is refused by ssh.exe (exit 255, a failed guest); the key published before any job ran is the
  one sshd presents.
- **Network**: cloud-init NoCloud on the P07 image applies `network-config` version 2 (static address, default route
  and resolvers, matched by driver `hv_netvsc`, `link-local: []`) and no DHCP client keeps asking; `Set-VMDvdDrive`
  on the empty drive of an Off VM (`SetSeed`) is what the first boot reads; the provider's adapter read-back
  (`VlanSetting.OperationMode`, `StormLimit`, the extended ACL fields as text, `Get-VMNetworkAdapter -All` with
  stopped VMs) is what Hyper-V shows; the adapter the module creates is named `aap-guest-<vm id>`.
- **Seed**: IMAPI2's result stream fills every block `AapLinIsoWriter` asks for (it reports each read's count, and the
  writer fails the image on a short one), and `BlockSize * TotalBlocks` is the file's size; the image labelled `CIDATA`
  is read by cloud-init NoCloud on the P07 image; `users` with only `runner` creates no uid 1000; root's
  `authorized_keys` from `write_files` survives `cc_ssh` with `disable_root: false`; `Set-VMDvdDrive -Path $null` ejects
  it from a running generation 2 VM.
- **Secret oracle (lab step 5)**: add the clone's private key (its marker) to the search: host PowerShell 4103/4104,
  transcripts, the supervisor's logs and status, the journal, every folder after teardown (the key must be gone with the
  clone folder), and the guest.
- **Budgets**: the clone cap must hold the job's whole root file system growth (no scratch disk); measure with real jobs.
- **Mount options and read-ahead**: confirm on the running clone that the root file system's options and `read_ahead_kb`
  are the image's (the backend adds none), for the P24 comparison.
- **Lifetime cap (P11.3)**: `Set-VM -Notes` keeps the compact deadline record byte for byte and `Get-VM` reads it back;
  `Stop-VM -TurnOff -Force` turns a busy Linux guest off with no guest cooperation and the VM is then observed `Off`;
  the registry `PrefetchParameters\BootId` changes at every host boot and never with the wall clock (it is the boot id
  the watchdog, P10.7, must use too); the 90 s bound from deadline to observed Off, with a real job running.

## Coordinator and CI

- Add `tests/backends/linux` to the Pester `Run.Path` in `.github/workflows/ci.yml` (P00-owned line). The suite needs
  `python` on `PATH` and creates junctions with `mklink /J` (no elevation needed). About 3 minutes on pwsh 7 and 5 on
  Windows PowerShell 5.1; the crash tests start about 25 hidden child processes.

## Contract requests and open questions

1. **Lease id, lease outcome and runner start in the journal**: as the Windows twin's request 1, plus the runner start
   (`runner started on the guest`), which this backend needs to know after a restart whether it may ask the guest for
   `status`.
2. **Seq persistence** is a host-side mark file in the clone's ssh folder (blocks of 1000). guest-transport.md's
   Sequence rule allows it (gaps are normal); a contract revision could name it.
3. **Crash between `New-VM` and its record; teardown of a reservation that never got a VM; base re-hash cost**: as the
   Windows twin's requests 2, 4 and 5. The hard VM lifetime cap is implemented (P12 item 8).
4. **KVP for pinning** keeps the Key-Value Pair Exchange integration service on for Linux clones (host-to-guest items are
   never written). If P02.1 rejects it, the fallback is to pin the host key from the first SSH connection made before any
   job ran (the hvsocket endpoint is the VM itself, so there is no network to spoof); that needs a contract revision.
