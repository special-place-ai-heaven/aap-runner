# zccache guest integration: what other items wire (P13)

P13 ships the guest-side pieces in `guests/cache` and the host-side trust classifier. Every shared file stays with its
owner; this page lists what each owner has to do, and the decisions P13 cannot make. Read [README.md](README.md) first.

## Decision for the owner and P16: where the job's trust class comes from

Contract rule 6 needs the job's event, ref and head repository from GitHub's record of the job assigned to the runner,
bound before any shared root attaches, never from the guest. The broker's App has only the organization
self-hosted-runners permission (broker.md), which cannot read a job, its run or its event.

Two facts shape the answer. First, GitHub assigns a job to a runner only after the runner is online, so the class can
never be known at VM creation or registration: the shared root is attached **during** the job, and compiler calls
before the attach use the private root. Second, nothing in the guest can be trusted for the class.

| Option | What it needs | Verdict |
|---|---|---|
| **A. App gains `actions: read`** (repository permission) | After the broker's `status` reports the runner busy: list the runner group's repositories (`GET /orgs/{org}/actions/runner-groups/{id}/repositories`, the existing permission), list each one's runs in progress (`GET /repos/{o}/{r}/actions/runs?status=in_progress`), their jobs (`GET .../runs/{run_id}/jobs`), and pick the job whose `runner_name` is the VM name. Its run gives `event`, `head_branch`, `repository.id`, `head_repository.id`; `GET /repos/{o}/{r}` gives `default_branch` (metadata, always granted). Feed them to `Get-AapCacheTrustClass` | **Recommended.** It reads exactly the record the rule names. Cost: the App can also read run logs and artifacts of the repositories it is installed on, and a leaked App key exposes them; that widening is the owner's call |
| B. One runner group per trust class, the trusted group restricted to selected workflows at `refs/heads/<default>` | Two groups and labels; the allocator must choose a group before any job exists | **Not sufficient alone.** `pull_request_target`, `workflow_run` and `issue_comment` run default-branch workflow files, so the restriction admits them; an event check is still needed, which is option A. It also splits the five slots by class in advance |

**Tag hazard (any option).** For a tag push, the run's `head_branch` is the tag name, so a tag named like the default
branch looks like the branch. `Get-AapCacheTrustClass` therefore needs `-TagNamedLikeBranch`; `$null` (not checked)
never yields `trusted`. The check is one ref lookup (`GET /repos/{o}/{r}/git/matching-refs/tags/<name>`); P16 confirms
in the lab which permission it needs. If it needs `contents: read`, the owner chooses between granting that and a tag
ruleset in every repository of the group that forbids such tags, recorded host-side, in which case the host passes
`$false` on the strength of that ruleset.

**Deadline.** If the class is not established within a bounded time after the runner turns busy (start with 60 s),
the job keeps its private root for its whole life. No retry later in the job.

**Untrusted shared roots** stay off unless the owner turns them on: an untrusted job then gets the untrusted root of
its repository; otherwise only its private root.

## P12 (supervisor, status) and P19 (installer, storage)

1. A host **cache tier** for shared roots: one VHDX per namespace (repository id, class, platform, toolchain digest),
   under an admin-only root that passes the same owner, ACL, reparse-point and ancestor checks as the other storage
   tiers (ARCHITECTURE.md section 3). P19 adds the tier to the storage document; no default path.
2. Each namespace disk carries `aap-cache-root.json` at its root, written by the host when the disk is created:
   `{"schema":1,"root_id":"ns-<16 hex>","namespace":{"repository_id":<id>,"repository":"owner/name","trust_class":"trusted"|"untrusted","platform":"linux-x86_64"|"windows-x86_64","toolchain_digest":"<64 hex>"}}`.
   The digest comes from the generation's `install.json` (P21 copies it into the catalog).
3. An **exclusive read-write lease** per namespace disk: attached to at most one VM at a time; a second concurrent job
   of the same namespace gets nothing (private root). The lease ends at VM destroy; a lost heartbeat does not free it
   until the VM is proven gone (allocator rule).
4. The class (option A above) is computed host-side, and the disk is attached only for a matching class. Bind order:
   compute class, take the lease, hot-add the disk to the running VM, then send the binding to the guest.
5. `status.v5.json` `profiles[].cache`: report the guest's `Get-AapZcState` / `state` `state` and `detail` as they come
   (already in the schema's enum and limits). Bytes per root go to evidence, not the tray.

## P10 / P11 (providers) and P02 (guest transport)

1. **Contract change needed**: guest-transport.md has no command that can carry a binding mid-job (`probe`,
   `deliver_registration`, `start_runner`, `status`, `collect`, `shutdown`). Add a one-shot `bind_cache` with a payload
   of at most 1 KiB: the binding record
   `{"schema":1,"runner_name":"<VM name>","root_id":"ns-...","budget_bytes":<n>,"namespace":{...same five fields...}}`.
   P02 owns the revision; P10/P11 send it, P14/P15 handle it. Until it exists, no shared root is ever bound, which is
   safe (private roots only).
2. Hot-add of the namespace VHDX to the running VM (SCSI) after the lease, and removal at destroy without writing to it
   from the host.
3. Size each job's scratch disk to include the private root budget passed to `Initialize-AapZcJob` / `init`.

## P14 (Windows guest bootstrap)

1. Image build: `Install-AapZcCache -Archive <staged zip> -Provenance <zip>.provenance.json -InstallDir "C:\Program Files\aap-guest\cache" -Toolchains <list>`.
   The toolchain list is `{"toolchains":[{"compiler","compiler_version","path"}]}` for every compiler the P04 matrix
   names, at the versions the P01 inventory records (`clang`, `clang++`, `clang-cl` 20.1.8; `cl`, `link` with the exact
   `19.xx` toolset once P04 records it; `lld-link`; `rustc` only as the real toolchain binary, never the rustup proxy).
   The folder is Administrators-only for writes, readable and executable by the runner user.
2. Agent, before `Runner.Listener` starts and from its own clean environment:
   `Initialize-AapZcJob -InstallDir ... -JobRoot <scratch>\aap-cache -BudgetBytes <n>`; merge `state\runner.env` into
   the runner's environment (the runner's `.env`). Nothing else: no `ZCCACHE_*` variable, no PATH change.
3. On `bind_cache`: mount the hot-added disk, write the payload to an admin-only file, call
   `Connect-AapZcSharedRoot -JobRoot ... -BindingPath ... -MountPath ... -RunnerName <own VM name>`, and answer with
   its `Attached`/`Reason`.
4. `status`/`collect`: include `Get-AapZcState` (`state`, `detail`; bytes in `collect`).
5. **Gap G3, rustc on Windows**: `RUSTC_WRAPPER` must name one executable; a `.cmd` wrapper mangles arguments and a
   PowerShell script cannot be named directly. Before any Windows rustc row is qualified, P14 ships a small native
   launcher that runs `zcshim.ps1` with the exact argv. Until then `Initialize-AapZcJob` never sets `RUSTC_WRAPPER`, so
   rustc builds directly. CMake's launcher list (`powershell.exe;-NoProfile;...;-File;zcshim.ps1`) covers C/C++ where
   the generator honours `CMAKE_<LANG>_COMPILER_LAUNCHER` (Ninja, Makefiles); a generator or build system that ignores
   it compiles directly, which is correct but uncached. The lab confirms per generator.

## P15 (Linux guest bootstrap)

1. Image build, as root: `aap-zccache.sh install <staged tar.gz> <tar.gz>.provenance.json /usr/local/libexec/aap-guest/cache <list>`
   (files root-owned, 0755). Toolchain paths are the ones jobs call (`/usr/bin/clang-18`, `/usr/bin/gcc-13`, ...); the
   real binary behind a symlink is recorded and checked too. `rustc` only as the real toolchain binary.
2. Agent, before the runner starts, from a clean environment: `aap-zccache.sh init <install> <scratch>/aap-cache <bytes>`;
   merge `state/runner.env` into the runner's environment. A qualified rustc pair sets `RUSTC_WRAPPER` to `zcshim`.
3. On `bind_cache`: `aap-zccache.sh attach <job root> <binding file> <mount> <own VM name>`; reply with its JSON.
4. `status`/`collect`: `aap-zccache.sh state <job root>`.
5. The job's mount of the shared disk must belong to root and not be a symlink; the runner user needs read-write access
   to `<mount>/root` only through the shim's zccache calls (the daemon runs as the agent's user; P15 picks the user).

## P16 (legacy distro)

Owns the trust-source decision above and the API calls (the broker or the supervisor makes them; the App key stays in
the distro). Keeps the legacy pool's compile cache untouched until approved cutover, and removes sccache wiring as its
ledger item says. The guest code here does not run in the legacy distro.

## P21 (image composition), P25 (retention), P04 / P22 (qualification)

- P21: install the overlay in each generation, record `install.json` (zccache hashes, toolchain digest) in the catalog,
  and mark every generation that contains zccache as **not for redistribution** until the owner's AGPL decision.
- P25: owns shared namespace disks: delete on digest change or repository removal, whole-root reset when
  `Get-AapZcState` reports `over-budget` on a shared root, and nothing finer. Never trims files inside a root.
- P04 / P22: when a matrix row becomes `qualified`, bump `matrix_revision` and run
  `python -B -I guests/cache/gen_wrappers.py`; `--check` fails until `wrappers.json` is regenerated. The lab items in
  README.md "To confirm in the lab" gate the first qualified row.

## Coordinator (CI)

Not wired yet: add `tests/guests/cache` to the Pester `Run.Path` (both PowerShell editions), and on hosted
`ubuntu-latest` run `bash tests/guests/cache/zccache_test.sh`, `python3 -B -I -m unittest discover -s tests/guests/cache -p "test_*.py"`,
`python3 -B -I guests/cache/gen_wrappers.py --check` and shellcheck at `-S warning` on `guests/cache/linux/aap-zccache.sh`,
`tests/guests/cache/zccache_test.sh` and the bash fakes.
