"""Self-built risk-weighted router over the Sydney OSM graph.

Loads data/graph/{profile}_{nodes,edges}.parquet (built by scripts/build_graph.py)
into scipy CSR matrices. Cost model per edge:

    cost = length_m * (1 + k * risk_per_100m) * (0.9 if school_zone else 1.0)

where k scales with the user's safety slider, so safety=0 reproduces the
shortest path and higher k trades distance for lower crash exposure.
Graphs are treated as undirected (fine for walking; acceptable for hack-week
cycling — note oneway streets are ignored).
"""
import json
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import cKDTree

GRAPH_DIR = Path(__file__).resolve().parent.parent.parent / "data" / "graph"

SPEED_MPS = {"walking": 4.8 / 3.6, "cycling": 15.0 / 3.6}
K_MAX = 4.0  # cost multiplier scale at safety=1


class Profile:
    def __init__(self, name: str):
        nodes = pd.read_parquet(GRAPH_DIR / f"{name}_nodes.parquet")
        edges = gpd.read_parquet(GRAPH_DIR / f"{name}_edges.parquet")
        self.name = name
        self.xy = np.column_stack([nodes["x"].to_numpy(), nodes["y"].to_numpy()])
        self.kdtree = cKDTree(self.xy)
        self.n = len(nodes)

        u = edges["u"].to_numpy(np.int32)
        v = edges["v"].to_numpy(np.int32)
        self.length = edges["length_m"].to_numpy(np.float64)
        self.risk = edges["risk"].to_numpy(np.float64)
        self.risk_dark = edges["risk_dark"].to_numpy(np.float64) if "risk_dark" in edges else self.risk
        self.szone = edges["school_zone"].to_numpy(bool)
        # undirected: duplicate each edge both ways; remember original edge row
        self.eu = np.concatenate([u, v])
        self.ev = np.concatenate([v, u])
        self.eid = np.concatenate([np.arange(len(edges)), np.arange(len(edges))])
        self.geoms = edges.geometry.values  # shapely lines, indexed by original edge id
        # map (min(u,v),max(u,v)) -> edge id for path reconstruction
        lo = np.minimum(u, v).astype(np.int64)
        hi = np.maximum(u, v).astype(np.int64)
        self.pair_key = lo * (self.n + 1) + hi
        order = np.argsort(self.pair_key)
        self.pair_key_sorted = self.pair_key[order]
        self.pair_eid_sorted = np.arange(len(edges))[order]

    def edge_costs(self, k: float, after_dark: bool = False) -> np.ndarray:
        risk = self.risk_dark if after_dark else self.risk
        # normalized so a typical risky edge (risk ~10 over 100 m) costs ~2x at
        # full slider instead of saturating; keeps the slider a real dial
        risk_per_100m = risk / np.maximum(self.length, 5.0) * 100.0
        cost = self.length * (1.0 + k * risk_per_100m / 10.0)
        cost[self.szone] *= 0.9
        return np.concatenate([cost, cost])

    def matrix(self, k: float, after_dark: bool = False) -> csr_matrix:
        return csr_matrix((self.edge_costs(k, after_dark), (self.eu, self.ev)), shape=(self.n, self.n))

    def nearest_node(self, lon: float, lat: float) -> int:
        _, i = self.kdtree.query([lon, lat])
        return int(i)

    def lookup_edge(self, a: int, b: int) -> int:
        key = min(a, b) * (self.n + 1) + max(a, b)
        j = np.searchsorted(self.pair_key_sorted, key)
        if j < len(self.pair_key_sorted) and self.pair_key_sorted[j] == key:
            return int(self.pair_eid_sorted[j])
        return -1

    def route(self, start: list[float], end: list[float], k: float, after_dark: bool = False) -> dict:
        s = self.nearest_node(*start)
        t = self.nearest_node(*end)
        dist, pred = dijkstra(self.matrix(k, after_dark), directed=False, indices=s, return_predecessors=True)
        if not np.isfinite(dist[t]):
            raise ValueError("no path found between the snapped points")
        # walk predecessors back from t
        path = [t]
        while path[-1] != s:
            p = pred[path[-1]]
            if p < 0:
                raise ValueError("path reconstruction failed")
            path.append(int(p))
        path.reverse()

        coords: list[list[float]] = []
        total_len = 0.0
        total_risk = 0.0
        for a, b in zip(path[:-1], path[1:]):
            e = self.lookup_edge(a, b)
            if e >= 0:
                seg = list(self.geoms[e].coords)
                # orient segment from a to b
                if seg and tuple(np.round(self.xy[a], 6)) != tuple(np.round(seg[0][:2], 6)):
                    seg = seg[::-1]
                total_len += self.length[e]
                total_risk += self.risk[e]
            else:
                seg = [tuple(self.xy[a]), tuple(self.xy[b])]
            if coords:
                seg = seg[1:]
            coords.extend([[round(c[0], 6), round(c[1], 6)] for c in seg])

        duration = total_len / SPEED_MPS[self.name]
        return {
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "geometry": {"type": "LineString", "coordinates": coords},
                "properties": {"summary": {"distance": round(total_len, 1), "duration": round(duration)}},
            }],
        }


_profiles: dict[str, Profile] = {}


def available() -> bool:
    return (GRAPH_DIR / "walking_nodes.parquet").exists()


def get_profile(ors_profile: str) -> Profile:
    name = "cycling" if "cycling" in ors_profile else "walking"
    if name not in _profiles:
        _profiles[name] = Profile(name)
    return _profiles[name]
