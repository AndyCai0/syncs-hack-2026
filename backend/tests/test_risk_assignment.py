import geopandas as gpd
from shapely.geometry import LineString, Point

from scripts.risk_assignment import assign_relevant_crashes


def test_walking_assignment_filters_cyclists_and_breaks_edge_ties_deterministically():
    crashes = gpd.GeoDataFrame(
        [
            {
                "crash_id": 10,
                "has_pedestrian": True,
                "has_bicycle": False,
                "severity_w": 5.0,
                "speed_limit_kmh": 60,
                "natural_lighting": "Darkness",
            },
            {
                "crash_id": 20,
                "has_pedestrian": False,
                "has_bicycle": True,
                "severity_w": 10.0,
                "speed_limit_kmh": 40,
                "natural_lighting": "Daylight",
            },
        ],
        geometry=[Point(151.0005, -33.9), Point(151.0005, -33.9)],
        crs="EPSG:4326",
    )
    # Equal geometries intentionally create an equal-nearest-edge tie.
    edges = gpd.GeoDataFrame(
        geometry=[
            LineString([(151.0, -33.9), (151.001, -33.9)]),
            LineString([(151.0, -33.9), (151.001, -33.9)]),
        ],
        crs="EPSG:4326",
    )

    assigned = assign_relevant_crashes(crashes, edges, profile="walking")

    assert assigned[["crash_id", "edge_id"]].to_dict("records") == [
        {"crash_id": 10, "edge_id": 0}
    ]
    assert assigned.iloc[0]["effective_risk"] == 6.5
    assert assigned.iloc[0]["effective_risk_dark"] == 9.75
