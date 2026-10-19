# Frozen hosted baselines (ledger item P01)

Reviewed record of the two certified target profiles and their consumers. Facts fetched 2026-10-19.

**Baseline commits (coordinator decision).** The baseline for each profile is the `actions/runner-images` commit that built the
observed image: Windows `aee0669dd04510a11756664eb77f5630debabed3` (image `20261007.264.1`), Ubuntu
`7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe` (image `20261012.334.1`). `ee1ff4569e381a9649b400338bdc8ceb7e18a80e` stays recorded as the
planning candidate only. Both toolset versions remain under each profile's `sources/`.

| File | Content |
|---|---|
| `windows-2025-vs2026-x64/` | `README.md` identity, defaults, environment, services, provisioning order, counts. `inventory.json` every Readme entry. `inputs.md` installer inputs, blockers, drift. `sources/` template and toolset copies. |
| `ubuntu-24.04-x64/` | Same layout for Ubuntu 24.04 x64. |
| `hosted-reference.md` | How to capture the real "Set up job" image identity. Status: not captured yet. |
| `reference-workflows/` | Two inert workflow files for that capture. Never copy them into `.github/workflows` of this repository. |
| `consumers.md` | Consumer census from this repository's documents. Incomplete. |
| `zccache.md` | zccache 1.15.6 pin, release assets, pinned compiler statements, daemon and retention interface. |
| `tools/` | Python scripts that build and verify the inventories (`python -I`, standard library only). |

## Findings

1. **Pin drift, resolved by pinning to the build commit.** At the candidate `ee1ff45` the toolsets list Python 3.11 to 3.15
   while the Readmes record 3.10 to 3.14, and the Windows template orders `Install-LLVM.ps1` differently. The baseline
   is the build commit, where these agree with the Readmes. See "Pin drift" in each profile README.
2. **The hosted fleet has already moved on.** Newer releases than both pinned images exist (2026-10-19). Moving
   labels cannot select the pinned releases. The hosted "Set up job" capture ran on 2026-10-19: both labels still served the frozen images (`20261007.264.1`, `20261012.334.1`). Windows is fully captured. Ubuntu is partial and needs a workflow fix and re-run.
3. **Label conflict (finding).** The runner-images README at the candidate lists `windows-latest` and `windows-2025` on the VS2026
   row. The GitHub docs source links them to the VS2022 image. Certification uses `windows-2025-vs2026` and `ubuntu-24.04` only.
4. **Unreproducible and licensed inputs** are listed in each `inputs.md` (Azure Marketplace base images, Windows
   Server 2025 media and activation, Visual Studio 2026 Enterprise entitlement and its moving channel, floating
   vendor feeds, superseded apt versions, six floating `:latest` container images on Ubuntu).
5. **The Readmes are not stored** because they contain a default database credential. Their hashes and URLs are in
   each `sources/NOT-STORED.md`. The credential is masked in `inventory.json`.

## Regenerate and verify

```
python -I tools/build_inventory.py <Readme> <toolset.json> <out.json> <profile> <commit> <readme_url>
python -I tools/verify_inventory.py <Readme> <inventory.json>
python -I tools/provisioning_order.py <template.pkr.hcl>
python -I tools/gen_inputs.py <template.pkr.hcl> <scripts/build dir> <scripts/helpers dir>
```

Inputs fetched from the network are untrusted data: read them with these scripts only and never execute them.
