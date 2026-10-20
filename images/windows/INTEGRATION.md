# Windows image builder: integration requests (ledger item P06)

P06 owns only `images/windows/**` and `tests/images/windows/**`. Nothing below is wired into the supervisor, the helper,
the providers or the catalog yet. Contracts: `parity/contracts/image-catalog.md` (revision 2) and
`parity/contracts/backend-lifecycle.md` (revision 2, Storage tiers, budgets).

## What a build produces

| Output | Where | Shape |
|---|---|---|
| The sealed base disk | `<base_root>\win25-vs2026-x64\<image_version>-aap.<n>\base.vhdx` | Read-only file and folder: owner Administrators; SYSTEM, Administrators and `S-1-5-83-0` (Virtual Machines) read and execute; protected DACL; ReadOnly attribute |
| Generation entry | `<EvidenceRoot>\P06\<build id>\generation.json` | One image-catalog schema 2 `generations[]` item, `state` `candidate`, `built_by_item` `P06`, no overlays, no certificate |
| Budget | `...\budget.json` | backend-lifecycle schema 2 `budget` record, `measured: true` |
| Evidence | `...\build.json`, `secret-scan.json`, `software-report.md/.json`, `job-inventory.json` | Phase-by-phase script hashes and exit codes, media hash and edition, waived blockers, evaluation dates, verification counts, measured bytes |

`<build id>` is the generation id with `/` replaced by `_`. Build VMs are named `aap-wbuild-<8 hex>` and
`aap-wverify-<8 hex>` (SHA-256 of the build id), never the `aap-w-<slot>-...` pattern of runner clones, so reconcile can
tell them apart.

## P10: Windows VM backend

1. **Clone settings the image needs.** Generation 2; Secure Boot off (upstream sets `TESTSIGNING ON`); nested
   virtualization exposed (`ExposeVirtualizationExtensions`, the image enables Hyper-V, Containers and WSL2); the scratch
   disk as the second disk, which becomes `D:` (hosted `D:` is the temp disk; `TEMP_DIR` was `D:\temp`).
2. **Per-clone answer file.** Use the exported `New-AapWinUnattend -UserName runneradmin -Password <per-clone>` and write it
   offline to `Windows\Panther\unattend.xml` in `os.avhdx` before the first boot, never into the base. It sets
   `SanPolicy` 1 in specialize: without it a generalized Server image leaves the scratch disk offline. It never enables
   autologon. First boot runs specialize and OOBE; budget minutes, not seconds, for the first `ready`.
3. **Base hash.** Every `create` re-hashes `base.vhdx` against the pin outside the roots
   (`approved-images.json`, P24 certificate). P06's `generation.json` hash is input to that pin, not a substitute.
4. **Differencing children of a read-only parent.** Prove in the lab that Hyper-V attaches `os.avhdx` without needing
   write or ACL changes on `base.vhdx`; P06's ACL already grants the Virtual Machines group read.
5. **Budgets.** Admission counts `clone_gib_max` and `scratch_gib_max` from `budget.json`. The scratch peak comes from the
   verification guest only; re-measure with real jobs (P22). Open question for the chair: the contract makes the scratch
   VHDX maximum `scratch_gib_max`, while the hosted `D:` is about 150 GiB; jobs that report or need the disk size will see
   the difference.
6. **Guest transport.** The builder uses plain PowerShell Direct, because the build guest has run no job. Runner clones use
   P10's hardened transport (guest-transport.md, wire framing). The image does not contain `C:\Program Files\aap-guest`.

## P14: Windows guest bootstrap

- The base image holds the upstream provisioning result: `C:\image` laid out as upstream, the TestsHelpers and ImageHelpers
  modules, the tool cache, services as upstream configured them, the software report at `C:\software-report.*`.
- It does **not** hold the Actions runner, the guest agent, zccache, cache configuration or any registration material:
  those are overlays (`overlays[]`, P14/P21), and the secret scan refuses an image with runner credential files.
- The local user `installer` exists (upstream's install user; `Configure-User.ps1` copied its profile settings to the
  default user) with a random password nobody knows. Decide whether the overlay disables it.
- The job user is created per clone by P10's answer file (`runneradmin`, local administrator), the same name P06 verified
  with. Configure the runner as that user. Developer environments are entered per job (`VsDevCmd`), as on hosted runners;
  do not prepend compiler paths machine-wide.
- Upstream sets `PGUSER`/`PGPASSWORD` machine-wide with the public default from the upstream Readme; P06 does not change
  that (parity), and the secret scan does not look for it.

## P19: installer, helper, storage

- The builder needs a valid storage document (`storage.json`) with admin-only `base_root` and staging root on their
  recorded volumes; it refuses otherwise and creates, repairs or re-permissions nothing above its own build and generation
  folders.
- Copy the owner's evaluation ISO into `<base_root>\media\` (admin-only) and record its SHA-256 where the caller can pass it
  as `MediaSha256`; the full hash is not in this repository.
- Pass the owner-approved values: `BuildCpus` 4, `BuildMemGib` 10, `BaseGibMax` 186 and `JobDiskGibMax` 55 (GiB, from the
  200 GB and 60 GB of the 2026-10-20 approval), `StagingGibMax` within what the staging volume holds above its floor.
- A build runs for hours, elevated, with no console. Run it from the hidden supervisor context or a helper verb that
  starts it hidden; never hand the owner a script.
- `New-AapWinHyperVProvider` imports `images/common/AapArtifact.psm1` and its manifest by relative path: deploy
  `images/common` beside `images/windows`.

## P12: supervisor and status

- Surface a running build (generation id, phase id) and a failed build's `Reason` in `status.v5.json`; never its `Detail`
  unfiltered (it is printable ASCII and bounded, but it can name paths).
- Read `build.json` `evaluation.rebuild_by` and `expires_at` for the `stale` and quarantine rules of image-catalog.md.
- Admission refuses the Windows profile until a generation has a measured `budget.json` (backend-lifecycle.md).

## P21, P24, P25: catalog, certificate, operations

- P21 inserts `generation.json` into `catalog.json` (scope `lab` until D5), adds overlays and, if it reseals, a new
  generation id.
- P24 certifies the candidate: the verification here (upstream tests, inventory, discovery) is build-time evidence, not the
  certificate; compare `job-inventory.json` against the hosted baseline with `tools/parity-certify`.
- P25 schedules `aap.<n+1>` before `rebuild_by`, and builds when a P03 blocker or waiver changes.

## P03: inputs

- Add a literal-pinned entry for the `actions/runner-images` archive at `aee0669dd04510a11756664eb77f5630debabed3`
  (images/windows scripts, assets, toolsets, helpers/software-report-base). Then rerun
  `New-AapWinBuildPlan.ps1 -ScriptsDir <extracted images\windows\scripts>` to pin the 82 script hashes, and drop the plan
  blockers it resolves.
- The 11 Windows blockers stay blockers. A build needs each resolved or waived by id in `Waivers`; who may waive what is a
  chair decision.

## Open questions for the chair

1. **Secret-scan allowlist.** A real upstream image likely ships PEM private keys in package test data (Python, Node, OpenSSL
   samples). The scan fails on any of them. Allowlist reviewed path plus SHA-256 pairs, or keep failing?
2. **Waiver policy** for the P03 blockers (Windows Updates level and Visual Studio channel cannot be reproduced exactly).
3. **LSA secret check**: Administrators normally cannot read the offline SECURITY hive. Use backup privilege, check inside
   the guest as SYSTEM before sysprep, or rely on the Winlogon values?
4. **Scratch disk size** versus the hosted 150 GiB `D:` (P10 item 5).
