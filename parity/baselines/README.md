# Frozen hosted baselines (ledger item P01)

Reviewed record of the two certified target profiles and their consumers. Upstream pin:
`actions/runner-images` commit `ee1ff4569e381a9649b400338bdc8ceb7e18a80e`. Facts fetched 2026-10-19.

| File | Content |
|---|---|
| `windows-2025-vs2026-x64/` | `README.md` identity, defaults, environment, services, provisioning order, counts. `inventory.json` every Readme entry. `inputs.md` installer inputs, blockers, drift. `sources/` template and toolset copies. |
| `ubuntu-24.04-x64/` | Same layout for Ubuntu 24.04 x64. |
| `hosted-reference.md` | How to capture the real "Set up job" image identity. Status: not captured yet. |
| `reference-workflows/` | Two inert workflow files for that capture. Never copy them into `.github/workflows` of this repository. |
| `consumers.md` | Consumer census from this repository's documents. Incomplete. |
| `zccache.md` | zccache 1.15.6 pin, release assets, pinned compiler statements, daemon and retention interface. |
| `tools/` | Python scripts that build and verify the inventories (`python -I`, standard library only). |

## Findings that need a coordinator decision

1. **The pinned build definition is not the one that built the pinned Readme.** The Readmes are byte-identical to the
   Readmes at the release commits, but the pinned toolsets list Python 3.11 to 3.15 while the Readmes record
   Python 3.10 to 3.14, and the Windows template orders `Install-LLVM.ps1` differently. See "Pin versus build commit"
   in each profile README. Choose to keep the pin or move it to the release commits.
2. **The hosted fleet has already moved on.** Newer releases than both pinned images exist (2026-10-19). Moving
   labels cannot select the pinned releases. The hosted "Set up job" capture is still open.
3. **Label ambiguity.** `windows-latest` and `windows-2025` are not safe labels for the VS2026 image. The GitHub docs
   and the runner-images README disagree. Use `windows-2025-vs2026` and `ubuntu-24.04`.
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
