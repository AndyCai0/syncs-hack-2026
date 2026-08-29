"""Build risk-weighted routing graphs for Greater Sydney from OSM.

Prereqs (see README):
  data/raw/sydney.osm.pbf     clipped with osmium from australia-latest.osm.pbf
  data/processed/active_crashes.geojson   from prepare_data.py

Outputs (data/graph/):
  {profile}_nodes.parquet   node_id, x, y
  {profile}_edges.parquet   u, v (node indices), length_m, risk, school_zone, geometry (wkb)

Risk model: each profile-relevant crash is assigned once to one deterministic
nearest edge within 40 m. Walking uses pedestrian crashes only; cycling uses
cyclist crashes only. Equal-distance edge ties choose the lowest edge id.

Run:  .venv/bin/python scripts/build_graph.py [walking|cycling|both]
"""
import sys
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd

try:
    from scripts.risk_assignment import assign_relevant_crashes
except ModuleNotFoundError:  # direct `python scripts/build_graph.py`
    from risk_assignment import assign_relevant_crashes

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
    crashes = gpd.read_file(PROCESSED / "active_crashes.geojson")
    print(f"[{profile}] assigning relevant crashes to edges ...")
    assigned = assign_relevant_crashes(crashes, edges, profile=profile)
    agg = assigned.groupby("edge_id")[["effective_risk", "effective_risk_dark"]].sum()
    edges["risk"] = 0.0
    edges["risk_dark"] = 0.0
    edges.loc[agg.index, "risk"] = agg["effective_risk"].to_numpy()
    edges.loc[agg.index, "risk_dark"] = agg["effective_risk_dark"].to_numpy()
    print(f"[{profile}] {int((edges['risk'] > 0).sum())} edges carry risk, "
          f"{assigned['effective_risk'].sum():.0f} total risk assigned "
          f"({len(assigned)} unique relevant crashes within 40 m)")

    # ---- school zone flag (display-only until operating times are modelled) ----
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
    overlay = agg.rename(
        columns={"effective_risk": "risk", "effective_risk_dark": "risk_dark"}
    ).join(assigned.groupby("edge_id")["crash_id"].nunique().rename("incident_count"))
    overlay.reset_index().to_csv(GRAPH / f"{profile}_risk_v1.csv", index=False)
    print(f"[{profile}] wrote {GRAPH}/{profile}_{{nodes,edges}}.parquet")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    for p in (["walking", "cycling"] if which == "both" else [which]):
        build(p)
