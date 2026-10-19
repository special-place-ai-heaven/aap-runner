# Outcome counts of one per-session compile journal, shared by both harnesses (jq -R -s).
# Outcomes per README 1240-1252 at the pin: hit, miss, error, link_hit, link_miss. Lines that
# are not JSON are skipped; JSON without a string outcome counts as "other".
split("\n")
| map(fromjson? | ((.outcome? | strings) // "other"))
| reduce .[] as $o ({hit: 0, miss: 0, error: 0, link_hit: 0, link_miss: 0, other: 0};
    if has($o) then .[$o] += 1 else .other += 1 end)
