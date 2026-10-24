"""The hard VM lifetime cap's contract rules (owner decision Q4; parity/contracts allocator.md,
status-settings.md, backend-lifecycle.md), tested through the reference validator.

    python -B -I -m unittest discover -s tests/parity/contracts -p "test_*.py"

What is checked, none of it wording:
  * the ceiling is one number, 6, in every schema a cap value can appear in, so no layer accepts a cap
    that another layer refuses;
  * settings schemas 3 and 4 accept exactly 1..6 whole hours, and moving a schema 3 file to schema 4 is
    a rename that never changes the value (7..72 is refused before the move, not clamped);
  * the journal evidence and the status slot object obey the cap's arithmetic and placement rules at
    their boundaries, and the evidence follows the power-off (latch in memory, power off, then persist);
  * the deadline record a VM carries and the clock record that survives restarts (high-water mark, boot id,
    latched decisions) obey their rules at their boundaries, and the record's digest is the documented one;
  * every cap invalid fixture is its valid base plus one defect (CASES): the base validates, the fixture
    on disk is exactly base plus the listed edits, and the validator refuses it for the stated reason.
"""
import copy
import hashlib
import importlib.util
import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CONTRACTS = REPO / "parity" / "contracts"
FIXTURES = CONTRACTS / "fixtures"


def _load_validator():
    spec = importlib.util.spec_from_file_location("contract_validate", CONTRACTS / "validate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


V = _load_validator()
_SCHEMAS = {}
TIME = "%Y-%m-%dT%H:%M:%SZ"


def schema(name):
    if name not in _SCHEMAS:
        _SCHEMAS[name] = V.load(CONTRACTS / f"{name}.schema.json")
    return _SCHEMAS[name]


def fixture(contract, path):
    """A fixture by its path under fixtures/<contract>/, with or without .json."""
    return V.load(FIXTURES / contract / (path if path.endswith(".json") else path + ".json"))


def verdict(contract, instance):
    """None when the validator accepts the instance, else the message it refuses it with."""
    try:
        V.validate(contract, schema(contract), instance)
    except V.Invalid as e:
        return str(e)
    return None


def apply(doc, edits):
    """A deep copy of doc with edits applied: ("set", "a.b.0.c", value) or ("del", "a.b"); a numeric
    path part indexes a list."""
    doc = copy.deepcopy(doc)
    for op, path, *value in edits:
        keys = [int(k) if k.isdigit() else k for k in path.split(".")]
        node = doc
        for k in keys[:-1]:
            node = node[k]
        if op == "set":
            node[keys[-1]] = copy.deepcopy(value[0])
        else:
            del node[keys[-1]]
    return doc


def stamp(moment):
    return moment.strftime(TIME)


def parse(text):
    return datetime.strptime(text, TIME)


# ---- the invalid fixtures: (contract, name, base fixture, edits, the error the validator must give) ----
# The edits are the one defect, plus whatever keeps the rest of the document consistent with it (a cap of
# seven hours keeps a deadline seven hours out, so the ceiling is the only rule it breaks).

CAP_LIVE = {"cap_hours": 6, "started_utc": "2026-10-22T09:00:00Z", "deadline_utc": "2026-10-22T15:00:00Z", "reason": None}
EVIDENCE = {"cap_hours": 6, "started_utc": "2026-10-19T12:00:00Z", "deadline_utc": "2026-10-19T18:00:00Z",
            "elapsed_s": 21600, "trigger": "deadline", "power_off_utc": "2026-10-19T18:00:00Z", "reason": "vm_lifetime_cap"}
SETTINGS_V4 = "valid/owner-example-per-profile"
SETTINGS_V4_EVEN = "valid/windows-only-even"
LIVE = "valid/vm-lifetime-cap-live"
RECLAIMING = "valid/vm-lifetime-cap-reclaiming"
EVIDENCE_INTENT = "valid/destroy-intent-vm-lifetime-cap"
RUN_ONE_FAILED = "valid/run-one-failed-vm-lifetime-cap"
NOTES = "valid/windows-managed"
NOTES_LINUX = "valid/linux-managed"
CLOCK = "valid/supervisor-idle"
WATCHDOG = "valid/watchdog-with-latch"
LATCH = {"reservation_id": "r-1a2b3c4d000000b1", "vm_id": "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b",
         "decided_utc": "2026-10-22T15:00:30Z", "cap_hours": 6, "elapsed_s": 21630,
         "trigger": "deadline", "enforcement_stage": "power_off_attempted"}


def renoted(base, **fields):
    """Edits that change identity fields of a Notes record and keep its `check` right, so the defect is only the one listed."""
    doc = dict(fixture("vm-cap-notes", base), **fields)
    return [("set", k, v) for k, v in fields.items()] + [("set", "check", V.notes_check(doc))]

CASES = [
    # settings schema 4: the ceiling, the rename, the version and the rules it shares with schema 3
    ("settings-v4", "cap-seven-hours", SETTINGS_V4, [("set", "vm_lifetime_cap_hours", 7)],
     "$.vm_lifetime_cap_hours: above maximum 6"),
    ("settings-v4", "cap-72-hours-the-old-maximum", SETTINGS_V4, [("set", "vm_lifetime_cap_hours", 72)],
     "$.vm_lifetime_cap_hours: above maximum 6"),
    ("settings-v4", "cap-zero", SETTINGS_V4, [("set", "vm_lifetime_cap_hours", 0)],
     "$.vm_lifetime_cap_hours: below minimum 1"),
    ("settings-v4", "cap-fraction", SETTINGS_V4, [("set", "vm_lifetime_cap_hours", 5.5)],
     "$.vm_lifetime_cap_hours: expected type integer"),
    ("settings-v4", "cap-as-string", SETTINGS_V4, [("set", "vm_lifetime_cap_hours", "6")],
     "$.vm_lifetime_cap_hours: expected type integer"),
    ("settings-v4", "old-key-in-place-of-the-cap", SETTINGS_V4,
     [("del", "vm_lifetime_cap_hours"), ("set", "lease_wall_clock_hours", 6)],
     "missing required property 'vm_lifetime_cap_hours'"),
    ("settings-v4", "both-cap-keys", SETTINGS_V4, [("set", "lease_wall_clock_hours", 6)],
     "unexpected property 'lease_wall_clock_hours'"),
    ("settings-v4", "future-schema-5", SETTINGS_V4, [("set", "schema", 5)], "$.schema: must be 4"),
    ("settings-v4", "three-plus-three", SETTINGS_V4_EVEN,
     [("set", "runner_count", 3), ("set", "windows_runner_count", 3)],
     "linux + windows runner counts must be 1..5"),
    ("settings-v4", "shares-sum-95", SETTINGS_V4, [("set", "windows_share_percent", 25)],
     "profile shares plus host_reserve_percent must equal 100"),
    # settings schema 3 keeps its key and now stops at the ceiling (7..72 was valid in revision 3)
    ("settings-v3", "lease-hours-seven", "valid/owner-example-per-profile", [("set", "lease_wall_clock_hours", 7)],
     "$.lease_wall_clock_hours: above maximum 6"),
    ("settings-v3", "lease-hours-72-the-old-maximum", "valid/owner-example-per-profile",
     [("set", "lease_wall_clock_hours", 72)], "$.lease_wall_clock_hours: above maximum 6"),
    # status.v5.json: the slot's cap object and the schemas the supervisor may advertise
    ("status-v5", "cap-deadline-not-start-plus-hours", LIVE,
     [("set", "slots.3.vm_lifetime_cap.deadline_utc", "2026-10-22T14:00:00Z")],
     "deadline_utc must be started_utc plus cap_hours hours"),
    ("status-v5", "cap-hours-seven", LIVE,
     [("set", "slots.3.vm_lifetime_cap.cap_hours", 7), ("set", "slots.3.vm_lifetime_cap.deadline_utc", "2026-10-22T16:00:00Z")],
     "$.slots[3].vm_lifetime_cap.cap_hours: above maximum 6"),
    ("status-v5", "cap-fired-slot-still-busy", LIVE,
     [("set", "slots.3.vm_lifetime_cap.reason", "vm_lifetime_cap"),
      ("set", "detail", "vm_lifetime_cap: slot 4 reached the 6 h cap")],
     "slot 4: the cap has fired, so the slot is creating (no VM id yet), deleting or quarantined, not busy"),
    ("status-v5", "cap-on-legacy-slot", LIVE, [("set", "slots.0.vm_lifetime_cap", CAP_LIVE)],
     "slot 1: a wsl-legacy slot has no VM lifetime cap"),
    ("status-v5", "slot-past-deadline-cap-not-fired", LIVE, [("set", "updated", "2026-10-22T15:01:01Z")],
     "slot 4: past its deadline_utc and the cap has not fired"),
    ("status-v5", "cap-fired-detail-silent", RECLAIMING, [("set", "detail", "")],
     "a slot is being reclaimed for the cap: detail must start with vm_lifetime_cap"),
    ("status-v5", "cap-start-not-a-real-time", LIVE,
     [("set", "slots.3.vm_lifetime_cap.started_utc", "2026-02-30T09:00:00Z"),
      ("set", "slots.3.vm_lifetime_cap.deadline_utc", "2026-02-30T15:00:00Z")],
     "started_utc is not a real UTC time"),
    ("status-v5", "cap-reason-wrong-word", RECLAIMING, [("set", "slots.3.vm_lifetime_cap.reason", "lifetime_cap")],
     '$.slots[3].vm_lifetime_cap.reason: "lifetime_cap" not in enum'),
    ("status-v5", "settings-schemas-lists-unknown-5", LIVE, [("set", "settings_schemas", [2, 3, 4, 5])],
     "$.settings_schemas[3]: 5 not in enum"),
    ("status-v5", "applied-settings-schema-5", LIVE, [("set", "applied_settings_schema", 5)],
     "$.applied_settings_schema: 5 not in enum"),
    # the provider journal: the evidence on the destroy intent, and the code on the ops the cap can end
    ("backend-lifecycle", "cap-evidence-deadline-off-by-an-hour", EVIDENCE_INTENT,
     [("set", "lifetime_cap.deadline_utc", "2026-10-19T19:00:00Z")],
     "deadline_utc must be started_utc plus cap_hours hours"),
    ("backend-lifecycle", "cap-evidence-hours-seven", EVIDENCE_INTENT,
     [("set", "lifetime_cap.cap_hours", 7), ("set", "lifetime_cap.deadline_utc", "2026-10-19T19:00:00Z"),
      ("set", "lifetime_cap.elapsed_s", 25200)],
     "$.lifetime_cap.cap_hours: above maximum 6"),
    ("backend-lifecycle", "cap-evidence-elapsed-below-cap", EVIDENCE_INTENT, [("set", "lifetime_cap.elapsed_s", 21599)],
     "elapsed_s is below cap_hours"),
    ("backend-lifecycle", "cap-evidence-missing-elapsed", EVIDENCE_INTENT, [("del", "lifetime_cap.elapsed_s")],
     "missing required property 'elapsed_s'"),
    ("backend-lifecycle", "cap-evidence-wrong-reason", EVIDENCE_INTENT, [("set", "lifetime_cap.reason", "clone over cap")],
     '$.lifetime_cap.reason: must be "vm_lifetime_cap"'),
    ("backend-lifecycle", "cap-evidence-start-not-a-real-time", EVIDENCE_INTENT,
     [("set", "lifetime_cap.started_utc", "2026-02-30T12:00:00Z"), ("set", "lifetime_cap.deadline_utc", "2026-02-30T18:00:00Z")],
     "started_utc is not a real UTC time"),
    ("backend-lifecycle", "cap-evidence-on-run-one-failed", RUN_ONE_FAILED, [("set", "lifetime_cap", EVIDENCE)],
     "lifetime_cap rides only on a destroy intent record"),
    ("backend-lifecycle", "cap-evidence-on-destroy-done", EVIDENCE_INTENT,
     [("set", "phase", "done"), ("set", "result", {"code": "absent", "detail": "VM and folders observed absent"})],
     "lifetime_cap rides only on a destroy intent record"),
    ("backend-lifecycle", "cap-code-on-destroy-failed", "valid/destroy-intent",
     [("set", "phase", "failed"), ("set", "result", {"code": "vm_lifetime_cap", "detail": "cap reached"})],
     "never destroy or reconcile"),
    ("backend-lifecycle", "cap-code-on-reconcile-failed", "valid/destroy-intent",
     [("set", "op", "reconcile"), ("set", "idempotency_key", "r-1a2b3c4d000000b1/3/reconcile"),
      ("set", "phase", "failed"), ("set", "result", {"code": "vm_lifetime_cap", "detail": "cap reached"})],
     "never destroy or reconcile"),
    ("backend-lifecycle", "cap-evidence-on-wsl-legacy-record", EVIDENCE_INTENT, [("set", "backend", "wsl-legacy")],
     "the lifetime cap binds hyperv-vm records only"),
    # the power-off precedes the evidence (allocator.md L4: latch in memory, power off, then persist)
    ("backend-lifecycle", "cap-evidence-before-the-power-off", EVIDENCE_INTENT, [("set", "at", "2026-10-19T17:59:59Z")],
     "the evidence is written after the power-off was issued"),
    ("backend-lifecycle", "cap-evidence-power-off-before-start", EVIDENCE_INTENT,
     [("set", "lifetime_cap.power_off_utc", "2026-10-19T11:59:59Z")],
     "power_off_utc is before started_utc"),
    ("backend-lifecycle", "cap-evidence-missing-power-off", EVIDENCE_INTENT, [("del", "lifetime_cap.power_off_utc")],
     "missing required property 'power_off_utc'"),
    ("backend-lifecycle", "cap-evidence-power-off-not-a-real-time", EVIDENCE_INTENT,
     [("set", "lifetime_cap.power_off_utc", "2026-02-30T18:00:00Z")],
     "power_off_utc is not a real UTC time"),
    # the deadline record a VM carries (allocator.md B1, B3): the deadline is start plus the ceiling, the identity holds together
    ("vm-cap-notes", "deadline-five-hours-out", NOTES, renoted(NOTES, deadline_utc="2026-10-19T17:00:00Z"),
     "deadline_utc must be started_utc plus the 6 hour ceiling"),
    ("vm-cap-notes", "deadline-seven-hours-out", NOTES, renoted(NOTES, deadline_utc="2026-10-19T19:00:00Z"),
     "deadline_utc must be started_utc plus the 6 hour ceiling"),
    ("vm-cap-notes", "check-for-another-vm", NOTES, [("set", "vm_id", "0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b")],
     "check does not match the record's identity fields"),
    ("vm-cap-notes", "name-for-another-reservation", NOTES, renoted(NOTES, vm_name="aap-w-4-3-ffffffff"),
     "vm_name must end with the first 8 hex of the reservation_id"),
    ("vm-cap-notes", "foreign-kind", NOTES, [("set", "kind", "other")], '$.kind: must be "aap-vm-cap"'),
    ("vm-cap-notes", "uppercase-guid", NOTES, [("set", "vm_id", "6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4B")],
     "$.vm_id: does not match pattern"),
    ("vm-cap-notes", "name-outside-the-managed-pattern", NOTES, renoted(NOTES, vm_name="build-vm-1"),
     "$.vm_name: does not match pattern"),
    ("vm-cap-notes", "slot-seven", NOTES, renoted(NOTES, vm_name="aap-w-7-3-1a2b3c4d"),
     "$.vm_name: does not match pattern"),
    ("vm-cap-notes", "extra-key", NOTES, [("set", "host", "x")], "unexpected property 'host'"),
    ("vm-cap-notes", "missing-check", NOTES, [("del", "check")], "missing required property 'check'"),
    ("vm-cap-notes", "start-not-a-real-time", NOTES,
     renoted(NOTES, started_utc="2026-02-30T12:00:00Z", deadline_utc="2026-02-30T18:00:00Z"),
     "started_utc is not a real UTC time"),
    # the clock record that survives restarts (allocator.md L7, B2)
    ("lifetime-clock", "high-water-before-written", CLOCK, [("set", "high_water_utc", "2026-10-22T09:00:04Z")],
     "high_water_utc is the largest time ever seen"),
    ("lifetime-clock", "boot-id-too-short", CLOCK, [("set", "boot_id", "3f2a9c1")], "$.boot_id: does not match pattern"),
    ("lifetime-clock", "boot-id-uppercase", CLOCK, [("set", "boot_id", "3F2A9C1E-7B4D-4E58-9A61-0C5D2B8E7F10")],
     "$.boot_id: does not match pattern"),
    ("lifetime-clock", "role-unknown", CLOCK, [("set", "role", "provider")], '$.role: "provider" not in enum'),
    ("lifetime-clock", "negative-counter", CLOCK, [("set", "mono_ms", -1)], "$.mono_ms: below minimum 0"),
    ("lifetime-clock", "extra-key", CLOCK, [("set", "host", "x")], "unexpected property 'host'"),
    ("lifetime-clock", "written-not-a-real-time", CLOCK,
     [("set", "written_utc", "2026-02-30T09:00:00Z"), ("set", "high_water_utc", "2026-02-30T09:00:00Z")],
     "written_utc is not a real UTC time"),
    ("lifetime-clock", "latched-twice", WATCHDOG, [("set", "latched", [LATCH, LATCH])],
     "a VM or a reservation is latched once"),
    ("lifetime-clock", "latched-elapsed-below-cap", WATCHDOG, [("set", "latched", [dict(LATCH, elapsed_s=21599)])],
     "elapsed_s is below cap_hours"),
    ("lifetime-clock", "latched-after-high-water", WATCHDOG, [("set", "latched", [dict(LATCH, decided_utc="2026-10-22T15:01:01Z")])],
     "a latched decision is never after high_water_utc"),
    ("lifetime-clock", "watchdog-latches-below-the-ceiling", WATCHDOG,
     [("set", "latched", [dict(LATCH, cap_hours=2, elapsed_s=7200)])],
     "the watchdog latches only at the 6 hour ceiling"),
    ("backend-lifecycle", "cap-evidence-missing-trigger", EVIDENCE_INTENT, [("del", "lifetime_cap.trigger")],
     "missing required property 'trigger'"),
    ("backend-lifecycle", "cap-evidence-deadline-unknown-elapsed", EVIDENCE_INTENT, [("set", "lifetime_cap.elapsed_s", None)],
     "elapsed_s is below cap_hours"),
    ("backend-lifecycle", "cap-evidence-trigger-unknown", EVIDENCE_INTENT, [("set", "lifetime_cap.trigger", "clock_step")],
     "not in enum"),
    ("lifetime-clock", "latched-missing-trigger", WATCHDOG, [("del", "latched.0.trigger")],
     "missing required property 'trigger'"),
    ("lifetime-clock", "latched-deadline-unknown-elapsed", WATCHDOG, [("set", "latched.0.elapsed_s", None)],
     "elapsed_s is below cap_hours"),
    ("lifetime-clock", "latched-missing-enforcement-stage", WATCHDOG, [("del", "latched.0.enforcement_stage")],
     "missing required property 'enforcement_stage'"),
    ("lifetime-clock", "latched-enforcement-stage-unknown", WATCHDOG, [("set", "latched.0.enforcement_stage", "detached")],
     "not in enum"),
    ("backend-lifecycle", "cap-evidence-safety-negative-elapsed", EVIDENCE_INTENT,
     [("set", "lifetime_cap.trigger", "clock_unavailable"), ("set", "lifetime_cap.elapsed_s", -1)],
     "below minimum 0"),
    ("lifetime-clock", "latched-safety-negative-elapsed", WATCHDOG,
     [("set", "latched.0.trigger", "host_reboot"), ("set", "latched.0.elapsed_s", -1)],
     "below minimum 0"),
    ("lifetime-clock", "latched-trigger-unknown", WATCHDOG, [("set", "latched.0.trigger", "clock_step")],
     "not in enum"),
]


def case_instance(contract, base, edits):
    return apply(fixture(contract, base), edits)


class OneCeiling(unittest.TestCase):
    def test_every_schema_a_cap_value_appears_in_stops_at_the_same_six_hours(self):
        places = {
            "settings-v3": lambda s: s["properties"]["lease_wall_clock_hours"],
            "settings-v4": lambda s: s["properties"]["vm_lifetime_cap_hours"],
            "status-v5": lambda s: s["$defs"]["vm_lifetime_cap"]["properties"]["cap_hours"],
            "backend-lifecycle": lambda s: s["$defs"]["lifetime_cap"]["properties"]["cap_hours"],
            "lifetime-clock": lambda s: s["$defs"]["latched"]["properties"]["cap_hours"],
        }
        for name, pick in places.items():
            node = pick(schema(name))
            self.assertEqual((node["type"], node["minimum"], node["maximum"]), ("integer", 1, 6), name)

    def test_the_contract_versions_are_the_ones_the_documents_state(self):
        for name, version in {"settings-v3": 3, "settings-v4": 4, "status-v5": 5, "backend-lifecycle": 3, "vm-cap-notes": 1, "lifetime-clock": 1}.items():
            self.assertEqual(schema(name)["x-contract-version"], version, name)
        self.assertEqual(schema("settings-v4")["properties"]["schema"]["const"], 4)


class SettingsCeiling(unittest.TestCase):
    BASES = (("settings-v3", "lease_wall_clock_hours", "valid/windows-only-even"),
             ("settings-v4", "vm_lifetime_cap_hours", "valid/windows-only-even"))

    def test_both_schemas_take_exactly_one_to_six_whole_hours(self):
        for contract, key, base in self.BASES:
            for hours in range(-2, 80):
                doc = apply(fixture(contract, base), [("set", key, hours)])
                self.assertEqual(verdict(contract, doc) is None, 1 <= hours <= 6, f"{contract} {hours}")

    def test_a_cap_that_is_not_a_whole_number_is_refused(self):
        for contract, key, base in self.BASES:
            for bad in (5.5, 6.0000001, "6", True, None, [6], {"hours": 6}):
                doc = apply(fixture(contract, base), [("set", key, bad)])
                self.assertIsNotNone(verdict(contract, doc), f"{contract} {bad!r}")

    def test_moving_a_schema_3_file_to_schema_4_is_a_rename_that_never_changes_the_value(self):
        for path in sorted((FIXTURES / "settings-v3" / "valid").glob("*.json")):
            old = V.load(path)
            self.assertIsNone(verdict("settings-v3", old), path.name)
            for hours in range(1, 7):
                v3 = apply(old, [("set", "lease_wall_clock_hours", hours)])
                v4 = {("vm_lifetime_cap_hours" if k == "lease_wall_clock_hours" else k): v for k, v in v3.items()}
                v4["schema"] = 4
                self.assertIsNone(verdict("settings-v3", v3), f"{path.name} {hours}")
                self.assertIsNone(verdict("settings-v4", v4), f"{path.name} {hours}")
            for hours in (7, 12, 72):
                v3 = apply(old, [("set", "lease_wall_clock_hours", hours)])
                self.assertIn("above maximum 6", verdict("settings-v3", v3), f"{path.name} {hours}")

    def test_schema_4_has_exactly_the_keys_of_schema_3_except_the_cap_key(self):
        v3, v4 = schema("settings-v3"), schema("settings-v4")
        self.assertEqual(set(v4["properties"]) - {"vm_lifetime_cap_hours"}, set(v3["properties"]) - {"lease_wall_clock_hours"})
        self.assertEqual(set(v4["required"]), set(v4["properties"]))
        self.assertEqual(set(v3["required"]), set(v3["properties"]))


class StatusAdvertisesSettingsSchema4(unittest.TestCase):
    def test_a_supervisor_may_advertise_and_apply_schema_4_and_nothing_newer(self):
        base = fixture("status-v5", LIVE)
        for listed in ([2, 3], [2, 3, 4], [1, 2, 3, 4]):
            self.assertIsNone(verdict("status-v5", apply(base, [("set", "settings_schemas", listed), ("set", "applied_settings_schema", listed[-1])])), listed)
        self.assertIsNotNone(verdict("status-v5", apply(base, [("set", "settings_schemas", [2, 3, 4, 5])])))

    def test_a_status_without_the_cap_object_is_still_valid(self):
        # a supervisor that predates revision 4 writes none, and the tray must keep reading its file
        doc = fixture("status-v5", "valid/mixed-five-slots")
        self.assertFalse(any("vm_lifetime_cap" in s for s in doc["slots"]))
        self.assertIsNone(verdict("status-v5", doc))


class StatusCapRules(unittest.TestCase):
    def fired(self, lifecycle):
        return apply(fixture("status-v5", LIVE), [
            ("set", "slots.3.lifecycle", lifecycle),
            ("set", "slots.3.vm_lifetime_cap.reason", "vm_lifetime_cap"),
            ("set", "detail", "vm_lifetime_cap: slot 4 reached the 6 h cap")])

    def test_a_fired_cap_is_only_ever_on_a_slot_that_is_on_its_way_down(self):
        # creating is allowed: a reservation without a vm_id yet cannot be deleting (allocator.md rule 9)
        for lifecycle in ("creating", "ready", "busy", "draining", "collecting", "deleting", "quarantined"):
            got = verdict("status-v5", self.fired(lifecycle))
            if lifecycle in ("creating", "deleting", "quarantined"):
                self.assertIsNone(got, lifecycle)
            else:
                self.assertIn("the cap has fired", got, lifecycle)

    def test_a_slot_has_sixty_seconds_past_its_deadline_and_then_the_cap_must_have_fired(self):
        base = fixture("status-v5", LIVE)
        deadline = parse(base["slots"][3]["vm_lifetime_cap"]["deadline_utc"])
        for late, ok in ((-3600, True), (0, True), (59, True), (60, True), (61, False), (3600, False)):
            doc = apply(base, [("set", "updated", stamp(deadline + timedelta(seconds=late)))])
            got = verdict("status-v5", doc)
            self.assertEqual(got is None, ok, f"{late}: {got}")
            if not ok:
                self.assertIn("past its deadline_utc and the cap has not fired", got)

    def test_the_deadline_rule_binds_only_in_a_state_that_runs_the_capacity_pass(self):
        # idle, running, draining and paused evaluate the cap before each status document (allocator.md L3);
        # off, starting and error make no such claim (L9), so a slot past its deadline there is not refused
        base = fixture("status-v5", LIVE)
        deadline = parse(base["slots"][3]["vm_lifetime_cap"]["deadline_utc"])
        edits = [("set", "updated", stamp(deadline + timedelta(hours=1)))]
        for state in ("idle", "running", "draining", "paused"):
            got = verdict("status-v5", apply(base, edits + [("set", "state", state)]))
            self.assertIn("past its deadline_utc and the cap has not fired", got, state)
        for state in ("off", "starting", "error"):
            self.assertIsNone(verdict("status-v5", apply(base, edits + [("set", "state", state)])), state)

    def test_a_slot_that_has_fired_is_not_asked_about_the_clock(self):
        # the wall clock may be far from the deadline either way (a step); a fired slot stays valid
        base = self.fired("deleting")
        # slot 5 is a young VM here, so the clock stays before its deadline (17:59); only slot 4 has fired
        for updated in ("2026-10-22T09:00:00Z", "2026-10-22T15:00:00Z", "2026-10-22T17:00:00Z"):
            self.assertIsNone(verdict("status-v5", apply(base, [("set", "updated", updated)])), updated)

    def test_the_window_is_start_plus_whole_hours_for_every_allowed_cap(self):
        base = fixture("status-v5", LIVE)
        start = parse("2026-10-22T09:00:00Z")
        for hours in range(1, 7):
            cap = {"cap_hours": hours, "started_utc": stamp(start), "deadline_utc": stamp(start + timedelta(hours=hours)), "reason": None}
            edits = [("set", "updated", stamp(start)), ("set", "slots.3.vm_lifetime_cap", cap)]
            self.assertIsNone(verdict("status-v5", apply(base, edits)), hours)
            for off in (-1, 1):
                cap["deadline_utc"] = stamp(start + timedelta(hours=hours, seconds=off))
                self.assertIn("deadline_utc must be started_utc plus cap_hours hours",
                              verdict("status-v5", apply(base, edits)), f"{hours} {off}")

    def test_a_fired_cap_leads_the_detail_with_the_word_and_a_colon(self):
        base = self.fired("deleting")
        for detail, ok in (("vm_lifetime_cap: slot 4", True), ("vm_lifetime_cap:", True), ("", False), ("vm_lifetime_cap", False),
                           ("vm_lifetime_capx: slot 4", False), ("resize_waits: x; vm_lifetime_cap: slot 4", False),
                           (" vm_lifetime_cap: x", False)):
            got = verdict("status-v5", apply(base, [("set", "detail", detail)]))
            self.assertEqual(got is None, ok, f"{detail!r}: {got}")
            if not ok:
                self.assertIn("detail must start with vm_lifetime_cap:", got)

    def test_the_detail_rule_holds_whichever_slot_fired(self):
        # a fired slot followed by a slot that has not fired, and the other way round
        first = apply(fixture("status-v5", LIVE), [("set", "slots.3.lifecycle", "deleting"), ("set", "slots.3.vm_lifetime_cap.reason", "vm_lifetime_cap")])
        second = apply(fixture("status-v5", LIVE), [("set", "slots.4.lifecycle", "deleting"), ("set", "slots.4.vm_lifetime_cap.reason", "vm_lifetime_cap")])
        for doc in (first, second):
            self.assertIn("detail must start with vm_lifetime_cap:", verdict("status-v5", apply(doc, [("set", "detail", "")])))
            self.assertIsNone(verdict("status-v5", apply(doc, [("set", "detail", "vm_lifetime_cap: a slot reached the cap")])))

    def test_every_capped_slot_is_checked_not_only_the_first(self):
        base = fixture("status-v5", LIVE)
        bad = apply(base, [("set", "slots.4.vm_lifetime_cap.deadline_utc", "2026-10-22T18:59:00Z")])  # slot 5 started 11:59
        self.assertIn("deadline_utc must be started_utc plus cap_hours hours", verdict("status-v5", bad))
        fired_first = apply(self.fired("deleting"), [("set", "slots.4.vm_lifetime_cap.deadline_utc", "2026-10-22T18:59:00Z")])
        self.assertIn("deadline_utc must be started_utc plus cap_hours hours", verdict("status-v5", fired_first))
        late = apply(base, [("set", "slots.4.vm_lifetime_cap", dict(CAP_LIVE, started_utc="2026-10-22T05:00:00Z", deadline_utc="2026-10-22T11:00:00Z"))])
        self.assertIn("slot 5: past its deadline_utc and the cap has not fired", verdict("status-v5", late))

    def test_a_cap_object_takes_exactly_its_four_fields(self):
        base = fixture("status-v5", LIVE)
        for key in ("cap_hours", "started_utc", "deadline_utc", "reason"):
            self.assertIn("missing required property", verdict("status-v5", apply(base, [("del", f"slots.3.vm_lifetime_cap.{key}")])), key)
        self.assertIn("unexpected property", verdict("status-v5", apply(base, [("set", "slots.3.vm_lifetime_cap.host", "x")])))

    def test_a_start_at_the_end_of_the_calendar_is_refused_not_a_crash(self):
        cap = {"cap_hours": 6, "started_utc": "9999-12-31T22:00:00Z", "deadline_utc": "9999-12-31T23:59:59Z", "reason": None}
        self.assertIn("beyond the calendar", verdict("status-v5", apply(fixture("status-v5", LIVE), [("set", "slots.3.vm_lifetime_cap", cap)])))


class JournalCapRules(unittest.TestCase):
    OPS = ("create", "boot", "ready", "run_one", "drain", "collect", "destroy", "reconcile")
    ENDABLE = ("create", "boot", "ready", "run_one", "drain", "collect")

    def record(self, op, phase, **extra):
        base = fixture("backend-lifecycle", "valid/destroy-intent")
        result = None if phase == "intent" else {"code": {"done": "ok", "failed": "retryable"}[phase], "detail": "x"}
        edits = [("set", "op", op), ("set", "idempotency_key", f"r-1a2b3c4d000000b1/3/{op}"), ("set", "phase", phase),
                 ("set", "result", result), ("set", "at", "2026-10-19T18:00:00Z")]
        return apply(base, edits + [("set", k, v) for k, v in extra.items()])

    def test_the_evidence_is_accepted_on_a_destroy_intent_and_nowhere_else(self):
        for op in self.OPS:
            for phase in ("intent", "done", "failed"):
                got = verdict("backend-lifecycle", self.record(op, phase, lifetime_cap=EVIDENCE))
                if (op, phase) == ("destroy", "intent"):
                    self.assertIsNone(got, f"{op} {phase}")
                else:
                    self.assertIn("lifetime_cap rides only on a destroy intent record", got, f"{op} {phase}")

    def test_the_result_code_closes_only_the_ops_the_cap_can_end_and_only_as_failed(self):
        for op in self.OPS:
            for phase in ("done", "failed"):
                rec = self.record(op, phase, result={"code": "vm_lifetime_cap", "detail": "cap reached"})
                got = verdict("backend-lifecycle", rec)
                if phase == "failed" and op in self.ENDABLE:
                    self.assertIsNone(got, f"{op} {phase}")
                else:
                    self.assertIsNotNone(got, f"{op} {phase}")

    def test_the_deadline_is_start_plus_whole_hours_for_every_allowed_cap(self):
        start = parse("2026-10-19T12:00:00Z")
        for hours in range(1, 7):
            cap = dict(EVIDENCE, cap_hours=hours, started_utc=stamp(start), deadline_utc=stamp(start + timedelta(hours=hours)), elapsed_s=hours * 3600)
            self.assertIsNone(verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=cap)), hours)
            for off in (-1, 1):
                bad = dict(cap, deadline_utc=stamp(start + timedelta(hours=hours, seconds=off)))
                self.assertIn("deadline_utc must be started_utc plus cap_hours hours",
                              verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=bad)), f"{hours} {off}")

    def test_the_evidence_proves_a_measure_reached_the_cap_to_the_second(self):
        for hours in range(1, 7):
            start = parse("2026-10-19T12:00:00Z")
            cap = dict(EVIDENCE, cap_hours=hours, deadline_utc=stamp(start + timedelta(hours=hours)))
            for elapsed, ok in ((hours * 3600 - 1, False), (hours * 3600, True), (hours * 3600 + 1, True), (31536000, True)):
                got = verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=dict(cap, elapsed_s=elapsed)))
                self.assertEqual(got is None, ok, f"{hours} {elapsed}: {got}")

    def test_a_record_written_before_the_deadline_by_the_wall_clock_is_valid_evidence(self):
        # a monotonic measure fired while the wall clock was stepped back: the record's time is before
        # deadline_utc, which the evidence allows because elapsed_s shows the cap was reached
        doc = self.record("destroy", "intent", lifetime_cap=dict(EVIDENCE, power_off_utc="2026-10-19T16:29:55Z"), at="2026-10-19T16:30:00Z")
        self.assertIsNone(verdict("backend-lifecycle", doc))

    def test_no_cap_field_is_required_so_every_older_record_stays_valid(self):
        for path in sorted((FIXTURES / "backend-lifecycle" / "valid").glob("*.json")):
            if "lifetime-cap" not in path.name:
                self.assertIsNone(verdict("backend-lifecycle", V.load(path)), path.name)

    def test_the_cap_binds_hyperv_vm_records_only(self):
        evidence = self.record("destroy", "intent", lifetime_cap=EVIDENCE)
        code = self.record("run_one", "failed", result={"code": "vm_lifetime_cap", "detail": "cap reached"})
        for doc in (evidence, code):
            self.assertIsNone(verdict("backend-lifecycle", doc))
            self.assertIn("binds hyperv-vm records only", verdict("backend-lifecycle", apply(doc, [("set", "backend", "wsl-legacy")])))

    def test_the_evidence_takes_exactly_its_six_fields(self):
        base = fixture("backend-lifecycle", EVIDENCE_INTENT)
        for key in EVIDENCE:
            self.assertIn("missing required property", verdict("backend-lifecycle", apply(base, [("del", f"lifetime_cap.{key}")])), key)
        self.assertIn("unexpected property", verdict("backend-lifecycle", apply(base, [("set", "lifetime_cap.host", "x")])))

    def test_elapsed_has_a_ceiling_of_a_year(self):
        base = fixture("backend-lifecycle", EVIDENCE_INTENT)
        for elapsed, ok in ((31536000, True), (31536001, False)):
            got = verdict("backend-lifecycle", apply(base, [("set", "lifetime_cap.elapsed_s", elapsed)]))
            self.assertEqual(got is None, ok, f"{elapsed}: {got}")

    def test_a_start_at_the_end_of_the_calendar_is_refused_not_a_crash(self):
        cap = dict(EVIDENCE, started_utc="9999-12-31T22:00:00Z", deadline_utc="9999-12-31T23:59:59Z")
        self.assertIn("beyond the calendar", verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=cap)))

    def test_the_evidence_follows_the_power_off(self):
        # latch in memory, power off, then persist (allocator.md L4): a record time before power_off_utc is refused
        for delta, ok in ((-1, False), (0, True), (1, True)):
            at = stamp(parse(EVIDENCE["power_off_utc"]) + timedelta(seconds=delta))
            got = verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=EVIDENCE, at=at))
            self.assertEqual(got is None, ok, f"{delta}: {got}")
            if not ok:
                self.assertIn("written after the power-off", got)

    def test_the_power_off_cannot_precede_the_reservation(self):
        for delta, ok in ((-1, False), (0, True)):
            cap = dict(EVIDENCE, power_off_utc=stamp(parse(EVIDENCE["started_utc"]) + timedelta(seconds=delta)))
            got = verdict("backend-lifecycle", self.record("destroy", "intent", lifetime_cap=cap))
            self.assertEqual(got is None, ok, f"{delta}: {got}")
            if not ok:
                self.assertIn("power_off_utc is before started_utc", got)


class SafetyDecisionEvidence(unittest.TestCase):
    def test_clock_loss_and_reboot_allow_unknown_or_early_elapsed_in_both_records(self):
        for trigger in ("clock_unavailable", "host_reboot"):
            for elapsed in (None, 0, 7200, 21600):
                journal = fixture("backend-lifecycle", EVIDENCE_INTENT)
                journal["lifetime_cap"] = dict(EVIDENCE, trigger=trigger, elapsed_s=elapsed)
                clock = fixture("lifetime-clock", WATCHDOG)
                clock["latched"] = [dict(LATCH, trigger=trigger, elapsed_s=elapsed)]
                for contract, doc in (("backend-lifecycle", journal), ("lifetime-clock", clock)):
                    self.assertIsNone(verdict(contract, doc), f"{contract}: {trigger} {elapsed}")

    def test_deadline_still_requires_measured_elapsed_at_the_cap(self):
        for elapsed in (None, 0, 7200, 21599):
            journal = fixture("backend-lifecycle", EVIDENCE_INTENT)
            journal["lifetime_cap"] = dict(EVIDENCE, elapsed_s=elapsed)
            clock = fixture("lifetime-clock", WATCHDOG)
            clock["latched"] = [dict(LATCH, elapsed_s=elapsed)]
            for contract, doc in (("backend-lifecycle", journal), ("lifetime-clock", clock)):
                self.assertIn("elapsed_s is below cap_hours", verdict(contract, doc) or "")

    def test_every_durable_escalation_stage_round_trips(self):
        for stage in ("power_off_attempted", "worker_stop_attempted", "off", "cap_breach"):
            clock = fixture("lifetime-clock", WATCHDOG)
            clock["latched"] = [dict(LATCH, enforcement_stage=stage)]
            self.assertIsNone(verdict("lifetime-clock", clock), stage)

    def test_high_water_evidence_survives_rollback_before_start_and_between_events(self):
        start = parse(EVIDENCE["started_utc"])
        for raw_issue, raw_write in (("2026-10-19T11:00:00Z", "2026-10-19T11:00:01Z"),
                                     ("2026-10-19T18:00:00Z", "2026-10-19T10:00:00Z")):
            # The contract records high-water timestamps, never the raw rolled-back wall samples.
            issued = max(start, parse(raw_issue))
            written = max(issued, parse(raw_write))
            doc = fixture("backend-lifecycle", EVIDENCE_INTENT)
            doc["at"] = stamp(written)
            doc["lifetime_cap"] = dict(EVIDENCE, power_off_utc=stamp(issued))
            self.assertIsNone(verdict("backend-lifecycle", doc), (raw_issue, raw_write))

    def test_new_valid_safety_and_rollback_fixtures_are_accepted(self):
        for contract, names in {
            "backend-lifecycle": ("cap-clock-unavailable", "cap-host-reboot", "cap-rollback-before-start", "cap-rollback-between-events"),
            "lifetime-clock": ("clock-unavailable", "host-reboot", "watchdog-worker-stop", "watchdog-cap-breach"),
        }.items():
            for name in names:
                self.assertIsNone(verdict(contract, fixture(contract, "valid/" + name)), f"{contract}/{name}")


class CapFixtures(unittest.TestCase):
    def test_every_base_is_valid(self):
        for contract, base in sorted({(c[0], c[2]) for c in CASES}):
            self.assertIsNone(verdict(contract, fixture(contract, base)), f"{contract}/{base}")

    def test_every_invalid_fixture_is_its_valid_base_plus_one_defect_refused_for_the_stated_reason(self):
        for contract, name, base, edits, expect in CASES:
            instance = case_instance(contract, base, edits)
            got = verdict(contract, instance)
            self.assertIsNotNone(got, f"{contract}/{name} was accepted")
            self.assertIn(expect, got, f"{contract}/{name}")
            path = FIXTURES / contract / "invalid" / f"{name}.json"
            self.assertTrue(path.is_file(), f"{path} is missing")
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"expect": expect, "instance": instance}, f"{contract}/{name} differs from its base plus the listed edits")

    def test_settings_v4_has_no_invalid_fixture_outside_the_list(self):
        listed = {name + ".json" for contract, name, *_ in CASES if contract == "settings-v4"}
        on_disk = {p.name for p in (FIXTURES / "settings-v4" / "invalid").glob("*.json")}
        self.assertEqual(on_disk, listed)

    def test_an_edit_that_changes_nothing_is_not_a_defect(self):
        for contract, name, base, edits, _ in CASES:
            self.assertNotEqual(case_instance(contract, base, edits), fixture(contract, base), f"{contract}/{name}")

    def test_no_cap_contract_has_an_invalid_fixture_outside_the_list(self):
        for contract in ("settings-v4", "vm-cap-notes", "lifetime-clock"):
            listed = {name + ".json" for c, name, *_ in CASES if c == contract}
            on_disk = {p.name for p in (FIXTURES / contract / "invalid").glob("*.json")}
            self.assertEqual(on_disk, listed, contract)


class NotesRecord(unittest.TestCase):
    FIELDS = ("vm_id", "vm_name", "reservation_id", "started_utc", "deadline_utc")

    def test_both_profiles_write_the_same_record(self):
        for base in (NOTES, NOTES_LINUX):
            self.assertIsNone(verdict("vm-cap-notes", fixture("vm-cap-notes", base)), base)

    def test_the_check_is_the_documented_digest_of_the_identity_fields(self):
        doc = fixture("vm-cap-notes", NOTES)
        text = "aap-vm-cap:1|" + "|".join(doc[k] for k in self.FIELDS)
        self.assertEqual(doc["check"], hashlib.sha256(text.encode("ascii")).hexdigest()[:32])

    def test_the_check_covers_every_identity_field(self):
        doc = fixture("vm-cap-notes", NOTES)
        other = {"vm_id": "0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b", "vm_name": "aap-w-4-3-1a2b3c4e",
                 "reservation_id": "r-1a2b3c4d000000b2", "started_utc": "2026-10-19T12:00:01Z", "deadline_utc": "2026-10-19T18:00:01Z"}
        for key in self.FIELDS:
            self.assertNotEqual(V.notes_check(dict(doc, **{key: other[key]})), doc["check"], key)

    def test_the_deadline_is_start_plus_six_hours_to_the_second_and_never_the_configured_cap(self):
        base = fixture("vm-cap-notes", NOTES)
        start = parse(base["started_utc"])
        for offset, ok in ((-3601, False), (-1, False), (0, True), (1, False), (3600, False)):
            deadline = stamp(start + timedelta(hours=6, seconds=offset))
            got = verdict("vm-cap-notes", apply(base, renoted(NOTES, deadline_utc=deadline)))
            self.assertEqual(got is None, ok, f"{offset}: {got}")
            if not ok:
                self.assertIn("plus the 6 hour ceiling", got)

    def test_a_start_at_the_end_of_the_calendar_is_refused_not_a_crash(self):
        edits = renoted(NOTES, started_utc="9999-12-31T22:00:00Z", deadline_utc="9999-12-31T23:59:59Z")
        self.assertIn("beyond the calendar", verdict("vm-cap-notes", apply(fixture("vm-cap-notes", NOTES), edits)))

    def test_the_record_is_small_and_plain_ascii(self):
        text = json.dumps(fixture("vm-cap-notes", NOTES), separators=(",", ":"))
        self.assertLess(len(text), 1024)
        self.assertTrue(text.isascii())


class ClockRecord(unittest.TestCase):
    def test_every_valid_record_is_accepted(self):
        for path in sorted((FIXTURES / "lifetime-clock" / "valid").glob("*.json")):
            self.assertIsNone(verdict("lifetime-clock", V.load(path)), path.name)

    def test_the_high_water_mark_is_never_before_the_write(self):
        base = fixture("lifetime-clock", CLOCK)
        written = parse(base["written_utc"])
        for offset, ok in ((-1, False), (0, True), (1, True), (7200, True)):
            got = verdict("lifetime-clock", apply(base, [("set", "high_water_utc", stamp(written + timedelta(seconds=offset)))]))
            self.assertEqual(got is None, ok, f"{offset}: {got}")

    def test_a_stepped_back_clock_leaves_the_write_time_behind_the_mark(self):
        # the supervisor keeps advancing the mark by its counter while the wall clock is stepped back two hours
        doc = apply(fixture("lifetime-clock", CLOCK), [("set", "written_utc", "2026-10-22T07:00:05Z")])
        self.assertIsNone(verdict("lifetime-clock", doc))

    def test_boot_id_is_8_to_64_lowercase_hex_and_dashes(self):
        base = fixture("lifetime-clock", CLOCK)
        for value, ok in (("a" * 7, False), ("a" * 8, True), ("0" * 32, True), ("a-" * 32, True), ("a" * 64, True),
                          ("a" * 65, False), ("A" * 8, False), ("a_" * 8, False), ("a b" * 4, False), ("", False)):
            self.assertEqual(verdict("lifetime-clock", apply(base, [("set", "boot_id", value)])) is None, ok, repr(value))

    def test_latched_decisions_are_bounded_and_unique(self):
        base = fixture("lifetime-clock", WATCHDOG)

        def many(n):
            return [dict(LATCH, reservation_id=f"r-{i:016x}", vm_id=f"00000000-0000-4000-8000-{i:012x}") for i in range(n)]

        self.assertIsNone(verdict("lifetime-clock", apply(base, [("set", "latched", many(32))])))
        self.assertIn("$.latched", verdict("lifetime-clock", apply(base, [("set", "latched", many(33))])) or "")
        same_vm = [LATCH, dict(LATCH, reservation_id="r-1a2b3c4d000000b2")]
        same_reservation = [LATCH, dict(LATCH, vm_id="0b7e5d4c-3a2f-4e1d-9c8b-7a6f5e4d3c2b")]
        for latched in (same_vm, same_reservation):
            self.assertIn("latched once", verdict("lifetime-clock", apply(base, [("set", "latched", latched)])))

    def test_the_supervisor_may_latch_its_configured_cap_and_the_watchdog_only_the_ceiling(self):
        entry = dict(LATCH, cap_hours=2, elapsed_s=7200)
        for role, ok in (("supervisor", True), ("watchdog", False)):
            doc = apply(fixture("lifetime-clock", WATCHDOG), [("set", "role", role), ("set", "latched", [entry])])
            self.assertEqual(verdict("lifetime-clock", doc) is None, ok, role)

    def test_the_elapsed_time_of_a_latched_decision_reaches_its_cap_to_the_second(self):
        base = fixture("lifetime-clock", WATCHDOG)
        for elapsed, ok in ((21599, False), (21600, True), (21601, True), (31536000, True), (31536001, False)):
            got = verdict("lifetime-clock", apply(base, [("set", "latched", [dict(LATCH, elapsed_s=elapsed)])]))
            self.assertEqual(got is None, ok, f"{elapsed}: {got}")


class RecordBoundaries(unittest.TestCase):
    def test_the_guid_is_lowercase_in_every_group(self):
        base = fixture("vm-cap-notes", NOTES)
        for i in range(5):
            groups = base["vm_id"].split("-")
            groups[i] = groups[i].upper()
            got = verdict("vm-cap-notes", apply(base, [("set", "vm_id", "-".join(groups))]))
            self.assertIn("$.vm_id: does not match pattern", got or "", f"group {i}")

    def test_a_latched_decision_is_never_after_the_high_water_mark_and_may_equal_it(self):
        base = fixture("lifetime-clock", WATCHDOG)
        high = parse(base["high_water_utc"])
        for delta, ok in ((-1, True), (0, True), (1, False)):
            entry = dict(LATCH, decided_utc=stamp(high + timedelta(seconds=delta)))
            got = verdict("lifetime-clock", apply(base, [("set", "latched", [entry])]))
            self.assertEqual(got is None, ok, f"{delta}: {got}")


class SafetyDecisionBounds(unittest.TestCase):
    def test_safety_elapsed_remains_nonnegative_and_bounded(self):
        for trigger in ("clock_unavailable", "host_reboot"):
            for elapsed, ok in ((-1, False), (0, True), (31536000, True), (31536001, False)):
                journal = fixture("backend-lifecycle", EVIDENCE_INTENT)
                journal["lifetime_cap"] = dict(EVIDENCE, trigger=trigger, elapsed_s=elapsed)
                clock = fixture("lifetime-clock", WATCHDOG)
                clock["latched"] = [dict(LATCH, trigger=trigger, elapsed_s=elapsed)]
                for contract, doc in (("backend-lifecycle", journal), ("lifetime-clock", clock)):
                    self.assertEqual(verdict(contract, doc) is None, ok, (contract, trigger, elapsed))


if __name__ == "__main__":
    unittest.main()
