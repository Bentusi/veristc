"""Tests for the project lifecycle API behind the startup page."""

import pytest
import tomllib
import yaml
from fastapi.testclient import TestClient

from veri_ide.api.server import app
from veri_ide.backend.device.service import get_device_project
from veri_ide.backend.graph.service import get_graph_project
from veri_ide.backend.library.service import get_library_service
from veri_ide.backend.project import workspace
from veri_ide.backend.project.recent import RecentStore, reset_recent_store
from veri_ide.backend.project.service import is_project_dir


@pytest.fixture
def client(tmp_path):
    """A client over a clean sidecar: no open project, isolated recent list."""
    reset_recent_store()
    if workspace.current_workspace():
        workspace.close_workspace()
    get_device_project().reset([])
    get_graph_project().reset()
    get_library_service().set_project_dir(None)

    from veri_ide.backend.project import recent

    recent._STORE = RecentStore(tmp_path / "recent.json")

    yield TestClient(app)

    workspace.close_workspace()
    recent._STORE = None


def _create(client, name="plant_unit", parent=None, **kwargs):
    payload = {"name": name, "parent_dir": str(parent), **kwargs}
    response = client.post("/project/create", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


# ---------- create ----------


def test_create_project_writes_the_text_layout(client, tmp_path):
    body = _create(client, "rps_unit", tmp_path / "projects", safety_level="SIL3")
    root = tmp_path / "projects" / "rps_unit"

    assert body["path"] == str(root)
    assert body["safety_level"] == "SIL3"
    assert is_project_dir(root)

    project = yaml.safe_load((root / "project.yaml").read_text(encoding="utf-8"))
    assert project["name"] == "rps_unit"
    assert project["logic_files"] == []

    for directory in ("logic", "iomap", "device", "blocks", "sim", "build"):
        assert (root / directory).is_dir(), directory
    assert "build/" in (root / ".gitignore").read_text(encoding="utf-8")
    assert (root / ".git").is_dir()


def test_new_project_is_seeded_with_text_artifacts(client, tmp_path):
    _create(client, "seeded", tmp_path / "projects")
    root = tmp_path / "projects" / "seeded"

    assert (root / "device" / "stations.toml").is_file()
    assert (root / "iomap" / "ST1.toml").is_file()
    pages = list((root / "logic").glob("*.FC.json"))
    assert len(pages) == 1
    assert pages[0].read_text(encoding="utf-8").startswith("{")

    stations = get_device_project().stations()
    assert [s["station_id"] for s in stations] == ["ST1"]
    assert stations[0]["variables"] == 0
    assert [p["id"] for p in get_graph_project().pages()] == ["PAGE1"]


def test_create_rejects_bad_names_and_used_directories(client, tmp_path):
    bad = client.post("/project/create", json={"name": "bad-name", "parent_dir": str(tmp_path)})
    assert bad.status_code == 400

    _create(client, "dup", tmp_path)
    again = client.post("/project/create", json={"name": "dup", "parent_dir": str(tmp_path)})
    assert again.status_code == 409
    assert "占用" in again.json()["detail"]


def test_create_rejects_unknown_safety_level(client, tmp_path):
    response = client.post(
        "/project/create",
        json={"name": "sil9", "parent_dir": str(tmp_path), "safety_level": "SIL9"},
    )
    assert response.status_code == 400


# ---------- open / save / close ----------


def test_open_loads_device_and_pages_from_disk(client, tmp_path):
    body = _create(client, "reopen", tmp_path)
    root = body["path"]

    # Drop the in-memory models as if the sidecar had just restarted.
    get_device_project().reset([])
    get_graph_project().reset(name="OTHER")
    workspace.close_workspace()

    opened = client.post("/project/open", json={"path": root})
    assert opened.status_code == 200
    assert opened.json()["name"] == "reopen"
    assert [s["station_id"] for s in get_device_project().stations()] == ["ST1"]
    assert [p["id"] for p in get_graph_project().pages()] == ["PAGE1"]


def test_open_missing_or_foreign_directory_fails(client, tmp_path):
    missing = client.post("/project/open", json={"path": str(tmp_path / "nope")})
    assert missing.status_code == 404
    assert "不存在" in missing.json()["detail"]

    other = tmp_path / "not_a_project"
    other.mkdir()
    foreign = client.post("/project/open", json={"path": str(other)})
    assert foreign.status_code == 404
    assert "project.yaml" in foreign.json()["detail"]


def test_save_writes_back_every_domain(client, tmp_path):
    body = _create(client, "writer", tmp_path)
    root = body["path"]

    client.put("/device/stations/ST1/variables", json={"variables": [
        {"name": "PV", "direction": "input", "st_type": "REAL", "description": "过程值"}
    ]})
    client.put("/device/stations/ST1/mapping", json={
        "var_name": "PV", "channel": 0, "scale": 1.0, "bias": 0.0, "unit": "%"
    })
    client.post("/graph/save", json={})
    saved = client.post("/project/save", json={})
    assert saved.status_code == 200

    binding = tomllib.loads((tmp_path / "writer" / "iomap" / "ST1.toml").read_text(encoding="utf-8"))
    assert binding["PV"]["channel"] == 0
    assert binding["PV"]["unit"] == "%"
    assert (tmp_path / "writer" / "logic" / "PAGE1.FC.json").is_file()


def test_save_without_project_reports_conflict(client):
    assert client.post("/project/save", json={}).status_code == 409


def test_close_forgets_the_current_project(client, tmp_path):
    _create(client, "closer", tmp_path)
    assert client.get("/project/current").json()["name"] == "closer"
    assert client.post("/project/close", json={}).json() == {"closed": True}
    assert client.get("/project/current").json() is None


# ---------- recent lists / launcher state ----------


def test_state_lists_recent_projects_newest_first(client, tmp_path):
    first = _create(client, "alpha", tmp_path)
    second = _create(client, "beta", tmp_path)

    state = client.get("/project/state").json()
    paths = [row["path"] for row in state["recent_projects"]]
    assert paths == [second["path"], first["path"]]
    assert state["recent_projects"][0]["exists"] is True
    assert state["recent_projects"][0]["pages"] == 1
    assert state["current"]["name"] == "beta"
    assert state["default_parent_dir"]

    forgotten = client.post("/project/forget", json={"path": first["path"]})
    assert forgotten.json() == {"forgotten": True}
    assert [row["path"] for row in client.get("/project/state").json()["recent_projects"]] == [
        second["path"]
    ]


def test_recent_project_reports_a_moved_folder(client, tmp_path):
    body = _create(client, "moving", tmp_path)
    (tmp_path / "moving").rename(tmp_path / "moved")

    row = client.get("/project/state").json()["recent_projects"][0]
    assert row["path"] == body["path"]
    assert row["exists"] is False


def _new_block(client, name: str, pou: str) -> dict:
    response = client.post("/library/blocks", json={
        "name": name,
        "category": "math",
        "inputs": [{"name": "IN", "direction": "input", "data_type": "REAL"}],
        "outputs": [{"name": "OUT", "direction": "output", "data_type": "REAL"}],
        "st_template": (
            f"FUNCTION_BLOCK {pou}\nVAR_INPUT\n    IN : REAL;\nEND_VAR\n"
            f"VAR_OUTPUT\n    OUT : REAL;\nEND_VAR\n\nOUT := IN / 2.0;\nEND_FUNCTION_BLOCK"
        ),
    })
    assert response.status_code == 200, response.text
    return response.json()


def test_state_lists_recent_blocks(client, tmp_path):
    _create(client, "blocks", tmp_path)
    created = _new_block(client, "二分器", "HALVER")
    assert created["scope"] == "project"
    assert created["path"].endswith("blocks/HALVER.block.yaml")

    rows = client.get("/project/state").json()["recent_blocks"]
    assert rows[0]["name"] == "二分器"
    assert rows[0]["id"] == created["id"]
    assert rows[0]["scope"] == "project"
    assert rows[0]["project"] == "blocks"


def test_project_block_stays_recent_when_its_project_is_closed(client, tmp_path):
    """A `blocks/` block is only loaded while its project is open -- the history is not."""
    _create(client, "shut", tmp_path)
    created = _new_block(client, "二分器", "HALVER")
    client.post("/project/close", json={})

    assert created["id"] not in [b["id"] for b in client.get("/library/blocks").json()]
    rows = client.get("/project/state").json()["recent_blocks"]
    assert rows[0]["id"] == created["id"]
    assert rows[0]["project"] == "shut"


def test_deleted_user_block_leaves_the_recent_list(client, tmp_path):
    client.post("/project/close", json={})
    created = _new_block(client, "半份", "HALVER2")
    assert created["scope"] == "user"

    assert created["id"] in [r["id"] for r in client.get("/project/state").json()["recent_blocks"]]
    assert client.delete(f"/library/blocks/{created['id']}").status_code == 200
    assert created["id"] not in [r["id"] for r in client.get("/project/state").json()["recent_blocks"]]
