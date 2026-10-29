"""
Simulation service: compile ST → .sasm, execute simulation, parse watch frames.

Supports two modes:
- Dry-run mode: no plant model, I/O reads return 0
- Twin mode: with plant model, closed-loop simulation
"""
import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class SimulationResult:
    """Simulation result."""
    success: bool
    waveforms: dict[str, list[float]]
    cycles: int
    errors: list[str]
    mode: str  # "dry_run" or "twin"
    plant_file: str | None = None


class SimService:
    """Simulation service."""

    def __init__(
        self,
        sim_binary: str | None = None,
        veristc_binary: str | None = None,
    ):
        self.sim_binary = sim_binary or self._find_sim_binary()
        self.veristc_binary = veristc_binary or self._find_veristc_binary()

    def _find_sim_binary(self) -> str:
        """Find sim binary."""
        paths = [
            Path(__file__).parent.parent.parent.parent.parent / "build" / "bin" / "sim",
            Path("/home/wei/veristc/build/bin/sim"),
        ]
        for p in paths:
            if p.exists():
                return str(p)
        return "sim"

    def _find_veristc_binary(self) -> str:
        """Find veristc binary."""
        paths = [
            Path(__file__).parent.parent.parent.parent.parent / "build" / "bin" / "veristc",
            Path("/home/wei/veristc/build/bin/veristc"),
        ]
        for p in paths:
            if p.exists():
                return str(p)
        return "veristc"

    def run_simulation(
        self,
        st_code: str,
        cycles: int,
        watch_vars: list[str],
        plant_file: str | None = None,
        cycle_time_ms: int = 100,
    ) -> SimulationResult:
        """
        Run simulation.

        Args:
            st_code: ST code
            cycles: Number of cycles
            watch_vars: Variables to watch
            plant_file: .plant file path (twin mode)
            cycle_time_ms: Virtual cycle time in milliseconds

        Returns:
            SimulationResult with waveforms
        """
        errors = []
        mode = "twin" if plant_file else "dry_run"

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            # Write ST code
            st_file = tmpdir_path / "program.st"
            with open(st_file, "w") as f:
                f.write(st_code)

            # Compile ST → .sasm
            sasm_file = tmpdir_path / "program.sasm"
            compile_result = self._compile_st(st_file, sasm_file)
            if not compile_result["success"]:
                errors.extend(compile_result["errors"])
                return SimulationResult(
                    success=False,
                    waveforms={},
                    cycles=0,
                    errors=errors,
                    mode=mode,
                    plant_file=plant_file,
                )

            # Build sim command
            cmd = [
                self.sim_binary,
                "-n", str(cycles),
                "-t", str(cycle_time_ms),
            ]

            if watch_vars:
                cmd.extend(["--watch", ",".join(watch_vars)])

            cmd.append(str(sasm_file))

            if plant_file:
                cmd.append(plant_file)

            # Run simulation
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

                if result.returncode != 0:
                    errors.append(f"Simulation failed (exit {result.returncode})")
                    if result.stderr:
                        errors.append(result.stderr.strip())
                    return SimulationResult(
                        success=False,
                        waveforms={},
                        cycles=0,
                        errors=errors,
                        mode=mode,
                        plant_file=plant_file,
                    )

                # Parse watch frames (JSONL)
                waveforms = self._parse_watch_frames(result.stdout, watch_vars)

                return SimulationResult(
                    success=True,
                    waveforms=waveforms,
                    cycles=cycles,
                    errors=[],
                    mode=mode,
                    plant_file=plant_file,
                )

            except subprocess.TimeoutExpired:
                errors.append("Simulation timeout")
                return SimulationResult(
                    success=False,
                    waveforms={},
                    cycles=0,
                    errors=errors,
                    mode=mode,
                    plant_file=plant_file,
                )
            except FileNotFoundError:
                errors.append(f"sim binary not found: {self.sim_binary}")
                return SimulationResult(
                    success=False,
                    waveforms={},
                    cycles=0,
                    errors=errors,
                    mode=mode,
                    plant_file=plant_file,
                )

    def _compile_st(
        self,
        st_file: Path,
        sasm_file: Path,
    ) -> dict[str, Any]:
        """
        Compile ST to .sasm.

        Args:
            st_file: Input .st file
            sasm_file: Output .sasm file

        Returns:
            Dict with 'success' and 'errors' keys
        """
        cmd = [
            self.veristc_binary,
            "-c", str(st_file),
            "-o", str(sasm_file),
        ]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
            )

            if result.returncode != 0:
                errors = [f"Compilation failed (exit {result.returncode})"]
                if result.stderr:
                    errors.append(result.stderr.strip())
                return {"success": False, "errors": errors}

            return {"success": True, "errors": []}

        except subprocess.TimeoutExpired:
            return {"success": False, "errors": ["Compilation timeout"]}
        except FileNotFoundError:
            return {
                "success": False,
                "errors": [f"veristc binary not found: {self.veristc_binary}"],
            }

    def _parse_watch_frames(
        self,
        output: str,
        watch_vars: list[str],
    ) -> dict[str, list[float]]:
        """
        Parse watch frames from JSONL output.

        Args:
            output: JSONL output from sim
            watch_vars: Variables to extract

        Returns:
            Variable name → value sequence
        """
        waveforms: dict[str, list[float]] = {var: [] for var in watch_vars}

        for line in output.strip().split("\n"):
            if not line.strip():
                continue

            # Only process lines starting with {"frame":
            if not line.startswith('{"frame":'):
                continue

            try:
                frame = json.loads(line)

                # Only process cycle frames
                if frame.get("frame") != "cycle":
                    continue

                # Extract variable values
                # Format: values is an array of {name, addr, type, size, value, channel, raw}
                values = frame.get("values", [])
                for item in values:
                    name = item.get("name")
                    value = item.get("value")
                    if name in watch_vars and value is not None:
                        waveforms[name].append(float(value))

            except json.JSONDecodeError:
                continue

        return waveforms

    def run_dry_simulation(
        self,
        st_code: str,
        cycles: int,
        watch_vars: list[str],
    ) -> SimulationResult:
        """
        Run dry-run simulation (no plant model).

        Args:
            st_code: ST code
            cycles: Number of cycles
            watch_vars: Variables to watch

        Returns:
            SimulationResult with waveforms
        """
        return self.run_simulation(
            st_code=st_code,
            cycles=cycles,
            watch_vars=watch_vars,
            plant_file=None,
        )

    def run_twin_simulation(
        self,
        st_code: str,
        cycles: int,
        watch_vars: list[str],
        plant_file: str | Path,
        cycle_time_ms: int = 100,
    ) -> SimulationResult:
        """
        Run twin-mode simulation (with plant model).

        Args:
            st_code: ST code
            cycles: Number of cycles
            watch_vars: Variables to watch
            plant_file: .plant file path
            cycle_time_ms: Virtual cycle time in milliseconds

        Returns:
            SimulationResult with waveforms
        """
        return self.run_simulation(
            st_code=st_code,
            cycles=cycles,
            watch_vars=watch_vars,
            plant_file=str(plant_file),
            cycle_time_ms=cycle_time_ms,
        )
