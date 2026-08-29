import geopandas as gpd
from shapely.geometry import Point

from backend.app.main import route_stats


def test_route_stats_count_unique_nearby_pedestrian_incidents_only():
    route = {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[151.0, -33.9], [151.01, -33.9]],
                },
                "properties": {
                    "summary": {
                        "distance": 1000.0,
                        "duration": 750,
                        "historical_hazard_index": 12.5,
                    }
                },
            }
        ],
    }
    incidents = gpd.GeoDataFrame(
        [
            {"crash_id": 101, "has_pedestrian": True, "degree_of_crash": "Injury"},
            {"crash_id": 101, "has_pedestrian": True, "degree_of_crash": "Injury"},
            {"crash_id": 202, "has_pedestrian": False, "degree_of_crash": "Injury"},
        ],
        geometry=[
            Point(151.005, -33.90005),
            Point(151.005, -33.90005),
            Point(151.006, -33.90005),
        ],
        crs="EPSG:4326",
    )

    stats = route_stats(route, crash_frame=incidents)

    assert stats == {
        "historical_hazard_index": 12.5,
        "nearby_reported_incidents": 1,
        "distance_m": 1000.0,
        "duration_s": 750,
        "data_period": "2020-2024",
        "model_version": "hack-2026-v1",
    }
