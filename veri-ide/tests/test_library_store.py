"""Algorithm blocks live as text: `<Type>.block.yaml` + `<Type>.st` inside library directories."""

import pytest
import yaml
from fastapi.testclient import TestClient

from veri_ide.api.server import app
from veri_ide.backend.library.service import LibraryService, get_library_service
from veri_ide.backend.library.store import BlockStore, LibraryStore, st_type_name, global_libraries_dir
from veri_ide.backend.project import workspace

HALVER_ST = """FUNCTION_BLOCK HALVER
VAR_INPUT
    IN : REAL;
END_VAR
VAR_OUTPUT
    OUT : REAL;
END_VAR

OUT := IN / 2.0;
END_FUNCTION_BLOCK"""

PID_SHORT_ST = """FUNCTION_BLOCK PID
VAR_INPUT
    SP : REAL;
    PV : REAL;
END_VAR
VAR_OUTPUT
    OUT : REAL;
END_VAR

OUT := SP - PV;
END_FUNCTION_BLOCK"""


@pytest.fixture
def libraries_root(tmp_path, monkeypatch):
    """A sidecar whose global block libraries root is a fresh temporary directory."""
    from veri_ide.backend.library import service as library_service
    from veri_ide.backend.project import recent

    root = tmp_path / "libraries"
    monkeypatch.setattr(library_service, "_service", LibraryService(libraries_root=root))
    monkeypatch.setattr(recent, "_STORE", None)
    if workspace.current_workspace():
        workspace.close_workspace()
    yield root
    monkeypatch.setattr(recent, "_STORE", None)


@pytest.fixture
def client(libraries_root):
    return TestClient(app)


def _create_block(client, name="二分器", st=HALVER_ST, category="math"):
    response = client.post("/library/blocks", json={
        "name": name,
        "category": category,
        "inputs": [{"name": "IN", "direction": "input", "data_type": "REAL"}],
        "outputs": [{"name": "OUT", "direction": "output", "data_type": "REAL"}],
        "st_template": st,
    })
    assert response.status_code == 200, response.text
    return response.json()


def test_first_use_seeds_the_builtin_blocks_as_text(tmp_path):
    root = tmp_path / "libraries"
    service = LibraryService(libraries_root=root)
    builtin_dir = root / "builtin" / "blocks"
    assert sorted(p.name for p in builtin_dir.glob("*.block.yaml")) == [
        "FBY.block.yaml",
        "LIMITER.block.yaml",
        "PID.block.yaml",
        "RS.block.yaml",
    ]
    assert (builtin_dir / "PID.st").read_text(encoding="utf-8").startswith(
        "FUNCTION_BLOCK PID"
    )
    assert len(service.list_blocks()) == 4


def test_reopening_the_directory_reads_the_same_blocks_back(tmp_path):
    root = tmp_path / "libraries"
    first = {b.id: b for b in LibraryService(libraries_root=root).list_blocks()}
    second = {b.id: b for b in LibraryService(libraries_root=root).list_blocks()}

    assert set(first) == set(second)
    assert first["PID_v1"].st_template == second["PID_v1"].st_template
    assert [p.name for p in second["PID_v1"].inputs] == ["SP", "PV"]
    assert second["PID_v1"].sha256


def test_created_block_is_written_and_survives_restart(client, libraries_root):
    created = _create_block(client)

    blocks = {b.id: b for b in get_library_service().list_blocks()}
    assert blocks[created["id"]].st_template.startswith("FUNCTION_BLOCK HALVER")

    user_blocks_dir = libraries_root / "user-default" / "blocks"
    assert (user_blocks_dir / "HALVER.block.yaml").is_file()
    assert (user_blocks_dir / "HALVER.st").read_text(encoding="utf-8") == HALVER_ST + "\n"

    manifest = yaml.safe_load((user_blocks_dir / "HALVER.block.yaml").read_text(encoding="utf-8"))
    assert manifest["name"] == "二分器"
    assert manifest["inputs"][0]["data_type"] == "REAL"
    assert "st_template" not in manifest

    reloaded = {b.id: b for b in LibraryService(libraries_root=libraries_root).list_blocks()}
    assert reloaded[created["id"]].st_template == HALVER_ST


def test_updating_a_block_rewrites_its_pair(client, libraries_root):
    created = _create_block(client)

    response = client.put(
        f"/library/blocks/{created['id']}", json={"st_template": PID_SHORT_ST}
    )
    assert response.status_code == 200

    user_blocks_dir = libraries_root / "user-default" / "blocks"
    assert not (user_blocks_dir / "HALVER.block.yaml").exists()
    assert (user_blocks_dir / "PID.block.yaml").is_file()
    assert (user_blocks_dir / "PID.st").read_text(encoding="utf-8").startswith("FUNCTION_BLOCK PID")


def test_deleting_a_block_removes_its_files(client, libraries_root):
    created = _create_block(client)

    assert client.delete(f"/library/blocks/{created['id']}").status_code == 200
    user_blocks_dir = libraries_root / "user-default" / "blocks"
    assert not list(user_blocks_dir.glob("HALVER*"))


def test_project_scope_blocks_shadow_the_global_library(client, libraries_root, tmp_path):
    from veri_ide.backend.project.service import create_project

    root = create_project("shadowing", tmp_path / "proj").path
    workspace.open_workspace(root)
    get_library_service().set_project_dir(root)

    _create_block(client, name="工程版 HALVER", st=HALVER_ST)
    override = _create_block(client, name="站点 PID", st=PID_SHORT_ST)

    by_type: dict[str, list] = {}
    for block in get_library_service().list_blocks():
        by_type.setdefault(st_type_name(block), []).append(block)

    assert len(by_type["PID"]) == 1, "the project block must replace the global one"
    assert by_type["PID"][0].id == override["id"]
    assert by_type["PID"][0].scope == "project"
    assert (root / "blocks" / "PID.block.yaml").is_file()
    assert (root / "blocks" / "HALVER.st").is_file()

    get_library_service().set_project_dir(None)
    ids = {b.id for b in get_library_service().list_blocks()}
    assert override["id"] not in ids
    assert "PID_v1" in ids


def test_store_reuses_pou_name_and_falls_back_on_collision(tmp_path):
    from veri_ide.backend.library.models import AlgorithmBlock, BlockCategory

    store = BlockStore(tmp_path / "blocks")
    common = dict(name="", category=BlockCategory.MATH, version="1.0.0", description="",
                  st_template=HALVER_ST)
    first = store.save(AlgorithmBlock(id="A", **common))
    second = store.save(AlgorithmBlock(id="B", **common))

    assert first.name == "HALVER.block.yaml"
    assert second.name == "B.block.yaml"


def test_library_crud(tmp_path):
    root = tmp_path / "libraries"
    service = LibraryService(libraries_root=root)

    lib = service.create_library("test-lib", "Test Library", "tester")
    assert lib.id == "test-lib"
    assert (root / "test-lib" / "library.yaml").is_file()

    libs = service.list_libraries()
    assert any(l.id == "test-lib" for l in libs)

    service.update_library("test-lib", description="Updated")
    updated = service.get_library("test-lib")
    assert updated.description == "Updated"

    service.delete_library("test-lib")
    assert not (root / "test-lib").exists()


def test_library_zip_roundtrip(tmp_path):
    import zipfile
    root = tmp_path / "libraries"
    service = LibraryService(libraries_root=root)

    lib = service.create_library("zip-test", "ZIP Test")
    from veri_ide.backend.library.models import (
        AlgorithmBlock, BlockCategory, BlockPort, PortDirection,
    )
    block = AlgorithmBlock(
        id="ZBLOCK", name="ZipBlock", category=BlockCategory.MATH,
        version="1.0.0", description="",
        inputs=[BlockPort(name="X", direction=PortDirection.INPUT, data_type="REAL")],
        st_template="FUNCTION_BLOCK ZBLOCK\nEND_FUNCTION_BLOCK",
    )
    service.add_block(block, library_id="zip-test")

    zip_path = tmp_path / "export.zip"
    service.export_library_zip("zip-test", zip_path)
    assert zip_path.is_file()
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        assert "library.yaml" in names

    service.delete_library("zip-test")
    imported = service.import_library_zip(zip_path, library_id="zip-reimport")
    assert imported.id == "zip-reimport"
    blocks = service.list_blocks()
    assert any(b.id == "ZBLOCK" for b in blocks)
