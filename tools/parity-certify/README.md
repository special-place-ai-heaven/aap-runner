# parity-certify (P05)

Differential certification harness. One stdlib Python CLI, two in-job probes.

| Piece | Purpose |
|---|---|
| `probe/windows.ps1`, `probe/linux.sh` | Run inside a job; write `job-inventory.json` (schema 1). Fixed env names, credential variables as presence booleans, no environment dump. `-Safe` / `--safe` skips Docker and sudo and drops Docker from `coverage`. Linux probe: run on real Linux only. |
| `certify.py parse-hosted-log` | Hosted capture log (`parity/baselines/*/sources/hosted-capture-*.log`) to `job-inventory.json`. |
| `certify.py parse-readme` | P01 `inventory.json` to the same shape for overlapping categories (image, env, tool_cache, tools). |
| `certify.py compare` | Inventory diff. Classes: `missing-required`, `version-mismatch`, `default-mismatch`, `path-order`, `env-mismatch`, `service-mismatch`, `identity-mismatch` fail; `documented-rig-difference` (only from `allowlist.json`) and `extra` do not. A category in the reference `coverage` that the candidate did not probe is `missing-required`. |
| `certify.py run-workloads` | Runs workload definitions (`workloads/*.json`): exit code, artifacts with hashes, first causal error, timing. A log claiming success with exit code not 0 (or the reverse) is `forged-green` and fails. |
| `certify.py certify` | Inventory + identity pins + behaviour as separate sections; a missing workload result is `skipped`; no workloads means `missing`. Writes `parity-report.json` and one evidence record per section/workload, validated with `parity/contracts/validate.py evidence-bundle`. |

Workload definition fields: `id`, `commands` (argv lists; placeholders `{python}`, `{fixtures}`, `{work}`, `{exe}`) or `variants` (first whose `requires` tool is on PATH), `expected_exit_codes`, `artifact_globs`, `expected_hashes`, `expected_first_error` (`contains`, optional `file`, `line`), optional `claim_success_regex` / `claim_failure_regex`.

Notes
- Default tool-cache version = first process-PATH entry under `<cache>/<name>/<ver>/`, else `JAVA_HOME`; the Linux probe also resolves a few commands. Same rule in the parser and both probes.
- Execution policy depends on the PowerShell engine running the probe; run it under `pwsh` as the hosted reference did.
- `image.runner_environment` (`github-hosted` vs `self-hosted`) is NOT allowlisted. A real local candidate will report a mismatch until the coordinator decides whether to allowlist it.
- Tests: `tests/parity-certify` (Pester 5). `mutate.py` there creates the negative-control inventories.
