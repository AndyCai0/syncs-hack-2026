# Demo guide

## Start from a clean checkout

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements-dev.txt
npm --prefix frontend ci
./scripts/dev.sh
```

Open <http://127.0.0.1:5173>. No `ORS_API_KEY` is needed. Before presenting, verify the local API in another terminal:

```bash
.venv/bin/python scripts/smoke_test.py
```

## Verified deterministic cases

Metrics below were regenerated from the committed walking graph and pedestrian-only `hack-2026-v1` overlay on 29 August 2026. Destinations are approximate school points, not verified entrances.

| Case | Start `[lon, lat]` | End `[lon, lat]` | Fastest | Lower-hazard | Detour |
| --- | --- | --- | --- | --- | ---: |
| Alexandria Park Community School | `[151.210284, -33.912690]` | `[151.196518, -33.901164]` | 2,313.2 m, 1,735 s, index 5.0, 4 nearby incidents | 2,391.4 m, 1,794 s, index 0.0, 4 nearby incidents | 1.034× |
| Allambie Heights Public School | `[151.267673, -33.781632]` | `[151.249208, -33.766150]` | 2,945.0 m, 2,209 s, index 3.9, 5 nearby incidents | 3,092.5 m, 2,319 s, index 0.0, 2 nearby incidents | 1.050× |
| Annandale North Public School | `[151.158606, -33.878190]` | `[151.171835, -33.877905]` | 2,315.3 m, 1,737 s, index 3.9, 3 nearby incidents | 2,343.2 m, 1,757 s, index 0.0, 0 nearby incidents | 1.012× |

The zeroes mean no pedestrian incidents from this model snapshot were assigned to the alternative's selected edges. They do not mean the routes have zero real-world risk.

## Measured route latency

Measured on the current Apple-silicon development host through the real FastAPI endpoint on 29 August 2026:

- First route after backend startup, including walking-profile load: 2,551.5 ms (Alexandria case).
- Warm Alexandria request: 942.4 ms.
- Warm Allambie Heights request: 946.8 ms.
- Warm Annandale request: 943.3 ms.

These figures are evidence for this machine and graph snapshot, not a cross-device performance guarantee. Expect the first request to be slower.

## 90–120 second live sequence

1. **0–15 s:** State the scope: “This compares walking routes for Sydney school journeys using reported pedestrian crash history. It does not claim an objectively safest route.”
2. **15–35 s:** Click **Alexandria Park Community School** under “Try a verified demo route.” Point out that the coordinates bypass place search.
3. **35–65 s:** Compare the dashed fastest route and solid lower-hazard route. Read the added time and distance, then distinguish the edge-based Historical Hazard Exposure Index from the separate 30-metre nearby-incident count.
4. **65–85 s:** Point to the 25% duration cap and explain that the example detour is only about 3.4%. Toggle after-dark if desired and explain that recorded dark incidents receive extra weight; do not claim live night safety.
5. **85–105 s:** Show the school-zone layer and explain that it is display-only because operating times are not yet modelled in route cost.
6. **105–120 s:** Close with the limitation statement and the reproducibility point: committed graph, deterministic cases, local API, no ORS key.

## Network fallback

If Photon place search fails, use a verified Demo Case button. If the online basemap fails, keep the page open: route computation and coordinates still work, and the dashed/solid routes can reappear when tiles recover. Keep screenshots or a short recording of the same verified cases as a presentation fallback.

If a route request itself fails, run:

```bash
curl -s http://127.0.0.1:8000/api/health
.venv/bin/python scripts/smoke_test.py
```

Expected health fields include `"ok": true` and `"local_walking_graph": true`.
