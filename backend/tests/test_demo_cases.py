import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.app.main import app

ROOT = Path(__file__).resolve().parents[2]


def load_cases() -> list[dict]:
    return json.loads((ROOT / "data/demo_cases.json").read_text(encoding="utf-8"))


def test_committed_demo_cases_are_distinct_bounded_school_walks():
    cases = load_cases()

    assert len(cases) == 3
    assert len({case["school_name"] for case in cases}) == 3
    for case in cases:
        assert len(case["start"]) == len(case["end"]) == 2
        assert 800 <= case["fastest"]["distance_m"] <= 3_000
        assert case["detour_ratio"] <= 1.25
        assert case["maximum_route_separation_m"] >= 25
        assert (
            case["lower_hazard"]["historical_hazard_index"]
            < case["fastest"]["historical_hazard_index"]
        )
        assert "not a verified entrance" in case["destination_label"]


@pytest.mark.slow
def test_first_demo_case_routes_through_local_api_without_ors_key():
    case = load_cases()[0]
    with TestClient(app) as client:
        health = client.get("/api/health")
        assert health.status_code == 200
        assert health.json()["local_walking_graph"] is True

        listed = client.get("/api/demo_cases")
        assert listed.status_code == 200
        assert listed.json()[0]["id"] == case["id"]

        response = client.post(
            "/api/route",
            json={
                "start": case["start"],
                "end": case["end"],
                "profile": "foot-walking",
                "safety": 1.0,
                "after_dark": False,
                "engine": "local",
            },
        )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["engine"] == "local"
    assert body["alternative_found"] is True
    assert body["detour_ratio"] <= 1.25
    assert body["data_period"] == "2020-2024"
    assert body["model_version"] == "hack-2026-v1"
    assert body["fastest"]["stats"]["historical_hazard_index"] > body["lower_hazard"]["stats"]["historical_hazard_index"]
