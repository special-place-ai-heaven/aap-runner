# GitHub runner parity: code audit and required changes

As of 2026-10-18. Inspected source at `ae001a6`, with M4 wizard work in progress.
This is a read-only assessment of runner execution and provisioning, not a claim
that the running installation has been changed or that parity has been achieved.

## Required outcome

The owner requires native Windows and Ubuntu build environments that provide the
same build service as the corresponding GitHub-hosted runners, with less repeated
dependency repair by coding agents. Preserve the rig's isolation, resource controls,
ephemeral jobs, and maximum of five concurrent jobs across both operating systems.
Ubuntu remains 24.04. Fork pull-request workflows remain prohibited.

The intended complete cache replacement is **zccache**. It is a requirement for
future work; the current code still uses sccache. Do not assume binary, option,
environment-variable, or cache-format compatibility between them.

## What the code actually supplies

SymForge was used for the repository map, file context, and source/knowledge
searches. Its admission policy withheld several shell files containing secret
handling code, so their relevant non-secret sections were inspected directly.
No runner process, install script, WSL distro, or scheduled task was started,
stopped, or reconfigured for this assessment.

| Evidence in this checkout | Consequence for parity |
| --- | --- |
| `distro/Dockerfile:7` starts from scratch and adds the Ubuntu WSL rootfs; lines 16-46 install a short package list and Docker. | This is a custom minimal Linux image, not GitHub's fully provisioned runner image. The recipe does not install Clang/LLD, CMake/Ninja, Rust, Node, .NET, or a Windows SDK. Individual workflows may install some of these. |
| `distro/Dockerfile:48-83` creates the runner user and explicitly rejects sudo access. | Ordinary hosted Ubuntu workflows that install system packages with sudo encounter a different privilege model. |
| `distro/ephemeral-entry.sh:7` starts inner Docker; lines 59-80 register the Linux runner and launch it through runuser. | Job startup supplies execution and Docker, but does not provision a hosted tool cache or SDK environment. Environment initialization must be an explicit part of a replacement image. |
| `distro/manager.sh:1229-1247` creates a Sysbox container from the configured image and sets `RUSTC_WRAPPER=sccache`. | All jobs are Linux container jobs. Rust builds depend on each workflow supplying the wrapper. zccache migration must cover this injection as well as the image and workflows. |
| `supervisor/aap-runner-supervisor.ps1:642` starts WSL and the Linux systemd units; its settings describe one Linux pool. | There is no native Windows worker/VM lifecycle or shared Windows/Linux capacity allocator. Windows image parity cannot be implemented solely inside this bash manager. |
| `distro/bootstrap.sh:990-1011` builds the image and checks Sysbox startup and mounts. | Infrastructure preflight does not establish compiler, linker, SDK, environment, or packaging compatibility. |

Fresh containers and inner Docker are already implemented. The missing pieces are
the broader build environment, the native Windows execution backend, and evidence
that those environments behave like the selected hosted baselines. WSL itself is
not a failed Linux-runner design, but Sysbox containers sharing a WSL kernel are
not interchangeable with full hosted VMs for every workflow.

The consuming AAP CI workflow was also checked read-only (workflow blob
`b65d76a87c490985685a3ea573714d9b798b9811`). Its Rust jobs install Rust and sccache,
its frontend job installs Node, and its known-failures job explicitly clears the
wrapper. This shows that setup exists in some workflows; it does not establish a
complete shared environment or explain every reported failure.

## Changes required

1. **Pin complete upstream baselines.** Use GitHub's Windows and Ubuntu 24.04
   provisioning definitions and toolsets, including their environment configuration
   and validation scripts. Record the source commit, image release, built artifact
   hash, full installed-tool inventory, paths, and cached tool versions. Do not
   substitute a handpicked list of popular packages for the required inventory.
2. **Add native Windows execution.** Extend the Windows supervisor with disposable
   Windows workers, preferably Hyper-V VM clones restored from a validated image.
   Keep the existing Linux manager responsible for its Linux jobs. If full Ubuntu
   VM behavior is required by parity tests, use Ubuntu VM workers for that baseline
   rather than declaring the Sysbox profile equivalent without proof.
3. **Coordinate capacity and routing.** GitHub routes jobs through runner labels.
   Register truthful OS/profile labels and enforce a shared five-job ceiling plus
   aggregate CPU, memory, disk, and IO budgets. Version settings/status contracts and
   update the tray, supervisor, backend tests, and contract docs together.
4. **Match guest privileges and initialization.** Hosted Ubuntu permits passwordless
   sudo and hosted Windows runs jobs as administrators. Provide equivalent job
   privileges inside disposable guests, not on the owner's Windows desktop. Match
   tool-cache layout, PATH, SDK variables, shells, and supported setup-action behavior.
5. **Migrate the entire cache integration to zccache.** Inspect its actual supported
   interface first. Replace provisioning, wrapper/environment injection, startup
   allowlists, workflow setup, cache paths/ownership, cleanup limits, diagnostics,
   tests, and docs. Do not treat an existing sccache cache as zccache-compatible.
6. **Prove parity before advertising it.** Compare the complete inventory with the
   pinned hosted baseline, then run the same representative workflows on both
   environments: Rust with native C/C++ dependencies, MSVC compile/link, Windows
   resources/packaging, .NET, Node, and Docker/services where supported by the
   selected baseline. Test clean and warm cache runs, isolated concurrent jobs, and
   worker reset. Preserve the first causal error and distinguish missing baseline
   tools from project-specific dependency declarations.

## Upstream evidence and implementation boundaries

The upstream source inspected was `actions/runner-images` commit
`ee1ff4569e381a9649b400338bdc8ceb7e18a80e`. Its Windows 2025 build template references
79 distinct install/configuration scripts, including Visual Studio, LLVM, Rust,
.NET, toolsets, user setup, and system environment configuration. Its builder is
Azure-specific; a local Hyper-V build adapter is additional work, not an existing
drop-in local installer. Choose and record one exact Windows image variant and
release rather than following a moving `windows-latest` label silently.

- [Runner image definitions](https://github.com/actions/runner-images/tree/ee1ff4569e381a9649b400338bdc8ceb7e18a80e)
- [Windows build template](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/templates/build.windows-2025.pkr.hcl)
- [Windows inventory](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/Windows2025-Readme.md)
- [Ubuntu 24.04 inventory](https://github.com/actions/runner-images/blob/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md)
- [Hosted VM lifecycle and guest privileges](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [cargo-xwin requirements](https://github.com/rust-cross/cargo-xwin#prerequisite)

xwin cross-compilation is a separate useful capability; it does not supply native
Windows execution, services, tests, or packaging behavior. M4 adds an installation
wizard for the existing Linux backend. It does not implement the changes above.
Deployment remains separately controlled by the owner after reviewed code lands.
