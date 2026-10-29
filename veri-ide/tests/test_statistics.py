"""
Tests for statistics module.
"""
import pytest
import math

from veri_ide.backend.sim.statistics import (
    StatisticsService,
    WaveformStats,
)


class TestStatisticsService:
    """Tests for StatisticsService."""

    def test_compute_stats_empty(self):
        """Test computing stats for empty waveform."""
        service = StatisticsService()
        stats = service.compute_stats("test", [])

        assert stats.name == "test"
        assert stats.cycles == 0
        assert stats.mean == 0.0

    def test_compute_stats_constant(self):
        """Test computing stats for constant waveform."""
        service = StatisticsService()
        values = [100.0] * 10
        stats = service.compute_stats("const", values)

        assert stats.cycles == 10
        assert stats.mean == 100.0
        assert stats.variance == 0.0
        assert stats.std_dev == 0.0
        assert stats.min_val == 100.0
        assert stats.max_val == 100.0
        assert stats.peak == 0.0
        assert stats.final_value == 100.0

    def test_compute_stats_linear_ramp(self):
        """Test computing stats for linear ramp."""
        service = StatisticsService()
        values = [0.0, 10.0, 20.0, 30.0, 40.0]
        stats = service.compute_stats("ramp", values)

        assert stats.cycles == 5
        assert stats.mean == 20.0  # (0+10+20+30+40)/5
        assert stats.min_val == 0.0
        assert stats.max_val == 40.0
        assert stats.final_value == 40.0

    def test_compute_stats_variance(self):
        """Test variance computation."""
        service = StatisticsService()
        values = [1.0, 2.0, 3.0, 4.0, 5.0]
        stats = service.compute_stats("test", values)

        # Mean = 3.0
        # Variance = ((1-3)^2 + (2-3)^2 + (3-3)^2 + (4-3)^2 + (5-3)^2) / 5
        #          = (4 + 1 + 0 + 1 + 4) / 5 = 2.0
        assert stats.mean == 3.0
        assert abs(stats.variance - 2.0) < 1e-9
        assert abs(stats.std_dev - math.sqrt(2.0)) < 1e-9

    def test_compute_stats_peak(self):
        """Test peak (max deviation from mean) computation."""
        service = StatisticsService()
        values = [10.0, 20.0, 30.0, 20.0, 10.0]
        stats = service.compute_stats("test", values)

        # Mean = 18.0
        # Deviations: 8, 2, 12, 2, 8
        # Peak = 12
        assert stats.mean == 18.0
        assert stats.peak == 12.0

    def test_compute_settling_time_settled(self):
        """Test settling time for signal that settles."""
        service = StatisticsService(settling_threshold=0.02)
        # Signal that settles at 100 after cycle 5
        values = [0.0, 50.0, 80.0, 95.0, 99.0, 100.0, 100.0, 100.0, 100.0, 100.0]
        stats = service.compute_stats("test", values)

        # Final value = 100, threshold = 2% of 100 = 2
        # Signal is within [98, 102] starting from cycle 4 (value 99)
        assert stats.settling_time is not None
        assert stats.settling_time <= 5

    def test_compute_settling_time_not_settled(self):
        """Test settling time for signal that doesn't settle until the end."""
        service = StatisticsService(settling_threshold=0.02)
        # Signal that only settles at the very last cycle
        values = [0.0, 100.0, 0.0, 100.0, 0.0, 100.0, 0.0, 100.0, 0.0, 100.0]
        stats = service.compute_stats("test", values)

        # Final value = 100, threshold = 2.0
        # Signal oscillates between 0 and 100
        # Only the last few values (100) are within [98, 102]
        # Working backwards: last value is 100 (within), second-to-last is 0 (outside)
        # So settling_time = 9 (only the last cycle is within threshold)
        assert stats.settling_time == 9

    def test_compute_rise_time(self):
        """Test rise time computation."""
        service = StatisticsService()
        # Signal that rises from 0 to 100
        values = [0.0, 5.0, 15.0, 30.0, 50.0, 70.0, 85.0, 95.0, 100.0, 100.0]
        stats = service.compute_stats("test", values)

        # 10% threshold = 10, 90% threshold = 90
        # Crosses 10% at cycle 2 (value 15)
        # Crosses 90% at cycle 7 (value 95)
        assert stats.rise_time is not None
        assert stats.rise_time == 7

    def test_compute_all_stats(self):
        """Test computing stats for multiple waveforms."""
        service = StatisticsService()
        waveforms = {
            "var1": [1.0, 2.0, 3.0],
            "var2": [10.0, 20.0, 30.0],
        }

        stats = service.compute_all_stats(waveforms)

        assert "var1" in stats
        assert "var2" in stats
        assert stats["var1"].mean == 2.0
        assert stats["var2"].mean == 20.0

    def test_compute_deviation_from_setpoint(self):
        """Test deviation from setpoint computation."""
        service = StatisticsService()
        values = [90.0, 95.0, 98.0, 99.0, 100.0]
        setpoint = 100.0

        deviation = service.compute_deviation_from_setpoint(values, setpoint)

        # Errors: 10, 5, 2, 1, 0
        assert deviation["mean_error"] == 3.6  # (10+5+2+1+0)/5
        assert deviation["max_error"] == 10.0
        assert deviation["steady_state_error"] == 0.0
        # RMS = sqrt((100+25+4+1+0)/5) = sqrt(26) ≈ 5.099
        assert abs(deviation["rms_error"] - math.sqrt(26)) < 1e-6

    def test_detect_oscillation_not_oscillating(self):
        """Test oscillation detection for non-oscillating signal."""
        service = StatisticsService()
        values = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0]

        result = service.detect_oscillation(values)

        assert result["oscillating"] is False

    def test_detect_oscillation_oscillating(self):
        """Test oscillation detection for oscillating signal."""
        service = StatisticsService()
        # Oscillating around 50
        values = [50.0, 80.0, 50.0, 20.0, 50.0, 80.0, 50.0, 20.0, 50.0, 80.0]

        result = service.detect_oscillation(values, threshold=10.0)

        assert result["oscillating"] is True
        assert result["amplitude"] == 30.0  # (80-20)/2
        assert result["period"] is not None

    def test_detect_oscillation_short_signal(self):
        """Test oscillation detection for short signal."""
        service = StatisticsService()
        values = [1.0, 2.0]

        result = service.detect_oscillation(values)

        assert result["oscillating"] is False

    def test_waveform_stats_to_dict(self):
        """Test converting WaveformStats to dict."""
        stats = WaveformStats(
            name="test",
            cycles=10,
            mean=50.0,
            variance=100.0,
            std_dev=10.0,
            min_val=0.0,
            max_val=100.0,
            peak=50.0,
            final_value=100.0,
            settling_time=5,
            rise_time=3,
        )

        d = stats.to_dict()

        assert d["name"] == "test"
        assert d["cycles"] == 10
        assert d["mean"] == 50.0
        assert d["settling_time"] == 5
        assert d["rise_time"] == 3
