# Evidence and cleanup contract (version 1)

Owners: **P05** (evidence harness) and **P00** (cleanup receipts; P00.1 hardening). Every item
records its results with the evidence shape; P24 certificates, P26 review and P28 closure consume
both. Schemas: [`evidence-bundle.schema.json`](evidence-bundle.schema.json),
[`cleanup-receipt.schema.json`](cleanup-receipt.schema.json). Lifecycle and deletion rules:
[docs/parity/WORKTREES.md](../../docs/parity/WORKTREES.md). Oracles: [docs/parity/ACCEPTANCE.md](../../docs/parity/ACCEPTANCE.md).

## Evidence record (DECIDED)

One JSON record per accepted result, with the fields ACCEPTANCE.md lists: item, contract revision,
exact head SHA, pinned action SHAs, reference image (hosted label and version) and candidate
generation with base hash, inputs manifest hash, fixture id, OS and tool versions, command, start
and end, exit status, the oracle (`expected` success or failure, `observed`), result, sanitized
artifact hashes and the independent verifier.

- `pass` means observed equals expected. A deliberate failure observed as failure is a pass.
- An observed success with an expected success must have `exit_status` 0.
- `skipped`, `blocked`, `timeout` and `unknown` are reported as such and are never a pass.
- No raw environment dump, no log body, no field whose name looks like a token, secret, password,
  key, credential or JIT config, and no value shaped like a GitHub token or a PEM private key
  (`validate.py` scans every contract document for both). Artifacts are referenced by hash.

## Cleanup receipt (DECIDED: both shapes in use are accepted)

Two shapes exist on 2026-10-19 and the schema accepts exactly these:

1. **Automated**, schema 1, written by `New-PwReceipt` in `tools/parity-work/ParityWork.psm1`:
   item, attempt, final reviewed head, PR URL, merge SHA, base and origin SHAs, merge comparison,
   implementer, tester, reviewers, protected state with sentinels, disposed resources with observed
   absence, retained assets with owner/retention/expiry/size/hash, process observations, released
   leases, verifier, times.
2. **Manual** (`kind` `manual-cleanup` or `manual-bootstrap-cleanup`), as the coordinator wrote
   the P00, P01 and P20.0 receipts: item, attempt, written time, cleanup actor, verifier, branch,
   base SHA, reviewed head, PR, merge (method, merge SHA, origin after, comparison), disposed
   (resource, how, observed absence), retained, lab VMs, released leases, and
   `"secrets": "none recorded"`.

Both require full 40-hex SHAs, a verifier that is not the implementer or cleanup actor, and
`observed_absent: true` for every disposed resource. Lab VMs from guest-transport proofs are listed
by VM id and must be observed absent.

`python -I parity/contracts/validate.py cleanup-receipt <file>...` checks real receipts. Run on
2026-10-19 against the evidence store: P00 and P20.0 pass; **P01 fails** because its
`reviewed_head` is `"99d2734 (worker fixes after review at b0407c2)"`, a short SHA with prose.
That receipt belongs to the coordinator; this contract does not edit it.

## Negative fixtures

Evidence: pass with a mismatched oracle, a success with a non-zero exit status, skipped reported as pass, a token-named field, a raw
`env` dump, a short head SHA. Receipt: self-verified, absence not observed, missing merge SHA, a
recorded secret, a protected path that vanished.
