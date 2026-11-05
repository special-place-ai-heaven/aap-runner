#![forbid(unsafe_code)]

//! Control-plane logic of the Linux runner pool, moved out of `distro/manager.sh` one verified
//! slice at a time. Bash keeps the docker and systemctl glue and calls the `aap-pool` binary for
//! the pure parts. Every module is pinned to the bash behaviour it replaces by golden tests
//! generated from `manager.sh` itself (`tests/pool_core_limits_golden_test.sh`).

pub mod cli;
pub mod limits;
