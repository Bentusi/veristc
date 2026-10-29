"""
Plant model management: create, validate, and manage .plant files.

The .plant format is defined in spec/simulation-spec.md §1.
"""
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any
import json


class ChannelDir(str, Enum):
    """Channel direction relative to program."""
    INPUT = "INPUT"
    OUTPUT = "OUTPUT"


class ChannelKind(str, Enum):
    """Channel dynamic model."""
    CONST = "CONST"
    LAG = "LAG"
    RAMP = "RAMP"
    ACTUATOR = "ACTUATOR"


@dataclass
class PlantChannel:
    """Single channel in a plant model."""
    channel_id: int
    dir: ChannelDir
    kind: ChannelKind
    gain: float
    offset: float
    min_val: int
    max_val: int
    init_val: int
    drive: int  # -1 = no drive

    def to_plant_line(self) -> str:
        """Convert to .plant file line."""
        return (
            f"{self.channel_id} {self.dir.value} {self.kind.value} "
            f"{self.gain} {self.offset} {self.min_val} {self.max_val} "
            f"{self.init_val} {self.drive}"
        )

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary."""
        return {
            "channel_id": self.channel_id,
            "dir": self.dir.value,
            "kind": self.kind.value,
            "gain": self.gain,
            "offset": self.offset,
            "min_val": self.min_val,
            "max_val": self.max_val,
            "init_val": self.init_val,
            "drive": self.drive,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PlantChannel":
        """Create from dictionary."""
        return cls(
            channel_id=data["channel_id"],
            dir=ChannelDir(data["dir"]),
            kind=ChannelKind(data["kind"]),
            gain=data["gain"],
            offset=data["offset"],
            min_val=data["min_val"],
            max_val=data["max_val"],
            init_val=data["init_val"],
            drive=data["drive"],
        )


@dataclass
class PlantModel:
    """Plant model with multiple channels."""
    name: str
    channels: list[PlantChannel] = field(default_factory=list)
    description: str = ""

    def to_plant_text(self) -> str:
        """Convert to .plant file text."""
        lines = [f"# Plant model: {self.name}"]
        if self.description:
            lines.append(f"# {self.description}")
        lines.append("#")
        lines.append("# columns: channel dir kind gain offset min max init drive")
        lines.append("")
        for ch in self.channels:
            lines.append(ch.to_plant_line())
        return "\n".join(lines)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary."""
        return {
            "name": self.name,
            "description": self.description,
            "channels": [ch.to_dict() for ch in self.channels],
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PlantModel":
        """Create from dictionary."""
        return cls(
            name=data["name"],
            description=data.get("description", ""),
            channels=[PlantChannel.from_dict(ch) for ch in data.get("channels", [])],
        )


class PlantValidationError(Exception):
    """Raised when plant model validation fails."""
    pass


class PlantService:
    """Service for managing plant models."""

    def __init__(self, storage_dir: str | Path | None = None):
        """
        Initialize plant service.

        Args:
            storage_dir: Directory to store plant models (JSON format)
        """
        if storage_dir:
            self.storage_dir = Path(storage_dir)
            self.storage_dir.mkdir(parents=True, exist_ok=True)
        else:
            self.storage_dir = None

    def parse_plant_file(self, path: str | Path) -> PlantModel:
        """
        Parse a .plant file.

        Args:
            path: Path to .plant file

        Returns:
            PlantModel

        Raises:
            PlantValidationError: If file is malformed
        """
        path = Path(path)
        if not path.exists():
            raise PlantValidationError(f"Plant file not found: {path}")

        with open(path, "r") as f:
            lines = f.readlines()

        return self._parse_plant_lines(lines, path.stem)

    def _parse_plant_lines(self, lines: list[str], name: str) -> PlantModel:
        """Parse plant file lines."""
        channels = []

        for line_no, line in enumerate(lines, 1):
            line = line.strip()

            # Skip empty lines and comments
            if not line or line.startswith("#"):
                continue

            parts = line.split()
            if len(parts) != 9:
                raise PlantValidationError(
                    f"Line {line_no}: expected 9 fields, got {len(parts)}"
                )

            try:
                channel_id = int(parts[0])
                dir_val = ChannelDir(parts[1])
                kind_val = ChannelKind(parts[2])
                gain = float(parts[3])
                offset = float(parts[4])
                min_val = int(parts[5])
                max_val = int(parts[6])
                init_val = int(parts[7])
                drive = int(parts[8])
            except (ValueError, KeyError) as e:
                raise PlantValidationError(
                    f"Line {line_no}: invalid field value: {e}"
                )

            channels.append(PlantChannel(
                channel_id=channel_id,
                dir=dir_val,
                kind=kind_val,
                gain=gain,
                offset=offset,
                min_val=min_val,
                max_val=max_val,
                init_val=init_val,
                drive=drive,
            ))

        return PlantModel(name=name, channels=channels)

    def validate_plant_model(self, model: PlantModel) -> list[str]:
        """
        Validate a plant model against .plant protocol rules.

        Args:
            model: PlantModel to validate

        Returns:
            List of validation errors (empty if valid)
        """
        errors = []

        # Check channel count limit (64 max per spec)
        if len(model.channels) > 64:
            errors.append(f"Too many channels: {len(model.channels)} > 64")

        # Check for duplicate channel IDs
        channel_ids = [ch.channel_id for ch in model.channels]
        if len(channel_ids) != len(set(channel_ids)):
            errors.append("Duplicate channel IDs")

        # Check channel ID range (0-63)
        for ch in model.channels:
            if ch.channel_id < 0 or ch.channel_id > 63:
                errors.append(
                    f"Channel {ch.channel_id}: ID out of range [0, 63]"
                )

        # Check OUTPUT must be ACTUATOR
        for ch in model.channels:
            if ch.dir == ChannelDir.OUTPUT and ch.kind != ChannelKind.ACTUATOR:
                errors.append(
                    f"Channel {ch.channel_id}: OUTPUT must be ACTUATOR"
                )

        # Check ACTUATOR must be OUTPUT
        for ch in model.channels:
            if ch.kind == ChannelKind.ACTUATOR and ch.dir != ChannelDir.OUTPUT:
                errors.append(
                    f"Channel {ch.channel_id}: ACTUATOR must be OUTPUT"
                )

        # Check min <= max
        for ch in model.channels:
            if ch.min_val > ch.max_val:
                errors.append(
                    f"Channel {ch.channel_id}: min ({ch.min_val}) > max ({ch.max_val})"
                )

        # Check init within [min, max]
        for ch in model.channels:
            if ch.init_val < ch.min_val or ch.init_val > ch.max_val:
                errors.append(
                    f"Channel {ch.channel_id}: init ({ch.init_val}) "
                    f"outside [{ch.min_val}, {ch.max_val}]"
                )

        # Check LAG gain in (0, 1]
        for ch in model.channels:
            if ch.kind == ChannelKind.LAG:
                if ch.gain <= 0 or ch.gain > 1:
                    errors.append(
                        f"Channel {ch.channel_id}: LAG gain ({ch.gain}) "
                        f"must be in (0, 1]"
                    )

        # Check CONST/RAMP must not have drive
        for ch in model.channels:
            if ch.kind in (ChannelKind.CONST, ChannelKind.RAMP) and ch.drive >= 0:
                errors.append(
                    f"Channel {ch.channel_id}: {ch.kind.value} must not have drive"
                )

        # Check drive points to existing OUTPUT channel
        output_ids = {ch.channel_id for ch in model.channels if ch.dir == ChannelDir.OUTPUT}
        for ch in model.channels:
            if ch.drive >= 0 and ch.drive not in output_ids:
                errors.append(
                    f"Channel {ch.channel_id}: drive ({ch.drive}) "
                    f"points to non-existent OUTPUT channel"
                )

        # Check finite gain/offset (no NaN/Inf)
        import math
        for ch in model.channels:
            if not math.isfinite(ch.gain):
                errors.append(
                    f"Channel {ch.channel_id}: gain is not finite"
                )
            if not math.isfinite(ch.offset):
                errors.append(
                    f"Channel {ch.channel_id}: offset is not finite"
                )

        # Check non-empty
        if not model.channels:
            errors.append("Plant model has no channels")

        return errors

    def generate_plant_file(
        self,
        model: PlantModel,
        output_path: str | Path,
    ) -> Path:
        """
        Generate a .plant file from a model.

        Args:
            model: PlantModel
            output_path: Output file path

        Returns:
            Path to generated file

        Raises:
            PlantValidationError: If model is invalid
        """
        errors = self.validate_plant_model(model)
        if errors:
            raise PlantValidationError(
                f"Invalid plant model: {'; '.join(errors)}"
            )

        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        with open(output_path, "w") as f:
            f.write(model.to_plant_text())

        return output_path

    def save_plant_model(self, model: PlantModel) -> str:
        """
        Save plant model to storage (JSON format).

        Args:
            model: PlantModel to save

        Returns:
            Model name

        Raises:
            ValueError: If storage_dir not configured
        """
        if not self.storage_dir:
            raise ValueError("Storage directory not configured")

        model_path = self.storage_dir / f"{model.name}.json"
        with open(model_path, "w") as f:
            json.dump(model.to_dict(), f, indent=2)

        return model.name

    def load_plant_model(self, name: str) -> PlantModel:
        """
        Load plant model from storage.

        Args:
            name: Model name

        Returns:
            PlantModel

        Raises:
            FileNotFoundError: If model not found
        """
        if not self.storage_dir:
            raise ValueError("Storage directory not configured")

        model_path = self.storage_dir / f"{name}.json"
        if not model_path.exists():
            raise FileNotFoundError(f"Plant model not found: {name}")

        with open(model_path, "r") as f:
            data = json.load(f)

        return PlantModel.from_dict(data)

    def delete_plant_model(self, name: str) -> bool:
        """
        Delete plant model from storage.

        Args:
            name: Model name

        Returns:
            True if deleted, False if not found
        """
        if not self.storage_dir:
            raise ValueError("Storage directory not configured")

        model_path = self.storage_dir / f"{name}.json"
        if model_path.exists():
            model_path.unlink()
            return True
        return False

    def list_plant_models(self) -> list[str]:
        """
        List all plant models in storage.

        Returns:
            List of model names
        """
        if not self.storage_dir:
            return []

        return [
            p.stem for p in self.storage_dir.glob("*.json")
        ]

    def create_closed_loop_plant(self) -> PlantModel:
        """
        Create a default closed-loop plant model (integrator + actuator + setpoint).

        This matches the demo plant in veri-runtime/sim/plants/closed_loop.plant.
        """
        return PlantModel(
            name="closed_loop",
            description="First-order lag + actuator + constant setpoint",
            channels=[
                PlantChannel(
                    channel_id=0,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.LAG,
                    gain=0.125,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=1,
                ),
                PlantChannel(
                    channel_id=1,
                    dir=ChannelDir.OUTPUT,
                    kind=ChannelKind.ACTUATOR,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=0,
                    drive=-1,
                ),
                PlantChannel(
                    channel_id=2,
                    dir=ChannelDir.INPUT,
                    kind=ChannelKind.CONST,
                    gain=0,
                    offset=0,
                    min_val=0,
                    max_val=1000,
                    init_val=500,
                    drive=-1,
                ),
            ],
        )
