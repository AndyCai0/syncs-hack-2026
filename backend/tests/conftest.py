from pathlib import Path

import geopandas as gpd
import pandas as pd
import pytest
from shapely.geometry import LineString


@pytest.fixture
def graph_writer(tmp_path: Path):
    def write_graph(
        nodes: list[tuple[float, float]],
        edges: list[dict],
        name: str = "walking",
    ) -> Path:
        pd.DataFrame(nodes, columns=["x", "y"]).to_parquet(
            tmp_path / f"{name}_nodes.parquet", index=False
        )
        records = []
        geometries = []
        for edge in edges:
            record = {
                "u": edge["u"],
                "v": edge["v"],
                "length_m": edge["length_m"],
                "risk": edge.get("risk", 0.0),
                "risk_dark": edge.get("risk_dark", edge.get("risk", 0.0)),
                "school_zone": edge.get("school_zone", False),
            }
            records.append(record)
            geometry = edge.get("geometry")
            if geometry is None:
                geometry = [nodes[edge["u"]], nodes[edge["v"]]]
            geometries.append(LineString(geometry))
        gpd.GeoDataFrame(records, geometry=geometries, crs="EPSG:4326").to_parquet(
            tmp_path / f"{name}_edges.parquet", index=False
        )
        return tmp_path

    return write_graph
