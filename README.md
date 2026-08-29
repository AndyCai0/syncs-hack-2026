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
- Routing track 1 (live): OpenRouteService with risk-clustered `avoid_polygons`
- Routing track 2 (planned): self-built osmnx graph with continuous risk weights `length × (1 + k·risk)`

## Getting started

```bash
# 1. Backend deps (Python 3.11+)
python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt

# 2. Data pipeline (downloads already in data/processed/ if committed; else see scripts/)
.venv/bin/python scripts/prepare_data.py

# 3. ORS key (free): https://openrouteservice.org/dev/#/signup
cp backend/.env.example backend/.env   # then paste ORS_API_KEY=...

# 4. Run backend
.venv/bin/uvicorn app.main:app --app-dir backend --port 8000 --reload

# 5. Run frontend (Node 20+)
cd frontend && npm install && npm run dev   # http://localhost:5173
```

Data sources (all CC BY 4.0, cite in Devpost): TfNSW Road Crash Data 2020–2024, TfNSW Speed/School Zones, NSW Public Schools Master Dataset, © OpenStreetMap contributors.

## Hackathon notes

- Submit on Devpost (early and often — resubmitting is encouraged)
- GitHub repo must be linked in the submission; version history is monitored
- Preliminary judging: 3-minute video · Final judging: 4-minute live pitch + Q&A
- Hacking ends **Sunday 12:00pm**; final pitches 2:30–4:15pm, awards 4:30pm
