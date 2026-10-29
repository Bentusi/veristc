"""
Deploy service: send .sasm files to target via download frame protocol.

Calls dl_frames.py to generate frame stream, then sends via pipe/file to target.
"""
import json
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class TargetConfig:
    """Target configuration for deployment."""
    backend: str  # "pipe" or "file"
    path: str  # pipe path or file path
    agent_binary: str = "veristc-agent"
    cycles: int = 10
    period_ms: int = 100
    role: str = "active"
    node_id: int = 0


@dataclass
class DeployResult:
    """Deployment result."""
    success: bool = False
    stages: list[str] = field(default_factory=list)
    status_frames: list[dict[str, Any]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    target: TargetConfig | None = None


class DeployService:
    """Service for deploying .sasm files to targets."""

    def __init__(
        self,
        dl_frames_script: str | Path | None = None,
    ):
        """
        Initialize deploy service.

        Args:
            dl_frames_script: Path to dl_frames.py (default: integration/dl_frames.py)
        """
        if dl_frames_script:
            self.dl_frames_script = Path(dl_frames_script)
        else:
            # Default path relative to this file
            self.dl_frames_script = (
                Path(__file__).parent.parent.parent.parent.parent
                / "integration"
                / "dl_frames.py"
            )

    def deploy(
        self,
        sasm_file: str | Path,
        target: TargetConfig,
        key: bytes,
        download_at: int = 1,
        health_cycles: int = 3,
    ) -> DeployResult:
        """
        Deploy a .sasm file to a target.

        Args:
            sasm_file: Path to .sasm file
            target: Target configuration
            key: 32-byte HMAC key
            download_at: Cycle number to apply switch
            health_cycles: Number of health check cycles

        Returns:
            DeployResult with progress and status
        """
        result = DeployResult(target=target)
        sasm_path = Path(sasm_file)

        if len(key) != 32:
            result.errors.append(f"Invalid key length: {len(key)} bytes (expected 32)")
            return result

        if not sasm_path.exists():
            result.errors.append(f".sasm file not found: {sasm_file}")
            return result

        key_hex = key.hex()

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            # Stage 1: Generate frame stream
            result.stages.append("Generating frame stream")
            frames_file = tmpdir_path / "frames.bin"
            gen_result = self._generate_frames(
                sasm_path, frames_file, key_hex
            )
            if not gen_result["success"]:
                result.errors.extend(gen_result["errors"])
                return result

            # Stage 2: Send frames to target
            result.stages.append("Sending frames to target")
            if target.backend == "file":
                send_result = self._send_via_file(
                    frames_file, target, key_hex, download_at, health_cycles
                )
            else:  # pipe
                send_result = self._send_via_pipe(
                    frames_file, target, key_hex, download_at, health_cycles
                )

            if not send_result["success"]:
                result.errors.extend(send_result["errors"])
                return result

            # Stage 3: Parse status frames
            result.stages.append("Parsing status frames")
            status_frames = self._parse_status_frames(send_result.get("output", ""))
            result.status_frames = status_frames

            # Check for errors in status frames
            for frame in status_frames:
                event = frame.get("event")
                if event in ("download_rejected", "switch_failed", "rollback", "cycle_error"):
                    result.errors.append(f"Agent event: {event}")

            # Determine success
            has_end = any(f.get("event") == "end" for f in status_frames)
            has_switch = any(f.get("event") == "switch" for f in status_frames)
            has_rollback = any(f.get("event") == "rollback" for f in status_frames)

            if has_end and has_switch and not has_rollback:
                result.success = True
                result.stages.append("Deployment successful")
            elif has_rollback:
                result.success = False
                result.stages.append("Deployment rolled back")
            else:
                result.success = False
                result.stages.append("Deployment incomplete")

        return result

    def _generate_frames(
        self,
        sasm_file: Path,
        output_file: Path,
        key_hex: str,
    ) -> dict[str, Any]:
        """
        Generate frame stream using dl_frames.py.

        Args:
            sasm_file: Input .sasm file
            output_file: Output frames file
            key_hex: 64-character hex key

        Returns:
            Dict with 'success' and 'errors' keys
        """
        cmd = [
            "python3",
            str(self.dl_frames_script),
            "--key", key_hex,
            "--image", str(sasm_file),
        ]

        try:
            with open(output_file, "wb") as f:
                result = subprocess.run(
                    cmd,
                    stdout=f,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                )

            if result.returncode != 0:
                errors = [f"Frame generation failed (exit {result.returncode})"]
                if result.stderr:
                    errors.append(result.stderr.strip())
                return {"success": False, "errors": errors}

            return {"success": True, "errors": []}

        except subprocess.TimeoutExpired:
            return {"success": False, "errors": ["Frame generation timeout"]}
        except FileNotFoundError:
            return {
                "success": False,
                "errors": [f"dl_frames.py not found: {self.dl_frames_script}"],
            }

    def _send_via_file(
        self,
        frames_file: Path,
        target: TargetConfig,
        key_hex: str,
        download_at: int,
        health_cycles: int,
    ) -> dict[str, Any]:
        """
        Send frames via file backend.

        Args:
            frames_file: Frames file to send
            target: Target configuration
            key_hex: Hex key
            download_at: Cycle to apply switch
            health_cycles: Health check cycles

        Returns:
            Dict with 'success', 'errors', and 'output' keys
        """
        cmd = [
            target.agent_binary,
            "--key", key_hex,
            "--download-from", str(frames_file),
            "--download-at", str(download_at),
            "--health-cycles", str(health_cycles),
            "--cycles", str(target.cycles),
            "--period-ms", str(target.period_ms),
            "--role", target.role,
            "--node-id", str(target.node_id),
            target.path,  # .sasm file for initial load
        ]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60,
            )

            if result.returncode != 0:
                errors = [f"Agent failed (exit {result.returncode})"]
                if result.stderr:
                    errors.append(result.stderr.strip())
                return {"success": False, "errors": errors, "output": result.stdout}

            return {"success": True, "errors": [], "output": result.stdout}

        except subprocess.TimeoutExpired:
            return {"success": False, "errors": ["Agent timeout"], "output": ""}
        except FileNotFoundError:
            return {
                "success": False,
                "errors": [f"Agent binary not found: {target.agent_binary}"],
                "output": "",
            }

    def _send_via_pipe(
        self,
        frames_file: Path,
        target: TargetConfig,
        key_hex: str,
        download_at: int,
        health_cycles: int,
    ) -> dict[str, Any]:
        """
        Send frames via pipe backend.

        Args:
            frames_file: Frames file to send
            target: Target configuration
            key_hex: Hex key
            download_at: Cycle to apply switch
            health_cycles: Health check cycles

        Returns:
            Dict with 'success', 'errors', and 'output' keys
        """
        # For pipe backend, we cat the frames file to the agent's stdin
        cmd = [
            "cat", str(frames_file), "|",
            target.agent_binary,
            "--key", key_hex,
            "--download-from", "-",
            "--download-at", str(download_at),
            "--health-cycles", str(health_cycles),
            "--cycles", str(target.cycles),
            "--period-ms", str(target.period_ms),
            "--role", target.role,
            "--node-id", str(target.node_id),
            target.path,
        ]

        # Use shell=True for pipe
        try:
            result = subprocess.run(
                " ".join(cmd),
                shell=True,
                capture_output=True,
                text=True,
                timeout=60,
            )

            if result.returncode != 0:
                errors = [f"Agent failed (exit {result.returncode})"]
                if result.stderr:
                    errors.append(result.stderr.strip())
                return {"success": False, "errors": errors, "output": result.stdout}

            return {"success": True, "errors": [], "output": result.stdout}

        except subprocess.TimeoutExpired:
            return {"success": False, "errors": ["Agent timeout"], "output": ""}

    def _parse_status_frames(self, output: str) -> list[dict[str, Any]]:
        """
        Parse agent status frames from JSONL output.

        Args:
            output: Agent stdout output

        Returns:
            List of status frame dicts
        """
        frames = []

        for line in output.strip().split("\n"):
            if not line.strip():
                continue

            # Only process lines starting with {"frame":"status"
            if not line.startswith('{"frame":"status"'):
                continue

            try:
                frame = json.loads(line)
                frames.append(frame)
            except json.JSONDecodeError:
                continue

        return frames
