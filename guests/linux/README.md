# Linux guest bootstrap and agent (P15)

The guest side of a Linux runner clone (profile `ubuntu-24.04`): the management agent the host drives over SSH on vsock
5222, and the first-boot step that turns a fresh clone of the sealed image into the machine a hosted job expects. It is
the catalog's `guest-agent` overlay; P21 installs it into each generation with `install.sh`. Contracts:
[guest-transport.md](../../parity/contracts/guest-transport.md) (revision 2; envelope, offline identity, Linux candidate, runner start),
[broker.md](../../parity/contracts/broker.md) (JIT delivery). What the host side expects of it:
[supervisor/backends/linux/INTEGRATION.md](../../supervisor/backends/linux/INTEGRATION.md), P15; what the image expects:
[images/ubuntu-24.04/INTEGRATION.md](../../images/ubuntu-24.04/INTEGRATION.md), P15. The compile cache it wires is P13's
[guests/cache](../cache/README.md) (its INTEGRATION.md, P15). What other items must wire: [INTEGRATION.md](INTEGRATION.md).

**Status: authored against fakes only.** No VM, sshd, hvsocket, KVP daemon, systemd, Docker or real runner was used; the
tests stub every system command. The transport is CANDIDATE (D2) until the lab proof P02.1 passes.

| File | Installed as | What it is |
|---|---|---|
| `agent.sh` | `/usr/local/libexec/aap-guest/agent`, root 0755 | The agent (no argument: sshd's forced command), `firstboot`, and `launch` (the runner's launcher) |
| `sshd_config` | `/etc/ssh/aap-guest/sshd_config` | The management sshd: root, public key, forced agent, nothing else |
| `units/aap-guest-ssh.socket`, `units/aap-guest-ssh@.service` | `/etc/systemd/system/` | `ListenStream=vsock::5222`, `Accept=yes`; one `sshd -i -f /etc/ssh/aap-guest/sshd_config` per connection |
| `units/aap-guest-firstboot.service` | `/etc/systemd/system/` | `agent firstboot`, once, after `cloud-final.service` |
| `install.sh` | (not installed) | `install.sh [DEST]`: copies the above and makes the `systemctl enable` symlinks |

## The management channel

The seed (P11's `New-AapLinSeed`) gives root one `authorized_keys` line, `restrict,command="/usr/local/libexec/aap-guest/agent"`
with the clone's public key. The management sshd listens only on vsock 5222 and adds `ForceCommand` with the same agent,
`PermitRootLogin forced-commands-only`, ed25519 only, no password, keyboard-interactive, forwarding, tunnel, tty, client
environment, subsystem, banner, MOTD or last-log line (any byte before the reply is hostile to the host). It has no
`Include`, so the image's `sshd_config.d` never applies to it.

Each connection runs the agent once: stdin is the envelope line (a leading UTF-8 BOM is dropped), then exactly
`payload_bytes` bytes; stdout is one `guest_reply` line; exit 0 after every reply, a refusal included. An envelope that
is not exactly the ten `host_cmd` fields with their schema types and patterns, or a line over 1024 bytes, gets no reply
(the host counts a failed guest and sends again with a higher `seq`). Under a lock (`/var/lib/aap-guest/lock`, waited
20 s) the first `probe` binds the offline identity described below. Every command must match its `vm_id`, `reservation_id`
and `lease_generation`; no value is learned from SMBIOS, KVP or the first envelope. The agent then refuses a `seq` not
above the last accepted one (gaps are normal), a nonce it saw, a one-shot class (`deliver_registration`, `start_runner`,
`shutdown`) that already ran, an expired command, or `payload_bytes` other than non-zero for `deliver_registration` and
zero for the rest. Accepted commands move the marks (`seq`, `nonces`, `shots` in `/var/lib/aap-guest`, root 0700) and flush
them (`sync -f`) before work. If a mark cannot be written or flushed the command gets no reply and never runs under an
old sequence or without its one-shot mark. Core dumps are off (`RLIMIT_CORE` 0) from the first statement, in every mode,
before input; failure to set the limit stops there without a reply.

| Command | Answer |
|---|---|
| `probe` | `booting` until first boot finished, then `ready`; `error` with `first boot failed at <step>` when it failed |
| `deliver_registration` | `error` before first boot finished or for a payload that is not base64 of exactly `payload_bytes` bytes; otherwise removes the seed's copies (an `error` if one stays), hands the JIT config to the launcher and answers `registered` |
| `start_runner` | `error` without a delivery; waits up to 45 s for the launcher, then `listening` (or `busy`), or `error`/`failed` with the runner's exit code |
| `status`, `collect` | from the launcher's records: `listening`, `busy` (a `Runner.Worker` process exists), `job_done` (exit 0) or `failed` (another exit, or the launcher gone without a record), with `runner_exit_code`; `collect` adds the cache state to `diag` (`runner exited 0; cache direct`) |
| `shutdown` | powers off in 2 s, `shutting_down` (the backend never sends it) |

**The guest is trusted only until the first job starts.** From then on the job user has passwordless sudo, so a job can
replace the agent, its state or sshd and forge any reply (`busy`, `job_done`, an exit code); the host's authority over a
job comes only from the broker's status of the runner, never from these replies, which the backend checks as hostile
input and uses for display and the summary only.

Accepted residual (security review, low 1): root inside the guest can tamper with the agent's state and replay a command
it once saw over the local vsock socket. That gains nothing outside this VM: the VM is destroyed after its one job, and
the reservation id and nonces are not guessable from outside it.

## Per-clone offline identity (guest-transport revision 2)

`New-AapLinSeed` writes one ignored YAML comment as line 2 of the clone's NoCloud `user-data`, immediately after
`#cloud-config`. Its payload is compact JSON, in this key order:

```text
# aap-guest-identity: {"schema":2,"kind":"guest_identity","vm_id":"6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b","reservation_id":"r-1a2b3c4d000000b1","lease_generation":7,"scratch":null}
```

The UUID and reservation id are lowercase, the generation an integer in 1..999999999. The Linux profile has only its
OS disk: `scratch` must be null and `lsblk -dn -o TYPE` must report exactly one disk. Extra keys, a scratch object,
duplicate JSON keys, schema 1, a wrong type or a malformed marker fail closed. The record carries no host name, host
path, user name, credential or token. It is not a YAML setting, a KVP item or a SMBIOS UUID.

The reader scans `/var/lib/cloud/instances/*/user-data.txt*` and `cloud-config.txt*`, a plain `/var/lib/cloud/instance`
directory if present, and all files below `/var/lib/cloud/seed`. Cloud-init's `instance` alias may use its normal
relative `instances/<id>` or absolute `/var/lib/cloud/instances/<id>` target; only a one-component target under the
plain `instances` directory is accepted, and target directories that are links are refused. Arbitrary links are never
followed. Cloud-init's `/var/lib/cloud/instances/*/obj.pkl` datasource cache is retained as opaque data until cleanup;
the agent never parses it as the identity source, but removes every cache entry and requires absence afterward because
it can retain the original user-data. Text material must be readable, plain ASCII and at most 1 MiB. A marker anywhere
makes that line a candidate; it must start with `# aap-guest-identity: `. Two candidates in one file are refused even if
identical; identical records across cached text files are copies of one record, while conflicting copies are refused.
A merged cloud-config with no marker is normal: cloud-init ignores comments.

1. The **first probe** validates the material and disk inventory, then atomically saves the canonical record as
   `/var/lib/aap-guest/identity.json` (0600, inside root-only state) and flushes it. It never rebinds; the file survives
   separate SSH invocations, agent restarts and guest reboots. A non-probe before binding is refused without binding.
2. **Before cleanup**, every command checks the material still holds exactly the bound record. The first-boot service
   deliberately leaves copies in place so it cannot erase identity before the host's first probe. A mismatched command
   is refused without changing the binding or sequence marks; a later correct command can still proceed.
3. **Delivery cleanup**, before registration is handed to the runner or `registered`/`listening` is answered, deletes the
   seed cache, each text copy and every opaque `obj.pkl`, checks all those locations are absent, then durably records
   `identity.cleaned`. A crash between removal and the cleanup mark fails closed rather than rebinding. A cleanup mark
   with lost binding state also refuses a new binding, even if a valid seed record reappears. The host separately ejects/
   deletes `seed.iso` after `ready`.
4. **After cleanup**, before every command (including replays), any text record or `obj.pkl` cache entry found again,
   identical or not, is a final failure. A malformed, missing, unreadable or changed record before cleanup is final too.
   `identity.failed` persists this terminal state: first-probe input errors answer `error`/`failed`, later violations
   `refused`/`failed`, with only the fixed printable-ASCII diagnostic `identity record invalid`; no input text or path is reflected.

Wire replies remain schema 1. `identity_exchange` schema 2 is test evidence, not a new wire reply: `agent_test.sh`
validates successful replies with the bound record and a reread of actual copies (or their absence after cleanup).
Old agents cannot be identified from their byte-identical replies: `create` must first admit matching catalog and
admin-approved guest-agent revision 2 (image-catalog rule 8), including candidates and rollback generations.

The host tests compare the real writer's output byte-for-byte with `tests/guests/linux/fixtures/seed-user-data.golden`;
the guest tests consume that same fixture. For a direct real-writer-to-real-reader run, render with
`pwsh -File tests/backends/linux/Write-IdentitySeed.ps1 -Output <temporary-user-data>`, then run the Linux suite with
`AAP_SEED_USER_DATA=<that-file> bash tests/guests/linux/agent_test.sh`. No VM, cloud-init daemon or live state is used.


## The registration path

The JIT config exists in four places only, all memory: the agent process (read from its stdin), a pipe to the launcher
(written by `printf`, a builtin, so no command line), the launcher process, and `Runner.Listener`'s environment. The agent
starts the launcher detached in a transient scope, `setsid systemd-run --scope --unit=aap-runner -- /bin/bash <agent>
launch`, so the runner leaves the ssh connection's cgroup; neither side keeps the connection's stdout or the agent's
lock. The launcher records its pid and start time, sets the hosted limits (65536 open files, 16 MiB stack; no core
dumps, as for the agent), replaces its environment with the job's, and runs `setpriv --reuid=runner --regid=runner --init-groups --
/opt/actions-runner/bin/Runner.Listener run` in the runner root with `ACTIONS_RUNNER_INPUT_JITCONFIG` exported to that
child only (guest-transport.md, Runner start: no `run.sh`, no shell, no file). When the runner exits it records the exit
code (`runner.exit`). The runner removes the variable from its own environment block before it starts a job (runner
`CommandSettings`; a lab point below); its initial environment in `/proc` stays readable to the job user, as the runner's
own credential files in its root are: destroying the VM is the control (guest-transport.md).

The job's environment is what a login would get from `/etc/default/locale` and `/etc/environment` (pam_env's
`KEY=VALUE`, one pair of surrounding quotes removed; other lines skipped), plus `HOME=/home/runner`, `USER`, `LOGNAME`,
`SHELL=/bin/bash` and the compile cache's variables; nothing of the agent's or sshd's environment, and no tool path
prepended (the image's `/etc/environment` PATH, as the post-generation scripts left it, is the job's).

## First boot

`aap-guest-firstboot.service` runs `agent firstboot` once per clone. A step that fails stops it and is recorded
(`firstboot.failed`); a first boot found started but not finished (a crash or a reboot) is recorded as `interrupted` and
never resumed: after any job, `/imagegeneration` (mode 777 upstream) may hold planted scripts.

| Step | What it does and checks |
|---|---|
| `host_key` | `/etc/ssh/ssh_host_ed25519_key.pub` must be `ssh-ed25519` with a 68-character key; `hv-kvp-daemon.service` must be active; publishes exactly `ssh-ed25519 <key>` as the guest-to-host KVP item `aap-ssh-host-key-ed25519` (pool 1 record: 512-byte key, 2048-byte value, NUL padded; an earlier record of that key replaced, others kept; the new pool file is written beside it and renamed over it only when every read, copy and write worked and its size is exactly the records it should hold; otherwise the old pool stays) |
| `identity` | `runner` has uid 1001 and home `/home/runner`, is in `adm`, `users`, `docker` and `systemd-journal`, and runs `sudo -n true`; no account has uid 1000 |
| (cleanup) | not a first-boot step: seed copies remain until identity binds at the first probe, then delivery scrubs them before registration |
| `tls` | `make-ssl-cert generate-default-snakeoil --force-overwrite`; both snakeoil files must exist (P07's verification runs the same) |
| `post_generation` | each `*.sh` in `/imagegeneration/post-generation`, through `bash`, in `find`'s order, as root; any failure fails the step after all ran (P07's `run_verify` does the same) |
| `linger` | `loginctl enable-linger runner` |
| `docker` | `systemctl start docker.service`, then it must be active |
| `runner_root` | `/opt/actions-runner/bin/Runner.Listener` exists (the root not a link) and none of `.runner`, `.credentials`, `.credentials_rsaparams`, `.env`, `.path` came with the image; the root becomes the job user's (`chown -R`, links not followed) |
| `cache` | if P13's overlay is installed: `/var/lib/aap-cache` (job user, 0700) and, as the job user from `env -i PATH=/usr/bin:/bin HOME=/home/runner`, `aap-zccache.sh init /usr/local/libexec/aap-guest/cache /var/lib/aap-cache 10737418240`; only `AAP_ZC_STATE`, `RUSTC_WRAPPER`, `CMAKE_C_COMPILER_LAUNCHER` and `CMAKE_CXX_COMPILER_LAUNCHER` with an absolute path reach the runner. No overlay, or any cache failure: every build runs directly, and the clone is still good |

## Decisions taken here (for review)

1. **`deliver_registration` starts the runner.** The JIT config then never rests anywhere between two commands (the
   alternative was a holder process or a file); the answer is `registered` (the backend accepts it), and `start_runner`
   confirms the runner is up. A runner that took its job before `start_runner` was answered is harmless: the host sends it
   at once, and the broker's status is what it trusts.
2. **A transient scope plus `setpriv`, not a unit with `User=`**: nothing systemd stores (a unit file, a transient unit's
   properties, `systemctl show`, the manager environment) ever holds the config. The limits a unit would set are set by
   the launcher instead.
3. **Runner root `/opt/actions-runner`**, the overlay's own folder made the job user's at first boot (no copy). The work
   folder is the broker's fixed `_work`, so `GITHUB_WORKSPACE` is `/opt/actions-runner/_work/<repo>/<repo>`, not hosted's
   `/home/runner/work/<repo>/<repo>` (INTEGRATION.md, P08).
4. **Private cache budget 10 GiB** (`CACHE_BUDGET`), inside the clone cap (no scratch disk on Linux); P22 measures.
5. **No swap file**: hosted shows 3 GiB (Azure's resource disk); the difference stays allowlisted (`hardware.swap_bytes`,
   P05) rather than growing every clone by 3 GiB.
6. **`walinuxagent` stays masked and cloud-init on NoCloud**: first boot touches neither.

## Tests

`tests/guests/linux` (bash on a real Linux; WSL Ubuntu 24.04 or hosted `ubuntu-latest`; needs python3, jq, flock, setsid,
coreutils). Every system command is a stub on a private PATH and every system path sits under a temporary root
(`AAP_SYSROOT`); each reply is checked with `parity/contracts/validate.py` as an exchange with its command, and against the
backend's per-command state table.

| File | Covers |
|---|---|
| `agent_test.sh` | malformed envelopes and the 1024-byte line (no reply), BOM, every refusal, gaps; an unwritable mark (no reply, nothing run, the same command refused afterwards); core dumps off while the agent holds the JIT config; each first-boot step failing closed and reported by probe, an interrupted first boot, a good one (the KVP pool records, the seed copies, post-generation, linger, Docker, the runner root), no second run; delivery before first boot, a non-JIT payload, undeletable seed copies; the JIT config only in the runner's environment (never in a file under the root, a stub's arguments or any `/proc/*/cmdline`), the runner as `runner` in its scope, its limits and exact environment; listening, busy, job_done, failed and a reused pid; the cache's init, environment and variable filter; the sshd, unit and install files; the overlay against P07's image secret-scan rules |
| `agent_mutations.sh` | disables each `# check:` in `guests/linux/*.sh` in turn; every one must make a check of `agent_test.sh` fail (its exit 10); a timeout or any other exit is an ERROR and fails the run |

```bash
bash tests/guests/linux/agent_test.sh
bash tests/guests/linux/agent_mutations.sh
```

The suite checks file modes, so its temp folder must be on a Linux file system (not WSL's `/mnt/c`), and it must run
unprivileged (it makes a state file unwritable to the agent) on a host that allows a core limit of 1024 blocks.

## What is not done

- No real run: sshd over vsock, `hv_kvp_daemon` serving the pool-1 record, `systemd-run --scope` from a forced command,
  the runner's removal of its input variable and the whole first boot on the P07 image are lab points (INTEGRATION.md,
  P02.1).
- `bind_cache` (a shared cache root) is not in guest-transport.md, so the agent has no such command and shared roots stay
  off (guests/cache/INTEGRATION.md).
