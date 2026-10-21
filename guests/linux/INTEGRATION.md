# Linux guest bootstrap: integration requests (ledger item P15)

P15 owns only `guests/linux/**` and `tests/guests/linux/**`. Nothing below is wired into an image, the catalog or CI yet.
How the agent works: [README.md](README.md).

## P21: image composition

1. Install the overlay into each `ubuntu-24.04-x64` generation as root: `bash guests/linux/install.sh` (or
   `install.sh <root>`), from the same commit the catalog records for the `guest-agent` overlay.
2. The `actions-runner` overlay: the pinned release extracted to **`/opt/actions-runner`** (root-owned is fine; first boot
   makes it the job user's), with `bin/Runner.Listener` and no `.runner`, `.credentials`, `.credentials_rsaparams`,
   `.env` or `.path` (first boot refuses a root that has any). Never run `config.sh` in the image.
3. The cache overlay (P13): `aap-zccache.sh install ... /usr/local/libexec/aap-guest/cache ...` as P13's INTEGRATION.md
   says; the agent looks for `/usr/local/libexec/aap-guest/cache/aap-zccache.sh` and runs `init` only if it is there.
4. The image must ship and enable `hv-kvp-daemon.service` (Ubuntu's `linux-cloud-tools`, matching the `linux-azure`
   kernel), `jq`, `setpriv` and `runuser` (util-linux), `flock`, `make-ssl-cert` (`ssl-cert`) and `systemd-run`; first
   boot fails at `host_key` without an active KVP daemon.
5. Re-run P07's secret scan on the final overlaid image: the overlay holds no key or token (the suite checks it against
   the scan's content and file-name rules), and the runner overlay must not bring registration material.

## P07: image builder

- `run_verify` (`images/ubuntu-24.04/guest/aap-agent.sh`) and this agent's `post_generation` step run the same scripts the
  same way (each `*.sh` through `bash`, `find`'s order, any failure fails); keep the two in step, as for the snakeoil step.

## P11: Linux backend

- Nothing new: the agent implements the backend's P15 list. Two notes for its README ("What is not done" says the agent
  does not exist; it does now, unrun): `deliver_registration` answers `registered` and starts the runner at once, and
  `start_runner` answers `listening` or `busy` once the runner is up (both in the backend's state table).

## P08: broker (work folder parity)

- The JIT runner's work folder is the broker's fixed `_work` (broker.md), so a job sees `GITHUB_WORKSPACE`
  `/opt/actions-runner/_work/<repo>/<repo>` and `RUNNER_TEMP` `/opt/actions-runner/_work/_temp`, where hosted shows
  `/home/runner/work/...`. Exact parity needs `work_folder` `/home/runner/work` in `generate-jitconfig` (still fixed by the
  broker, never from a request): a broker.md revision. Until then P24 decides the difference.

## P02.1: what the lab must show for this agent

- **vm_id.** The agent reads its own id from `/sys/class/dmi/id/product_uuid` (backend INTEGRATION.md, P15). On Hyper-V
  that is the VM's SMBIOS (BIOS) GUID, which is not necessarily the VM id `Get-VM` reports. If they differ, every command is
  refused (fail closed: no clone gets past its first probe). The fallback is the host-to-guest intrinsic KVP item
  `VirtualMachineId` (pool 3, written by Hyper-V, not by the host's code): a contract wording change in guest-transport.md
  and the backend's INTEGRATION.md, and a one-line change in `own_vm_id`.
- **Host key.** The pool-1 record the agent writes appears in `Msvm_KvpExchangeComponent.GuestExchangeItems` as
  `aap-ssh-host-key-ed25519` with exactly `ssh-ed25519 <key>`; `hv_kvp_daemon` picks up a pool file
  replaced by a rename (a new inode: the daemon must reopen it by name; its `fcntl` lock was on the old one).
- **Channel.** `aap-guest-ssh.socket` accepts on vsock 5222 under Hyper-V's vsock transport; `sshd -i` with this
  configuration authenticates the seed's key for root and runs the agent with nothing on stdout before the reply (PAM's
  session modules included).
- **Runner start.** `systemd-run --scope` from the forced command moves the launcher out of the connection's unit and the
  runner survives the connection's end; `setpriv --init-groups` gives the job user its groups; the runner removes
  `ACTIONS_RUNNER_INPUT_JITCONFIG` from the environment its job processes inherit (lab step 5: the marker absent from
  every job step's environment, journald and files); the runner's console output goes nowhere (its `_diag` has the logs).
- **Crash dumps.** `RLIMIT_CORE` 0 for the agent, the launcher and the runner, set before any input is read
  (`PR_SET_DUMPABLE` cannot be set from bash); with Ubuntu's `apport` (a pipe in `core_pattern`) confirm no crash
  file with the runner's memory is written, or disable apport in the image (P21).
- **First boot on the P07 image**: every step passes, Docker answers, PostgreSQL starts with the new snakeoil pair, and
  `probe` answers `ready` within the backend's 15-minute boot deadline.

## Coordinator (CI)

- On hosted `ubuntu-latest`: `bash tests/guests/linux/agent_test.sh` (about 10 s; python3, jq, flock, setsid, coreutils).
- shellcheck 0.11.0 at `-S warning` over `guests/linux/*.sh` and `tests/guests/linux/*.sh` (clean in WSL Ubuntu-24.04).
- `bash tests/guests/linux/agent_mutations.sh` is the mutation run (33 checks, about 5 minutes); not needed on every push.
