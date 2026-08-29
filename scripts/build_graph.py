"""Build risk-weighted routing graphs for Greater Sydney from OSM.

Prereqs (see README):
  data/raw/sydney.osm.pbf     clipped with osmium from australia-latest.osm.pbf
  data/processed/active_crashes.geojson   from prepare_data.py

Outputs (data/graph/):
  {profile}_nodes.parquet   node_id, x, y
  {profile}_edges.parquet   u, v (node indices), length_m, risk, school_zone, geometry (wkb)

Risk model: each ped/bike crash is snapped to the nearest edge within 40 m and
adds its severity-weighted risk to that edge. Walking uses pedestrian crashes
double-weighted; cycling weighs cyclist crashes double.

Run:  .venv/bin/python scripts/build_graph.py [walking|cycling|both]
"""
import sys
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
PROCESSED = ROOT / "data" / "processed"
GRAPH = ROOT / "data" / "graph"
GRAPH.mkdir(parents=True, exist_ok=True)

METRIC = "EPSG:7856"


def build(profile: str) -> None:
    from pyrosm import OSM

    print(f"[{profile}] reading sydney.osm.pbf with pyrosm ...")
    osm = OSM(str(RAW / "sydney.osm.pbf"))
    nodes, edges = osm.get_network(network_type=profile, nodes=True)
    print(f"[{profile}] {len(nodes)} nodes, {len(edges)} edges")

    # compact node indexing
    node_ids = nodes["id"].to_numpy()
    idx_of = pd.Series(np.arange(len(node_ids)), index=node_ids)
    edges = edges[edges["u"].isin(idx_of.index) & edges["v"].isin(idx_of.index)].copy()
    edges["ui"] = idx_of[edges["u"]].to_numpy()
    edges["vi"] = idx_of[edges["v"]].to_numpy()

    edges_m = edges.set_geometry("geometry").set_crs("EPSG:4326", allow_override=True).to_crs(METRIC)
    edges["length_m"] = edges_m.length.to_numpy()

    # ---- snap crashes to nearest edge (<=40 m) ----
    crashes = gpd.read_file(PROCESSED / "active_crashes.geojson").to_crs(METRIC)
    if profile == "walking":
        mode_w = np.where(crashes["has_pedestrian"], 2.0, 1.0)
    else:
        mode_w = np.where(crashes["has_bicycle"], 2.0, 1.0)
    crash_risk = crashes["risk"].to_numpy() * mode_w
    dark = crashes["natural_lighting"].astype(str).str.contains("Dark|Dusk|Dawn", case=False, na=False)
    crash_risk_dark = crash_risk * np.where(dark, 1.5, 1.0)

    print(f"[{profile}] snapping {len(crashes)} crashes to edges ...")
    joined = gpd.sjoin_nearest(
        crashes[["geometry"]].assign(cr=crash_risk, crd=crash_risk_dark),
        edges_m[["geometry"]].reset_index(),
        max_distance=40.0, distance_col="snap_d",
    )
    agg = joined.groupby("index")[["cr", "crd"]].sum()
    edges["risk"] = 0.0
    edges["risk_dark"] = 0.0
    edges.loc[agg.index, "risk"] = agg["cr"].to_numpy()
    edges.loc[agg.index, "risk_dark"] = agg["crd"].to_numpy()
    print(f"[{profile}] {int((edges['risk'] > 0).sum())} edges carry risk, "
          f"{joined['cr'].sum():.0f} total risk snapped ({len(joined)}/{len(crashes)} crashes within 40 m)")

    # ---- school zone flag (routes through 40 km/h zones are calmer) ----
    zones = gpd.read_file(PROCESSED / "school_zones.geojson").to_crs(METRIC)
    zidx = edges_m.sindex.query(zones.geometry.union_all(), predicate="intersects")
    edges["school_zone"] = False
    edges.iloc[zidx, edges.columns.get_loc("school_zone")] = True
    print(f"[{profile}] {int(edges['school_zone'].sum())} edges in school zones")

    out_nodes = pd.DataFrame({"id": node_ids, "x": nodes["lon"].to_numpy(), "y": nodes["lat"].to_numpy()})
    out_nodes.to_parquet(GRAPH / f"{profile}_nodes.parquet", index=False)
    out_edges = gpd.GeoDataFrame(
        {
            "u": edges["ui"].to_numpy(), "v": edges["vi"].to_numpy(),
            "length_m": edges["length_m"].to_numpy(),
            "risk": edges["risk"].to_numpy(),
            "risk_dark": edges["risk_dark"].to_numpy(),
            "school_zone": edges["school_zone"].to_numpy(),
        },
        geometry=edges["geometry"].to_numpy(), crs="EPSG:4326",
    )
    out_edges.to_parquet(GRAPH / f"{profile}_edges.parquet", index=False)
    print(f"[{profile}] wrote {GRAPH}/{profile}_{{nodes,edges}}.parquet")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    for p in (["walking", "cycling"] if which == "both" else [which]):
        build(p)
