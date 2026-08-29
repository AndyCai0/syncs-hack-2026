import pytest
from pydantic import ValidationError

from backend.app.main import RouteReq


@pytest.mark.parametrize("preference", [-0.01, 1.01])
def test_preference_is_bounded(preference):
    with pytest.raises(ValidationError):
        RouteReq(
            start=[151.0, -33.9],
            end=[151.01, -33.9],
            safety=preference,
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("start", [151.0]),
        ("start", [181.0, -33.9]),
        ("end", [151.0, -91.0]),
        ("start", [0.0, 0.0]),
    ],
)
def test_invalid_or_out_of_coverage_coordinates_are_rejected(field, value):
    payload = {"start": [151.0, -33.9], "end": [151.01, -33.9]}
    payload[field] = value
    with pytest.raises(ValidationError):
        RouteReq(**payload)


def test_profile_and_engine_are_known_literals():
    with pytest.raises(ValidationError):
        RouteReq(start=[151.0, -33.9], end=[151.01, -33.9], profile="cycling-regular")
    with pytest.raises(ValidationError):
        RouteReq(start=[151.0, -33.9], end=[151.01, -33.9], engine="mystery")
