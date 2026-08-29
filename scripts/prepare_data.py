"""One-off data preparation: raw downloads -> processed parquet/geojson.

Inputs (data/raw/):
  crash.xlsx           TfNSW NSW Road Crash Data 2020-2024, CRASH table
  traffic_unit.xlsx    same release, TRAFFIC UNIT table
  schoolzones/SchoolZones.json   TfNSW school zone polygons
  schools_master.csv   NSW public schools master dataset

Outputs (data/processed/):
  crashes.parquet          all NSW crashes + ped/bike flags + risk score
  active_crashes.geojson   Greater Sydney ped/bike-involved crashes (map layer + routing)
  schools.geojson          public schools with enrolment
  school_zones.geojson     school zone polygons (simplified)

Run:  .venv/bin/python scripts/prepare_data.py
"""
import json
from pathlib import Path

import geopandas as gpd
import pandas as pd
from shapely.geometry import shape

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
OUT = ROOT / "data" / "processed"
OUT.mkdir(parents=True, exist_ok=True)

# Greater Sydney bounding box (generous: Hawkesbury to Sutherland, Penrith to coast)
SYD = dict(minx=150.5, miny=-34.35, maxx=151.65, maxy=-33.35)
DATA_YEARS = frozenset(range(2020, 2025))

SEVERITY_W = {
    "Fatal": 10.0,
    "Serious Injury": 5.0,
    "Moderate Injury": 3.0,
    "Minor/Other Injury": 2.0,
    "Injury": 3.0,  # fallback if only coarse degree present
    "Non-casualty (towaway)": 1.0,
    "Towaway": 1.0,
}


def severity_weight(row) -> float:
    d = row.get("Degree of crash - detailed") or row.get("Degree of crash") or ""
    for key, w in SEVERITY_W.items():
        if key.lower() in str(d).lower():
            return w
    return 1.0


def main() -> None:
    print("Reading traffic_unit.xlsx ...")
    tu = pd.read_excel(RAW / "traffic_unit.xlsx", sheet_name="Export")
    print("  TU type group values:", tu["TU type group"].value_counts().to_dict())
    grp = tu.groupby("Crash ID")["TU type group"].agg(list)
    flags = pd.DataFrame({
        "has_pedestrian": grp.apply(lambda ts: any("Pedestrian" in str(t) for t in ts)),
        "has_bicycle": grp.apply(lambda ts: any("Pedal" in str(t) or "cycle" in str(t).lower() for t in ts)),
    })

    print("Reading crash.xlsx (slow, ~1 min) ...")
    crash = pd.read_excel(RAW / "crash.xlsx", sheet_name="Sheet1")
    print(f"  {len(crash)} crashes")
    print("  Degree of crash:", crash["Degree of crash"].value_counts().to_dict())
    print("  Degree detailed:", crash["Degree of crash - detailed"].value_counts().to_dict())
    print("  Conurbation 1:", crash["Conurbation 1"].value_counts().to_dict())

    crash = crash.merge(flags, left_on="Crash ID", right_index=True, how="left")
    crash[["has_pedestrian", "has_bicycle"]] = crash[["has_pedestrian", "has_bicycle"]].fillna(False)

    crash["severity_w"] = crash.apply(severity_weight, axis=1)
    active = crash["has_pedestrian"] | crash["has_bicycle"]
    crash["risk"] = crash["severity_w"] * active.map({True: 2.0, False: 1.0})
    # speed-limit uplift: crashes on high-speed roads weigh more for vulnerable users
    speed = crash["Speed limit"].astype(str).str.extract(r"(\d+)")[0].astype(float)
    crash["speed_limit_kmh"] = speed
    crash.loc[speed >= 60, "risk"] *= 1.3
    crash["school_zone_active"] = crash["School zone active"].astype(str).str.contains("Yes|active", case=False, na=False) & ~crash["School zone active"].astype(str).str.contains("Not", case=False, na=False)

    crash.to_parquet(OUT / "crashes.parquet", index=False)
    print(f"  wrote crashes.parquet ({len(crash)} rows)")

    # Greater Sydney, pedestrian/cyclist involved -> geojson for map + routing
    syd = crash[
        crash["Longitude"].between(SYD["minx"], SYD["maxx"])
        & crash["Latitude"].between(SYD["miny"], SYD["maxy"])
        & crash["Year of crash"].isin(DATA_YEARS)
        & (crash["has_pedestrian"] | crash["has_bicycle"])
    ].copy()
    cols = [
        "Crash ID", "Degree of crash", "Degree of crash - detailed", "Year of crash",
        "Two-hour intervals", "Day of week of crash", "Natural lighting", "Street lighting",
        "speed_limit_kmh", "School zone location", "school_zone_active", "LGA", "Town",
        "Street of crash", "has_pedestrian", "has_bicycle", "severity_w", "risk",
        "No. killed", "No. seriously injured",
    ]
    gdf = gpd.GeoDataFrame(
        syd[cols].rename(columns=lambda c: c.lower().replace(" ", "_").replace(".", "").replace("-_", "")),
        geometry=gpd.points_from_xy(syd["Longitude"], syd["Latitude"]),
        crs="EPSG:4326",
    )
    gdf.to_file(OUT / "active_crashes.geojson", driver="GeoJSON")
    print(f"  wrote active_crashes.geojson ({len(gdf)} Sydney ped/bike crashes)")

    # ---- schools ----
    print("Reading schools_master.csv ...")
    sch = pd.read_csv(RAW / "schools_master.csv", low_memory=False)
    latc = [c for c in sch.columns if c.lower() in ("latitude", "lat")]
    lonc = [c for c in sch.columns if c.lower() in ("longitude", "long", "lon")]
    print("  coord cols:", latc, lonc, "n =", len(sch))
    sch = sch.dropna(subset=[latc[0], lonc[0]])
    keep = {
        "School_name": "name", "Level_of_schooling": "level",
        "latest_year_enrolment_FTE": "enrolment", "LGA": "lga",
        "ICSEA_value": "icsea", "Town_suburb": "suburb", "Postcode": "postcode",
    }
    sg = gpd.GeoDataFrame(
        sch[list(keep)].rename(columns=keep),
        geometry=gpd.points_from_xy(sch[lonc[0]], sch[latc[0]]),
        crs="EPSG:4326",
    )
    sg = sg.cx[SYD["minx"]:SYD["maxx"], SYD["miny"]:SYD["maxy"]]
    sg.to_file(OUT / "schools.geojson", driver="GeoJSON")
    print(f"  wrote schools.geojson ({len(sg)} Sydney schools)")

    # ---- school zones ----
    print("Reading SchoolZones.json ...")
    # TfNSW export: a list whose first element is metadata; each feature is a
    # flat dict with GeoJSON geometry under "json_geometry" (WGS84).
    raw = json.loads((RAW / "schoolzones" / "SchoolZones.json").read_text())
    feats = [f for f in raw if isinstance(f, dict) and "json_geometry" in f]
    print("  n zone features:", len(feats))
    geoms, props = [], []
    keep_props = ["SZ_ZONE_ID", "SZ_TYPE", "SZ_SPEED", "START_TIME_AM", "END_TIME_AM",
                  "START_TIME_PM", "END_TIME_PM", "SCL_NAME", "LATE_OPENING_SCHOOL"]
    for f in feats:
        try:
            geoms.append(shape(f["json_geometry"]))
            props.append({k: f.get(k) for k in keep_props})
        except Exception:
            continue
    zg = gpd.GeoDataFrame(props, geometry=geoms, crs="EPSG:4326")
    zg = zg.cx[SYD["minx"]:SYD["maxx"], SYD["miny"]:SYD["maxy"]]
    zg["geometry"] = zg.geometry.simplify(0.00005)
    zg.to_file(OUT / "school_zones.geojson", driver="GeoJSON")
    print(f"  wrote school_zones.geojson ({len(zg)} Sydney zones)")


if __name__ == "__main__":
    main()
