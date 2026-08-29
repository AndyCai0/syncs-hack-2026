"""Deterministic crash-to-edge assignment shared by graph exporters."""

from __future__ import annotations

import geopandas as gpd
import numpy as np

METRIC = "EPSG:7856"


def assign_relevant_crashes(
    crashes: gpd.GeoDataFrame,
    edges: gpd.GeoDataFrame,
    *,
    profile: str,
    max_distance_m: float = 40.0,
) -> gpd.GeoDataFrame:
    """Assign each mode-relevant crash to exactly one nearest edge.

    Equal-distance matches are resolved by the stable zero-based edge id. One
    crash id therefore contributes once, never once per tied edge.
    """

    if profile not in {"walking", "cycling"}:
        raise ValueError(f"unknown profile: {profile}")
    flag = "has_pedestrian" if profile == "walking" else "has_bicycle"
    relevant = crashes[crashes[flag].fillna(False).astype(bool)].copy()
    relevant = relevant.drop_duplicates(subset=["crash_id"], keep="first")
    if relevant.empty:
        return gpd.GeoDataFrame(
            columns=["crash_id", "edge_id", "effective_risk", "effective_risk_dark", "snap_d"],
            geometry=[],
            crs=METRIC,
        )

    speed_uplift = np.where(relevant["speed_limit_kmh"].fillna(0) >= 60, 1.3, 1.0)
    relevant["effective_risk"] = relevant["severity_w"].astype(float) * speed_uplift
    dark = relevant["natural_lighting"].astype(str).str.contains(
        "Dark|Dusk|Dawn", case=False, na=False
    )
    relevant["effective_risk_dark"] = relevant["effective_risk"] * np.where(dark, 1.5, 1.0)
    relevant = relevant.to_crs(METRIC)

    edges_m = gpd.GeoDataFrame(
        {"edge_id": np.arange(len(edges), dtype=np.int64)},
        geometry=edges.geometry,
        crs=edges.crs,
    ).to_crs(METRIC)
    joined = gpd.sjoin_nearest(
        relevant[
            ["crash_id", "effective_risk", "effective_risk_dark", "geometry"]
        ],
        edges_m,
        max_distance=max_distance_m,
        distance_col="snap_d",
        how="inner",
    )
    joined = joined.sort_values(
        ["crash_id", "snap_d", "edge_id"], kind="stable"
    ).drop_duplicates(subset=["crash_id"], keep="first")
    return joined[
        ["crash_id", "edge_id", "effective_risk", "effective_risk_dark", "snap_d", "geometry"]
    ].reset_index(drop=True)
