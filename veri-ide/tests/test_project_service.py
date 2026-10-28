"""Tests for project service."""

import pytest
from pathlib import Path
import tempfile
import shutil

from veri_ide.backend.project.service import (
    create_project,
    open_project,
    list_projects,
    commit_project,
    diff_project,
    delete_project,
    ProjectMeta,
)


@pytest.fixture
def temp_dir():
    """Create a temporary directory for tests."""
    tmp = tempfile.mkdtemp(prefix="veride_test_")
    yield Path(tmp)
    shutil.rmtree(tmp, ignore_errors=True)


def test_create_project_basic(temp_dir):
    """Test creating a basic project."""
    project_path = temp_dir / "test_project"
    meta = create_project("test_project", project_path)

    assert meta.name == "test_project"
    assert meta.path == project_path
    assert meta.safety_level == "SIL2"
    assert meta.svm_version == "1.0.0"
    assert meta.logic_files == []

    # Check directory structure
    assert (project_path / "project.yaml").exists()
    assert (project_path / "logic").is_dir()
    assert (project_path / "iomap").is_dir()
    assert (project_path / "build").is_dir()

    # Check Git initialization
    assert (project_path / ".git").exists()


def test_create_project_custom_safety_level(temp_dir):
    """Test creating a project with custom safety level."""
    project_path = temp_dir / "sil3_project"
    meta = create_project("sil3_project", project_path, safety_level="SIL3")

    assert meta.safety_level == "SIL3"


def test_create_project_invalid_name(temp_dir):
    """Test that invalid project names are rejected."""
    project_path = temp_dir / "invalid-name"
    with pytest.raises(ValueError, match="Invalid project name"):
        create_project("invalid-name", project_path)


def test_create_project_invalid_safety_level(temp_dir):
    """Test that invalid safety levels are rejected."""
    project_path = temp_dir / "test"
    with pytest.raises(ValueError, match="Invalid safety level"):
        create_project("test", project_path, safety_level="SIL4")


def test_create_project_existing_directory(temp_dir):
    """Test that creating in non-empty directory fails."""
    project_path = temp_dir / "existing"
    project_path.mkdir()
    (project_path / "file.txt").write_text("content")

    with pytest.raises(FileExistsError):
        create_project("test", project_path)


def test_open_project(temp_dir):
    """Test opening an existing project."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path, safety_level="SIL1")

    meta = open_project(project_path)

    assert meta.name == "test_project"
    assert meta.safety_level == "SIL1"


def test_open_project_not_found(temp_dir):
    """Test opening non-existent project fails."""
    with pytest.raises(FileNotFoundError):
        open_project(temp_dir / "nonexistent")


def test_list_projects(temp_dir):
    """Test listing projects in a directory."""
    # Create multiple projects
    create_project("proj1", temp_dir / "proj1")
    create_project("proj2", temp_dir / "proj2")
    create_project("proj3", temp_dir / "proj3")

    projects = list_projects(temp_dir)

    assert len(projects) == 3
    names = {p.name for p in projects}
    assert names == {"proj1", "proj2", "proj3"}


def test_list_projects_empty(temp_dir):
    """Test listing projects in empty directory."""
    projects = list_projects(temp_dir)
    assert projects == []


def test_list_projects_nonexistent():
    """Test listing projects in non-existent directory."""
    projects = list_projects(Path("/nonexistent/path"))
    assert projects == []


def test_commit_project(temp_dir):
    """Test committing project changes."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    # Make a change
    (project_path / "logic" / "test.st").write_text("PROGRAM test END_PROGRAM")

    # Commit
    commit_hash = commit_project(project_path, "Add test.st")

    assert len(commit_hash) == 40
    assert commit_hash.isalnum()


def test_commit_project_no_changes(temp_dir):
    """Test committing with no changes fails."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    with pytest.raises(ValueError, match="No changes to commit"):
        commit_project(project_path, "Empty commit")


def test_diff_project(temp_dir):
    """Test getting diff between revisions."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    # Make and commit a change
    (project_path / "logic" / "test.st").write_text("PROGRAM test END_PROGRAM")
    commit_project(project_path, "Add test.st")

    # Get diff
    diff = diff_project(project_path)

    assert "test.st" in diff
    assert "PROGRAM test" in diff


def test_delete_project(temp_dir):
    """Test deleting a project."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    assert project_path.exists()
    delete_project(project_path)
    assert not project_path.exists()


def test_delete_project_not_found(temp_dir):
    """Test deleting non-existent project fails."""
    with pytest.raises(FileNotFoundError):
        delete_project(temp_dir / "nonexistent")
