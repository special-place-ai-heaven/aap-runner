# Registration broker: integration (ledger item P08)

Contract: [`parity/contracts/broker.md`](../../parity/contracts/broker.md) (version 1). P08 ships the
two ends of it and leaves every shared file to its owner. This page lists what each owner has to
wire, and where P08 reads the frozen contract more strictly than its text.

| File | What it is |
|---|---|
| `distro/worker-auth.sh` | The broker. Installed in the `aap-runner` distro as `/usr/local/sbin/aap-runner-broker` |
| `supervisor/broker/aap-broker.psm1` | The supervisor's client: builds requests, runs the hidden `wsl.exe`, checks replies |
| `tests/worker_auth_test.sh` | Bash suite (Linux only: `flock`, `/proc`, `jq`, `openssl`, `python3`) |
| `tests/broker/*.Tests.ps1` | Pester 5 suite by topic, Windows PowerShell 5.1 and PowerShell 7 (see `tests/broker/README.md`) |

## Distro side (P16 owns `bootstrap.sh`, `manager.sh`, `staging.sha256`, `README.md`; P19 the installer)

1. **Install.** In `bootstrap.sh`'s install step, beside the manager:
   `copy_staged worker-auth.sh /usr/local/sbin/aap-runner-broker`, then mode `0755` and owner
   `root:root` (the same `chmod 755` and `chown root:root` lines as `aap-runner-manager`). The
   broker sources the installed manager from its own directory, so it must sit in
   `/usr/local/sbin` beside `aap-runner-manager` and `labels.sh`.
2. **Stage.** Add `worker-auth.sh` to the `cp` list in `bootstrap.sh`'s `outside()` and to
   `distro/staging.sha256` (`sha256sum distro/worker-auth.sh`, two spaces, `worker-auth.sh`);
   `bootstrap.sh --self-check` checks every listed file. P19: the installer's upgrade path copies
   the same file.
3. **Nothing else to create.** On first run the broker creates `/var/lib/aap-runner/broker/`
   (`leases/`, `open/`, `slots/`, `lock`, `group-id`; root `0700`/`0600`) and
   `/var/log/aap-runner/broker-audit.jsonl` (root `0600`, rotated at 5 MB to one `.1`). No unit,
   timer, socket, listener or sudoers entry: the supervisor reaches root through
   `wsl.exe -u root`.
4. **What the manager must keep.** The broker reuses the manager's App code instead of a second
   JWT signer. It sources the installed manager and calls `load_config`, `check_key`,
   `mint_installation_token`, `auth_header` and `now_s`, and reads `AAP_GITHUB_ORG` and
   `AAP_RUNNER_GROUP`. `manager.sh` must stay sourceable without side effects (its
   `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard) and keep those names and behaviours. The broker
   sets `CONFIG_PATH=/etc/aap-runner/manager.conf` after sourcing, so `AAP_MANAGER_CONF` never
   redirects it. `tests/worker_auth_test.sh` sources the repository's `manager.sh` through the
   broker, so a rename fails CI.
5. **Profile table (contract wording).** broker.md places the labels and group in "a root-only
   profile table in `manager.conf`". `manager.sh` refuses unknown `manager.conf` keys, so such a
   table there would stop the manager. Until P16 decides otherwise, the group is
   `manager.conf`'s `AAP_RUNNER_GROUP` (which `load_config` already forces to `aap-crrr`). The
   labels are a fixed table in the root-owned broker: `win25-vs2026-x64` registers
   `self-hosted,Windows,X64,aap-win25-vs2026` and `ubuntu-24.04-x64` registers
   `self-hosted,Linux,X64,aap-ubuntu-24.04`, exactly the owner's decision. If the owner wants
   them configurable, P16 adds keys to `manager.sh`'s allow-list and the broker reads them.
6. **Threat model.** The `distro/README.md` row correction from the contract (any operator
   process reaches the distro as root; the broker's rules are integrity controls, not access
   control) stays a P16 todo.

## Supervisor side (P12 integrates; P10 and P11 call it)

Import it from the supervisor folder (Administrators-only), next to the supervisor script; the
installer copies `supervisor\broker\` with it:

```powershell
Import-Module (Join-Path $PSScriptRoot 'broker\aap-broker.psm1')
```

Every call starts exactly this child, hidden, with `WSL_UTF8=1` and without `WSLENV`. It writes
the request to stdin, waits at most 60 s, reads at most 20 KiB of stdout, and drains and drops
stderr:

```text
C:\Windows\System32\wsl.exe -d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker
```

`-Distro` (default `aap-runner`) is the only part a caller can change, and it must match the
supervisor's distro-name pattern. `-Invoker` replaces the process for tests only.

| Function | Use |
|---|---|
| `New-AapBrokerLeaseId` | A new `l-` + 32 hex lease id from the CSPRNG |
| `Invoke-AapBrokerLease` | `-LeaseId -ReservationId -LeaseGeneration -Slot -RunnerProfile -ImageGeneration`. Outcome `issued` (with `RunnerId`, `RunnerName`, `ExpiresAt`, `JitConfig`), `refused` (`Reason`), `unavailable` (`ExitCode`; `$null` on timeout), `bad_reply` |
| `Invoke-AapBrokerRelease` | `-LeaseId`. Outcome `deregistered`, `already_gone`, `retry`, `refused`, `unavailable`, `bad_reply` |
| `Invoke-AapBrokerStatus` | `-LeaseId`. Outcome `ok` (with `RunnerStatus` `online`/`offline`/`absent` and `RunnerBusy`), `refused`, `unavailable`, `bad_reply` |
| `Test-AapBrokerDocument`, `ConvertFrom-AapBrokerJson` | The contract check and strict parser the client uses, for other owners' tests |

`JitConfig` is an object whose only property is `Length`, so it formats, serializes and logs as
nothing else. `$r.JitConfig.WriteTo($stream)` writes the JIT config's ASCII bytes to a stream
(the guest transport child's stdin); `$r.JitConfig.Clear()` zeroes them. It never becomes a
string, a SecureString or a file.

Rules for the callers:

1. Persist the lease id (the journal's intent record) **before** `Invoke-AapBrokerLease`. Every
   teardown releases it, whatever the lease call returned, including `unavailable` and
   `bad_reply`.
2. Only `issued` registers a runner. Call `JitConfig.WriteTo` inside the guest-transport call that
   writes the payload to the transport child's stdin (guest-transport.md), before `ExpiresAt`,
   then `JitConfig.Clear()`. Never turn it into a string, never log it, never write it to a file,
   status or the inbox.
3. Any other lease outcome means no registration: the slot goes to `deleting`. A new attempt
   needs a new lease id **and** a new slot generation (see "Stricter readings" below).
4. Release: `deregistered` and `already_gone` close the lease and are the teardown proof's runner
   part. `retry` means GitHub failed: keep `deleting` and call again later (each call sends a new
   nonce). `refused`/`not_found` means the broker has no record of the lease id, so it never
   created a runner under it. If that lease call is still waiting on the broker's lock it can
   still create one; the broker never delivers that runner, and the sweep deletes it after
   `expires_at` (GitHub reports it offline and idle).
5. Status is read-only, for the heartbeat-quarantine rule in allocator.md: destroy only on
   `offline` or `absent` with `RunnerBusy` false.
6. Log only `Outcome`, `Reason` and `ExitCode`. The broker's stdout and stderr never reach a log.
   A result object prints the JIT config as `@{Length=N}`, and `ConvertTo-Json` and
   `Export-Clixml` write only that length.
7. The Windows and WSL clocks must agree within 300 s; otherwise every request is
   `clock_skew` (a WSL clock that lags after host sleep shows up here).

## CI (owner of `.github/workflows/ci.yml`)

Add `tests/broker` to the Pester run: `$c.Run.Path = @('supervisor', 'tests/parity-work', 'tests/broker')`.
`tests/worker_auth_test.sh` already runs from `tests/run.sh` on `ubuntu-latest`.

## Stricter readings of the frozen contract (for the coordinator and P02)

- **Equal generation is stale.** broker.md refuses a lower `lease_generation` per slot; the broker
  also refuses an equal one. One lease per slot generation keeps the derived runner name unique
  per lease, so a pending lease's by-name lookup can never reach another lease's runner. Every
  documented retry already takes a new reservation generation. If the allocator's slot counters
  ever restart from 1, remove `/var/lib/aap-runner/broker/slots/*` (as root, with no VM runner
  alive).
- **`expired` is never sent.** The contract defines no case for it: an old request is
  `clock_skew`, and an expired lease is swept. Clients still accept it as a refusal.
- **No response without a lease id.** Stdin over 4096 bytes, not exactly one JSON object, or
  without a request kind and a valid `lease_id`: exit 2, nothing on stdout, no audit line. No
  schema-valid response or audit record can name an unknown lease. With a kind and a lease id,
  every other defect is `refused`/`malformed` or `unknown_profile`. Malformed requests make no
  GitHub call and are not swept for.
- **Pre-GitHub refusals spend the lease id.** `clock_skew`, `stale_generation` and `lease_limit`
  write a closed `refused` ledger file through the same `O_CREAT|O_EXCL` create, so the id is
  spent like any other.
- **An uncertain create stays open.** When GitHub may have created the runner (a timeout, a 5xx,
  an unusable 201), the broker deletes it before answering. If that delete or lookup also fails,
  the lease stays `pending` and open, so the release or the sweep removes it by name.
- **Absent runners close in the sweep.** Past `expires_at`, a lease whose runner GitHub no longer
  lists is closed (`already_gone`), so a lost lease id cannot hold the outstanding limit forever.
  Busy or online runners are never touched.
- **Image generation matches the profile.** A lease request whose `image_generation` does not
  start with its `profile` is `malformed` (image-catalog.md's rule).
- **Client checks validate.py does not make.** A `release_response` whose result and reason
  disagree, a `status_response` `ok` without runner state, duplicate JSON keys, any backslash or
  non-ASCII byte, and a reply that does not echo the request's lease id and derived runner name
  are `bad_reply`. The client's parser also refuses `\uXXXX` escapes; no broker document needs
  one.
- **validate.py finding.** Its patterns use `$` with `re.search`, which also matches before a
  trailing newline, so `"l-<32 hex>\n"` passes validate.py. The broker (printable ASCII only) and
  the client (`\z`) refuse it. `re.fullmatch` would close it in validate.py.

## Notes from building it

- Git Bash cannot run `tests/worker_auth_test.sh` (no `flock`); it runs in CI and in WSL Ubuntu.
- On the owner's machine, Malwarebytes quarantined an early draft of the Pester file (and the
  scratch launcher that ran it) as `RiskWare.ObfuscatedPowershell` during an AMSI scan. That
  draft built `-EncodedCommand` children and hand-concatenated JSON. The committed module and
  tests use no SecureString or BSTR marshaling, char-code strings, base64, `-EncodedCommand` or
  `Invoke-Expression`. The module and the Pester suite were run from a copy outside the
  allow-listed `aap-runner-work\parity` folder, on both hosts, with no detection. Keep new
  PowerShell in that style: an installed module that trips the heuristic would be quarantined
  from the supervisor folder. The patterns to avoid and how to check a file are in
  `tests/broker/README.md`.
