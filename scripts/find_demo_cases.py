#!/usr/bin/env python3
"""Find deterministic school-walk demo cases using committed local data.

The search is intentionally bounded: it walks a stable, name-sorted school
sample and tests a small ring of graph-snapped candidate origins. The output is
small JSON; graph or processed datasets are never regenerated.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

import geopandas as gpd
from shapely.geometry import LineString

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app import main as api  # noqa: E402
from backend.app.graph_router import (  # noqa: E402
    DATA_PERIOD,
    MODEL_VERSION,
    Profile,
    select_route_pair,
)


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48]


def offset(lon: float, lat: float, kilometres: float, bearing_deg: int) -> tuple[float, float]:
    bearing = math.radians(bearing_deg)
    dlat = kilometres * math.cos(bearing) / 110.574
    dlon = kilometres * math.sin(bearing) / (111.320 * math.cos(math.radians(lat)))
    return lon + dlon, lat + dlat


def summary(route: dict) -> dict:
    return route["features"][0]["properties"]["summary"]


def find_cases(limit: int, school_limit: int) -> list[dict]:
    profile = Profile("walking")
    schools = gpd.read_file(ROOT / "data/processed/schools.geojson")
    schools = schools[
        schools.geometry.x.between(150.90, 151.30)
        & schools.geometry.y.between(-34.05, -33.70)
    ].sort_values("name", kind="stable").head(school_limit)
    api.load_data()

    cases: list[dict] = []
    for school in schools.itertuples():
        found_for_school = False
        destination = [round(school.geometry.x, 6), round(school.geometry.y, 6)]
        try:
            profile.nearest_node(*destination, label="school destination")
        except ValueError:
            continue
        for distance_km in (1.2, 1.8, 2.4):
            for bearing in (0, 90, 180, 270, 45, 135, 225, 315):
                target = offset(destination[0], destination[1], distance_km, bearing)
                try:
                    origin_node = profile.nearest_node(*target, label="candidate origin")
                    origin = [
                        round(float(profile.xy[origin_node][0]), 6),
                        round(float(profile.xy[origin_node][1]), 6),
                    ]
                    pair = select_route_pair(
                        profile, origin, destination, preference=1.0, after_dark=False
                    )
                except ValueError:
                    continue
                fastest = summary(pair["fastest"])
                lower = summary(pair["lower_hazard"])
                route_lines = gpd.GeoSeries(
                    [
                        LineString(pair["fastest"]["features"][0]["geometry"]["coordinates"]),
                        LineString(pair["lower_hazard"]["features"][0]["geometry"]["coordinates"]),
                    ],
                    crs="EPSG:4326",
                ).to_crs(api.METRIC)
                separation_m = route_lines.iloc[0].hausdorff_distance(route_lines.iloc[1])
                if not (
                    pair["alternative_found"]
                    and 800 <= fastest["distance"] <= 3_000
                    and pair["detour_ratio"] <= 1.25
                    and pair["extra_distance_m"] >= 20
                    and separation_m >= 25
                    and lower["historical_hazard_index"] < fastest["historical_hazard_index"]
                    and pair["fastest"]["features"][0]["geometry"]
                    != pair["lower_hazard"]["features"][0]["geometry"]
                ):
                    continue

                fastest_stats = api.route_stats(pair["fastest"])
                lower_stats = api.route_stats(pair["lower_hazard"])
                case_id = slug(f"{school.name}-{bearing}-{distance_km}")
                cases.append(
                    {
                        "id": case_id,
                        "school_name": school.name,
                        "origin_label": f"Verified graph point about {distance_km:.1f} km from school",
                        "destination_label": "Approximate school destination (not a verified entrance)",
                        "start": origin,
                        "end": destination,
                        "preference": "high",
                        "after_dark": False,
                        "fastest": {
                            "distance_m": fastest["distance"],
                            "duration_s": fastest["duration"],
                            "historical_hazard_index": fastest["historical_hazard_index"],
                            "nearby_reported_incidents": fastest_stats["nearby_reported_incidents"],
                        },
                        "lower_hazard": {
                            "distance_m": lower["distance"],
                            "duration_s": lower["duration"],
                            "historical_hazard_index": lower["historical_hazard_index"],
                            "nearby_reported_incidents": lower_stats["nearby_reported_incidents"],
                        },
                        "detour_ratio": pair["detour_ratio"],
                        "maximum_route_separation_m": round(separation_m, 1),
                        "expected_hazard_reduction_percent": -pair["hazard_change_percent"],
                        "data_period": DATA_PERIOD,
                        "model_version": MODEL_VERSION,
                    }
                )
                print(
                    f"found {case_id}: {fastest['distance']:.0f} m / "
                    f"index {fastest['historical_hazard_index']:.1f} -> "
                    f"{lower['historical_hazard_index']:.1f} / {pair['detour_ratio']:.3f}x",
                    flush=True,
                )
                if len(cases) >= limit:
                    return cases
                found_for_school = True
                break
            if found_for_school:
                break
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--school-limit", type=int, default=80)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "data/demo_cases.json"
    )
    args = parser.parse_args()
    cases = find_cases(limit=max(1, min(args.limit, 5)), school_limit=max(1, args.school_limit))
    if len(cases) < args.limit:
        print(f"Only found {len(cases)} qualifying cases.", file=sys.stderr)
        return 1
    args.output.write_text(json.dumps(cases, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(cases)} cases to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
