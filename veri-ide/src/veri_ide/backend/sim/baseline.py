"""
Baseline management: save, load, compare baselines.
"""
import json
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass
class Baseline:
    """Baseline data."""
    name: str
    cycles: int
    variables: dict[str, list[float]]
    created: str
    description: str = ""


class BaselineManager:
    """Baseline management service."""

    def __init__(self, baseline_dir: str | Path):
        self.baseline_dir = Path(baseline_dir)
        self.baseline_dir.mkdir(parents=True, exist_ok=True)

    def save_baseline(
        self,
        name: str,
        cycles: int,
        variables: dict[str, list[float]],
        description: str = "",
    ) -> Baseline:
        """
        Save baseline.

        Args:
            name: Baseline name
            cycles: Number of cycles
            variables: Variable waveforms
            description: Optional description

        Returns:
            Saved Baseline object
        """
        baseline = Baseline(
            name=name,
            cycles=cycles,
            variables=variables,
            created=datetime.now().isoformat(),
            description=description,
        )

        baseline_file = self.baseline_dir / f"{name}.json"
        with open(baseline_file, "w") as f:
            json.dump(asdict(baseline), f, indent=2)

        return baseline

    def load_baseline(self, name: str) -> Baseline | None:
        """
        Load baseline.

        Args:
            name: Baseline name

        Returns:
            Baseline object or None if not found
        """
        baseline_file = self.baseline_dir / f"{name}.json"
        if not baseline_file.exists():
            return None

        with open(baseline_file, "r") as f:
            data = json.load(f)

        return Baseline(**data)

    def delete_baseline(self, name: str) -> bool:
        """
        Delete baseline.

        Args:
            name: Baseline name

        Returns:
            True if deleted, False if not found
        """
        baseline_file = self.baseline_dir / f"{name}.json"
        if not baseline_file.exists():
            return False

        baseline_file.unlink()
        return True

    def list_baselines(self) -> list[str]:
        """
        List all baseline names.

        Returns:
            List of baseline names
        """
        return [
            f.stem for f in self.baseline_dir.glob("*.json")
            if f.is_file()
        ]

    def compute_deviation(
        self,
        current: dict[str, list[float]],
        baseline: dict[str, list[float]],
    ) -> dict[str, list[float]]:
        """
        Compute deviation between current and baseline.

        Args:
            current: Current waveforms
            baseline: Baseline waveforms

        Returns:
            Deviation per variable per cycle
        """
        deviations = {}

        for var_name in current:
            if var_name not in baseline:
                continue

            current_vals = current[var_name]
            baseline_vals = baseline[var_name]

            # Compute absolute deviation per cycle
            deviation = [
                abs(c - b) for c, b in zip(current_vals, baseline_vals)
            ]
            deviations[var_name] = deviation

        return deviations

    def find_max_deviation(
        self,
        deviations: dict[str, list[float]],
    ) -> dict[str, tuple[int, float]]:
        """
        Find maximum deviation per variable.

        Args:
            deviations: Deviation per variable per cycle

        Returns:
            Variable → (cycle_index, max_deviation)
        """
        max_deviations = {}

        for var_name, deviation in deviations.items():
            if not deviation:
                continue

            max_idx = max(range(len(deviation)), key=lambda i: deviation[i])
            max_deviations[var_name] = (max_idx, deviation[max_idx])

        return max_deviations

    def check_threshold(
        self,
        deviations: dict[str, list[float]],
        threshold: float,
    ) -> dict[str, list[bool]]:
        """
        Check if deviations exceed threshold.

        Args:
            deviations: Deviation per variable per cycle
            threshold: Deviation threshold

        Returns:
            Variable → list of booleans (True if exceeds threshold)
        """
        exceeds = {}

        for var_name, deviation in deviations.items():
            exceeds[var_name] = [d > threshold for d in deviation]

        return exceeds
