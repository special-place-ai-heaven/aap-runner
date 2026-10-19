# Registration broker contract (version 1)

Owner: **P08**. Readers: P10, P11, P14, P15, P16, P26. Schema: [`broker.schema.json`](broker.schema.json)
(`lease_request`, `lease_response`, `release_request`, `release_response`, `audit`).
Fixtures: `fixtures/broker/` (the issued response carries a synthetic marker, not a credential).

## Placement and invocation (DECIDED)

- The broker is `/usr/local/sbin/aap-runner-broker` inside the existing `aap-runner` distro,
  root 0755, reading `/etc/aap-runner/manager.conf` and `/etc/aap-runner/app.pem` exactly as the
  manager does. The App key never leaves the distro.
- The supervisor calls it through its existing hidden `wsl.exe` path:
  `wsl.exe -d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker`, no further
  arguments. The request is one JSON document on stdin, at most 4096 bytes; the response is one
  JSON document on stdout, at most 20 KiB. Any other output, size or exit code is a refusal.
- No socket, port, named pipe or file drop. Guests cannot reach the distro (network rule,
  ARCHITECTURE.md boundary 4), so the only caller is the elevated supervisor.
- The broker stays a one-shot process: it holds GitHub tokens only for one request.

## Requests accept nothing attacker-chosen

`lease_request` carries ids, numbers and enums only: `lease_id` (`l-` + 32 hex, from the
supervisor's CSPRNG), `reservation_id`, `lease_generation`, `slot`, `profile`
(`win25-vs2026-x64` or `ubuntu-24.04-x64`), `image_generation`, `nonce`, `issued_at`.
Unknown fields fail. The broker derives:

- runner name `aap-<w|l>-<slot>-<lease_generation>-<first 8 hex of lease_id>`;
- labels and runner group from a root-only profile table in `manager.conf` (OWNER: the label set,
  see README open decisions); the group id is resolved by name through the API and cached;
- `work_folder`: the runner default `_work`, never from the request.

## Lease ledger, expiry and replay (DECIDED)

`/var/lib/aap-runner/broker/leases/<lease_id>.json`, root 0600, written before the GitHub call
(`pending`) and after it (`issued` with runner id and name, or `refused`). Rules:

- A `lease_id` that already has a ledger file is refused with `replay`, whatever its state.
- `issued_at` more than 300 s from the broker clock: `clock_skew`. A lease expires 10 minutes
  after issue (`expires_at`); the supervisor must deliver and start the runner before that or
  send `release_request`.
- A `lease_generation` lower than the highest seen for that `reservation_id`: `stale_generation`.
- More than 5 leases in state `issued` without a release or an observed job end: `lease_limit`.
- `release_request` deletes the runner by id (`DELETE /orgs/{org}/actions/runners/{id}`, 404 is
  `already_gone`) and closes the ledger entry. Its `nonce` must be new for that lease.
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
5 MB with one `.1`. Fields: time, op, lease and reservation ids, generation, profile, image
generation, outcome, reason, runner id and name. The schema forbids any other field, and
`validate.py` rejects secret-shaped field names in it.

## Failure handling

| Case | Result |
|---|---|
| malformed, oversized, unknown field, unknown profile | `refused`/`malformed` or `unknown_profile`; no GitHub call |
| replayed lease id, reused nonce | `refused`/`replay` |
| GitHub 404/409/422/5xx, timeout | `refused`/`github_error` or `rate_limited`; if a runner was created, delete it before answering |
| key unreadable, conf invalid | non-zero exit, no stdout; supervisor treats the broker as unavailable |
| supervisor crashes after `issued` | on restart the lease is spent: `release_request` for its runner, new lease for a new generation |

## Tests P08 must ship

Expired, replayed, stale-generation, oversized, unknown-field (including `command`, `path`,
`work_folder`, `labels`), cross-reservation lease reuse, unavailable broker; secret-marker test
that a synthetic JIT value never appears in logs, the ledger, audit, status, inbox or evidence.
The fixtures here cover the shapes: a `command` field, a `work_folder` path, an audit record with
`jit_config`, an issued response without material, a refused response with material, and an
unknown profile.
