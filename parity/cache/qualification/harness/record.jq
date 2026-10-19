# Evidence record for one harness run, shared by qualify.sh and qualify.ps1 (jq 1.7+).
# Input: {meta, runs, errors}. The row always stays "direct": the harness covers method steps 1-6;
# a reviewer sets "qualified" only after lab steps 7-9 pass (README "Verdicts").
# Missing or mistyped input fails a check and never passes one: exits and counts must be numbers,
# hashes 64 hex digits, and two absent values never compare equal.
def obj: if type == "object" then . else {} end;
def num: type == "number";
def sha: type == "string" and test("^[0-9a-f]{64}$");
def same($a; $b): ($a.artifacts | type) == "object" and ($b.artifacts | type) == "object"
  and $a.artifacts == $b.artifacts;
# Journal counts from journal.jq: six numbers, or null when no session id came back.
def journal_ok($r): ($r.journal | type) == "object"
  and all($r.journal | .hit, .miss, .error, .link_hit, .link_miss, .other; num);
def hits($r): $r.journal.hit + $r.journal.link_hit;
# No hit and no unrecognised outcome: upstream lists every outcome (README 1247), so "other"
# could be a hit under another name.
def no_hits($r): journal_ok($r) and hits($r) == 0 and $r.journal.other == 0;
# A corrupted entry was looked up (a miss, error or link miss), nothing was served, and the
# build still equals uncached.
def rejected($r; $u):
  ($r.corrupted_files | num) and $r.corrupted_files >= 1 and ($u.exit | num)
  and $r.prime_exit == $u.exit and $r.exit == $u.exit and same($u; $r)
  and no_hits($r) and $r.journal.miss + $r.journal.error + $r.journal.link_miss >= 1;
# The version as a whole dotted number, e.g. 18.1.3 but not 18.1.30.
def names_version($text; $v):
  ($text | type) == "string" and ($v | type) == "string" and ($v | test("^[0-9]+([.][0-9]+)+$"))
  and ($text | test("(^|[^0-9.])" + ($v | gsub("[.]"; "[.]")) + "($|[^0-9.]|[.]($|[^0-9]))"));
def harness_vars: ["ZCCACHE_MODE", "ZCCACHE_CACHE_DIR", "ZCCACHE_SESSION_ID"];
def tool_keys: ["compiler", "compiler_path", "compiler_sha256", "zccache", "zccache_sha256",
  "zccache-fp_sha256", "jq"];

obj | (.meta | obj) as $m | (.runs | obj | map_values(obj)) as $r | (.errors | obj | map_values(obj)) as $e
| $r.uncached as $u | ($m.tool_versions | obj) as $t
| ({
    ok_exit_zero: ($u.exit == 0),
    ok_runs_produce_primary: (($r | length) >= 1 and all($r[]; .primary_present == true)),
    exit_codes_equal: (($u.exit | num) and $r.cold.exit == $u.exit and $r.warm.exit == $u.exit),
    artifacts_equal: (same($u; $r.cold) and same($u; $r.warm)),
    cold_has_no_hits: no_hits($r.cold),
    warm_has_hits: (journal_ok($r.warm) and hits($r.warm) >= 1),
    errors_stay_errors: (all($e.uncached, $e.cold, $e.warm; (.exit | num) and .primary_present == false)
      and $e.uncached.exit != 0 and $e.cold.exit == $e.uncached.exit and $e.warm.exit == $e.uncached.exit),
    poisoned_artifact_rejected: rejected($r.poisoned_artifact; $u),
    poisoned_same_size_rejected: rejected($r.poisoned_same_size; $u),
    poisoned_marker_rejected: rejected($r.poisoned_marker; $u),
    zccache_env_clean: (($r | length) >= 1 and all($r[], $e[]; (.zccache_env | type) == "array"
      and all(.zccache_env[]; IN(harness_vars[])))),
    daemons_pinned: (($t.zccache_sha256 | sha) and ($t["zccache-fp_sha256"] | sha)
      and ($m.daemons | type) == "array" and ($m.daemons | length) >= 1
      and all($m.daemons[]; type == "object" and .in_private_bin == true and (.sha256 | sha)
        and (.sha256 == $t.zccache_sha256 or .sha256 == $t["zccache-fp_sha256"]))),
    no_crash_dumps: (($m.crash_dumps | type) == "object" and ($m.crash_dumps | length) >= 1
      and all($m.crash_dumps[]; num and . == 0)),
    tool_versions_recorded: (($m.tool_versions | type) == "object" and all(tool_keys[]; . as $k | $t | has($k))
      and all($t[]; type == "string" and test("^[ -~]{1,120}$")))
  }
  + (if ($m.compiler | IN("cl", "link")) then {} else {
      compiler_version_observed: names_version($t.compiler; $m.compiler_version)
    } end)
  + (if $m.invocation == "debug-pdb" then {
      relocated_matches_direct: ($r.relocated_direct.exit == 0 and $r.relocated.exit == 0
        and same($r.relocated_direct; $r.relocated))
    } else {} end)) as $c
| [$c | to_entries[] | select(.value != true) | .key] as $failed
| {
    schema: 1,
    item: "P04",
    platform: $m.platform,
    command: $m.command,
    tool_versions: $m.tool_versions,
    os: $m.os,
    env: $m.env,
    started_at: $m.started_at,
    ended_at: $m.ended_at,
    runs: $r,
    error_runs: $e,
    daemons: $m.daemons,
    daemons_stopped: $m.daemons_stopped,
    crash_dumps: $m.crash_dumps,
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
