# Registration broker contract (version 1)

Owner: **P08**. Readers: P10, P11, P14, P15, P16, P26. Schema: [`broker.schema.json`](broker.schema.json)
(`lease_request`, `lease_response`, `release_request`, `release_response`, `status_request`,
`status_response`, `audit`). Fixtures: `fixtures/broker/` (the issued response carries a synthetic
marker, not a credential).

## Placement and invocation (DECIDED)

- The broker is `/usr/local/sbin/aap-runner-broker` inside the existing `aap-runner` distro,
  root 0755, reading `/etc/aap-runner/manager.conf` and `/etc/aap-runner/app.pem` exactly as the
  manager does. The App key never leaves the distro.
- The supervisor calls it through its existing hidden `wsl.exe` path:
  `wsl.exe -d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker`, no further
  arguments. The request is one JSON document on stdin, at most 4096 bytes; the response is one
  JSON document on stdout, at most 20 KiB. Any other output, size or exit code is a refusal.
  Timeout: 60 s per call.
- No socket, port, named pipe or file drop. Guests cannot reach the distro (network rule,
  ARCHITECTURE.md boundary 4), so the only caller is the elevated supervisor.
- The broker stays a one-shot process: it holds GitHub tokens only for one request.
- Availability: the distro and its keep-alive run whenever Linux + Windows >= 1 (owner decision
  2026-10-19), so a VM profile never waits on a stopped distro; see status-settings.md.

## Requests accept nothing attacker-chosen

`lease_request` carries ids, numbers and enums only: `lease_id` (`l-` + 32 hex, from the
supervisor's CSPRNG), `reservation_id`, `lease_generation` (the slot's counter from
allocator.json), `slot`, `profile` (`win25-vs2026-x64` or `ubuntu-24.04-x64`),
`image_generation`, `nonce`, `issued_at`. `release_request` and `status_request` carry only
`lease_id`, `nonce` and `issued_at`; the caller never names a runner id. Unknown fields fail.

The broker derives:

- the runner name, equal to the VM name:
  `aap-<w|l>-<slot>-<lease_generation>-<first 8 hex of reservation_id>`;
- labels and group from a root-only profile table in `manager.conf` (owner decision 2026-10-19):
  `win25-vs2026-x64` registers `self-hosted,Windows,X64,aap-win25-vs2026`, `ubuntu-24.04-x64`
  registers `self-hosted,Linux,X64,aap-ubuntu-24.04`, both in group `aap-crrr`; the legacy pool
  keeps its labels. The group id is resolved by name through the API and cached;
- `work_folder`: the runner default `_work`, never from the request.

## Lease ledger, expiry and replay (DECIDED)

`/var/lib/aap-runner/broker/leases/<lease_id>.json`, root 0600, written before the GitHub call
(`pending`, with the derived runner name) and after it (`issued` with runner id and name, or
`refused`), and closed by a release (`released`). Rules:

- A `lease_id` that already has a ledger file is refused with `replay` for `lease_request`,
  whatever its state.
- `issued_at` more than 300 s from the broker clock: `clock_skew`. A lease must be delivered and
  its runner started before `expires_at`, 10 minutes after issue.
- Stale generation: the broker keeps the highest `lease_generation` seen per **slot**. A request
  with a lower generation for that slot is refused with `stale_generation`.
- Outstanding limit: more than 5 leases not yet `released` (pending or issued) gives `lease_limit`.
  A crash therefore cannot let leases pile up beyond the slot count.
- `release_request` is **mandatory at every teardown**, whatever the reason, including a runner
  that ran its job. The broker resolves the runner id from the ledger; for a lease still `pending`
  after a crash it looks the runner up by its derived name
  (`GET /orgs/{org}/actions/runners?name=<name>`). It deletes the runner
  (`DELETE /orgs/{org}/actions/runners/{id}`) and answers `deregistered`; a 404 or no match is
  `already_gone`. Both close the lease and are accepted as the teardown proof's runner part. Its
  `nonce` must be new for that lease. `retry` means GitHub failed; the slot stays `deleting`.
- `status_request` reports the runner's GitHub `status` (`online`, `offline`) and `busy`, or
  `absent`; the allocator uses it to decide when a heartbeat-quarantined slot may be destroyed.
- The ledger never stores the JIT config, a token, a JWT or a hash of them.

## JIT config delivery (DECIDED mechanism, lab proof CANDIDATE D2)

`POST /orgs/{org}/actions/runners/generate-jitconfig` with `name`, `runner_group_id` and
`labels` (1..100 custom labels). Documented statuses: 201, 404, 409, 422 ("Validation failed, or
the endpoint has been spammed"). The `encoded_jit_config` goes only into the stdout response, then
the guest transport (guest-transport.md), then the runner environment as
`ACTIONS_RUNNER_INPUT_JITCONFIG`. Never argv (`run.sh --jitconfig` is forbidden), never a file,
the inbox, status, an image, a log or evidence. A registration token (`POST .../registration-token`,
"expires after one hour") is not one-use and is not used for VM profiles.

## Audit record

One `audit` line per request in `/var/log/aap-runner/broker-audit.jsonl`, root 0600, rotated at
5 MB with one `.1`. Fields: time, op (`lease`, `release`, `status`, `expire`), lease and
reservation ids, generation, profile, image generation, outcome, reason, runner id and name. The
schema forbids any other field, and `validate.py` rejects secret-shaped field names in it.

## Failure handling

| Case | Result |
|---|---|
| malformed, oversized, unknown field (including a caller-chosen `runner_id`), unknown profile | `refused`/`malformed` or `unknown_profile`; no GitHub call |
| replayed lease id, reused nonce | `refused`/`replay` |
| GitHub 404/409/422/5xx, timeout | `refused`/`github_error` or `rate_limited`; if a runner was created, delete it before answering |
| key unreadable, conf invalid | non-zero exit, no stdout; supervisor treats the broker as unavailable |
| supervisor crashes after `issued` | on restart the lease is spent: `release_request` with that lease id, then a new reservation generation |

## Tests P08 must ship

Expired, replayed, stale-generation (per slot), outstanding-limit, oversized, unknown-field
(including `command`, `path`, `work_folder`, `labels`, `runner_id`), release of a pending lease by
derived name, unavailable broker; a secret-marker test that a synthetic JIT value never appears in
logs, the ledger, audit, status, inbox or evidence. The fixtures cover the shapes: a `command`
field, a `work_folder` path, a caller-chosen `runner_id` on release, an audit record with
`jit_config`, an issued response without material, a refused response with material, a refused
status with runner state, and an unknown profile.
