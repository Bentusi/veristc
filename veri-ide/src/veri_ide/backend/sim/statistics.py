"""
Statistics module for waveform analysis.

Computes mean, variance, peak, settling time, rise time, etc.
"""
import math
from dataclasses import dataclass
from typing import Any


@dataclass
class WaveformStats:
    """Statistics for a single waveform."""
    name: str
    cycles: int
    mean: float
    variance: float
    std_dev: float
    min_val: float
    max_val: float
    peak: float  # max absolute deviation from mean
    final_value: float
    settling_time: int | None  # cycle index where signal settles, None if not settled
    rise_time: int | None  # cycle index where signal rises from 10% to 90%

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary."""
        return {
            "name": self.name,
            "cycles": self.cycles,
            "mean": self.mean,
            "variance": self.variance,
            "std_dev": self.std_dev,
            "min_val": self.min_val,
            "max_val": self.max_val,
            "peak": self.peak,
            "final_value": self.final_value,
            "settling_time": self.settling_time,
            "rise_time": self.rise_time,
        }


class StatisticsService:
    """Service for computing waveform statistics."""

    def __init__(self, settling_threshold: float = 0.02):
        """
        Initialize statistics service.

        Args:
            settling_threshold: Threshold for settling time detection (2% of final value)
        """
        self.settling_threshold = settling_threshold

    def compute_stats(
        self,
        name: str,
        values: list[float],
    ) -> WaveformStats:
        """
        Compute statistics for a waveform.

        Args:
            name: Variable name
            values: List of values per cycle

        Returns:
            WaveformStats
        """
        if not values:
            return WaveformStats(
                name=name,
                cycles=0,
                mean=0.0,
                variance=0.0,
                std_dev=0.0,
                min_val=0.0,
                max_val=0.0,
                peak=0.0,
                final_value=0.0,
                settling_time=None,
                rise_time=None,
            )

        cycles = len(values)
        mean = sum(values) / cycles
        variance = sum((v - mean) ** 2 for v in values) / cycles
        std_dev = math.sqrt(variance)
        min_val = min(values)
        max_val = max(values)
        peak = max(abs(v - mean) for v in values)
        final_value = values[-1]

        settling_time = self._compute_settling_time(values, final_value)
        rise_time = self._compute_rise_time(values, min_val, max_val)

        return WaveformStats(
            name=name,
            cycles=cycles,
            mean=mean,
            variance=variance,
            std_dev=std_dev,
            min_val=min_val,
            max_val=max_val,
            peak=peak,
            final_value=final_value,
            settling_time=settling_time,
            rise_time=rise_time,
        )

    def compute_all_stats(
        self,
        waveforms: dict[str, list[float]],
    ) -> dict[str, WaveformStats]:
        """
        Compute statistics for all waveforms.

        Args:
            waveforms: Variable name → value sequence

        Returns:
            Variable name → WaveformStats
        """
        return {
            name: self.compute_stats(name, values)
            for name, values in waveforms.items()
        }

    def _compute_settling_time(
        self,
        values: list[float],
        final_value: float,
    ) -> int | None:
        """
        Compute settling time: first cycle after which signal stays within threshold of final value forever.

        Args:
            values: List of values per cycle
            final_value: Final value to settle around

        Returns:
            Cycle index where settled, or None if not settled
        """
        if not values:
            return None

        threshold = abs(final_value) * self.settling_threshold
        if threshold < 1e-9:
            threshold = self.settling_threshold  # Use absolute threshold for near-zero values

        # Find the first cycle after which ALL subsequent cycles are within threshold
        # This is the standard definition of settling time in control theory
        for settle_idx in range(len(values)):
            # Check if all cycles from settle_idx onwards are within threshold
            all_within = True
            for i in range(settle_idx, len(values)):
                if abs(values[i] - final_value) > threshold:
                    all_within = False
                    break
            
            if all_within:
                return settle_idx

        # Never settled
        return None

    def _compute_rise_time(
        self,
        values: list[float],
        min_val: float,
        max_val: float,
    ) -> int | None:
        """
        Compute rise time: cycle index where signal goes from 10% to 90% of range.

        Args:
            values: List of values per cycle
            min_val: Minimum value
            max_val: Maximum value

        Returns:
            Cycle index where 90% reached after 10%, or None
        """
        if not values or max_val == min_val:
            return None

        range_val = max_val - min_val
        threshold_10 = min_val + 0.1 * range_val
        threshold_90 = min_val + 0.9 * range_val

        # Find first cycle where signal crosses 10%
        cross_10 = None
        for i, v in enumerate(values):
            if v >= threshold_10:
                cross_10 = i
                break

        if cross_10 is None:
            return None

        # Find first cycle after cross_10 where signal crosses 90%
        for i in range(cross_10, len(values)):
            if values[i] >= threshold_90:
                return i

        return None

    def compute_deviation_from_setpoint(
        self,
        values: list[float],
        setpoint: float,
    ) -> dict[str, float]:
        """
        Compute deviation metrics from a setpoint.

        Args:
            values: List of values per cycle
            setpoint: Target setpoint

        Returns:
            Dict with 'mean_error', 'max_error', 'rms_error', 'steady_state_error'
        """
        if not values:
            return {
                "mean_error": 0.0,
                "max_error": 0.0,
                "rms_error": 0.0,
                "steady_state_error": 0.0,
            }

        errors = [abs(v - setpoint) for v in values]
        mean_error = sum(errors) / len(errors)
        max_error = max(errors)
        rms_error = math.sqrt(sum(e ** 2 for e in errors) / len(errors))
        steady_state_error = abs(values[-1] - setpoint)

        return {
            "mean_error": mean_error,
            "max_error": max_error,
            "rms_error": rms_error,
            "steady_state_error": steady_state_error,
        }

    def detect_oscillation(
        self,
        values: list[float],
        threshold: float = 0.1,
    ) -> dict[str, Any]:
        """
        Detect oscillation in a waveform.

        Args:
            values: List of values per cycle
            threshold: Minimum amplitude to count as oscillation

        Returns:
            Dict with 'oscillating', 'period', 'amplitude'
        """
        if len(values) < 4:
            return {"oscillating": False, "period": None, "amplitude": 0.0}

        # Count zero crossings of (value - mean)
        mean = sum(values) / len(values)
        crossings = []
        for i in range(1, len(values)):
            prev_sign = values[i - 1] - mean
            curr_sign = values[i] - mean
            if prev_sign * curr_sign < 0:  # Sign change
                crossings.append(i)

        if len(crossings) < 2:
            return {"oscillating": False, "period": None, "amplitude": 0.0}

        # Compute average period between crossings
        periods = [crossings[i + 1] - crossings[i] for i in range(len(crossings) - 1)]
        avg_period = sum(periods) / len(periods)

        # Compute amplitude (half of peak-to-peak)
        amplitude = (max(values) - min(values)) / 2

        oscillating = amplitude > threshold and len(crossings) >= 2

        return {
            "oscillating": oscillating,
            "period": avg_period * 2 if oscillating else None,  # Full period = 2 half-periods
            "amplitude": amplitude,
        }
