"""Block manifest model and validation."""

import hashlib
import json
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

import jsonschema


BLOCK_SCHEMA_PATH = Path(__file__).parent.parent.parent.parent.parent / "schema" / "block.schema.json"


@dataclass
class PortDef:
    """Port definition."""
    name: str
    type: str
    default: Optional[object] = None
    description: str = ""


@dataclass
class InterfaceDef:
    """Interface definition."""
    input: list[PortDef] = field(default_factory=list)
    output: list[PortDef] = field(default_factory=list)
    in_out: list[PortDef] = field(default_factory=list)


@dataclass
class ImplementationDef:
    """Implementation definition."""
    source_hash: str
    source_path: str
    language: str = "ST"


@dataclass
class AnalysisResult:
    """Static analysis result."""
    wcet_cycles: Optional[int] = None
    stack_depth: Optional[int] = None
    is_pure: Optional[bool] = None
    loop_bound: Optional[int] = None
    compiler_version: Optional[str] = None


@dataclass
class BlockManifest:
    """Block manifest."""
    name: str
    version: str
    type: str  # "FUNCTION" or "FUNCTION_BLOCK"
    interface: InterfaceDef = field(default_factory=InterfaceDef)
    implementation: Optional[ImplementationDef] = None
    description: str = ""
    author: str = ""
    sil_level: Optional[str] = None
    parameters: dict = field(default_factory=dict)
    analysis: Optional[AnalysisResult] = None
    icon: str = ""
    tags: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        """Convert to dictionary."""
        result = {
            "name": self.name,
            "version": self.version,
            "type": self.type,
            "interface": {
                "input": [asdict(p) for p in self.interface.input],
                "output": [asdict(p) for p in self.interface.output],
                "in_out": [asdict(p) for p in self.interface.in_out],
            },
        }
        if self.description:
            result["description"] = self.description
        if self.author:
            result["author"] = self.author
        if self.sil_level:
            result["sil_level"] = self.sil_level
        if self.parameters:
            result["parameters"] = self.parameters
        if self.implementation:
            result["implementation"] = asdict(self.implementation)
        if self.analysis:
            result["analysis"] = asdict(self.analysis)
        if self.icon:
            result["icon"] = self.icon
        if self.tags:
            result["tags"] = self.tags
        return result

    @classmethod
    def from_dict(cls, data: dict) -> "BlockManifest":
        """Create from dictionary."""
        interface_data = data.get("interface", {})
        interface = InterfaceDef(
            input=[PortDef(**p) for p in interface_data.get("input", [])],
            output=[PortDef(**p) for p in interface_data.get("output", [])],
            in_out=[PortDef(**p) for p in interface_data.get("in_out", [])],
        )
        impl = None
        if "implementation" in data:
            impl = ImplementationDef(**data["implementation"])
        analysis = None
        if "analysis" in data:
            analysis = AnalysisResult(**data["analysis"])
        return cls(
            name=data["name"],
            version=data["version"],
            type=data["type"],
            interface=interface,
            implementation=impl,
            description=data.get("description", ""),
            author=data.get("author", ""),
            sil_level=data.get("sil_level"),
            parameters=data.get("parameters", {}),
            analysis=analysis,
            icon=data.get("icon", ""),
            tags=data.get("tags", []),
        )

    def to_json(self, indent: int = 2) -> str:
        """Serialize to JSON."""
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    @classmethod
    def from_json(cls, json_str: str) -> "BlockManifest":
        """Deserialize from JSON."""
        return cls.from_dict(json.loads(json_str))

    def validate(self) -> list[str]:
        """Validate against JSON Schema. Returns list of errors."""
        try:
            with open(BLOCK_SCHEMA_PATH) as f:
                schema = json.load(f)
            jsonschema.validate(instance=self.to_dict(), schema=schema)
            return []
        except jsonschema.ValidationError as e:
            return [e.message]
        except jsonschema.SchemaError as e:
            return [f"Schema error: {e.message}"]


def compute_source_hash(source_path: Path) -> str:
    """Compute SHA-256 hash of source file."""
    h = hashlib.sha256()
    with open(source_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()
