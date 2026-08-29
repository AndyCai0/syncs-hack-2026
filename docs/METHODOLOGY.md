# Methodology

## Scope

The public MVP compares historical-hazard-aware **walking** routes for school journeys inside the committed Greater Sydney graph. It uses reported pedestrian crashes from 2020–2024. It does not estimate a person's future crash probability and does not certify a route as safe.

- Model identifier: `hack-2026-v1`
- Data period returned by the API: `2020-2024`

## Incident preparation

Each unique crash ID is considered once for walking only when the traffic-unit data marks that crash as pedestrian-involved and the crash year is 2020–2024. The base severity weights are:

| Reported severity | Weight |
| --- | ---: |
| Fatal | 10 |
| Serious injury | 5 |
| Moderate injury | 3 |
| Minor/other injury | 2 |
| Non-casualty towaway | 1 |

A crash recorded on a road with a speed limit of at least 60 km/h receives a 1.3 multiplier. In after-dark mode, incidents whose recorded natural lighting contains darkness, dusk or dawn receive a further 1.5 multiplier. These are transparent hackathon heuristics, not calibrated causal estimates.

## Deterministic crash-to-edge assignment

Risk construction projects incidents and OSM edges to GDA2020 / MGA Zone 56 (`EPSG:7856`). Each incident is assigned to a nearest graph edge only when the edge is within 40 metres. If the spatial join returns equal nearest edges, the implementation sorts by crash ID, snap distance and zero-based edge ID, then keeps the lowest edge ID. This prevents one crash from being accidentally counted multiple times.

The committed `walking_risk_v1.csv` is a small risk overlay keyed by edge ID. It replaces the legacy mixed walking/cycling risk columns at runtime without rewriting the large committed Parquet graph.

## Route cost and displayed index

For an edge with length `L` metres and effective day or after-dark edge risk `R`:

```text
risk_per_100m = R / max(L, 5) * 100
cost = L * (1 + k * risk_per_100m / 10)
k = 4 * historical_hazard_preference
```

The fastest baseline uses `k = 0`. Low, Balanced and High are preference controls, not percentages of safety. A small bounded set of preference strengths is evaluated so the live demo does not run an excessive number of full-Sydney Dijkstra searches.

The displayed Historical Hazard Exposure Index is the sum of the same effective edge-risk values used to choose that route. After-dark routing and the displayed index both use the after-dark values. The index has no probability unit and is only comparable within this model/data snapshot.

SciPy sparse matrices sum duplicate `(u, v)` entries. Because OSM can contain parallel edges, the router first groups every undirected node pair and dynamically selects the minimum-cost edge for the current weighting, using edge ID as a deterministic tie-break. Path geometry, distance and index all use that selected edge.

## Detour constraint

The fastest route is computed first. Risk-weighted candidates qualify only when:

- their duration is no more than 1.25 times the fastest-route duration; and
- their Historical Hazard Exposure Index is strictly lower.

The qualifying candidate with the lowest index is returned, with duration as the tie-break. If none qualifies, the API returns the fastest route in both slots and the reason `no_reasonable_lower_hazard_alternative`. It never claims a reduction for an equal or higher index.

## Separate nearby-incident statistic

“Reported pedestrian incidents within 30 m of route” counts unique pedestrian crash IDs within a 30-metre projected buffer of the displayed route. It is descriptive only. It is deliberately separate from the edge-based index because a nearby crash may be on another carriageway, crossing or path.

## School zones

School-zone polygons and their source operating-time fields are retained for map explanation. The graph stores only an intersection boolean, so the earlier unconditional 10% discount has been removed. Time-aware school-zone routing is future work.

## Known limitations

- Reported crash data can omit unreported incidents and can reflect reporting, exposure and road-use patterns rather than intrinsic route danger alone.
- Crash coordinates are mapped to the nearest graph edge, not verified footpaths, crossings or carriageways.
- OSM completeness and the undirected walking representation can vary. The model does not yet encode crossing quality, footpath condition, stairs, slope, lighting quality, accessibility, construction or live closures.
- School coordinates are approximate destinations from a master dataset, not manually verified pedestrian gates.
- A zero index means no assigned model incidents on those selected edges; it does not mean zero real-world risk.
- School-zone operating times are not used in routing.
- After-dark weighting uses the crash record's natural-lighting category; it is not a live sunrise, lighting or weather model.
- Address search and online map tiles are convenience services and may be unavailable. Deterministic coordinates and local routing remain usable.

Always follow current signs, crossings and road conditions.
