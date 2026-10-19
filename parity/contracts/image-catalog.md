# Image catalog contract (version 1)

Owners: **P21** (assembly, catalog writer) and **P25** (promotion, rollback, retention).
Readers: P06, P07, P10, P11, P12, P19, P20, P24. Schema: [`image-catalog.schema.json`](image-catalog.schema.json).
Fixtures: `fixtures/image-catalog/` (artifact and overlay hashes there are synthetic; the baseline
commits, image versions and inventory hashes are the real P01 values).

## Location

`<image_root>\catalog.json` beside `<image_root>\images\`, Administrators/SYSTEM only, written by
atomic rename with `revision` + 1. Base disks are read-only for everyone after sealing.

## Generation identity (DECIDED)

`<profile>/<image_version>-aap.<n>`: `win25-vs2026-x64/20261007.264.1-aap.1`,
`ubuntu-24.04-x64/20261012.334.1-aap.1`. `image_version` is the hosted release the generation
reproduces; `aap.<n>` counts AAP rebuilds of it. An id is never reused for different bytes.

Each generation records:

- `baseline`: the P01 build commit and image version plus the profile's `inventory.json` path and
  SHA-256. Values at P02: Windows `aee0669dd04510a11756664eb77f5630debabed3`, `20261007.264.1`,
  inventory `cf842a07fd309da0100d955383883f9423bb2b7524e78bd33a67ecdcfc953f25`; Ubuntu
  `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe`, `20261012.334.1`, inventory
  `48608655281529b27f298ea92cc8ad63e52f847fa2fb8b03d1e0ddd5e2a192ed`.
- `artifacts`: every file with role, relative path under `images/`, bytes, SHA-256.
- `overlays`: guest agent, actions-runner, zccache, cache config, each with version and hash.
- `provenance`: building item, builder commit, the P03 inputs manifest hash, build time.
- `secret_scan`: result and evidence for "no credential, token, key or registration material in
  the sealed image".
- `certification`: the P24 certificate path once issued; `approved_by`.
- `retention`: owner (`P21`, `P25` or the owner), purpose, expiry.

## States and promotion (DECIDED)

`candidate -> approved -> active -> retired`, any of them `-> quarantined`. Diagram:
ARCHITECTURE.md section 6.

1. `candidate`: sealed, hashed, secret scan recorded. Bootable only for certification runs.
2. `approved` needs a certificate, an approver and a clean secret scan; a hash recheck of every
   artifact precedes the transition.
3. `active`: one per profile. Promotion is one atomic catalog write that sets the profile's
   `active` pointer and moves the previous active to `retired` and the `rollback` pointer. New
   admissions use the new active; running reservations keep their generation (allocator records it).
4. `retired`: kept as the single rollback generation (default 1, budget field
   `rollback_retained_generations`). Rollback is the same atomic switch in reverse.
5. `quarantined`: never re-activated; a fix is a new `aap.<n>`. Kept until its evidence is copied.
6. A create re-hashes the base (or verifies a hash recorded with a read-only, unchanged file
   identity; the P21 implementation picks one and proves tamper detection).

## Owners and retention

Product images, the retained rollback generation and their evidence are accounted assets with a
named owner, size and expiry (WORKTREES.md, "Cleanup sequence" step 1). Disposable build disks,
installers and clones are not catalog content and are cleaned through P00 manifests.

## Negative fixtures

An active generation without a certificate, two active generations, an active pointer naming a
quarantined generation, a short hash, an artifact path that escapes `images/`, an active
generation whose secret scan found something.
