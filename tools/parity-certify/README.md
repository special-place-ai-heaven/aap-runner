# parity-certify (P05)

Differential certification harness. One stdlib Python CLI, two in-job probes.

| Piece | Purpose |
|---|---|
| `probe/windows.ps1`, `probe/linux.sh` | Run inside a job; write `job-inventory.json` (schema 1). Fixed env names, credential variables as presence booleans, no environment dump. `-Safe` / `--safe` skips Docker and sudo: Docker is then left out of `coverage` and `passwordless_sudo` is `null` (unknown), never `false`. The Windows probe never runs a `bash` that resolves under `%SystemRoot%` (or `%windir%` when that is unset) or `WindowsApps` (the WSL launcher); it records `<not-run:wsl-launcher>` so the comparison fails honestly. Linux probe: run on real Linux only. |
| `certify.py parse-hosted-log` | Hosted capture log (`parity/baselines/*/sources/hosted-capture-*.log`) to `job-inventory.json`. A missing or empty expected step, or an unreadable value, exits 2 instead of producing an empty section. |
| `certify.py parse-readme` | P01 `inventory.json` to the same shape for overlapping categories (image, env, tool_cache, tools). |
| `certify.py compare` | Inventory diff. Classes `missing-required`, `version-mismatch`, `default-mismatch`, `path-order`, `env-mismatch`, `service-mismatch` and `identity-mismatch` fail. `documented-rig-difference` (only from `allowlist.json`) and `extra` do not. A reference whose covered section is empty exits 2. |
| `certify.py run-workloads` | Runs workload definitions (`workloads/*.json`): exit code, artifacts with hashes, first causal error, timing. Output goes to a log file, not a pipe, and the whole process tree (Windows job object, POSIX process group) is killed on timeout and when the workload ends, so a daemon grandchild cannot hang or outlive the harness. |
| `certify.py certify` | Inventory + identity pins + behaviour as separate sections. `--pin` is required with all five fields (`image_version`, `runner_version`, `source_sha`, `workflow_sha`, `action_shas`); a null identity on either side fails. Writes `parity-report.json`, one evidence record per section and workload (validated with `parity/contracts/validate.py evidence-bundle`, fail closed if the validator is missing), and `verdict.json` LAST. No `verdict.json` means not certified; a stale one is removed at the start of every run. |

## Rules that keep certification honest

- **Behaviour is recomputed.** `certify` never reads `status` from `results.json`. It recomputes every result from the definition, the recorded exit code and artifacts, and the log file next to the results file (its sha256 must match). A result must carry the sha256 of the definition it ran (`def_sha256`), so results from relaxed or different definitions cannot certify.
- **Variants.** A definition may list `variants`; the first whose `requires` tool is on PATH runs. Only the first declared variant (or the variant the reference run used) can certify. A fallback run is a harness self-test and fails certification.
- **Reference results** (`--reference-results`, optional): every workload needs a reference row, the reference row must itself pass its own oracle (otherwise it is invalid evidence and the row fails), and exit code, first causal error and artifacts must match. Artifacts are compared by sha256 (`"compare_artifacts": "sha256"`, the default). A definition may waive that with `"compare_artifacts": "names"`, which compares only artifact names and REQUIRES a non-empty `compare_artifacts_reason`; any other mode, or `names` without a reason, exits 2. Every waiver is carried in the behaviour row and the `waivers` list of `parity-report.json`, in `verdict.json`, and in the `command` text of that workload's evidence record (the evidence schema has no notes field).
- **Forged green.** A log claiming success with a nonzero exit code (or the reverse) is `forged-green`. Recognised markers include `BUILD SUCCESSFUL`, `BUILD FAILED`, `BUILD FAILURE`. First causal errors recognise gcc/clang `error:`, MSVC `error C2065:`, rustc `error[E0425]:` (location from the following `-->` line) and `##[error]`.
- **PATH.** An extra entry ahead of a reference entry, or a command (`cl.exe`) callable only on the candidate, is `path-order`; an extra service is `service-mismatch`. An extra PATH entry after the last reference entry is only reported as `extra`.
- **Allowlist.** `allowlist.json` enumerates keys (no section wildcards). `image.runner_environment` (hosted vs self-hosted) is allowlisted: it is the definition of the rig difference, not a gap. Free disk uses a floor rule: the candidate's `hardware.root_disk_free_bytes` must be at least the reference's.

## Review checklist for P17/P18 workload definitions

- Run `grep -rn compare_artifacts parity/workloads/**` and read every `reason`. Each hit is a waiver of the artifact hash comparison that someone must justify.
- `expected_hashes` still apply in `names` mode: a wrong or missing expected hash fails the workload whatever the compare mode.
- `names` mode is reachable only through `--reference-results`. Without reference results there is no artifact comparison at all, so the setting is inert (the waiver is still listed).
- A definition with `variants` can only certify through its first variant (or the variant the reference run used); do not rely on a fallback.

## Known limits

- `image.kernel`, `limits.read_ahead_kb` and `limits.mount_options` are deliberately NOT allowlisted. The Ubuntu reference runs the hosted Azure kernel with specific block read-ahead and mount options. They stay failing differences that P07/P11 must either match (for example install the linux-azure kernel) or justify through a reviewed allowlist entry.
- The Readme inventory cannot be compared against a probe candidate: its tool names differ from the probe's, the probe collects only about ten tools, and the hosted workflow never captured `ANDROID_NDK*` or `ANDROID_SDK_ROOT`. `parse-readme` exists for the overlapping categories (image and cached tool versions). Full inventory reconciliation is P24's job; P24 must not assume this harness does it.
- Default tool-cache version = first process-PATH entry under `<cache>/<name>/<ver>/`, else `JAVA_HOME`; the Linux probe also resolves a few commands. Same rule in the parser and both probes.
- Execution policy depends on the PowerShell engine running the probe; run it under `pwsh` as the hosted reference did.
- The POSIX process-group kill and the Linux probe have not run on Linux from this host; the coordinator's CI must exercise them.

## Workload definition fields

`id` (lowercase, `[a-z0-9._/-]`), `commands` (argv lists; placeholders `{python}`, `{fixtures}`, `{work}`, `{exe}`) or `variants`, `expected_exit_codes` (`[0]` or nonzero codes), `artifact_globs`, `expected_hashes`, `expected_first_error` (`contains`, optional `file`, `line`), `timeout_s`, `compare_artifacts` (`sha256` or `names`) with `compare_artifacts_reason`, optional `claim_success_regex` / `claim_failure_regex`.

Tests: `tests/parity-certify` (Pester 5). `mutate.py` and `logfilter.py` there create the negative-control inputs.
