"""Project service — engineering project CRUD + Git integration."""

import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import git
import yaml

from .schema import validate_project_yaml


@dataclass
class ProjectMeta:
    """Project metadata."""
    name: str
    path: Path
    safety_level: str
    svm_version: str
    logic_files: list[str]
    description: Optional[str] = None


def create_project(name: str, target_path: Path, safety_level: str = "SIL2",
                   svm_version: str = "1.0.0") -> ProjectMeta:
    """Create a new VeriIDE project.

    Args:
        name: Project name (alphanumeric + underscore)
        target_path: Directory where the project will be created
        safety_level: IEC 61508 safety level (SIL1/SIL2/SIL3)
        svm_version: Target SafeASM VM version

    Returns:
        ProjectMeta with project details

    Raises:
        FileExistsError: If target_path already exists and is not empty
        ValueError: If name or safety_level is invalid
    """
    if not name.replace("_", "").isalnum():
        raise ValueError(f"Invalid project name: {name} (alphanumeric + underscore only)")

    if safety_level not in ("SIL1", "SIL2", "SIL3"):
        raise ValueError(f"Invalid safety level: {safety_level} (must be SIL1/SIL2/SIL3)")

    if target_path.exists() and any(target_path.iterdir()):
        raise FileExistsError(f"Target path already exists and is not empty: {target_path}")

    # Create directory structure
    target_path.mkdir(parents=True, exist_ok=True)
    (target_path / "logic").mkdir()
    (target_path / "iomap").mkdir()
    (target_path / "build").mkdir()

    # Create project.yaml
    project_data = {
        "name": name,
        "safety_level": safety_level,
        "svm_version": svm_version,
        "logic_files": [],
    }
    with open(target_path / "project.yaml", "w", encoding="utf-8") as f:
        yaml.dump(project_data, f, default_flow_style=False, allow_unicode=True)

    # Initialize Git repository
    repo = git.Repo.init(target_path)
    repo.index.add(["project.yaml", "logic/", "iomap/", "build/"])
    repo.index.commit("Initial project structure")

    return ProjectMeta(
        name=name,
        path=target_path,
        safety_level=safety_level,
        svm_version=svm_version,
        logic_files=[],
    )


def open_project(project_path: Path) -> ProjectMeta:
    """Open an existing VeriIDE project.

    Args:
        project_path: Path to the project directory

    Returns:
        ProjectMeta with project details

    Raises:
        FileNotFoundError: If project.yaml doesn't exist
        ValidationError: If project.yaml fails schema validation
    """
    project_data = validate_project_yaml(project_path)

    return ProjectMeta(
        name=project_data["name"],
        path=project_path,
        safety_level=project_data["safety_level"],
        svm_version=project_data["svm_version"],
        logic_files=project_data["logic_files"],
        description=project_data.get("description"),
    )


def list_projects(base_path: Path) -> list[ProjectMeta]:
    """List all VeriIDE projects under a base directory.

    Args:
        base_path: Directory to search for projects

    Returns:
        List of ProjectMeta for each valid project found
    """
    projects = []
    if not base_path.exists():
        return projects

    for project_dir in base_path.iterdir():
        if project_dir.is_dir() and (project_dir / "project.yaml").exists():
            try:
                meta = open_project(project_dir)
                projects.append(meta)
            except Exception:
                # Skip invalid projects
                continue

    return projects


def commit_project(project_path: Path, message: str) -> str:
    """Commit all changes in a project to Git.

    Args:
        project_path: Path to the project directory
        message: Commit message

    Returns:
        Commit hash (40-character hex string)

    Raises:
        ValueError: If no changes to commit
        git.exc.InvalidGitRepositoryError: If not a Git repository
    """
    repo = git.Repo(project_path)

    # Add all changes
    repo.git.add(A=True)

    # Check if there are changes to commit
    if not repo.index.diff("HEAD"):
        raise ValueError("No changes to commit")

    # Commit
    commit = repo.index.commit(message)
    return commit.hexsha


def diff_project(project_path: Path, rev1: str = "HEAD~1", rev2: str = "HEAD") -> str:
    """Get Git diff between two revisions.

    Args:
        project_path: Path to the project directory
        rev1: First revision (default: HEAD~1)
        rev2: Second revision (default: HEAD)

    Returns:
        Unified diff as string

    Raises:
        git.exc.InvalidGitRepositoryError: If not a Git repository
        git.exc.GitCommandError: If revision doesn't exist
    """
    repo = git.Repo(project_path)
    return repo.git.diff(rev1, rev2)


def delete_project(project_path: Path) -> None:
    """Delete a project directory and all its contents.

    Args:
        project_path: Path to the project directory

    Raises:
        FileNotFoundError: If project doesn't exist
        PermissionError: If unable to delete files
    """
    if not project_path.exists():
        raise FileNotFoundError(f"Project not found: {project_path}")

    shutil.rmtree(project_path)
