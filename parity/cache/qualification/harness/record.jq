# Evidence record for one harness run, shared by qualify.sh and qualify.ps1 (jq 1.7+).
# Input: {meta, runs, errors}. The row always stays "direct": the harness covers method steps 1-6;
# a reviewer sets "qualified" only after lab steps 7-9 pass (README "Verdicts").
def same($a; $b): $a != null and $b != null and $a.artifacts == $b.artifacts;
def hits($r): ($r.journal.hit // 0) + ($r.journal.link_hit // 0);
def looked_up($r): $r.journal != null and ([$r.journal[]?] | add // 0) >= 1;
# A corrupted entry was looked up, not served, and the build still equals the uncached build.
def rejected($r; $u):
  $r != null and ($r.corrupted_files // 0) >= 1 and $r.prime_exit == $u.exit
  and $r.exit == $u.exit and same($u; $r) and looked_up($r) and hits($r) == 0;

.meta as $m | .runs as $r | .errors as $e | $r.uncached as $u
| ({
    ok_exit_zero: ($u.exit == 0),
    exit_codes_equal: ($r.cold.exit == $u.exit and $r.warm.exit == $u.exit),
    artifacts_equal: (same($u; $r.cold) and same($u; $r.warm)),
    cold_has_no_hits: ($r.cold.journal != null and hits($r.cold) == 0),
    warm_has_hits: ($r.warm.journal != null and hits($r.warm) >= 1),
    errors_stay_errors: ($e.uncached != null and $e.cold != null and $e.warm != null
      and $e.uncached.exit != 0
      and $e.cold.exit == $e.uncached.exit and $e.warm.exit == $e.uncached.exit
      and ([$e.uncached, $e.cold, $e.warm] | all(.primary_present == false))),
    poisoned_same_size_rejected: rejected($r.poisoned_same_size; $u),
    poisoned_marker_rejected: rejected($r.poisoned_marker; $u)
  }
  + (if $m.invocation == "debug-pdb" then {
      relocated_matches_direct: ($r.relocated_direct != null and $r.relocated_direct.exit == 0
        and $r.relocated.exit == $r.relocated_direct.exit and same($r.relocated_direct; $r.relocated))
    } else {} end)) as $c
| [$c | to_entries[] | select(.value != true) | .key] as $failed
| {
    schema: 1,
    item: "P04",
    platform: $m.platform,
    command: $m.command,
    tool_versions: $m.tool_versions,
    env: $m.env,
    started_at: $m.started_at,
    ended_at: $m.ended_at,
    runs: $r,
    error_runs: $e,
    checks: $c,
    harness_pass: ($failed | length == 0),
    lab_gates: {concurrency: null, daemon_restart: null, unsupported_invocations: null},
    row: {
      compiler: $m.compiler,
      compiler_version: $m.compiler_version,
      invocation: $m.invocation,
      mode: "direct",
      evidence_ref: $m.evidence_ref,
      reason: ((if ($failed | length) == 0 then "harness checks pass; lab steps 7-9 pending"
                else "harness checks failed: " + ($failed | join(",")) end)[0:200])
    }
  }
