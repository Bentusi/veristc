"""Tests for baseline management and deviation detection."""
import pytest
import tempfile
from pathlib import Path

from veri_ide.backend.sim.baseline import BaselineManager, Baseline


@pytest.fixture
def baseline_manager():
    """Create BaselineManager with temp directory."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield BaselineManager(tmpdir)


@pytest.fixture
def sample_baseline():
    """Sample baseline data."""
    return {
        "var1": [10.0, 20.0, 30.0, 40.0, 50.0],
        "var2": [100.0, 90.0, 80.0, 70.0, 60.0],
    }


def test_save_baseline(baseline_manager, sample_baseline):
    """Save baseline to file."""
    baseline = baseline_manager.save_baseline(
        name="test_baseline",
        cycles=5,
        variables=sample_baseline,
        description="Test baseline",
    )

    assert baseline.name == "test_baseline"
    assert baseline.cycles == 5
    assert baseline.variables == sample_baseline
    assert baseline.description == "Test baseline"

    # Verify file exists
    baseline_file = baseline_manager.baseline_dir / "test_baseline.json"
    assert baseline_file.exists()


def test_load_baseline(baseline_manager, sample_baseline):
    """Load baseline from file."""
    baseline_manager.save_baseline(
        name="test_baseline",
        cycles=5,
        variables=sample_baseline,
    )

    loaded = baseline_manager.load_baseline("test_baseline")
    assert loaded is not None
    assert loaded.name == "test_baseline"
    assert loaded.cycles == 5
    assert loaded.variables == sample_baseline


def test_load_baseline_not_found(baseline_manager):
    """Load non-existent baseline."""
    loaded = baseline_manager.load_baseline("nonexistent")
    assert loaded is None


def test_delete_baseline(baseline_manager, sample_baseline):
    """Delete baseline."""
    baseline_manager.save_baseline(
        name="test_baseline",
        cycles=5,
        variables=sample_baseline,
    )

    deleted = baseline_manager.delete_baseline("test_baseline")
    assert deleted is True

    # Verify file deleted
    loaded = baseline_manager.load_baseline("test_baseline")
    assert loaded is None


def test_delete_baseline_not_found(baseline_manager):
    """Delete non-existent baseline."""
    deleted = baseline_manager.delete_baseline("nonexistent")
    assert deleted is False


def test_list_baselines(baseline_manager, sample_baseline):
    """List all baselines."""
    baseline_manager.save_baseline("baseline1", 5, sample_baseline)
    baseline_manager.save_baseline("baseline2", 5, sample_baseline)
    baseline_manager.save_baseline("baseline3", 5, sample_baseline)

    baselines = baseline_manager.list_baselines()
    assert len(baselines) == 3
    assert "baseline1" in baselines
    assert "baseline2" in baselines
    assert "baseline3" in baselines


def test_list_baselines_empty(baseline_manager):
    """List baselines when empty."""
    baselines = baseline_manager.list_baselines()
    assert baselines == []


def test_compute_deviation(baseline_manager):
    """Compute deviation between current and baseline."""
    current = {
        "var1": [10.0, 22.0, 28.0, 42.0, 50.0],
        "var2": [100.0, 88.0, 82.0, 68.0, 60.0],
    }
    baseline = {
        "var1": [10.0, 20.0, 30.0, 40.0, 50.0],
        "var2": [100.0, 90.0, 80.0, 70.0, 60.0],
    }

    deviations = baseline_manager.compute_deviation(current, baseline)

    assert deviations["var1"] == [0.0, 2.0, 2.0, 2.0, 0.0]
    assert deviations["var2"] == [0.0, 2.0, 2.0, 2.0, 0.0]


def test_compute_deviation_missing_var(baseline_manager):
    """Compute deviation with missing variable."""
    current = {
        "var1": [10.0, 20.0],
        "var2": [100.0, 90.0],
    }
    baseline = {
        "var1": [10.0, 20.0],
    }

    deviations = baseline_manager.compute_deviation(current, baseline)

    assert "var1" in deviations
    assert "var2" not in deviations


def test_find_max_deviation(baseline_manager):
    """Find maximum deviation per variable."""
    deviations = {
        "var1": [0.0, 2.0, 5.0, 2.0, 0.0],
        "var2": [0.0, 1.0, 1.0, 3.0, 0.0],
    }

    max_deviations = baseline_manager.find_max_deviation(deviations)

    assert max_deviations["var1"] == (2, 5.0)
    assert max_deviations["var2"] == (3, 3.0)


def test_find_max_deviation_empty(baseline_manager):
    """Find max deviation with empty data."""
    deviations = {}
    max_deviations = baseline_manager.find_max_deviation(deviations)
    assert max_deviations == {}


def test_check_threshold(baseline_manager):
    """Check if deviations exceed threshold."""
    deviations = {
        "var1": [0.0, 2.0, 5.0, 2.0, 0.0],
        "var2": [0.0, 1.0, 1.0, 3.0, 0.0],
    }

    exceeds = baseline_manager.check_threshold(deviations, threshold=2.5)

    assert exceeds["var1"] == [False, False, True, False, False]
    assert exceeds["var2"] == [False, False, False, True, False]


def test_check_threshold_zero(baseline_manager):
    """Check threshold with zero (strict match)."""
    deviations = {
        "var1": [0.0, 0.1, 0.0],
    }

    exceeds = baseline_manager.check_threshold(deviations, threshold=0.0)

    assert exceeds["var1"] == [False, True, False]


def test_baseline_dataclass():
    """Baseline dataclass works correctly."""
    baseline = Baseline(
        name="test",
        cycles=10,
        variables={"var1": [1.0, 2.0]},
        created="2026-10-29T10:00:00",
        description="Test baseline",
    )

    assert baseline.name == "test"
    assert baseline.cycles == 10
    assert baseline.variables == {"var1": [1.0, 2.0]}
    assert baseline.description == "Test baseline"
