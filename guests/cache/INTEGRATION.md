# zccache guest integration: what other items wire (P13)

P13 ships the guest-side pieces in `guests/cache` and the host-side trust helpers. Every shared file stays with its
owner; this page lists what each owner has to do, and the decisions P13 cannot make. Read [README.md](README.md) first.

**Shared mutable roots stay OFF until the lab proof exists** (P04/P22; retention.md requirement 5: concurrency,
poisoning and direct-equivalence runs on a shared root). Until then the host never binds a shared root, P14/P15 never
pass `-SharedRoots` / `--shared-roots`, and every job uses only its private root. Everything below about shared roots
is the wiring for after that proof.

## Decisions for the owner

1. **Trust source (option A below): widen the GitHub App's permissions.** The App gains `actions: read` and
   `contents: read`. Cost: a stolen App key could then also read the run logs, artifacts and source of the repositories
   it is installed on.
2. **Precondition for 1: close the operator-account exposure first** (broker.md, security review M1). Any process
   running as the operator account can run `wsl -d aap-runner -u root` and read `app.pem`. The interim Windows host
   runner (`FRESH-win-interim`) runs jobs as that account, so today a job there can read the App key. That risk was
   accepted for the App's present, narrow permission; before the App gets more, either run that runner under a
   separate low-privilege account or retire it once the Windows VM profile is certified.
3. **zccache licence**: AGPL-3.0-only; images containing it are not redistributed until the owner records a compliance
   decision (README.md).
4. **Activation.** Shared roots stay OFF until the lab proof exists (top of this page). After it, a repository gets a
   shared root only once the owner's decision to enable that repository is recorded host-side; until then its jobs use
   private roots. Rule 6 leaves no per-repository condition to check before that decision (no merge-method or tag-rule
   precondition): it trusts only a run of the default branch's current head.

## Where the job's trust class comes from (decision for P16; option A chosen for the design)

Contract rule 6, as amended on 2026-10-20 and 2026-10-21 (cache-qualification.md): a job is `trusted` only when its
event is `push` or `schedule`, its `head_branch` is the repository's default branch, its head repository is the
repository itself, and its head commit IS the default branch's head when the class is bound; everything else is
`untrusted`. `workflow_dispatch` is untrusted: any untrusted job of the same
repository that holds `actions: write` can dispatch a workflow with inputs of its choosing. The class comes from
GitHub's records of the job assigned to the runner, bound before any shared root attaches, never from the guest. The
broker's App today has only the organization self-hosted-runners permission (broker.md), which cannot read a job, its
run or its event.

Two facts shape the answer. First, GitHub assigns a job to a runner only after the runner is online, so the class can
never be known at VM creation or registration: the shared root is attached **during** the job, and compiler calls
before the attach use the private root. Second, nothing in the guest can be trusted for the class.

| Option | What it needs | Verdict |
|---|---|---|
| **A. App gains `actions: read` and `contents: read`** (repository permissions), with the limits below | the lookup below | **Chosen for the design; the owner decides before activation.** It reads exactly the records the rule names |
| B. One runner group per trust class, the trusted group restricted to selected workflows at `refs/heads/<default>` | two groups and labels; the allocator must choose a group before any job exists | **Not sufficient alone.** `pull_request_target`, `workflow_run` and `issue_comment` run default-branch workflow files, so the restriction admits them; an event check is still needed, which is option A. It also splits the five slots by class in advance |

**Limits on option A.** The App is installed on **selected repositories only**, exactly the runner group's
repositories. For each lookup the broker mints a **narrowed installation token**
(`POST /app/installations/{id}/access_tokens` with `repository_ids: [<that repository>]` and `permissions:
{actions: read, contents: read, metadata: read}`), used for that lookup only and never logged; runner operations keep
their own separate token with the self-hosted-runners permission. The App key stays in the distro.

**The lookup** (after the broker's `status` reports the runner busy):

1. List the runner group's repositories (`GET /orgs/{org}/actions/runner-groups/{id}/repositories`, the runner-ops
   token).
2. Per repository, with a narrowed token: `GET /repos/{o}/{r}/actions/runs?status=in_progress`, then
   `GET /repos/{o}/{r}/actions/runs/{run_id}/jobs` for each run.
3. `Select-AapCacheJob -Jobs <all those jobs> -RunnerId <the runner id the broker registered for this VM, from its
   ledger> -RunnerGroupId <the pool's group>`: exactly one job or `$null`. Never match by runner name.
4. `GET /repos/{o}/{r}/actions/runs/{job.run_id}` (the run: `event`, `head_branch`, `head_sha`, `repository.id`,
   `head_repository.id`), `GET /repos/{o}/{r}` (`id`, `full_name`, `default_branch`) and, at bind time,
   `GET /repos/{o}/{r}/compare/{default_branch}...{head_sha}`: `-Compare` is its parsed body when it answered 200
   (`status`, `base_commit.sha`), `$null` for any other answer or none.
5. `Get-AapCacheTrustClass -Run <run> -Repository <repository> -Compare <compare body or $null>` returns `trust_class`,
   `repository_id` and `repository`, or `$null`.

Zero or several matching jobs, any failed call, a run of another repository, or a compare answer that is missing,
has no `status`, or says `identical` about another commit mean `$null`: no class, private root only.

**Tag pushes and re-runs.** GitHub's run record has no ref field, and for a tag push `head_branch` is the tag's name,
so a tag named like the default branch produces a record that looks exactly like a push to that branch. The rule does
not try to tell them apart. It trusts a run only when its `head_sha` is the default branch's head when the class is
bound (`status` exactly `identical`, `base_commit.sha` equal to the run's `head_sha`); `behind`, `ahead`, `diverged`
and any other status are untrusted. A tag at an older commit, live or deleted, a re-run of an older run and a run
whose push was superseded before binding all fail that; a tag at the current head runs exactly the reviewed head.
The cost is a private root for runs superseded before binding and for re-runs of older runs (a lower hit rate,
accepted). The compare call needs `contents: read`, already part of option A.

**Required call-site tests (P02.3, the host code that makes these calls).** With a recorded or faked GitHub, the bind
step must show, per compare answer, the class it hands on: 200 `identical` with the run's head as base: trusted;
200 `behind`, `ahead`, `diverged`: untrusted; 200 `identical` with another base commit, 200 without `status`, 404,
any other error status, a rate-limit answer (403/429), a timeout and a truncated or unparseable body: `$null`. Only
`identical` is ever trusted. Parse the body with `Invoke-RestMethod` or `ConvertFrom-Json`; both editions give the
same object (tested in `AapZcCache.Tests.ps1`).

**Deadline.** If the class is not established within a bounded time after the runner turns busy (start with 60 s),
the job keeps its private root for its whole life. No retry later in the job.

**Untrusted jobs** get only their private root. There is no untrusted shared root and no switch for one.

## P12 (supervisor, status), P19 (installer, storage) and P25 (retention)

1. A host **cache tier** for shared roots: one VHDX per namespace (repository id, class `trusted`, platform, toolchain
   digest, zccache version), under an admin-only root that passes the same owner, ACL, reparse-point and ancestor
   checks as the other storage tiers (ARCHITECTURE.md section 3). P19 adds the tier to the storage document; no default
   path.
2. Each namespace disk is created with a **fixed maximum virtual size** and carries `aap-cache-root.json` at its root,
   written by the host when the disk is created:
   `{"schema":1,"root_id":"ns-<16 hex>","namespace":{"repository_id":<id>,"repository":"owner/name","trust_class":"trusted","platform":"linux-x86_64"|"windows-x86_64","toolchain_digest":"<64 hex>","zccache_version":"1.15.6"}}`.
   The digest comes from the generation's `install.json` (P21 copies it into the catalog). For a Linux namespace the
   disk's file system and marker are made at creation by a provisioning step P19 picks; the rule below is the same.
3. **The host mounts a namespace disk only at its creation, to write the marker, and never after any guest has
   attached it.** A guest-written file system is never parsed by the host. Reset means delete and recreate.
4. An **exclusive read-write lease** per namespace disk: attached to at most one VM at a time; a second concurrent job
   of the same namespace gets nothing (private root). The lease ends at VM destroy; a lost heartbeat does not free it
   until the VM is proven gone (allocator rule).
5. The class (option A above) is computed host-side, and the disk is attached only for `trusted`. Bind order: compute
   the class, take the lease, hot-add the disk to the running VM, then send the binding to the guest. Never before the
   lab proof (top of this page).
6. **Size is measured on the host**: the VHDX file's length. P25 resets (deletes and recreates) a namespace disk on
   that host-measured size, on a digest or version change, or when its repository leaves the runner group; never on a
   size or state the guest reports, and never by trimming files inside a root.
7. `status.v5.json` `profiles[].cache`: report the guest's `Get-AapZcState` / `state` `state` and `detail` as they come
   (already in the schema's enum and limits). Bytes per root go to evidence, not the tray.

## P10 / P11 (providers) and P02 (guest transport)

1. **Contract change needed**: guest-transport.md has no command that can carry a binding mid-job (`probe`,
   `deliver_registration`, `start_runner`, `status`, `collect`, `shutdown`). Add a one-shot `bind_cache` with a payload
   of at most 1 KiB: the binding record
   `{"schema":1,"runner_name":"<VM name>","root_id":"ns-...","budget_bytes":<n>,"namespace":{...the same six fields...}}`.
   P02 owns the revision; P10/P11 send it, P14/P15 handle it. Until it exists, no shared root is ever bound, which is
   safe (private roots only).
2. Hot-add of the namespace VHDX to the running VM (SCSI) after the lease, and removal at destroy without the host
   mounting it.
3. Size each job's scratch disk to include the private root budget passed to `Initialize-AapZcJob` / `init`, plus the
   job root's `state/` and `shim/` (README.md, "The budget is the root's").

## P14 (Windows guest bootstrap)

1. Image build: `Install-AapZcCache -Archive <staged zip> -Provenance <zip>.provenance.json -InstallDir "C:\Program Files\aap-guest\cache" -Toolchains <list>`.
   The toolchain list is `{"toolchains":[{"compiler","compiler_version","path"}]}` for every compiler the P04 matrix
   names, at the versions the P01 inventory records (`clang`, `clang++`, `clang-cl` 20.1.8; `cl`, `link` with the exact
   `19.xx` toolset once P04 records it; `lld-link`; `rustc` only as the real toolchain binary, never the rustup proxy).
   The folder is Administrators-only for writes, readable and executable by the runner user. The image needs
   PowerShell 7 (`%ProgramFiles%\PowerShell\7\pwsh.exe`) for the compiler launcher.
2. Agent, before `Runner.Listener` starts: create the job root `<scratch>\aap-cache` with inheritance off, owner
   Administrators, Full control for SYSTEM, Administrators and the runner user, nobody else. Then, **as the runner
   user and from the agent's clean environment** (no runner token, JIT config or key), run
   `Initialize-AapZcJob -InstallDir ... -JobRoot <scratch>\aap-cache -BudgetBytes <n>` (`-SharedRoots` only after the
   lab proof). The daemons therefore run as the runner user, the user the compile clients run as, and their crash dumps
   stay in their root (reported only as counts). Merge `state\runner.env` into the runner's environment (the runner's `.env`). Nothing else: no
   `ZCCACHE_*` variable, no PATH change.
3. On `bind_cache`: mount the hot-added disk (the mount folder Administrators-owned; its `root` folder writable by the
   runner user; the marker read-only to it), write the payload to an admin-only file, call
   `Connect-AapZcSharedRoot -InstallDir ... -JobRoot ... -BindingPath ... -MountPath ... -RunnerName <own VM name>` as the
   runner user, and answer with its `Attached`/`Reason`.
4. `status`/`collect`: include `Get-AapZcState` (`state`, `detail`; bytes in `collect`).
5. **Gap G3, a native launcher.** `RUSTC_WRAPPER` must name one executable; a `.cmd` wrapper mangles arguments and a
   PowerShell script cannot be named directly, so `Initialize-AapZcJob` never sets `RUSTC_WRAPPER` and rustc builds
   directly. Before any Windows rustc row is qualified, P14 ships a small native launcher that runs the shim logic with
   the exact argv; it also removes the per-call PowerShell start-up cost and the PowerShell 7 requirement. Until then
   CMake's launcher list (`pwsh.exe;-NoProfile;...;-File;zcshim.ps1`) covers C/C++ where the generator honours
   `CMAKE_<LANG>_COMPILER_LAUNCHER` (Ninja, Makefiles); a generator or build system that ignores it compiles directly,
   which is correct but uncached. The lab confirms per generator.

## P15 (Linux guest bootstrap)

1. Image build, as root: `aap-zccache.sh install <staged tar.gz> <tar.gz>.provenance.json /usr/local/libexec/aap-guest/cache <list>`
   (files root-owned, 0755). Toolchain paths are the ones jobs call (`/usr/bin/clang-18`, `/usr/bin/gcc-13`, ...); the
   real binary behind a symlink is recorded and checked too. `rustc` only as the real toolchain binary.
2. Agent, before the runner starts: create `<scratch>/aap-cache` owned by the runner user, mode 0700. Then, **as the
   runner user and from a clean environment** (`runuser -u <runner> -- env -i PATH=/usr/bin:/bin HOME=<runner home>
   /usr/local/libexec/aap-guest/cache/aap-zccache.sh init <install> <scratch>/aap-cache <bytes>`; `--shared-roots` only
   after the lab proof). `init` itself starts each daemon under `env -i` with the allowlist, so the daemons run as the
   runner user. Merge `state/runner.env` into the runner's environment. A qualified rustc pair sets `RUSTC_WRAPPER` to
   `zcshim`.
3. On `bind_cache`: mount the disk with the mount point root-owned 0755, `<mount>/root` owned by the runner user 0700
   and the marker root-owned 0444; then, as the runner user,
   `aap-zccache.sh attach <install> <job root> <binding file> <mount> <own VM name>`; reply with its JSON.
4. `status`/`collect`: `aap-zccache.sh state <job root>`, as the runner user (the job root is 0700 to it).

## P16 (legacy distro)

Owns the trust-source decision above and the API calls (the broker makes them; the App key stays in the distro).
Keeps the legacy pool's compile cache untouched until approved cutover, and removes sccache wiring as its ledger item
says. The guest code here does not run in the legacy distro.

## P21 (image composition), P04 / P22 (qualification)

- P21: install the overlay in each generation, record `install.json` (zccache hashes, toolchain digest) in the catalog,
  and mark every generation that contains zccache as **not for redistribution** until the owner's AGPL decision.
- P04 / P22: when a matrix row becomes `qualified`, bump `matrix_revision` and run
  `python -B -I guests/cache/gen_wrappers.py`; `--check` fails until `wrappers.json` is regenerated. The lab items in
  README.md "To confirm in the lab" gate the first qualified row; the shared-root proof gates `-SharedRoots`.

## Coordinator (CI)

Not wired yet: add `tests/guests/cache` to the Pester `Run.Path` (both PowerShell editions; the tests start the shim
through PowerShell 7, present on hosted Windows), and on hosted `ubuntu-latest` run
`bash tests/guests/cache/zccache_test.sh`, `python3 -B -I -m unittest discover -s tests/guests/cache -p "test_*.py"`,
`python3 -B -I guests/cache/gen_wrappers.py --check` and shellcheck 0.11.0 at `-S warning` on
`guests/cache/linux/aap-zccache.sh`, `tests/guests/cache/zccache_test.sh` and `tests/guests/cache/fakes/fake-zccache`
and `fake-cc`. Each suite works under one per-run folder in the temp directory, stops the fakes it started and fails
when that folder or one of its processes survives the run.
