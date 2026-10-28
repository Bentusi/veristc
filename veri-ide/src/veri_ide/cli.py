#!/usr/bin/env python3
"""VeriIDE command-line interface."""

import sys
from pathlib import Path

import click

from veri_ide.backend.project.service import create_project, open_project, list_projects, commit_project
from veri_ide.backend.build.service import build_project


@click.group()
def cli():
    """VeriIDE — Verified Integrated Development Environment."""
    pass


@cli.command()
@click.argument("name")
@click.option("--path", "-p", type=click.Path(path_type=Path), default=".",
              help="Directory where the project will be created")
@click.option("--safety-level", "-s", type=click.Choice(["SIL1", "SIL2", "SIL3"]),
              default="SIL2", help="IEC 61508 safety level")
def create(name: str, path: Path, safety_level: str):
    """Create a new VeriIDE project."""
    project_path = path / name
    try:
        meta = create_project(name, project_path, safety_level=safety_level)
        click.echo(f"Created project '{meta.name}' at {meta.path}")
        click.echo(f"  Safety level: {meta.safety_level}")
        click.echo(f"  SVM version: {meta.svm_version}")
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("project_path", type=click.Path(exists=True, path_type=Path))
def info(project_path: Path):
    """Show project information."""
    try:
        meta = open_project(project_path)
        click.echo(f"Project: {meta.name}")
        click.echo(f"  Path: {meta.path}")
        click.echo(f"  Safety level: {meta.safety_level}")
        click.echo(f"  SVM version: {meta.svm_version}")
        click.echo(f"  Logic files: {', '.join(meta.logic_files) if meta.logic_files else '(none)'}")
        if meta.description:
            click.echo(f"  Description: {meta.description}")
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("base_path", type=click.Path(exists=True, path_type=Path), default=".")
def ls(base_path: Path):
    """List projects in a directory."""
    projects = list_projects(base_path)
    if not projects:
        click.echo("No projects found.")
        return

    for meta in projects:
        click.echo(f"{meta.name} ({meta.safety_level})")


@cli.command()
@click.argument("project_path", type=click.Path(exists=True, path_type=Path))
@click.option("--veristc", "-v", type=click.Path(path_type=Path),
              help="Path to veristc binary (auto-detected if not specified)")
def build(project_path: Path, veristc: Path):
    """Build a project to SafeASM."""
    click.echo(f"Building project at {project_path}...")

    result = build_project(project_path, veristc_path=veristc)

    if result.success:
        click.echo(f"✓ Build successful")
        click.echo(f"  Output: {result.sasm_path}")
        click.echo(f"  Merged ST: {result.merged_st_path}")
    else:
        click.echo(f"✗ Build failed (exit code {result.exit_code})")
        for diag in result.diagnostics:
            severity = diag.severity.upper()
            loc = f" at {diag.loc}" if diag.loc else ""
            click.echo(f"  [{severity}] {diag.message}{loc}")
        sys.exit(result.exit_code)


@cli.command()
@click.argument("project_path", type=click.Path(exists=True, path_type=Path))
@click.argument("message")
def commit(project_path: Path, message: str):
    """Commit project changes to Git."""
    try:
        commit_hash = commit_project(project_path, message)
        click.echo(f"Committed: {commit_hash[:8]}")
        click.echo(f"  Message: {message}")
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.option("--host", "-h", default="127.0.0.1", help="Host to bind to")
@click.option("--port", "-p", default=8000, type=int, help="Port to bind to")
@click.option("--editor/--no-editor", default=True, help="Also serve the web editor")
def watch(host: str, port: int, editor: bool):
    """Start the VeriIDE backend API server."""
    from veri_ide.api.server import run_server
    
    click.echo(f"Starting VeriIDE API server on http://{host}:{port}")
    if editor:
        click.echo(f"Web editor available at http://{host}:{port + 1}")
        click.echo("  (Start a separate HTTP server for the frontend)")
    
    try:
        run_server(host=host, port=port)
    except KeyboardInterrupt:
        click.echo("\nServer stopped")
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


if __name__ == "__main__":
    cli()
