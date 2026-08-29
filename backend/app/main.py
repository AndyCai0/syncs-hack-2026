"""SafeRoutes backend: fastest-vs-safest walking/cycling routes for Sydney.

MVP routing track: OpenRouteService directions with `avoid_polygons` built from
clustered high-risk pedestrian/cyclist crash sites (TfNSW 2020-2024, CC BY).
Requires ORS_API_KEY in backend/.env (free key from openrouteservice.org).
"""
import json
import os
from pathlib import Path

import geopandas as gpd
import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from shapely.geometry import LineString, box, mapping
from shapely.ops import unary_union

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

ROOT = Path(__file__).resolve().parent.parent.parent
PROCESSED = ROOT / "data" / "processed"
ORS_KEY = os.getenv("ORS_API_KEY", "")
ORS_BASE = "https://api.openrouteservice.org/v2/directions"

# Metric CRS for buffering (GDA2020 / MGA zone 56 covers Sydney)
METRIC = "EPSG:7856"

app = FastAPI(title="SafeRoutes API")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)

crashes: gpd.GeoDataFrame | None = None
crashes_m: gpd.GeoDataFrame | None = None  # projected copy for metric ops
schools_geojson: dict = {}
zones_geojson: dict = {}


@app.on_event("startup")
def load_data() -> None:
    global crashes, crashes_m, schools_geojson, zones_geojson
    crashes = gpd.read_file(PROCESSED / "active_crashes.geojson")
    crashes_m = crashes.to_crs(METRIC)
    schools_geojson = json.loads((PROCESSED / "schools.geojson").read_text())
    zones_geojson = json.loads((PROCESSED / "school_zones.geojson").read_text())
    print(f"loaded {len(crashes)} active-transport crashes")


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "crashes": 0 if crashes is None else len(crashes), "ors_key": bool(ORS_KEY)}


@app.get("/api/hotspots")
def hotspots() -> dict:
    """All Sydney ped/bike crash points (frontend renders heat/cluster layer)."""
    return json.loads(crashes.to_json())


@app.get("/api/schools")
def schools() -> dict:
    return schools_geojson


@app.get("/api/school_zones")
def school_zones() -> dict:
    return zones_geojson


@app.get("/api/geocode")
async def geocode(q: str = Query(..., min_length=2)) -> dict:
    """Proxy to Photon (komoot) biased to Sydney; no API key needed."""
    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.get(
            "https://photon.komoot.io/api",
            params={"q": q, "lat": -33.87, "lon": 151.05, "limit": 6, "lang": "en"},
            headers={"User-Agent": "SafeRoutesSydney/0.1 (SYNCS Hack 2026)"},
        )
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"geocoder error {r.status_code}")
    return r.json()


class RouteReq(BaseModel):
    start: list[float]  # [lon, lat]
    end: list[float]
    profile: str = "foot-walking"  # or cycling-regular
    safety: float = 0.6  # 0 = fastest only, 1 = avoid everything avoidable
    after_dark: bool = False


def corridor_crashes(start: list[float], end: list[float], after_dark: bool) -> gpd.GeoDataFrame:
    pad = 0.02  # ~2 km
    bbox = box(
        min(start[0], end[0]) - pad, min(start[1], end[1]) - pad,
        max(start[0], end[0]) + pad, max(start[1], end[1]) + pad,
    )
    sel = crashes[crashes.intersects(bbox)]
    if after_dark:
        dark = sel["natural_lighting"].astype(str).str.contains("Dark|Dusk|Dawn", case=False, na=False)
        sel = sel.copy()
        sel.loc[dark, "risk"] = sel.loc[dark, "risk"] * 1.5
    return sel


def build_avoid_polygons(sel: gpd.GeoDataFrame, safety: float, max_polys: int = 12):
    """Cluster corridor crashes into avoid polygons, worst clusters first.

    ORS free tier rejects huge avoid geometries, so buffers are tight (35 m)
    and we cap the polygon count; `safety` scales how many clusters we avoid.
    """
    if sel.empty or safety <= 0:
        return None, []
    m = sel.to_crs(METRIC)
    merged = unary_union(list(m.geometry.buffer(35)))
    polys = list(merged.geoms) if merged.geom_type == "MultiPolygon" else [merged]
    scored = []
    for p in polys:
        inside = m[m.within(p)]
        scored.append((float(inside["risk"].sum()), p))
    scored.sort(key=lambda t: -t[0])
    # risk threshold falls as safety rises -> more clusters avoided
    threshold = 20.0 * (1.0 - safety) + 6.0
    chosen = [p for s, p in scored[: max_polys] if s >= threshold]
    if not chosen:
        return None, []
    chosen_wgs = gpd.GeoSeries(chosen, crs=METRIC).to_crs("EPSG:4326")
    multi = unary_union(list(chosen_wgs))
    if multi.geom_type == "Polygon":
        geom = {"type": "Polygon", "coordinates": mapping(multi)["coordinates"]}
    else:
        geom = mapping(multi)
    return geom, [mapping(g) for g in chosen_wgs]


async def ors_route(req: RouteReq, avoid_geom: dict | None) -> dict:
    body: dict = {
        "coordinates": [req.start, req.end],
        "instructions": False,
        "elevation": False,
    }
    if avoid_geom:
        body["options"] = {"avoid_polygons": avoid_geom}
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(
            f"{ORS_BASE}/{req.profile}/geojson",
            json=body,
            headers={"Authorization": ORS_KEY, "Content-Type": "application/json"},
        )
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"ORS error {r.status_code}: {r.text[:300]}")
    return r.json()


def route_stats(route_geojson: dict) -> dict:
    feat = route_geojson["features"][0]
    line = LineString(feat["geometry"]["coordinates"])
    line_m = gpd.GeoSeries([line], crs="EPSG:4326").to_crs(METRIC).iloc[0]
    near = crashes_m[crashes_m.distance(line_m) <= 30]
    summary = feat["properties"].get("summary", {})
    return {
        "distance_m": summary.get("distance"),
        "duration_s": summary.get("duration"),
        "crashes_within_30m": int(len(near)),
        "risk_score": round(float(near["risk"].sum()), 1),
        "fatal_nearby": int((near["degree_of_crash"] == "Fatal").sum()),
        "crash_points": json.loads(crashes[crashes.index.isin(near.index)].to_json()),
    }


@app.post("/api/route")
async def route(req: RouteReq) -> dict:
    if not ORS_KEY:
        raise HTTPException(status_code=503, detail="ORS_API_KEY not configured in backend/.env")
    sel = corridor_crashes(req.start, req.end, req.after_dark)
    avoid_geom, avoid_polys = build_avoid_polygons(sel, req.safety)
    fastest = await ors_route(req, None)
    safest = await ors_route(req, avoid_geom) if avoid_geom else fastest
    return {
        "fastest": {"route": fastest, "stats": route_stats(fastest)},
        "safest": {"route": safest, "stats": route_stats(safest)},
        "avoided_polygons": {"type": "FeatureCollection", "features": [
            {"type": "Feature", "geometry": g, "properties": {}} for g in avoid_polys
        ]},
        "corridor_crash_count": int(len(sel)),
    }
