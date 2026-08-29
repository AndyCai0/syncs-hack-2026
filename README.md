# SYNCS Hack 2026

Theme: **Blocks that make up the world**

## Team

- Andy (@AndyCai0)
- <!-- teammates: add yourselves here -->

## Project

**SafeRoutes Sydney** — fastest vs safest walking & cycling routes for kids and the elderly, computed from 5 years of real NSW crash data (TfNSW Road Crash Data 2020–2024, 92k crashes, 12k pedestrian/cyclist-involved in Greater Sydney).

- Crash hotspot heatmap + per-crash detail popups (severity, time of day, lighting)
- 40 km/h school zone polygons + all Sydney public schools
- "Fastest vs safest" route comparison with a safety-priority slider and an after-dark mode
- Routing engine (default): self-built Sydney OSM graph (2.2M edges) with per-edge crash risk — cost = `length × (1 + k·risk_density)`, school-zone discount, after-dark risk column. Scipy dijkstra, ~1s per route, fully offline.
- Routing engine (fallback): OpenRouteService with risk-clustered `avoid_polygons` (needs free ORS key)

## Getting started

```bash
# 1. Backend deps (Python 3.11+)
python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt

# 2. Data pipeline (downloads already in data/processed/ if committed; else see scripts/)
.venv/bin/python scripts/prepare_data.py

# 3. ORS key (free): https://openrouteservice.org/dev/#/signup
cp backend/.env.example backend/.env   # then paste ORS_API_KEY=...

# 4. Local routing graph (~10 min one-off; needs osmium: conda install -c conda-forge osmium-tool)
curl -L -o data/raw/australia-latest.osm.pbf https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf
osmium extract -b 150.5,-34.35,151.65,-33.35 data/raw/australia-latest.osm.pbf -o data/raw/sydney.osm.pbf
.venv/bin/python scripts/build_graph.py     # writes data/graph/*.parquet (~200 MB, not in git)

# 5. Run backend
.venv/bin/uvicorn app.main:app --app-dir backend --port 8000 --reload

# 6. Run frontend (Node 20+)
cd frontend && npm install && npm run dev   # http://localhost:5173
```

## macOS native app (SafeRoutesMac/)

Fully offline SwiftUI app — the routing graph is bundled binary data, no Python, no network, no API keys. Requires macOS 14+.

```bash
# one-off: export binary graphs (10 s, needs data/graph/ parquets from step 4)
.venv/bin/python scripts/export_binary_graph.py

# build & test (or just open SafeRoutesMac/Package.swift in Xcode and hit Run)
cd SafeRoutesMac && xcodebuild -scheme SafeRoutesMac test
```

Engine: mmap'd SRG1 binary graph (spec in SafeRoutesMac/GRAPH_FORMAT.md), CSR adjacency, binary-heap Dijkstra — loads Sydney (2.2M edges) in ~2.5 s, routes a fastest+safest pair in <0.1 s. UI: NavigationSplitView + MapKit, MKLocalSearchCompleter address search, zoom-gated crash/school/zone layers.

Data sources (all CC BY 4.0, cite in Devpost): TfNSW Road Crash Data 2020–2024, TfNSW Speed/School Zones, NSW Public Schools Master Dataset, © OpenStreetMap contributors.

## Hackathon notes

- Submit on Devpost (early and often — resubmitting is encouraged)
- GitHub repo must be linked in the submission; version history is monitored
- Preliminary judging: 3-minute video · Final judging: 4-minute live pitch + Q&A
- Hacking ends **Sunday 12:00pm**; final pitches 2:30–4:15pm, awards 4:30pm
