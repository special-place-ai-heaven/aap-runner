# Hosted reference capture

How to capture the real GitHub-hosted "Set up job" image identity for each certified profile, and what
counts as valid evidence. Facts were fetched on 2026-10-19. Source IDs are defined at the end.

**Status: captured 2026-10-19.** Windows run 39303666617 succeeded. Ubuntu run 39303673044 failed at the privilege step (`sysctl vm.mmap_rnd_bits` is denied to the unprivileged user); after the fix merged, Ubuntu run 39305649952 succeeded in full. Both reported the frozen image versions. Logs: `windows-2025-vs2026-x64/sources/hosted-capture-39303666617.log`, `ubuntu-24.04-x64/sources/hosted-capture-39303673044.log` (partial) and `ubuntu-24.04-x64/sources/hosted-capture-39305649952.log`. Observed values are in each profile README, section "Observed on the hosted reference".

**Original status line:** P01 wrote the capture procedure and the inert workflows. No hosted job was
dispatched, so no observed image version string exists yet. The coordinator or owner must dispatch the two
workflows (hosted runners only, no secrets) and attach the logs before P01 closes.

## Moving labels do not select the pinned image

- A runner label names an image family, not an image release. GitHub rolls a new image release over the
  fleet roughly weekly, and the rollout takes several days (D1).
- `windows-latest`, `windows-2025`, `ubuntu-latest` and `ubuntu-24.04` can land on different releases on
  different days. The pin below was current on 2026-10-16. Newer releases already exist (see table).
- The two sources disagree on `windows-latest` and `windows-2025`. The runner-images README at the pin lists
  `windows-latest`, `windows-2025` and `windows-2025-vs2026` on one Windows Server 2025 row that links to
  the VS2026 Readme (S6). The GitHub docs source on `main` links `windows-latest` and `windows-2025` to
  `Windows2025-Readme.md` (the Visual Studio 2022 image) and only `windows-2025-vs2026` to the VS2026
  Readme (D2). Use `windows-2025-vs2026` and nothing else. **Finding:** the docs and the README conflict; certification uses the explicit label only.
- `ubuntu-latest` is announced to move to Ubuntu 26.04 in November 2026 (S1 announcements). Use
  `ubuntu-24.04` and nothing else. Ubuntu 26.04 is out of scope for this plan.
- A label cannot recover a historical release. Certification must record the exact image version string the
  job reports. If the observed string differs from the frozen one, the observed release needs its own
  baseline revision and recertification. Never compare against a mismatched generation.

## Expected identity at the pin

| | Windows Server 2025 / VS2026 x64 | Ubuntu 24.04 x64 |
|---|---|---|
| Label to use | `windows-2025-vs2026` | `ubuntu-24.04` |
| Image label printed by the image (`imagedata.json`) | `windows-2025-vs2026` (S3a) | `ubuntu-24.04` (S3b) |
| Image version string in the pinned Readme | `20261007.264.1` (S4a line 8) | `20261012.334.1` (S4b line 11) |
| Release tag the image links to | `win25-vs2026/20261007.264` | `ubuntu24/20261012.334` |
| Release published (UTC) | 2026-10-14T10:41:28Z (D3a) | 2026-10-13T10:25:13Z (D3b) |
| Commit the release tag targets | `aee0669dd04510a11756664eb77f5630debabed3` | `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe` |
| Newest release seen on 2026-10-19 | `win25-vs2026/20261018.275`, 2026-10-19T16:55Z | `ubuntu24/20261018.339`, 2026-10-19T11:58Z |
| Hosted standard runner, public repo | 4 vCPU, 16 GB RAM, 14 GB SSD (D2) | 4 vCPU, 16 GB RAM, 14 GB SSD (D2) |
| Hosted standard runner, private repo | 2 vCPU, 8 GB RAM, 14 GB SSD (D2) | 2 vCPU, 8 GB RAM, 14 GB SSD (D2) |

The Readme at both release commits is byte-identical to the Readme at the pin (same SHA-256, see each
profile's `sources/NOT-STORED.md`). The release commits are on a different branch line from the pin. The
pin's template and toolset differ from the release commits. See each profile README, "Pin versus build commit".

## Format of the Set up job lines

The image writes `imagedata.json` at build time. The runner prints it under `Set up job` in the group
`Runner Image`. Build scripts define the content (S3a, S3b):

- Windows: `Image: windows-2025-vs2026`, `Version: <ImageVersion>`, `Included Software: .../blob/win25-vs2026/<major.minor>/images/windows/Windows2025-VS2026-Readme.md`, `Image Release: .../releases/tag/win25-vs2026%2F<major.minor>`. The file is `C:\imagedata.json`.
- Ubuntu: `Image: ubuntu-24.04`, then the same three fields with tag family `ubuntu24`. The file is `/imagegeneration/imagedata.json`.
- GitHub documents that the `Included Software` link in the log describes the tools on the exact runner (D2).
- The runner version line and any other group under `Set up job` (for example an image provisioner group) are
  not defined in the pinned sources. Record them verbatim. Do not infer their format.

## Capture procedure

1. In a scratch repository (a public one is free for standard runners), copy
   `reference-workflows/hosted-reference-windows-2025-vs2026.yml` and
   `reference-workflows/hosted-reference-ubuntu-24.04.yml` to `.github/workflows/` and push to its default
   branch. Do this in a scratch repository only. The coordinator has since added both workflows to this repository's `.github/workflows`, which CLAUDE.md allows for hosted, dispatch-only, no-secret workflows.
2. Dispatch each workflow once with `workflow_dispatch`. Both use hosted labels, no secrets, no third-party
   actions, no token permissions.
3. Save the full raw job log, for example with `gh run view <run-id> --log` or the job logs API. Record from
   the `Set up job` section, verbatim:
   - `Current runner version`
   - the `Operating System` group
   - the whole `Runner Image` group (Image, Version, Included Software, Image Release)
   - every other group printed under `Set up job`
4. From the step logs record the observed hardware, user and privilege facts, allow-listed environment,
   PATH order, shells, services and tool-cache layout. The workflows print fixed name lists only. They never
   dump the whole environment, and `PGPASSWORD` is reported as present or absent (S5a installs it machine-wide).
5. Record the run id, run attempt, job id, date, repository visibility and the exact commit of the workflow file.
6. Open the `Included Software` link from the log. Diff that Readme against the frozen
   `inventory.json`. The Readme copies are not stored (they contain a default credential, see each
   profile's `sources/NOT-STORED.md`). Run `python -I tools/verify_inventory.py` on the fetched Readme if a new
   inventory is needed.

## Acceptance rules for the evidence

- The observed `Image:` equals the label in the table. Anything else invalidates the evidence.
- The observed `Version:` equals the frozen string. If it differs, the evidence is for a different
  generation. File a baseline revision for the observed release before any comparison.
- Capture both profiles in the same sitting where possible. Record the capture date. Do not reuse an old capture.
- A capture from a repository owner on a larger or custom runner is not the standard hosted reference.
- Azure addresses, instance metadata, GitHub ownership and hardware speed are known infrastructure
  differences. Record them and do not falsify hosted environment identifiers (plan, "Outcome").

## Lifecycle and privileges (documented)

- Every standard GitHub-hosted runner except `ubuntu-slim` is a new virtual machine for the job (D2).
  `ubuntu-slim` is a container and is out of scope.
- Linux VMs run with passwordless `sudo`. Windows VMs run as administrators with UAC disabled (D2).
  The image build also sets `ConsentPromptBehaviorAdmin` to 0 (S5b, Configure-BaseImage.ps1).
- Windows and Ubuntu runners are hosted in Azure. Inbound ICMP is blocked (D1).
- Hosted runners ship an `etc/hosts` file that blocks cryptocurrency mining pools and malicious sites (D4).
- The runtime user name, UID and group membership are not defined in the pinned image sources. Observe them
  with the workflows. Do not assume `runneradmin` or `runner`.

## Sources

- S1: [Ubuntu Readme at pin](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md), commit `ee1ff4569e381a9649b400338bdc8ceb7e18a80e`.
- S3a: [Configure-ImageDataFile.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-ImageDataFile.ps1), same commit.
- S3b: [configure-image-data.sh](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/scripts/build/configure-image-data.sh), same commit.
- S4a: [Windows2025-VS2026-Readme.md](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/Windows2025-VS2026-Readme.md), same commit.
- S4b: [Ubuntu2404-Readme.md](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md), same commit.
- S5a: [Install-PostgreSQL.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Install-PostgreSQL.ps1), same commit.
- S5b: [Configure-BaseImage.ps1](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/scripts/build/Configure-BaseImage.ps1), same commit.
- S6: [runner-images README](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/README.md), same commit.
- D1: [GitHub docs, hosted runners concepts](https://github.com/github/docs/blob/497671ebee089b38c8dc13ee9d09422405556ef3/content/actions/concepts/runners/github-hosted-runners.md), `github/docs` commit `497671ebee089b38c8dc13ee9d09422405556ef3` (main on 2026-10-19).
- D2: [GitHub docs, hosted runners reference](https://github.com/github/docs/blob/497671ebee089b38c8dc13ee9d09422405556ef3/content/actions/reference/runners/github-hosted-runners.md) and its [runner table](https://github.com/github/docs/blob/497671ebee089b38c8dc13ee9d09422405556ef3/data/reusables/actions/supported-github-runners.md), same docs commit. Rendered page: <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>.
- D3a: [release win25-vs2026/20261007.264](https://github.com/actions/runner-images/releases/tag/win25-vs2026%2F20261007.264). D3b: [release ubuntu24/20261012.334](https://github.com/actions/runner-images/releases/tag/ubuntu24%2F20261012.334). Both read through the GitHub releases API on 2026-10-19.
- D4: [etc/hosts reusable](https://github.com/github/docs/blob/497671ebee089b38c8dc13ee9d09422405556ef3/data/reusables/actions/runners-etc-hosts-file.md), same docs commit.
