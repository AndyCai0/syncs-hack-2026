# SYNCS Hack 2026 — SafeRoutes Sydney

Theme: **Blocks that make up the world**

## Team

- Andy ([@AndyCai0](https://github.com/AndyCai0))
- <!-- teammates: add yourselves here -->

## Public MVP

SafeRoutes Sydney compares two **walking** routes for school journeys in Greater Sydney:

- the fastest route on the committed OpenStreetMap walking graph; and
- a route with lower exposure to reported NSW pedestrian crashes from 2020–2024, capped at 25% additional travel time.

The Historical Hazard Exposure Index is a transparent routing heuristic, not an accident probability or a guarantee of safety. School zones are shown as an explanatory map layer; they do not receive an unconditional routing discount. Cycling code remains experimental and is not part of the public demo.

The web demo includes a FastAPI API, React/MapLibre interface, three deterministic school cases, pedestrian crash and school layers, after-dark weighting, input/snap validation, and a local SciPy Dijkstra router. The committed local walking graph is the default engine, so `ORS_API_KEY` is not required.

## Quick start

Requirements: Python 3.11+ and Node.js 20+.

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements-dev.txt
npm --prefix frontend ci
./scripts/dev.sh
```

Open <http://127.0.0.1:5173> and select one of the verified demo routes. Address search and the OpenStreetMap basemap require internet access, but the demo buttons and local route computation do not depend on geocoding.

To verify an already-running backend:

```bash
.venv/bin/python scripts/smoke_test.py
```

## Checks

```bash
.venv/bin/python -m compileall backend scripts
.venv/bin/pytest
npm --prefix frontend run lint
npm --prefix frontend run build
```

## Data and graph rebuilds

The processed data and local graph needed for the demo are committed. Rebuilding them is optional and uses separate data-pipeline dependencies:

```bash
.venv/bin/pip install -r backend/requirements-data.txt
.venv/bin/python scripts/prepare_data.py
.venv/bin/python scripts/build_graph.py
.venv/bin/python scripts/build_risk_overlay.py walking
.venv/bin/python scripts/find_demo_cases.py
```

Do not casually regenerate the committed data during normal application work. See [Methodology](docs/METHODOLOGY.md), [Data Sources](docs/DATA_SOURCES.md), and [Demo Guide](docs/DEMO.md) before changing the model or source snapshots.

## macOS native app

`SafeRoutesMac/` contains a SwiftUI/MapKit client and native mmap-backed SRG1 routing engine. The generated `data/appdata/*.graph` files exceed GitHub's file limit and are intentionally not committed. Build them locally from the committed Parquet graphs before launching the native router:

```bash
.venv/bin/python scripts/export_binary_graph.py
swift build --package-path SafeRoutesMac
```

For the full app and XCTest suite, open `SafeRoutesMac/Package.swift` in a compatible full Xcode installation. The native public UI follows the same walking-only, no-unsupported-claims scope. Binary details are in [SafeRoutesMac/GRAPH_FORMAT.md](SafeRoutesMac/GRAPH_FORMAT.md).

## Method boundary

Based on reported NSW pedestrian crashes from 2020–2024. This index is not a prediction or guarantee of safety. Always follow current signs, crossings and road conditions.

## Repository decisions before submission

- Teammates must replace the team-list placeholder above; names have not been invented.
- The repository owner must choose and approve a code licence. No code licence has been added on a teammate's behalf.

Dataset and map licences are independent of the future code licence; see [Data Sources](docs/DATA_SOURCES.md).
