"""Self-built risk-weighted router over the Sydney OSM graph.

Loads data/graph/{profile}_{nodes,edges}.parquet (built by scripts/build_graph.py)
into SciPy CSR matrices. Cost model per edge:

    cost = length_m * (1 + k * risk_per_100m / 10)

where k scales a historical-hazard avoidance preference. School zones remain
an explanatory layer but receive no unconditional routing discount because
their operating times are not represented in the graph. Graphs are treated as
undirected; the public demo uses only the walking profile.
"""
import json
from collections import OrderedDict
from dataclasses import dataclass
from math import asin, cos, radians, sin, sqrt
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
MAX_DETOUR_RATIO = 1.25
DATA_PERIOD = "2020-2024"
MODEL_VERSION = "hack-2026-v1"


@dataclass(frozen=True)
class EdgeSelection:
    """One deterministic edge per undirected node pair for a weighting."""

    matrix: csr_matrix
    pair_keys: np.ndarray
    edge_ids: np.ndarray


class Profile:
    def __init__(self, name: str, graph_dir: Path = GRAPH_DIR):
        nodes = pd.read_parquet(graph_dir / f"{name}_nodes.parquet")
        edges = gpd.read_parquet(graph_dir / f"{name}_edges.parquet")
        self.name = name
        self.xy = np.column_stack([nodes["x"].to_numpy(), nodes["y"].to_numpy()])
        self.kdtree = cKDTree(self.xy)
        self.n = len(nodes)

        self.u = edges["u"].to_numpy(np.int32)
        self.v = edges["v"].to_numpy(np.int32)
        self.length = edges["length_m"].to_numpy(np.float64)
        self.risk = edges["risk"].to_numpy(np.float64)
        self.risk_dark = edges["risk_dark"].to_numpy(np.float64) if "risk_dark" in edges else self.risk
        overlay_path = graph_dir / f"{name}_risk_v1.csv"
        self.risk_source = "legacy_graph_columns"
        if overlay_path.exists():
            overlay = pd.read_csv(overlay_path)
            edge_ids = overlay["edge_id"].to_numpy(np.int64)
            if len(np.unique(edge_ids)) != len(edge_ids):
                raise ValueError(f"duplicate edge ids in {overlay_path.name}")
            if len(edge_ids) and (edge_ids.min() < 0 or edge_ids.max() >= len(edges)):
                raise ValueError(f"edge id outside graph range in {overlay_path.name}")
            self.risk = np.zeros(len(edges), dtype=np.float64)
            self.risk_dark = np.zeros(len(edges), dtype=np.float64)
            self.risk[edge_ids] = overlay["risk"].to_numpy(np.float64)
            self.risk_dark[edge_ids] = overlay["risk_dark"].to_numpy(np.float64)
            self.risk_source = overlay_path.name
        self.szone = edges["school_zone"].to_numpy(bool)
        self.geoms = edges.geometry.values  # shapely lines, indexed by original edge id

        # SciPy sums duplicate CSR entries. Pre-group parallel edges once, then
        # choose the minimum-cost member of each pair for every weighting.
        lo = np.minimum(self.u, self.v).astype(np.int64)
        hi = np.maximum(self.u, self.v).astype(np.int64)
        self.pair_key = lo * (self.n + 1) + hi
        self._pair_order = np.argsort(self.pair_key, kind="stable")
        sorted_keys = self.pair_key[self._pair_order]
        self._group_start = np.flatnonzero(
            np.r_[True, sorted_keys[1:] != sorted_keys[:-1]]
        )
        self._group_end = np.r_[self._group_start[1:], len(sorted_keys)]
        self._selection_cache: OrderedDict[tuple[float, bool], EdgeSelection] = OrderedDict()

    def edge_costs(self, k: float, after_dark: bool = False) -> np.ndarray:
        risk = self.risk_dark if after_dark else self.risk
        # normalized so a typical risky edge (risk ~10 over 100 m) costs ~2x at
        # full slider instead of saturating; keeps the slider a real dial
        risk_per_100m = risk / np.maximum(self.length, 5.0) * 100.0
        return self.length * (1.0 + k * risk_per_100m / 10.0)

    def matrix(self, k: float, after_dark: bool = False) -> csr_matrix:
        return self._selection(k, after_dark).matrix

    def _selection(self, k: float, after_dark: bool = False) -> EdgeSelection:
        cache_key = (round(float(k), 6), bool(after_dark))
        if cache_key in self._selection_cache:
            self._selection_cache.move_to_end(cache_key)
            return self._selection_cache[cache_key]

        costs = self.edge_costs(k, after_dark)
        selected = self._pair_order[self._group_start].copy()
        group_sizes = self._group_end - self._group_start
        for group in np.flatnonzero(group_sizes > 1):
            candidates = self._pair_order[self._group_start[group] : self._group_end[group]]
            # Stable tie-break on original edge id makes geometry deterministic.
            best = np.lexsort((candidates, costs[candidates]))[0]
            selected[group] = candidates[best]

        # Self-loops never improve Dijkstra paths and duplicating them into a
        # symmetric matrix would reintroduce a duplicate sparse entry.
        traversable = self.u[selected] != self.v[selected]
        selected = selected[traversable]
        pair_keys = self.pair_key[selected]
        u = self.u[selected]
        v = self.v[selected]
        data = costs[selected]
        matrix = csr_matrix(
            (np.concatenate([data, data]), (np.concatenate([u, v]), np.concatenate([v, u]))),
            shape=(self.n, self.n),
        )
        result = EdgeSelection(matrix=matrix, pair_keys=pair_keys, edge_ids=selected)
        self._selection_cache[cache_key] = result
        self._selection_cache.move_to_end(cache_key)
        while len(self._selection_cache) > 2:
            self._selection_cache.popitem(last=False)
        return result

    @staticmethod
    def distance_metres(a: tuple[float, float], b: tuple[float, float]) -> float:
        """Haversine distance between two ``(lon, lat)`` points."""

        lon1, lat1 = map(radians, a)
        lon2, lat2 = map(radians, b)
        dlon = lon2 - lon1
        dlat = lat2 - lat1
        hav = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
        return 2 * 6_371_000 * asin(sqrt(hav))

    def nearest_node(
        self,
        lon: float,
        lat: float,
        *,
        label: str = "point",
        max_distance_m: float = 500,
    ) -> int:
        _, i = self.kdtree.query([lon, lat])
        node = int(i)
        snap_distance = self.distance_metres((lon, lat), tuple(self.xy[node]))
        if snap_distance > max_distance_m:
            raise ValueError(
                f"{label} is more than {max_distance_m:.0f} m from the walking graph "
                f"({snap_distance:.0f} m)"
            )
        return node

    def lookup_edge(self, a: int, b: int, selection: EdgeSelection) -> int:
        key = min(a, b) * (self.n + 1) + max(a, b)
        j = np.searchsorted(selection.pair_keys, key)
        if j < len(selection.pair_keys) and selection.pair_keys[j] == key:
            return int(selection.edge_ids[j])
        return -1

    def route(self, start: list[float], end: list[float], k: float, after_dark: bool = False) -> dict:
        s = self.nearest_node(*start, label="start")
        t = self.nearest_node(*end, label="destination")
        selection = self._selection(k, after_dark)
        dist, pred = dijkstra(selection.matrix, directed=True, indices=s, return_predecessors=True)
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
            e = self.lookup_edge(a, b, selection)
            if e >= 0:
                seg = list(self.geoms[e].coords)
                # orient segment from a to b
                if seg and tuple(np.round(self.xy[a], 6)) != tuple(np.round(seg[0][:2], 6)):
                    seg = seg[::-1]
                total_len += self.length[e]
                total_risk += (self.risk_dark if after_dark else self.risk)[e]
            else:
                seg = [tuple(self.xy[a]), tuple(self.xy[b])]
            if coords:
                seg = seg[1:]
            coords.extend([[round(c[0], 6), round(c[1], 6)] for c in seg])

        duration = float(total_len / SPEED_MPS[self.name])
        return {
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "geometry": {"type": "LineString", "coordinates": coords},
                "properties": {"summary": {
                    "distance": round(float(total_len), 1),
                    "duration": round(duration),
                    "historical_hazard_index": round(float(total_risk), 2),
                }},
            }],
        }


def _summary(route: dict) -> dict:
    return route["features"][0]["properties"]["summary"]


def select_route_pair(
    profile: Profile,
    start: list[float],
    end: list[float],
    preference: float,
    after_dark: bool = False,
    max_detour_ratio: float = MAX_DETOUR_RATIO,
) -> dict:
    """Return the lowest-index bounded candidate plus the fastest baseline.

    Candidate search is intentionally small for live-demo latency. A candidate
    only qualifies when its effective edge-risk index is strictly lower and
    its duration is at most ``max_detour_ratio`` times the fastest route.
    """

    fastest = profile.route(start, end, k=0.0, after_dark=after_dark)
    fast_summary = _summary(fastest)
    fast_duration = float(fast_summary["duration"])
    fast_distance = float(fast_summary["distance"])
    fast_hazard = float(fast_summary["historical_hazard_index"])

    preference = min(max(float(preference), 0.0), 1.0)
    base_k = preference * K_MAX
    candidate_ks = sorted(
        {
            round(k, 6)
            for k in (base_k * 0.5, base_k, min(K_MAX, base_k * 1.5))
            if k > 0
        }
    )
    eligible: list[tuple[float, float, dict]] = []
    for k in candidate_ks:
        candidate = profile.route(start, end, k=k, after_dark=after_dark)
        summary = _summary(candidate)
        duration = float(summary["duration"])
        hazard = float(summary["historical_hazard_index"])
        if duration <= fast_duration * max_detour_ratio + 1 and hazard < fast_hazard:
            eligible.append((hazard, duration, candidate))

    if eligible:
        _, _, lower_hazard = min(eligible, key=lambda item: (item[0], item[1]))
        alternative_found = True
        reason = None
    else:
        lower_hazard = fastest
        alternative_found = False
        reason = "no_reasonable_lower_hazard_alternative"

    lower_summary = _summary(lower_hazard)
    lower_duration = float(lower_summary["duration"])
    lower_distance = float(lower_summary["distance"])
    lower_hazard_value = float(lower_summary["historical_hazard_index"])
    hazard_change = (
        round((lower_hazard_value / fast_hazard - 1.0) * 100.0, 1)
        if alternative_found and fast_hazard > 0
        else None
    )
    return {
        "fastest": fastest,
        "lower_hazard": lower_hazard,
        "alternative_found": alternative_found,
        "reason": reason,
        "extra_duration_s": round(lower_duration - fast_duration),
        "extra_distance_m": round(lower_distance - fast_distance, 1),
        "hazard_change_percent": hazard_change,
        "detour_ratio": round(lower_duration / fast_duration, 3) if fast_duration > 0 else 1.0,
        "data_period": DATA_PERIOD,
        "model_version": MODEL_VERSION,
    }


_profiles: dict[str, Profile] = {}


def available() -> bool:
    return (GRAPH_DIR / "walking_nodes.parquet").exists()


def get_profile(ors_profile: str) -> Profile:
    name = "cycling" if "cycling" in ors_profile else "walking"
    if name not in _profiles:
        _profiles[name] = Profile(name)
    return _profiles[name]
