#!/usr/bin/env python3
"""Check health and one deterministic local walking route."""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request


REQUIRED_TOP_LEVEL = {
    "engine",
    "fastest",
    "lower_hazard",
    "alternative_found",
    "extra_duration_s",
    "extra_distance_m",
    "hazard_change_percent",
    "detour_ratio",
    "data_period",
    "model_version",
}
REQUIRED_STATS = {
    "historical_hazard_index",
    "nearby_reported_incidents",
    "distance_m",
    "duration_s",
    "data_period",
    "model_version",
}


def request_json(url: str, payload: dict | None = None) -> object:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"} if body else {},
        method="POST" if body else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{url} returned HTTP {error.code}: {detail}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")

    health = request_json(f"{base_url}/api/health")
    if not health.get("ok") or not health.get("local_walking_graph"):
        raise RuntimeError(f"backend is not demo-ready: {health}")

    cases = request_json(f"{base_url}/api/demo_cases")
    if not cases:
        raise RuntimeError("no committed demo cases were returned")
    demo = cases[0]
    result = request_json(
        f"{base_url}/api/route",
        {
            "start": demo["start"],
            "end": demo["end"],
            "profile": "foot-walking",
            "safety": 1.0,
            "after_dark": bool(demo.get("after_dark", False)),
            "engine": "local",
        },
    )
    missing = REQUIRED_TOP_LEVEL - result.keys()
    if missing:
        raise RuntimeError(f"route response is missing: {sorted(missing)}")
    for route_name in ("fastest", "lower_hazard"):
        stats_missing = REQUIRED_STATS - result[route_name]["stats"].keys()
        if stats_missing:
            raise RuntimeError(f"{route_name} stats are missing: {sorted(stats_missing)}")
    if result["engine"] != "local":
        raise RuntimeError(f"expected local engine, got {result['engine']}")
    if result["detour_ratio"] > 1.25:
        raise RuntimeError(f"detour ratio exceeds cap: {result['detour_ratio']}")

    fastest = result["fastest"]["stats"]
    lower = result["lower_hazard"]["stats"]
    print(
        f"smoke ok: {demo['school_name']} | "
        f"fastest {fastest['duration_s']}s/index {fastest['historical_hazard_index']} | "
        f"lower {lower['duration_s']}s/index {lower['historical_hazard_index']} | "
        f"detour {result['detour_ratio']:.3f}x"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
