"""Schema validation helpers for VeriIDE project files."""

import json
import tomllib
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft7Validator, ValidationError


_SCHEMA_DIR = Path(__file__).parent.parent.parent / "schema"


def _load_schema(name: str) -> dict[str, Any]:
    """Load a JSON schema from the schema/ directory."""
    schema_path = _SCHEMA_DIR / name
    with open(schema_path, encoding="utf-8") as f:
        return json.load(f)


def validate_project_yaml(project_path: Path) -> dict[str, Any]:
    """Validate project.yaml against the project schema.

    Args:
        project_path: Path to the project directory containing project.yaml

    Returns:
        Parsed project metadata dict

    Raises:
        ValidationError: If the file fails schema validation
        FileNotFoundError: If project.yaml doesn't exist
    """
    yaml_path = project_path / "project.yaml"
    if not yaml_path.exists():
        raise FileNotFoundError(f"project.yaml not found in {project_path}")

    with open(yaml_path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    schema = _load_schema("project.schema.json")
    validator = Draft7Validator(schema)
    validator.validate(data)

    return data


def validate_iomap_toml(iomap_path: Path) -> dict[str, Any]:
    """Validate an iomap/*.toml file against the iomap schema.

    Args:
        iomap_path: Path to the TOML file

    Returns:
        Parsed iomap dict

    Raises:
        ValidationError: If the file fails schema validation
        FileNotFoundError: If the file doesn't exist
    """
    if not iomap_path.exists():
        raise FileNotFoundError(f"IOMAP file not found: {iomap_path}")

    with open(iomap_path, "rb") as f:
        data = tomllib.load(f)

    schema = _load_schema("iomap.schema.json")
    validator = Draft7Validator(schema)
    validator.validate(data)

    return data


def validate_lib_lock_yaml(lock_path: Path) -> list[dict[str, Any]]:
    """Validate lib.lock.yaml against the library lock schema.

    Args:
        lock_path: Path to the lib.lock.yaml file

    Returns:
        Parsed library lock list

    Raises:
        ValidationError: If the file fails schema validation
        FileNotFoundError: If the file doesn't exist
    """
    if not lock_path.exists():
        raise FileNotFoundError(f"lib.lock.yaml not found: {lock_path}")

    with open(lock_path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    schema = _load_schema("lib.lock.schema.json")
    validator = Draft7Validator(schema)
    validator.validate(data)

    return data


def validate_project(project_path: Path) -> dict[str, Any]:
    """Validate all project files against their schemas.

    Args:
        project_path: Path to the project directory

    Returns:
        Dict with keys: project, iomaps, lib_lock

    Raises:
        ValidationError: If any file fails schema validation
    """
    result = {
        "project": validate_project_yaml(project_path),
        "iomaps": {},
        "lib_lock": None,
    }

    # Validate iomap files
    iomap_dir = project_path / "iomap"
    if iomap_dir.exists():
        for toml_file in iomap_dir.glob("*.toml"):
            result["iomaps"][toml_file.stem] = validate_iomap_toml(toml_file)

    # Validate lib.lock.yaml if present
    lock_file = project_path / "lib.lock.yaml"
    if lock_file.exists():
        result["lib_lock"] = validate_lib_lock_yaml(lock_file)

    return result
