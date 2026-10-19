# Image catalog contract (version 1)

Owners: **P21** (assembly, catalog writer) and **P25** (promotion, rollback, retention).
Readers: P06, P07, P10, P11, P12, P19, P20, P24. Schema: [`image-catalog.schema.json`](image-catalog.schema.json).
Fixtures: `fixtures/image-catalog/` (artifact and overlay hashes there are synthetic; the baseline
commits, image versions and inventory hashes are the real P01 values).

## Location

`D:\aap-runner\images\catalog.json` (owner decision 2026-10-19), beside one folder per
generation, `base\<profile>\<generation>\`, which never moves. Rollback is catalog state only.
Clones and scratch (`clones\`, `scratch\`) are per-reservation disposables, not catalog content. Administrators/SYSTEM only, written by
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
- `artifacts`: every file with role, relative path under `base/<generation_id>/`, bytes, SHA-256.
- `overlays`: guest agent, actions-runner, zccache, cache config, each with version and hash.
- `provenance`: building item, builder commit, the P03 inputs manifest hash, build time.
- `secret_scan`: result and evidence (`evidence_ref` under `evidence/`, required unless the
  result is `not_run`) for "no credential, token, key or registration material in the sealed
  image". Scan targets at minimum: PEM blocks; `ghs_`, `ghp_`, `gho_`, `ghu_`, `ghr_` and
  `github_pat_` shapes; runner `.credentials*` and `.runner` files; `Panther` and `unattend*.xml`;
  LSA `DefaultPassword` and autologon registry values; SSH host keys and `authorized_keys`;
  cloud-init seeds and instance data; shell and PowerShell history (including PSReadLine); the
  build user's password and any build-time credential; the synthetic lab marker.
- `certification`: the P24 certificate path once issued; `approved_by`.
- `retention`: owner (`P21`, `P25` or the owner), purpose, expiry.

## States and promotion (DECIDED)

`candidate -> approved -> active -> retired`, any of them `-> quarantined`. Diagram:
ARCHITECTURE.md section 6.

1. `candidate`: sealed, hashed, secret scan recorded. Bootable only for certification runs;
   P24 certifies the candidate, which is then approved (certification never needs `approved`).
2. `approved` needs a certificate, an approver and a clean secret scan; a hash recheck of every
   artifact precedes the transition.
3. `active`: one per profile. Promotion is one atomic catalog write that sets the profile's
   `active` pointer and moves the previous active to `retired` and the `rollback` pointer. New
   admissions use the new active; running reservations keep their generation (allocator records it).
4. `retired`: files stay in `base\<profile>\<generation>\`; kept as the single rollback generation (default 1, budget field
   `rollback_retained_generations`). Rollback is the same atomic switch in reverse.
5. `quarantined`: never re-activated; a fix is a new `aap.<n>`. Kept until its evidence is copied.
   Image root protection (owner, ACL, reparse, ancestors) is ARCHITECTURE.md section 3.
6. Every `create` re-hashes the base and compares it with the hash pinned **outside** the image
   root: the P24 certificate pins every artifact hash, and the supervisor keeps an admin-only copy
   in `C:\ProgramData\aap-runner\capacity\approved-images.json`. The catalog's own hashes are
   not trusted alone, and there is no "unchanged file identity" shortcut.
7. The catalog has a `scope`: `lab` (a disposable lab catalog) or `live` (the owner's
   installation). In a `live` catalog an `active` generation needs the owner's approval record
   (`live_activation`, gate D5); `validate.py` rejects it without one. A `lab` catalog may activate
   without it.
   The live supervisor refuses, and admits nothing from, a catalog at `D:\aap-runner\images` whose scope is not `live`. Lab catalogs never live under the live image root. A catalog at that path that says `lab` (or anything but `live`) disables the VM profiles, with the reason in status. Defense in depth: each entry in the admin-only `C:\ProgramData\aap-runner\capacity\approved-images.json` pins the generation's artifact hashes **and** carries the reference to the owner's `live_activation` record; the live supervisor admits an `active` generation only when the catalog and that entry both have it. (Supervisor rules for P12/P21.)

## Evaluation media (owner decision 2026-10-19)

The Windows golden image is built from a Windows Server 2025 Evaluation ISO (180-day), which is
sufficient to prove parity. A licensed production image is a later owner decision. P06 records the
evaluation expiry with each generation's provenance evidence and defines the rebuild (or rearm)
step; P25 schedules it so no active generation reaches expiry. Approaching expiry (or upstream
drift) is reported as `stale` in `status.v5.json` while admissions continue; **reaching** expiry
moves the generation to `quarantined`, never kept `active`, and admissions for that profile stop
until a new generation is active.

## Owners and retention

Product images, the retained rollback generation and their evidence are accounted assets with a
named owner, size and expiry (WORKTREES.md, "Cleanup sequence" step 1). Disposable build disks,
installers and clones are not catalog content and are cleaned through P00 manifests.

## Negative fixtures

An active generation without a certificate, two active generations, an active pointer naming a
quarantined generation, a short hash, an artifact path that escapes `base/`, an artifact in a
`rollback/` folder, an artifact stored under another generation's folder, an active generation without the owner's
live activation record, a clean scan without evidence, a certificate path with `..`, an active
generation whose secret scan found something.
