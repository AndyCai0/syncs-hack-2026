# SafeRoutes binary graph format (SRG1)

One file per profile: `data/appdata/walking.graph`, `data/appdata/cycling.graph`.
Exported by `scripts/export_binary_graph.py` from `data/graph/{profile}_{nodes,edges}.parquet`;
consumed by `SafeRoutesMac/Sources/SafeRoutesEngine/GraphStore.swift`.

All values little-endian. Arrays are laid out back-to-back in the order below,
each array starting at the next 8-byte-aligned offset after the previous one.

## Header (32 bytes)

| offset | type   | field     | value |
|--------|--------|-----------|-------|
| 0      | 4×UInt8| magic     | ASCII "SRG1" |
| 4      | UInt32 | version   | 1 |
| 8      | UInt32 | nodeCount | N |
| 12     | UInt32 | edgeCount | E |
| 16     | UInt64 | coordCount| C (total geometry points across all edges) |
| 24     | 8×UInt8| reserved  | zeros |

## Arrays (in file order, each 8-byte aligned)

1. `nodeLon`: N × Float64 (WGS84 longitude)
2. `nodeLat`: N × Float64
3. `edges`:   E × EdgeRecord (32 bytes each, layout below)
4. `geomLon`: C × Float32
5. `geomLat`: C × Float32

## EdgeRecord (32 bytes)

| offset | type    | field      | notes |
|--------|---------|------------|-------|
| 0      | UInt32  | u          | node index (0-based, < N) |
| 4      | UInt32  | v          | node index |
| 8      | Float32 | length     | metres (precomputed in EPSG:7856; use this, never recompute from coords) |
| 12     | Float32 | risk       | summed severity-weighted crash risk snapped to this edge |
| 16     | Float32 | riskDark   | same but night-time crashes weighted ×1.5 |
| 20     | UInt16  | crashCount | number of crashes snapped to this edge (display stat) |
| 22     | UInt8   | schoolZone | 1 if edge intersects a 40 km/h school zone |
| 23     | UInt8   | pad        | 0 |
| 24     | UInt32  | geomOffset | index of this edge's first point in geomLon/geomLat |
| 28     | UInt32  | geomCount  | number of points (≥2); oriented from node u to node v |

## Semantics

- Graph is **undirected**: each EdgeRecord represents travel in both directions.
- Cost model (must match backend/app/graph_router.py):
  `cost = length * (1 + k * (risk_or_riskDark / max(length, 5) * 100) / 10)`, then `*0.9` if schoolZone.
  `k = safety_slider(0..1) * 4.0`. `k = 0` gives the fastest (shortest) path.
- Speeds for duration: walking 4.8 km/h, cycling 15 km/h.
- Geometry is display-only (Float32 ≈ 1 m precision is fine); lengths/risks carry the math.

## Companion files in data/appdata/

- `active_crashes.geojson`, `schools.geojson`, `school_zones.geojson` — copied verbatim
  from data/processed/ for the map layers.
