from backend.app.graph_router import MAX_DETOUR_RATIO, Profile, select_route_pair
import pytest


def diversion_graph(graph_writer, detour_edge_length=70, risk=50, risk_dark=None):
    nodes = [
        (151.0000, -33.9000),
        (151.0010, -33.9000),
        (151.0020, -33.9000),
        (151.0015, -33.8990),
    ]
    graph_dir = graph_writer(
        nodes,
        [
            {"u": 0, "v": 1, "length_m": 100},
            {
                "u": 1,
                "v": 2,
                "length_m": 100,
                "risk": risk,
                "risk_dark": risk if risk_dark is None else risk_dark,
            },
            {"u": 1, "v": 3, "length_m": detour_edge_length},
            {"u": 3, "v": 2, "length_m": detour_edge_length},
        ],
    )
    return nodes, Profile("walking", graph_dir=graph_dir)


def test_fastest_route_on_tiny_graph_reports_edge_hazard(graph_writer):
    nodes = [(151.0000, -33.9000), (151.0010, -33.9000), (151.0020, -33.9000)]
    graph_dir = graph_writer(
        nodes,
        [
            {"u": 0, "v": 1, "length_m": 100, "risk": 2},
            {"u": 1, "v": 2, "length_m": 100, "risk": 3},
        ],
    )

    profile = Profile("walking", graph_dir=graph_dir)
    route = profile.route(list(nodes[0]), list(nodes[2]), k=0)
    summary = route["features"][0]["properties"]["summary"]

    assert summary["distance"] == 200.0
    assert summary["historical_hazard_index"] == 5.0
    assert summary["duration"] == 150


def test_parallel_edges_select_minimum_cost_edge_and_matching_geometry(graph_writer):
    nodes = [(151.0000, -33.9000), (151.0010, -33.9000), (151.0020, -33.9000)]
    graph_dir = graph_writer(
        nodes,
        [
            {"u": 0, "v": 1, "length_m": 50, "risk": 100},
            {
                "u": 0,
                "v": 1,
                "length_m": 80,
                "risk": 0,
                "geometry": [nodes[0], (151.0005, -33.8995), nodes[1]],
            },
            {"u": 1, "v": 2, "length_m": 50, "risk": 0},
        ],
    )
    profile = Profile("walking", graph_dir=graph_dir)

    fastest = profile.route(list(nodes[0]), list(nodes[2]), k=0)
    lower_hazard = profile.route(list(nodes[0]), list(nodes[2]), k=4)
    fast_summary = fastest["features"][0]["properties"]["summary"]
    lower_summary = lower_hazard["features"][0]["properties"]["summary"]

    assert fast_summary["distance"] == 100.0
    assert fast_summary["historical_hazard_index"] == 100.0
    assert lower_summary["distance"] == 130.0
    assert lower_summary["historical_hazard_index"] == 0.0
    assert [151.0005, -33.8995] in lower_hazard["features"][0]["geometry"]["coordinates"]


def test_school_zone_flag_does_not_discount_edge_cost(graph_writer):
    nodes = [(151.0000, -33.9000), (151.0020, -33.9000), (151.0010, -33.8995)]
    graph_dir = graph_writer(
        nodes,
        [
            {"u": 0, "v": 1, "length_m": 100},
            {"u": 0, "v": 2, "length_m": 51, "school_zone": True},
            {"u": 2, "v": 1, "length_m": 51, "school_zone": True},
        ],
    )

    route = Profile("walking", graph_dir=graph_dir).route(list(nodes[0]), list(nodes[1]), k=0)

    assert route["features"][0]["properties"]["summary"]["distance"] == 100.0
    assert [151.001, -33.8995] not in route["features"][0]["geometry"]["coordinates"]


def test_selects_lower_hazard_route_within_detour_cap(graph_writer):
    nodes, profile = diversion_graph(graph_writer, detour_edge_length=70)

    pair = select_route_pair(profile, list(nodes[0]), list(nodes[2]), preference=1.0)

    assert MAX_DETOUR_RATIO == 1.25
    assert pair["alternative_found"] is True
    assert pair["fastest"]["features"][0]["properties"]["summary"]["distance"] == 200.0
    assert pair["lower_hazard"]["features"][0]["properties"]["summary"]["distance"] == 240.0
    assert pair["detour_ratio"] == 1.2
    assert pair["hazard_change_percent"] == -100.0


def test_falls_back_when_only_lower_hazard_route_exceeds_detour_cap(graph_writer):
    nodes, profile = diversion_graph(graph_writer, detour_edge_length=80)

    pair = select_route_pair(profile, list(nodes[0]), list(nodes[2]), preference=1.0)

    assert pair["alternative_found"] is False
    assert pair["reason"] == "no_reasonable_lower_hazard_alternative"
    assert pair["lower_hazard"] == pair["fastest"]
    assert pair["detour_ratio"] == 1.0
    assert pair["hazard_change_percent"] is None


def test_after_dark_routing_and_reported_index_use_dark_risk(graph_writer):
    nodes, profile = diversion_graph(
        graph_writer, detour_edge_length=70, risk=0, risk_dark=50
    )

    day = select_route_pair(
        profile, list(nodes[0]), list(nodes[2]), preference=1.0, after_dark=False
    )
    night = select_route_pair(
        profile, list(nodes[0]), list(nodes[2]), preference=1.0, after_dark=True
    )

    assert day["alternative_found"] is False
    assert day["fastest"]["features"][0]["properties"]["summary"]["historical_hazard_index"] == 0
    assert night["fastest"]["features"][0]["properties"]["summary"]["historical_hazard_index"] == 50
    assert night["alternative_found"] is True
    assert night["lower_hazard"]["features"][0]["properties"]["summary"]["historical_hazard_index"] == 0


def test_route_rejects_endpoint_more_than_500m_from_graph(graph_writer):
    nodes = [(151.0000, -33.9000), (151.0010, -33.9000)]
    graph_dir = graph_writer(nodes, [{"u": 0, "v": 1, "length_m": 100}])
    profile = Profile("walking", graph_dir=graph_dir)

    with pytest.raises(ValueError, match="more than 500 m"):
        profile.route([151.0000, -33.8900], list(nodes[1]), k=0)
