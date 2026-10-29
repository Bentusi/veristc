"""
Tests for deploy service.
"""
import pytest
import tempfile
from pathlib import Path

from veri_ide.backend.deploy.service import DeployService, DeployResult, TargetConfig


class TestTargetConfig:
    """Tests for TargetConfig."""

    def test_create_target_config(self):
        """Test creating target configuration."""
        target = TargetConfig(
            backend="file",
            path="/tmp/test.sasm",
            agent_binary="veristc-agent",
            cycles=10,
            period_ms=100,
            role="active",
            node_id=0,
        )

        assert target.backend == "file"
        assert target.path == "/tmp/test.sasm"
        assert target.cycles == 10

    def test_target_config_defaults(self):
        """Test target configuration defaults."""
        target = TargetConfig(
            backend="pipe",
            path="/tmp/test.sasm",
        )

        assert target.agent_binary == "veristc-agent"
        assert target.cycles == 10
        assert target.period_ms == 100
        assert target.role == "active"
        assert target.node_id == 0


class TestDeployResult:
    """Tests for DeployResult."""

    def test_create_deploy_result(self):
        """Test creating deploy result."""
        result = DeployResult(
            success=True,
            stages=["Stage 1", "Stage 2"],
            status_frames=[],
            errors=[],
        )

        assert result.success is True
        assert len(result.stages) == 2
        assert result.errors == []

    def test_deploy_result_failure(self):
        """Test deploy result failure."""
        result = DeployResult(
            success=False,
            stages=["Stage 1"],
            status_frames=[],
            errors=["Error 1"],
        )

        assert result.success is False
        assert len(result.errors) == 1


class TestDeployService:
    """Tests for DeployService."""

    def test_init_default(self):
        """Test DeployService initialization with default path."""
        service = DeployService()
        assert service.dl_frames_script is not None

    def test_init_custom_path(self):
        """Test DeployService initialization with custom path."""
        service = DeployService(dl_frames_script="/custom/dl_frames.py")
        assert str(service.dl_frames_script) == "/custom/dl_frames.py"

    def test_deploy_sasm_not_found(self):
        """Test deploy with non-existent .sasm file."""
        service = DeployService()
        target = TargetConfig(backend="file", path="/tmp/test.sasm")
        key = b"\x00" * 32

        result = service.deploy("/nonexistent.sasm", target, key)

        assert not result.success
        assert any("not found" in e for e in result.errors)

    def test_deploy_invalid_key_length(self):
        """Test deploy with invalid key length."""
        service = DeployService()
        target = TargetConfig(backend="file", path="/tmp/test.sasm")
        key = b"\x00" * 16  # Wrong length

        result = service.deploy("/tmp/test.sasm", target, key)

        assert not result.success
        assert any("Invalid key length" in e for e in result.errors)

    def test_parse_status_frames_empty(self):
        """Test parsing empty status frames."""
        service = DeployService()
        frames = service._parse_status_frames("")
        assert frames == []

    def test_parse_status_frames_single(self):
        """Test parsing single status frame."""
        service = DeployService()
        output = '{"frame":"status","event":"start","role":"active","node":0,"version":1,"cycle":0}'
        frames = service._parse_status_frames(output)

        assert len(frames) == 1
        assert frames[0]["event"] == "start"

    def test_parse_status_frames_multiple(self):
        """Test parsing multiple status frames."""
        service = DeployService()
        output = """{"frame":"status","event":"start","role":"active","node":0,"version":1,"cycle":0}
{"frame":"status","event":"download_begin","role":"active","node":0,"version":1,"cycle":0}
{"frame":"status","event":"download_staged","role":"active","node":0,"version":1,"cycle":0,"staged":1,"bytes":1024}
{"frame":"status","event":"switch","role":"active","node":0,"version":1,"cycle":1,"from":0,"to":1}
{"frame":"status","event":"health_ok","role":"active","node":0,"version":1,"cycle":4}
{"frame":"status","event":"end","role":"active","node":0,"version":1,"cycle":10,"ran":10,"switches":1,"rollbacks":0}"""

        frames = service._parse_status_frames(output)

        assert len(frames) == 6
        events = [f["event"] for f in frames]
        assert "start" in events
        assert "download_begin" in events
        assert "download_staged" in events
        assert "switch" in events
        assert "health_ok" in events
        assert "end" in events

    def test_parse_status_frames_skip_non_status(self):
        """Test skipping non-status frames."""
        service = DeployService()
        output = """{"frame":"cycle","cycle":1,"t_ms":100}
{"frame":"status","event":"start","role":"active","node":0,"version":1,"cycle":0}
{"frame":"done","cycles":10}"""

        frames = service._parse_status_frames(output)

        assert len(frames) == 1
        assert frames[0]["event"] == "start"

    def test_parse_status_frames_malformed(self):
        """Test handling malformed JSON."""
        service = DeployService()
        output = """{"frame":"status","event":"start","role":"active","node":0,"version":1,"cycle":0}
{invalid json}"""

        frames = service._parse_status_frames(output)

        assert len(frames) == 1
