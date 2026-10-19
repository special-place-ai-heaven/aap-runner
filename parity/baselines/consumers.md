# Consumer inventory

Consuming repositories known from this repository's own docs and workflows, as of the `main` tree at
`3772e34` (2026-10-19). This is a census from documents only. No private repository was fetched, no
workflow file of a private repository was read, and no GitHub API call touched any consumer.

**Completeness: INCOMPLETE.** The owner's list of in-scope repositories is not in this repo. The only
consumer named by the docs is the AAP private repository. P23 and P27 need the owner to confirm the full
list and to supply or authorize read access to each workflow file.

## Consumers found

| # | Repository | Visibility | Workflows and jobs known | Labels / runner group today | Profile it maps to | Reachability and evidence |
|---|---|---|---|---|---|---|
| 1 | `special-place-ai-heaven/Agent_Army_Professionals` (AAP) | private (S1) | One CI workflow, blob `b65d76a87c490985685a3ea573714d9b798b9811`: Rust jobs (install Rust, sccache), a frontend job (Node), a known-failures job that clears the sccache wrapper (S2). A DB Integration job with MySQL and SingleStore service containers on the inner Docker (S3). Workspace, agents and backend test commands with `--no-fail-fast` (S3). | `runs-on: [self-hosted, linux, crrr]` and runner group `aap-crrr`, selected-repositories only (S3, S4). Heavy jobs will later target `fresh` (labels `self-hosted,linux,fresh,heavy`) (S3). | Ubuntu 24.04 x64 today. No Windows job is known. A Windows MSVC consumer, if one exists, is not documented. | NOT FETCHED. Private. Facts above come from `distro/README.md` and `docs/github-runner-parity-audit.md` at this commit. The workflow file itself was last read in the earlier audit only. |
| 2 | `special-place-ai-heaven/symforge` | public (S3) | Not a job consumer. AAP jobs check it out as a public sibling with `token: ${{ github.token }}`. Org access setting must allow AAP (S3). | None. It is excluded from group `aap-crrr` on purpose (S3). | n/a (checkout source only) | Public; not fetched by P01. Its own CI is unknown. |
| 3 | `special-place-ai-heaven/aap-runner` (this repo) | public | `.github/workflows/ci.yml` jobs `bash` (`ubuntu-latest`), `pester` (`windows-latest`) and `tray` (`windows-latest`) (S5). | Hosted moving labels. No self-hosted use. CLAUDE.md forbids untrusted code on `aap-crrr`. | Hosted Ubuntu 24.04 and Windows today. The moving labels drift: `ubuntu-latest` moves to Ubuntu 26.04 in November 2026 (see `hosted-reference.md`). Not a certification target. | Read directly from the worktree. |

## Observations that change later work

- **Third-party actions in AAP are pinned by commit.** `actions/checkout`, `actions/setup-node`,
  `Swatinem/rust-cache`, `dtolnay/rust-toolchain` and `mozilla-actions/sccache-action` (sccache version
  `v0.18.0`) (S3). P23 and P27 must remove the sccache coupling for zccache and must not let a rename
  float the pins.
- **The sccache wrapper is injected by the manager.** `distro/manager.sh` sets `RUSTC_WRAPPER=sccache` in
  the job container (S2). The zccache migration must cover that injection as well as the workflows.
- **Hosted workflows rely on `sudo`.** The current Linux job image rejects sudo (S2). An Ubuntu hosted
  profile must provide passwordless sudo inside the disposable guest, not on the owner's desktop.
- **Concurrency.** The plan allows at most five runner slots across both operating systems.
- **Fork pull requests stay prohibited** on the self-hosted group (S4).

## Not covered

- Repositories outside the `special-place-ai-heaven` organization.
- Any Windows consumer workflow (MSVC, clang-cl, MSBuild, .NET, Rust msvc). None is documented here.
  `ACCEPTANCE.md` still requires an actual consumer census for the Windows fixtures.
- Which AAP jobs actually fail today on the rig and why. The audit says the existing workflow shows that
  some setup exists but does not explain every reported failure (S2).

## Sources

All sources are in this repository at commit `3772e34` unless stated.

- S1: `distro/README.md`, section "Scope decision" (private AAP repositories, org group `aap-crrr`).
- S2: `docs/github-runner-parity-audit.md`, "What the code actually supplies" table and the paragraph about workflow blob `b65d76a87c490985685a3ea573714d9b798b9811`.
- S3: `distro/README.md`, sections "Workflow contract", "Pins in the workflow", "SymForge checkout".
- S4: `distro/README.md`, sections "Scope decision" and "Org settings checklist". `crates/tray/README.md` ("The current backend requires runner group `aap-crrr`").
- S5: `.github/workflows/ci.yml`.
