"""Pytest configuration and fixtures for VeriIDE tests."""

import os

import pytest
from pathlib import Path


@pytest.fixture(scope="session", autouse=True)
def isolated_veride_home(tmp_path_factory):
    """Keep per-user state (block library, recent list) out of the developer's home."""
    home = tmp_path_factory.mktemp("veride-home")
    os.environ["VERIDE_HOME"] = str(home)

    from veri_ide.backend.library.service import get_library_service
    from veri_ide.backend.project.recent import reset_recent_store

    reset_recent_store()
    get_library_service()
    yield
    reset_recent_store()
    os.environ.pop("VERIDE_HOME", None)


@pytest.fixture
def fixtures_dir():
    """Return the path to the test fixtures directory."""
    return Path(__file__).parent / "fixtures"


@pytest.fixture
def valid_project_path(fixtures_dir):
    """Return the path to a valid test project."""
    return fixtures_dir / "valid-project"


@pytest.fixture
def invalid_project_path(fixtures_dir):
    """Return the path to an invalid test project."""
    return fixtures_dir / "invalid-project"
