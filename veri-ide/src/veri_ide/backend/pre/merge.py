"""PRE (Preprocessor) merge logic for VeriIDE.

First version: simple file concatenation in the order specified by project.yaml.
No namespace mangling (PRE-4) in this version.
"""

from pathlib import Path


def pre_merge(project_path: Path, logic_files: list[str]) -> str:
    """Merge multiple ST source files into a single file.

    Args:
        project_path: Path to the project directory
        logic_files: Ordered list of filenames in logic/ directory

    Returns:
        Concatenated source code as a string

    Raises:
        FileNotFoundError: If any logic file doesn't exist
    """
    merged_parts = []
    logic_dir = project_path / "logic"

    for filename in logic_files:
        file_path = logic_dir / filename
        if not file_path.exists():
            raise FileNotFoundError(f"Logic file not found: {file_path}")

        with open(file_path, encoding="utf-8") as f:
            content = f.read()

        # Add file header comment for traceability
        merged_parts.append(f"(* Source: {filename} *)")
        merged_parts.append(content)
        merged_parts.append("")  # Blank line separator

    return "\n".join(merged_parts)


def write_merged_file(project_path: Path, logic_files: list[str]) -> Path:
    """Merge logic files and write to build/merged.st.

    Args:
        project_path: Path to the project directory
        logic_files: Ordered list of filenames in logic/ directory

    Returns:
        Path to the generated merged.st file
    """
    merged_content = pre_merge(project_path, logic_files)

    build_dir = project_path / "build"
    build_dir.mkdir(exist_ok=True)

    merged_path = build_dir / "merged.st"
    with open(merged_path, "w", encoding="utf-8") as f:
        f.write(merged_content)

    return merged_path
