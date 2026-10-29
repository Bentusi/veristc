"""Tests for simulation service."""
import pytest
from veri_ide.backend.sim.service import SimService, SimulationResult


@pytest.fixture
def sim_service():
    """Create SimService instance."""
    return SimService(sim_binary="/home/wei/veristc/build/bin/sim")


def test_sim_service_init():
    """SimService initializes correctly."""
    service = SimService(sim_binary="/usr/bin/sim")
    assert service.sim_binary == "/usr/bin/sim"


def test_parse_watch_frames_empty():
    """Parse empty watch frames."""
    service = SimService()
    result = service._parse_watch_frames("", ["var1", "var2"])
    assert result == {"var1": [], "var2": []}


def test_parse_watch_frames_single():
    """Parse single watch frame."""
    # New format: values is an array of {name, value, ...}
    output = '{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":10.5,"channel":null,"raw":null},{"name":"var2","addr":104,"type":"DINT","size":4,"value":20.3,"channel":null,"raw":null}]}'
    service = SimService()
    result = service._parse_watch_frames(output, ["var1", "var2"])
    assert result == {"var1": [10.5], "var2": [20.3]}


def test_parse_watch_frames_multiple():
    """Parse multiple watch frames."""
    output = """{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":10.5,"channel":null,"raw":null}]}
{"frame":"cycle","cycle":2,"t_ms":200,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":20.3,"channel":null,"raw":null}]}
{"frame":"cycle","cycle":3,"t_ms":300,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":30.1,"channel":null,"raw":null}]}"""
    service = SimService()
    result = service._parse_watch_frames(output, ["var1"])
    assert result == {"var1": [10.5, 20.3, 30.1]}


def test_parse_watch_frames_skip_non_cycle():
    """Skip non-cycle frames."""
    output = """{"frame":"status","cycle":0,"t_ms":0,"status":0,"violations":0,"values":[]}
{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":10.5,"channel":null,"raw":null}]}
{"frame":"done","cycles":1,"t_ms":100,"violations":0,"read_errors":0,"write_errors":0}"""
    service = SimService()
    result = service._parse_watch_frames(output, ["var1"])
    assert result == {"var1": [10.5]}


def test_parse_watch_frames_malformed():
    """Handle malformed JSON."""
    output = '{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":10.5,"channel":null,"raw":null}]}\n{invalid json}'
    service = SimService()
    result = service._parse_watch_frames(output, ["var1"])
    assert result == {"var1": [10.5]}


def test_parse_watch_frames_missing_var():
    """Handle missing variable."""
    output = '{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":10.5,"channel":null,"raw":null}]}'
    service = SimService()
    result = service._parse_watch_frames(output, ["var1", "var2"])
    assert result == {"var1": [10.5], "var2": []}


def test_parse_watch_frames_skip_null_values():
    """Skip null values."""
    output = '{"frame":"cycle","cycle":1,"t_ms":100,"status":0,"violations":0,"values":[{"name":"var1","addr":100,"type":"DINT","size":4,"value":null,"channel":null,"raw":null}]}'
    service = SimService()
    result = service._parse_watch_frames(output, ["var1"])
    assert result == {"var1": []}


def test_simulation_result_dataclass():
    """SimulationResult dataclass works correctly."""
    result = SimulationResult(
        success=True,
        waveforms={"var1": [1.0, 2.0, 3.0]},
        cycles=3,
        errors=[],
        mode="dry_run",
        plant_file=None,
    )
    assert result.success is True
    assert result.waveforms == {"var1": [1.0, 2.0, 3.0]}
    assert result.cycles == 3
    assert result.errors == []
    assert result.mode == "dry_run"
    assert result.plant_file is None


def test_simulation_result_failure():
    """SimulationResult failure case."""
    result = SimulationResult(
        success=False,
        waveforms={},
        cycles=0,
        errors=["Simulation failed"],
        mode="dry_run",
        plant_file=None,
    )
    assert result.success is False
    assert len(result.errors) == 1


def test_simulation_result_twin_mode():
    """SimulationResult twin mode case."""
    result = SimulationResult(
        success=True,
        waveforms={"var1": [1.0, 2.0, 3.0]},
        cycles=3,
        errors=[],
        mode="twin",
        plant_file="/path/to/plant.plant",
    )
    assert result.mode == "twin"
    assert result.plant_file == "/path/to/plant.plant"


def test_find_sim_binary_not_found():
    """Find sim binary returns default when not found."""
    service = SimService(sim_binary="/nonexistent/sim")
    assert service.sim_binary == "/nonexistent/sim"
