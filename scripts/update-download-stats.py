#!/usr/bin/env python3
"""Maintain a cumulative R2 installer-download counter and a shields.io badge.

Cloudflare R2 analytics only retains ~32 days of data, so a running total
"since launch" cannot be queried directly. This script keeps a persistent
state file in R2 (stats/state.json) and, on each run, adds the download
counts for the **fully elapsed** UTC days that have not been counted yet.
It then writes a shields.io endpoint badge (stats/downloads.json).

Counted metric: GetObject requests against the three installer aliases
(latest/win, latest/mac-intel, latest/mac-arm64). Vulnerability-scanner
noise (.env, wp-login.php, ...) and staging/* objects are excluded.

Token safety: the Cloudflare Analytics API token is read from the
CF_ANALYTICS_API_TOKEN env var (a GitHub Secret in CI). It is only ever
used to call the GraphQL API from this backend process. The artifacts
written to the public bucket are plain JSON with no credentials.

Required env:
  CF_ANALYTICS_API_TOKEN   Cloudflare API token, scope: Account Analytics:Read
  CLOUDFLARE_ACCOUNT_ID    account tag (also used to build the R2 S3 endpoint)
  AWS_ACCESS_KEY_ID        R2 access key id   (state read/write)
  AWS_SECRET_ACCESS_KEY    R2 secret access key
Optional env:
  R2_BUCKET_NAME           default: codex-app-mirror
  R2_S3_ENDPOINT           default: https://<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com
  STATS_STATE_KEY          default: stats/state.json
  STATS_BADGE_KEY          default: stats/downloads.json
  STATS_OBJECTS            default: latest/win,latest/mac-intel,latest/mac-arm64
  STATS_BADGE_LABEL        default: downloads
  STATS_BADGE_COLOR        default: brightgreen
  STATS_DRY_RUN            if set to 1/true, compute and print but do NOT write R2
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

GRAPHQL_URL = "https://api.cloudflare.com/client/v4/graphql"
# R2 analytics hard limit is "4w4d" (32 days). Stay a day inside it.
WINDOW_DAYS = 31


def env(name: str, default: str | None = None, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"error: required env var {name} is not set")
    return val or ""


def is_truthy(val: str) -> bool:
    return val.strip().lower() in {"1", "true", "yes", "on"}


def human(n: int) -> str:
    """Compact, badge-friendly number: 942, 44.2k, 1.23M."""
    n = int(n)
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        s = f"{n / 1000:.1f}"
        s = s[:-2] if s.endswith(".0") else s
        return f"{s}k"
    s = f"{n / 1_000_000:.2f}".rstrip("0").rstrip(".")
    return f"{s}M"


def graphql_per_day(account: str, bucket: str, objects: set[str],
                    start: str, end: str, token: str) -> dict[str, int]:
    """Return {YYYY-MM-DD: requests} of GetObject on the target objects.

    `start`/`end` are inclusive/exclusive-ish ISO instants; we additionally
    filter by the `date` dimension in the caller, so passing today's 00:00 as
    `end` keeps the (still-changing) current day out of the totals.
    """
    per_day: dict[str, int] = {}
    for object_name in sorted(objects):
        for day, requests in graphql_per_day_for_object(
            account, bucket, object_name, start, end, token
        ).items():
            per_day[day] = per_day.get(day, 0) + requests
    return per_day


def graphql_per_day_for_object(account: str, bucket: str, object_name: str,
                               start: str, end: str, token: str) -> dict[str, int]:
    """Return per-day GetObject counts for one exact R2 object key."""
    query = (
        "query($account:String!,$bucket:String!,$objectName:String!,"
        "$from:Time!,$to:Time!){"
        "viewer{accounts(filter:{accountTag:$account}){"
        "r2OperationsAdaptiveGroups(limit:10000,orderBy:[date_ASC],"
        "filter:{datetime_geq:$from,datetime_leq:$to,bucketName:$bucket,"
        'actionType:"GetObject",objectName:$objectName}){'
        "sum{requests} dimensions{date objectName}}}}}"
    )
    variables = {
        "account": account,
        "bucket": bucket,
        "objectName": object_name,
        "from": start,
        "to": end,
    }
    payload = json.dumps({"query": query, "variables": variables}).encode()

    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                GRAPHQL_URL, data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.load(resp)
            if body.get("errors"):
                raise RuntimeError(f"GraphQL errors: {body['errors']}")
            groups = (body["data"]["viewer"]["accounts"][0]
                      ["r2OperationsAdaptiveGroups"])
            if len(groups) >= 10000:
                raise RuntimeError(
                    f"GraphQL result hit the 10000-row limit for {object_name}"
                )
            per_day: dict[str, int] = {}
            for g in groups:
                if g["dimensions"]["objectName"] != object_name:
                    raise RuntimeError(
                        "GraphQL objectName filter returned unexpected object "
                        f"{g['dimensions']['objectName']!r} for {object_name!r}"
                    )
                d = g["dimensions"]["date"]
                per_day[d] = per_day.get(d, 0) + int(g["sum"]["requests"])
            return per_day
        except (urllib.error.URLError, RuntimeError, KeyError, ValueError) as e:
            last_err = e
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
    raise SystemExit(f"error: GraphQL query failed after retries: {last_err}")


def s3_args(endpoint: str) -> list[str]:
    return ["--endpoint-url", endpoint, "--region", "auto", "--no-progress"]


def is_missing_s3_object(stderr: bytes) -> bool:
    text = stderr.decode("utf-8", "replace").lower()
    missing_markers = (
        "404",
        "not found",
        "no such key",
        "nosuchkey",
        "does not exist",
    )
    return any(marker in text for marker in missing_markers)


def s3_read(bucket: str, key: str, endpoint: str, allow_missing_aws: bool = False) -> bytes | None:
    try:
        p = subprocess.run(
            ["aws", "s3", "cp", f"s3://{bucket}/{key}", "-", *s3_args(endpoint)],
            capture_output=True,
        )
    except FileNotFoundError:
        if allow_missing_aws:
            return None
        raise SystemExit("error: aws CLI is required to read stats state")
    if p.returncode != 0:
        if is_missing_s3_object(p.stderr):
            return None
        stderr = p.stderr.decode("utf-8", "replace").strip()
        raise SystemExit(
            f"error: failed to read s3://{bucket}/{key}; refusing to cold-start "
            f"from an ambiguous AWS CLI failure: {stderr}"
        )
    return p.stdout


def s3_write(bucket: str, key: str, data: bytes, content_type: str,
             cache_control: str, endpoint: str) -> None:
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as tmp:
        tmp.write(data)
        tmp_path = tmp.name
    try:
        subprocess.run(
            ["aws", "s3", "cp", tmp_path, f"s3://{bucket}/{key}",
             "--content-type", content_type,
             "--cache-control", cache_control, *s3_args(endpoint)],
            check=True,
        )
    finally:
        os.unlink(tmp_path)


def daterange(start: "datetime.date", end_inclusive: "datetime.date"):
    d = start
    while d <= end_inclusive:
        yield d
        d += timedelta(days=1)


def main() -> int:
    token = env("CF_ANALYTICS_API_TOKEN", required=True)
    account = env("CLOUDFLARE_ACCOUNT_ID", required=True)
    bucket = env("R2_BUCKET_NAME", "codex-app-mirror")
    endpoint = env("R2_S3_ENDPOINT",
                   f"https://{account}.r2.cloudflarestorage.com")
    state_key = env("STATS_STATE_KEY", "stats/state.json")
    badge_key = env("STATS_BADGE_KEY", "stats/downloads.json")
    objects = {s.strip() for s in env(
        "STATS_OBJECTS",
        "latest/win,latest/mac-intel,latest/mac-arm64").split(",") if s.strip()}
    label = env("STATS_BADGE_LABEL", "downloads")
    color = env("STATS_BADGE_COLOR", "brightgreen")
    dry_run = is_truthy(env("STATS_DRY_RUN", "0"))

    today = datetime.now(timezone.utc).date()
    yesterday = today - timedelta(days=1)
    window_start = today - timedelta(days=WINDOW_DAYS)
    today_iso = f"{today.isoformat()}T00:00:00Z"

    print(f"== R2 download stats == bucket={bucket} today(UTC)={today} "
          f"dry_run={dry_run}")
    print(f"   counting objects: {sorted(objects)}")

    raw = s3_read(bucket, state_key, endpoint, allow_missing_aws=dry_run)
    state = json.loads(raw) if raw else None

    if state is None:
        # Cold start: seed the cumulative total from the entire retention
        # window. While the bucket is younger than 32 days this captures the
        # full real history with no loss.
        print("   no existing state -> initializing from retention window")
        start_date = window_start
        gap_days = 0
    else:
        total0 = int(state.get("total", 0))
        last_counted = datetime.strptime(
            state["lastCountedDate"], "%Y-%m-%d").date()
        print(f"   loaded state: total={total0} lastCountedDate={last_counted}")
        start_date = last_counted + timedelta(days=1)
        # If we have been offline longer than the retention window, the missing
        # days are unrecoverable. Clamp and warn loudly rather than fail.
        gap_days = max(0, (window_start - start_date).days)
        if gap_days > 0:
            print(f"   WARNING: gap of {gap_days} day(s) older than the 32-day "
                  f"window cannot be recovered ({start_date} .. "
                  f"{window_start - timedelta(days=1)}). Their downloads are "
                  f"permanently lost from the cumulative total.")
            start_date = window_start

    if start_date > yesterday:
        # Already counted through yesterday; nothing new (today is in-flight).
        print("   up to date: no fully-elapsed new day to add")
        per_day_new: dict[str, int] = {}
    else:
        start_iso = f"{start_date.isoformat()}T00:00:00Z"
        per_day = graphql_per_day(account, bucket, objects, start_iso,
                                  today_iso, token)
        # Keep only fully-elapsed days in [start_date, yesterday].
        per_day_new = {
            d.isoformat(): per_day.get(d.isoformat(), 0)
            for d in daterange(start_date, yesterday)
        }

    increment = sum(per_day_new.values())

    if state is None:
        base_total = 0
        per_day_hist: dict[str, int] = {}
    else:
        base_total = int(state.get("total", 0))
        per_day_hist = dict(state.get("perDay", {}))
    per_day_hist.update(per_day_new)
    total = base_total + increment

    new_state = {
        "schema": 1,
        "bucket": bucket,
        "metric": "installer_downloads_getobject",
        "objects": sorted(objects),
        "total": total,
        "lastCountedDate": yesterday.isoformat()
        if start_date <= yesterday or state is None else state["lastCountedDate"],
        "perDay": dict(sorted(per_day_hist.items())),
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if gap_days > 0:
        new_state["lastGapDays"] = gap_days

    badge = {
        "schemaVersion": 1,
        "label": label,
        "message": human(total),
        "color": color,
    }

    # Report
    if per_day_new:
        print("   new days added:")
        for d, c in sorted(per_day_new.items()):
            print(f"     {d}  +{c}")
    print(f"   increment={increment}  cumulative total={total} "
          f"({human(total)})")

    if dry_run:
        print("   DRY RUN: not writing R2. Would write:")
        print("   --- state.json ---")
        print(json.dumps(new_state, indent=2))
        print("   --- downloads.json (badge) ---")
        print(json.dumps(badge))
        return 0

    s3_write(bucket, state_key,
             json.dumps(new_state, separators=(",", ":")).encode(),
             "application/json", "no-cache", endpoint)
    s3_write(bucket, badge_key,
             json.dumps(badge, separators=(",", ":")).encode(),
             "application/json", "max-age=300", endpoint)
    print(f"   wrote s3://{bucket}/{state_key} and s3://{bucket}/{badge_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
