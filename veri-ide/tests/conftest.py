"""Pytest configuration and fixtures for VeriIDE tests."""

import pytest
from pathlib import Path


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
