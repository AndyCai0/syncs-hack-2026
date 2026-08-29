"""Historical-hazard-aware walking routes for Sydney school journeys."""
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Literal

import geopandas as gpd
import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel, Field, field_validator
from shapely.geometry import LineString, box, mapping
from shapely.ops import unary_union

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

ROOT = Path(__file__).resolve().parent.parent.parent
PROCESSED = ROOT / "data" / "processed"
DEMO_CASES = ROOT / "data" / "demo_cases.json"
ORS_KEY = os.getenv("ORS_API_KEY", "")
ORS_BASE = "https://api.openrouteservice.org/v2/directions"

# Metric CRS for buffering (GDA2020 / MGA zone 56 covers Sydney)
METRIC = "EPSG:7856"

crashes: gpd.GeoDataFrame | None = None
crashes_m: gpd.GeoDataFrame | None = None  # projected copy for metric ops
schools_geojson: dict = {}
zones_geojson: dict = {}


def load_data() -> None:
    global crashes, crashes_m, schools_geojson, zones_geojson
    source = gpd.read_file(PROCESSED / "active_crashes.geojson")
    crashes = source[
        source["year_of_crash"].between(2020, 2024)
        & source["has_pedestrian"].fillna(False).astype(bool)
    ].copy()
    crashes_m = crashes.to_crs(METRIC)
    schools_geojson = json.loads((PROCESSED / "schools.geojson").read_text())
    zones_geojson = json.loads((PROCESSED / "school_zones.geojson").read_text())
    print(f"loaded {len(crashes)} reported pedestrian crashes from 2020-2024")


@asynccontextmanager
async def lifespan(_: FastAPI):
    load_data()
    yield


app = FastAPI(title="SafeRoutes API", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)
app.add_middleware(GZipMiddleware, minimum_size=1_000)


@app.get("/api/health")
def health() -> dict:
    from . import graph_router

    return {
        "ok": True,
        "pedestrian_incidents": 0 if crashes is None else len(crashes),
        "crashes": 0 if crashes is None else len(crashes),
        "local_walking_graph": graph_router.available(),
        "ors_key": bool(ORS_KEY),
    }


@app.get("/api/demo_cases")
def demo_cases() -> list[dict]:
    return json.loads(DEMO_CASES.read_text(encoding="utf-8"))


@app.get("/api/hotspots")
def hotspots() -> dict:
    """Reported Sydney pedestrian crash points for the public walking demo."""
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


Coordinate = Annotated[list[float], Field(min_length=2, max_length=2)]
SYDNEY_BOUNDS = (150.50, -34.35, 151.65, -33.30)


class RouteReq(BaseModel):
    start: Coordinate  # [lon, lat]
    end: Coordinate
    profile: Literal["foot-walking"] = "foot-walking"
    safety: float = Field(default=0.6, ge=0, le=1)
    after_dark: bool = False
    engine: Literal["auto", "local", "ors"] = "auto"

    @field_validator("start", "end")
    @classmethod
    def validate_sydney_coordinate(cls, coordinate: list[float]) -> list[float]:
        lon, lat = coordinate
        if not (-180 <= lon <= 180 and -90 <= lat <= 90):
            raise ValueError("coordinate must be valid [longitude, latitude]")
        min_lon, min_lat, max_lon, max_lat = SYDNEY_BOUNDS
        if not (min_lon <= lon <= max_lon and min_lat <= lat <= max_lat):
            raise ValueError("coordinate is outside the Greater Sydney demo coverage")
        return coordinate


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


def route_stats(
    route_geojson: dict,
    *,
    crash_frame: gpd.GeoDataFrame | None = None,
) -> dict:
    """Describe one route without treating nearby incidents as a probability."""

    feat = route_geojson["features"][0]
    line = LineString(feat["geometry"]["coordinates"])
    line_m = gpd.GeoSeries([line], crs="EPSG:4326").to_crs(METRIC).iloc[0]
    source = crashes if crash_frame is None else crash_frame
    if source is None:
        raise RuntimeError("crash data is not loaded")
    pedestrian = source[source["has_pedestrian"].fillna(False).astype(bool)].copy()
    pedestrian_m = pedestrian.to_crs(METRIC)
    near_m = pedestrian_m[pedestrian_m.distance(line_m) <= 30]
    if "crash_id" in near_m.columns:
        near_m = near_m.drop_duplicates(subset=["crash_id"], keep="first")
    summary = feat["properties"].get("summary", {})
    return {
        "historical_hazard_index": summary.get("historical_hazard_index"),
        "nearby_reported_incidents": int(len(near_m)),
        "distance_m": summary.get("distance"),
        "duration_s": summary.get("duration"),
        "data_period": "2020-2024",
        "model_version": "hack-2026-v1",
    }


@app.post("/api/route")
async def route(req: RouteReq) -> dict:
    from . import graph_router

    use_local = req.engine == "local" or (req.engine == "auto" and graph_router.available())
    if use_local:
        prof = graph_router.get_profile(req.profile)
        try:
            pair = graph_router.select_route_pair(
                prof,
                req.start,
                req.end,
                preference=req.safety,
                after_dark=req.after_dark,
            )
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        fastest = pair["fastest"]
        lower_hazard = pair["lower_hazard"]
        return {
            "engine": "local",
            "fastest": {"route": fastest, "stats": route_stats(fastest)},
            "lower_hazard": {
                "route": lower_hazard,
                "stats": route_stats(lower_hazard),
            },
            "alternative_found": pair["alternative_found"],
            "reason": pair["reason"],
            "extra_duration_s": pair["extra_duration_s"],
            "extra_distance_m": pair["extra_distance_m"],
            "hazard_change_percent": pair["hazard_change_percent"],
            "detour_ratio": pair["detour_ratio"],
            "data_period": pair["data_period"],
            "model_version": pair["model_version"],
            "avoided_polygons": {"type": "FeatureCollection", "features": []},
        }

    if not ORS_KEY:
        raise HTTPException(status_code=503, detail="ORS_API_KEY not configured in backend/.env (or build the local graph: scripts/build_graph.py)")
    fastest = await ors_route(req, None)
    return {
        "engine": "ors",
        "fastest": {"route": fastest, "stats": route_stats(fastest)},
        "lower_hazard": {"route": fastest, "stats": route_stats(fastest)},
        "alternative_found": False,
        "reason": "consistent_hazard_index_unavailable_for_ors",
        "extra_duration_s": 0,
        "extra_distance_m": 0,
        "hazard_change_percent": None,
        "detour_ratio": 1.0,
        "data_period": graph_router.DATA_PERIOD,
        "model_version": graph_router.MODEL_VERSION,
        "avoided_polygons": {"type": "FeatureCollection", "features": []},
    }
