#!/usr/bin/env python3
"""Build a small deterministic risk overlay without rewriting graph Parquets."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import geopandas as gpd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.risk_assignment import assign_relevant_crashes  # noqa: E402

GRAPH = ROOT / "data/graph"
PROCESSED = ROOT / "data/processed"


def build(profile: str) -> Path:
    edges = gpd.read_parquet(GRAPH / f"{profile}_edges.parquet")
    crashes = gpd.read_file(PROCESSED / "active_crashes.geojson")
    assigned = assign_relevant_crashes(crashes, edges, profile=profile)
    overlay = assigned.groupby("edge_id").agg(
        risk=("effective_risk", "sum"),
        risk_dark=("effective_risk_dark", "sum"),
        incident_count=("crash_id", "nunique"),
    ).reset_index()
    output = GRAPH / f"{profile}_risk_v1.csv"
    overlay.to_csv(output, index=False)
    print(
        f"wrote {output}: {len(assigned)} unique relevant incidents, "
        f"{len(overlay)} non-zero edges, risk={overlay['risk'].sum():.1f}"
    )
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=["walking", "cycling"], default="walking", nargs="?")
    args = parser.parse_args()
    build(args.profile)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
