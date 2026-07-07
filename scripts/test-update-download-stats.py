#!/usr/bin/env python3
"""Fixture tests for update-download-stats.py.

Exercises main() with the S3 and GraphQL layers monkeypatched -- no network
and no aws CLI. Focus: the incremental pass, the newly-tracked-object
backfill, and the double-count guard for legacy state without an objects
list.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "update-download-stats.py"

# Per-object daily downloads served by the fake GraphQL layer.
DAILY = {
    "latest/win": 1,
    "latest/mac-intel": 2,
    "latest/mac-arm64": 3,
    "latest/win-x64": 10,
    "latest/win-arm64": 20,
}
LEGACY_OBJECTS = ["latest/mac-arm64", "latest/mac-intel", "latest/win"]

TODAY = datetime.now(timezone.utc).date()
YESTERDAY = TODAY - timedelta(days=1)
WINDOW_START = TODAY - timedelta(days=31)

FAILURES = []


def load_module():
    spec = importlib.util.spec_from_file_location("update_download_stats",
                                                  SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_main(state: dict | None, env_overrides: dict[str, str]):
    """Run main() with fakes; return (exit_code, writes, graphql_calls)."""
    mod = load_module()
    writes: dict[str, dict] = {}
    graphql_calls: list[tuple[str, str]] = []

    def fake_s3_read(bucket, key, endpoint, allow_missing_aws=False):
        return json.dumps(state).encode() if state is not None else None

    def fake_s3_write(bucket, key, data, content_type, cache_control,
                      endpoint):
        writes[key] = json.loads(data)

    def fake_graphql(account, bucket, object_name, start, end, token):
        graphql_calls.append((object_name, start))
        per_day = {}
        day = datetime.strptime(start[:10], "%Y-%m-%d").date()
        # Include the in-flight current day: main() must filter it out.
        while day <= TODAY:
            per_day[day.isoformat()] = DAILY[object_name]
            day += timedelta(days=1)
        return per_day

    mod.s3_read = fake_s3_read
    mod.s3_write = fake_s3_write
    mod.graphql_per_day_for_object = fake_graphql

    base_env = {
        "CF_ANALYTICS_API_TOKEN": "test-token",
        "CLOUDFLARE_ACCOUNT_ID": "test-account",
        "STATS_DRY_RUN": "0",
    }
    saved = dict(os.environ)
    os.environ.update(base_env | env_overrides)
    try:
        code = mod.main()
    finally:
        os.environ.clear()
        os.environ.update(saved)
    return code, writes, graphql_calls


def check(name: str, cond: bool, detail: str = ""):
    if cond:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name} {detail}")
        FAILURES.append(name)


def days_between(start, end_inclusive) -> int:
    return (end_inclusive - start).days + 1


def test_backfills_newly_tracked_objects():
    last_counted = TODAY - timedelta(days=3)
    stale_day = (TODAY - timedelta(days=4)).isoformat()
    state = {
        "schema": 1,
        "total": 1000,
        "lastCountedDate": last_counted.isoformat(),
        "objects": LEGACY_OBJECTS,
        "perDay": {stale_day: 5},
    }
    code, writes, calls = run_main(state, {})

    backfill_days = days_between(WINDOW_START, last_counted)
    backfill = backfill_days * (DAILY["latest/win-x64"]
                                + DAILY["latest/win-arm64"])
    increment_days = days_between(last_counted + timedelta(days=1), YESTERDAY)
    increment = increment_days * sum(DAILY.values())
    expected_total = 1000 + backfill + increment

    new_state = writes.get("stats/state.json", {})
    badge = writes.get("stats/downloads.json", {})
    backfill_calls = [c for c in calls
                      if c[1].startswith(WINDOW_START.isoformat())]

    check("backfill: exit code 0", code == 0)
    check("backfill: total includes backfilled window",
          new_state.get("total") == expected_total,
          f"got {new_state.get('total')} want {expected_total}")
    check("backfill: only new objects queried from window start",
          sorted(c[0] for c in backfill_calls)
          == ["latest/win-arm64", "latest/win-x64"],
          f"got {backfill_calls}")
    check("backfill: state tracks the expanded object set",
          new_state.get("objects") == sorted(DAILY),
          f"got {new_state.get('objects')}")
    check("backfill: existing perDay values are added to, not overwritten",
          new_state.get("perDay", {}).get(stale_day)
          == 5 + DAILY["latest/win-x64"] + DAILY["latest/win-arm64"],
          f"got {new_state.get('perDay', {}).get(stale_day)}")
    check("backfill: lastCountedDate advances to yesterday",
          new_state.get("lastCountedDate") == YESTERDAY.isoformat())
    check("backfill: badge reflects the new total",
          badge.get("message") == load_module().human(expected_total))


def test_unchanged_object_set_skips_backfill():
    last_counted = TODAY - timedelta(days=3)
    state = {
        "schema": 1,
        "total": 500,
        "lastCountedDate": last_counted.isoformat(),
        "objects": LEGACY_OBJECTS,
        "perDay": {},
    }
    objects_env = ",".join(LEGACY_OBJECTS)
    code, writes, calls = run_main(state, {"STATS_OBJECTS": objects_env})

    increment = days_between(last_counted + timedelta(days=1), YESTERDAY) \
        * sum(DAILY[o] for o in LEGACY_OBJECTS)
    start_iso = (last_counted + timedelta(days=1)).isoformat()

    check("no-change: exit code 0", code == 0)
    check("no-change: every query starts at lastCountedDate + 1",
          all(c[1].startswith(start_iso) for c in calls), f"got {calls}")
    check("no-change: total only grows by the increment",
          writes.get("stats/state.json", {}).get("total") == 500 + increment)


def test_cold_start_counts_full_window():
    code, writes, calls = run_main(None, {})

    expected = days_between(WINDOW_START, YESTERDAY) * sum(DAILY.values())
    new_state = writes.get("stats/state.json", {})

    check("cold start: exit code 0", code == 0)
    check("cold start: seeds the full retention window",
          new_state.get("total") == expected,
          f"got {new_state.get('total')} want {expected}")
    check("cold start: queries all objects from window start",
          sorted(c[0] for c in calls) == sorted(DAILY)
          and all(c[1].startswith(WINDOW_START.isoformat()) for c in calls),
          f"got {calls}")


def test_legacy_state_without_objects_list_never_backfills():
    last_counted = TODAY - timedelta(days=3)
    state = {
        "schema": 1,
        "total": 500,
        "lastCountedDate": last_counted.isoformat(),
        "perDay": {},
    }
    code, writes, calls = run_main(state, {})

    increment = days_between(last_counted + timedelta(days=1), YESTERDAY) \
        * sum(DAILY.values())
    backfill_calls = [c for c in calls
                      if c[1].startswith(WINDOW_START.isoformat())]

    check("legacy state: exit code 0", code == 0)
    check("legacy state: no backfill queries", backfill_calls == [],
          f"got {backfill_calls}")
    check("legacy state: total only grows by the increment (no double count)",
          writes.get("stats/state.json", {}).get("total") == 500 + increment)


def main() -> int:
    test_backfills_newly_tracked_objects()
    test_unchanged_object_set_skips_backfill()
    test_cold_start_counts_full_window()
    test_legacy_state_without_objects_list_never_backfills()
    if FAILURES:
        print(f"\n{len(FAILURES)} test(s) failed")
        return 1
    print("\nall update-download-stats tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
