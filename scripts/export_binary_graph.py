"""Export the routing graphs to the SRG1 binary format consumed by the Swift app.

Reads   data/graph/{profile}_{nodes,edges}.parquet
Writes  data/appdata/{profile}.graph      (see SafeRoutesMac/GRAPH_FORMAT.md)
        data/appdata/{active_crashes,schools,school_zones}.geojson  (verbatim copies)

crashCount per edge is recomputed here with the same deterministic,
profile-relevant assignment used by build_graph.py.

Run:  .venv/bin/python scripts/export_binary_graph.py [walking|cycling|both]
"""
import shutil
import struct
import sys
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely

try:
    from scripts.risk_assignment import assign_relevant_crashes
except ModuleNotFoundError:  # direct `python scripts/export_binary_graph.py`
    from risk_assignment import assign_relevant_crashes

ROOT = Path(__file__).resolve().parent.parent
PROCESSED = ROOT / "data" / "processed"
GRAPH = ROOT / "data" / "graph"
APPDATA = ROOT / "data" / "appdata"

METRIC = "EPSG:7856"
MAGIC = b"SRG1"
VERSION = 1
HEADER_SIZE = 32
ALIGN = 8

EDGE_DTYPE = np.dtype(
    [
        ("u", "<u4"),
        ("v", "<u4"),
        ("length", "<f4"),
        ("risk", "<f4"),
        ("riskDark", "<f4"),
        ("crashCount", "<u2"),
        ("schoolZone", "u1"),
        ("pad", "u1"),
        ("geomOffset", "<u4"),
        ("geomCount", "<u4"),
    ]
)
assert EDGE_DTYPE.itemsize == 32, EDGE_DTYPE.itemsize
_OFFSETS = {n: EDGE_DTYPE.fields[n][1] for n in EDGE_DTYPE.names}
assert _OFFSETS == {
    "u": 0, "v": 4, "length": 8, "risk": 12, "riskDark": 16,
    "crashCount": 20, "schoolZone": 22, "pad": 23, "geomOffset": 24, "geomCount": 28,
}, _OFFSETS

COMPANIONS = ("active_crashes.geojson", "schools.geojson", "school_zones.geojson")


def _pad_to_align(fh) -> None:
    """Advance the file to the next ALIGN-byte boundary with zero bytes."""
    pos = fh.tell()
    rem = pos % ALIGN
    if rem:
        fh.write(b"\x00" * (ALIGN - rem))


def _crash_counts(edges: gpd.GeoDataFrame, profile: str) -> np.ndarray:
    """Count unique profile-relevant crashes assigned to each edge."""
    crashes = gpd.read_file(PROCESSED / "active_crashes.geojson")
    assigned = assign_relevant_crashes(crashes, edges, profile=profile)
    counts = np.bincount(assigned["edge_id"].to_numpy(), minlength=len(edges)).astype(np.int64)
    print(f"[{profile}] assigned {len(assigned)} unique relevant crashes onto "
          f"{int((counts > 0).sum())} edges (max {counts.max()} on one edge)")
    return np.clip(counts, 0, 65535).astype("<u2")


def export(profile: str) -> dict:
    APPDATA.mkdir(parents=True, exist_ok=True)
    out_path = APPDATA / f"{profile}.graph"

    nodes = pd.read_parquet(GRAPH / f"{profile}_nodes.parquet", columns=["x", "y"])
    node_lon = np.ascontiguousarray(nodes["x"].to_numpy(), dtype="<f8")
    node_lat = np.ascontiguousarray(nodes["y"].to_numpy(), dtype="<f8")
    n_nodes = len(node_lon)

    edges = gpd.read_parquet(GRAPH / f"{profile}_edges.parquet")
    overlay_path = GRAPH / f"{profile}_risk_v1.csv"
    if overlay_path.exists():
        overlay = pd.read_csv(overlay_path)
        edge_ids = overlay["edge_id"].to_numpy(np.int64)
        edges["risk"] = 0.0
        edges["risk_dark"] = 0.0
        edges.loc[edge_ids, "risk"] = overlay["risk"].to_numpy()
        edges.loc[edge_ids, "risk_dark"] = overlay["risk_dark"].to_numpy()
        print(f"[{profile}] applied {overlay_path.name} ({len(overlay)} non-zero edges)")
    n_edges = len(edges)
    print(f"[{profile}] {n_nodes} nodes, {n_edges} edges")

    u = edges["u"].to_numpy()
    v = edges["v"].to_numpy()
    if u.min() < 0 or u.max() >= n_nodes or v.min() < 0 or v.max() >= n_nodes:
        raise ValueError(f"[{profile}] edge endpoint index out of range")

    # ---- geometry: flat coordinate array + per-edge offset/count ----
    geoms = edges.geometry.values
    if shapely.is_missing(geoms).any():
        raise ValueError(f"[{profile}] missing geometry")
    bad = shapely.get_type_id(geoms) != 1  # 1 == LineString
    if bad.any():
        raise ValueError(f"[{profile}] {int(bad.sum())} non-LineString geometries")

    coords, geom_index = shapely.get_coordinates(geoms, return_index=True)
    n_coords = len(coords)
    counts = np.bincount(geom_index, minlength=n_edges)
    if counts.min() < 2:
        raise ValueError(f"[{profile}] edge geometry with < 2 points")
    offsets = np.empty(n_edges, dtype=np.int64)
    offsets[0] = 0
    np.cumsum(counts[:-1], out=offsets[1:])

    # ---- orient each LineString from node u to node v ----
    first = coords[offsets]
    last = coords[offsets + counts - 1]
    ux, uy = node_lon[u], node_lat[u]
    vx, vy = node_lon[v], node_lat[v]

    def d2(pts, px, py):
        dx = pts[:, 0] - px
        dy = pts[:, 1] - py
        return dx * dx + dy * dy

    forward = d2(first, ux, uy) + d2(last, vx, vy)
    reverse = d2(first, vx, vy) + d2(last, ux, uy)
    need_rev = reverse < forward
    print(f"[{profile}] reversing {int(need_rev.sum())} edge geometries to run u -> v")

    if need_rev.any():
        pos = np.arange(n_coords, dtype=np.int64)
        base = offsets[geom_index]
        within = pos - base
        mirrored = base + counts[geom_index] - 1 - within
        gather = np.where(need_rev[geom_index], mirrored, pos)
        coords = coords[gather]

    geom_lon = np.ascontiguousarray(coords[:, 0], dtype="<f4")
    geom_lat = np.ascontiguousarray(coords[:, 1], dtype="<f4")

    # ---- edge records ----
    rec = np.zeros(n_edges, dtype=EDGE_DTYPE)
    rec["u"] = u
    rec["v"] = v
    rec["length"] = edges["length_m"].to_numpy()
    rec["risk"] = edges["risk"].to_numpy()
    rec["riskDark"] = edges["risk_dark"].to_numpy()
    rec["crashCount"] = _crash_counts(edges, profile)
    rec["schoolZone"] = edges["school_zone"].to_numpy().astype(np.uint8)
    rec["pad"] = 0
    rec["geomOffset"] = offsets
    rec["geomCount"] = counts

    # ---- write ----
    with open(out_path, "wb") as fh:
        fh.write(MAGIC)
        fh.write(struct.pack("<IIIQ8x", VERSION, n_nodes, n_edges, n_coords))
        assert fh.tell() == HEADER_SIZE
        for arr in (node_lon, node_lat, rec, geom_lon, geom_lat):
            _pad_to_align(fh)
            arr.tofile(fh)

    size = out_path.stat().st_size
    print(f"[{profile}] wrote {out_path} ({size / 1e6:.1f} MB, {n_coords} geometry points)")
    return {"profile": profile, "nodes": n_nodes, "edges": n_edges,
            "coords": n_coords, "bytes": size}


# --------------------------------------------------------------------------
# self-check: re-read the file from scratch, independent of the writer's arrays
# --------------------------------------------------------------------------

def verify(profile: str, seed: int = 0) -> bool:
    path = APPDATA / f"{profile}.graph"
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok = ok and bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  [{profile}] {name}{(' -- ' + detail) if detail else ''}")

    raw = np.memmap(path, dtype=np.uint8, mode="r")
    magic, version, n_nodes, n_edges, n_coords = struct.unpack("<4sIIIQ", bytes(raw[:24]))
    reserved = bytes(raw[24:32])

    nodes = pd.read_parquet(GRAPH / f"{profile}_nodes.parquet", columns=["x", "y"])
    edges = pd.read_parquet(
        GRAPH / f"{profile}_edges.parquet",
        columns=["u", "v", "length_m", "risk", "risk_dark", "school_zone"],
    )

    check("magic/version", magic == MAGIC and version == VERSION, f"{magic!r} v{version}")
    check("reserved zero", reserved == b"\x00" * 8)
    check("counts match parquet",
          n_nodes == len(nodes) and n_edges == len(edges),
          f"nodes={n_nodes} edges={n_edges} coords={n_coords}")

    def align(off):
        return off + (-off % ALIGN)

    off = align(HEADER_SIZE)
    lon_off = off
    off = align(off + 8 * n_nodes)
    lat_off = off
    off = align(off + 8 * n_nodes)
    edge_off = off
    off = align(off + 32 * n_edges)
    glon_off = off
    off = align(off + 4 * n_coords)
    glat_off = off
    end = glat_off + 4 * n_coords
    check("file size matches layout", raw.nbytes == end, f"{raw.nbytes} vs {end}")

    node_lon = np.frombuffer(raw, dtype="<f8", count=n_nodes, offset=lon_off)
    node_lat = np.frombuffer(raw, dtype="<f8", count=n_nodes, offset=lat_off)
    rec = np.frombuffer(raw, dtype=EDGE_DTYPE, count=n_edges, offset=edge_off)
    glon = np.frombuffer(raw, dtype="<f4", count=n_coords, offset=glon_off)
    glat = np.frombuffer(raw, dtype="<f4", count=n_coords, offset=glat_off)

    px, py = nodes["x"].to_numpy(), nodes["y"].to_numpy()
    for label, i in (("node 0", 0), (f"node {n_nodes - 1}", n_nodes - 1)):
        good = node_lon[i] == px[i] and node_lat[i] == py[i]
        check(f"{label} coords", good, f"({node_lon[i]:.7f}, {node_lat[i]:.7f})")

    rng = np.random.default_rng(seed)
    sample = rng.choice(n_edges, size=5, replace=False)
    eu, ev = edges["u"].to_numpy(), edges["v"].to_numpy()
    elen = edges["length_m"].to_numpy()
    erisk = edges["risk"].to_numpy()
    for i in sample:
        good = (
            rec["u"][i] == eu[i]
            and rec["v"][i] == ev[i]
            and np.float32(elen[i]) == rec["length"][i]
            and np.float32(erisk[i]) == rec["risk"][i]
        )
        check(f"edge {i} u/v/length/risk", good,
              f"u={rec['u'][i]} v={rec['v'][i]} len={rec['length'][i]:.3f} risk={rec['risk'][i]:.4f}")

    geom_end = rec["geomOffset"].astype(np.int64) + rec["geomCount"].astype(np.int64)
    check("all geomOffset+geomCount <= coordCount",
          geom_end.max() <= n_coords and rec["geomCount"].min() >= 2,
          f"max end={geom_end.max()} of {n_coords}, min count={rec['geomCount'].min()}")
    check("edge records 32 bytes / pad zero", rec["pad"].max() == 0 and rec.dtype.itemsize == 32)
    check("schoolZone matches parquet",
          np.array_equal(rec["schoolZone"].astype(bool), edges["school_zone"].to_numpy()))

    worst = 0.0
    for i in sample:
        o = int(rec["geomOffset"][i])
        d = max(abs(float(glon[o]) - px[rec["u"][i]]), abs(float(glat[o]) - py[rec["u"][i]]))
        worst = max(worst, d)
    check("first geom point within 1e-4 deg of node u", worst < 1e-4, f"max delta {worst:.2e} deg")

    del raw
    return ok


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    profiles = ["walking", "cycling"] if which == "both" else [which]

    APPDATA.mkdir(parents=True, exist_ok=True)
    for name in COMPANIONS:
        shutil.copyfile(PROCESSED / name, APPDATA / name)
        print(f"copied {name} -> {APPDATA / name}")

    stats = [export(p) for p in profiles]

    print("\n--- self-check ---")
    all_ok = True
    for s in stats:
        all_ok &= verify(s["profile"])
    print("\nsummary:")
    for s in stats:
        print(f"  {s['profile']}: nodes={s['nodes']} edges={s['edges']} "
              f"coords={s['coords']} size={s['bytes']} bytes ({s['bytes'] / 1e6:.1f} MB)")
    print("SELF-CHECK: " + ("ALL PASS" if all_ok else "FAILURES PRESENT"))
    sys.exit(0 if all_ok else 1)
