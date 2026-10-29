"""Tests for registry module."""

import json
import pytest
from pathlib import Path
from tempfile import TemporaryDirectory

from veri_ide.backend.registry.manifest import (
    BlockManifest,
    PortDef,
    InterfaceDef,
    ImplementationDef,
    AnalysisResult,
    compute_source_hash,
)
from veri_ide.backend.registry.lock import LockFile, LockEntry
from veri_ide.backend.registry.service import RegistryService, RegistryError
from veri_ide.backend.registry.admission import AdmissionGate, AdmissionResult


# Test fixtures

@pytest.fixture
def sample_manifest():
    """Sample block manifest."""
    return BlockManifest(
        name="PID",
        version="1.0.0",
        type="FUNCTION_BLOCK",
        interface=InterfaceDef(
            input=[
                PortDef(name="SP", type="REAL", description="Setpoint"),
                PortDef(name="PV", type="REAL", description="Process variable"),
            ],
            output=[
                PortDef(name="OUT", type="REAL", description="Control output"),
            ],
        ),
        implementation=ImplementationDef(
            source_hash="a" * 64,
            source_path="pid.st",
        ),
        description="PID controller",
        author="Test",
        sil_level="SIL2",
        tags=["control", "pid"],
    )


@pytest.fixture
def sample_source(tmp_path):
    """Sample source file."""
    source = tmp_path / "pid.st"
    source.write_text("""
FUNCTION_BLOCK PID
VAR_INPUT
    SP : REAL;
    PV : REAL;
END_VAR
VAR_OUTPUT
    OUT : REAL;
END_VAR
OUT := SP - PV;
END_FUNCTION_BLOCK
""")
    return source


@pytest.fixture
def registry_dir(tmp_path):
    """Registry directory."""
    return tmp_path / "registry"


@pytest.fixture
def project_dir(tmp_path):
    """Project directory."""
    return tmp_path / "project"


# Manifest tests

class TestBlockManifest:
    def test_create_manifest(self, sample_manifest):
        assert sample_manifest.name == "PID"
        assert sample_manifest.version == "1.0.0"
        assert sample_manifest.type == "FUNCTION_BLOCK"

    def test_to_dict(self, sample_manifest):
        d = sample_manifest.to_dict()
        assert d["name"] == "PID"
        assert d["version"] == "1.0.0"
        assert len(d["interface"]["input"]) == 2
        assert len(d["interface"]["output"]) == 1

    def test_from_dict(self, sample_manifest):
        d = sample_manifest.to_dict()
        m = BlockManifest.from_dict(d)
        assert m.name == sample_manifest.name
        assert m.version == sample_manifest.version
        assert len(m.interface.input) == len(sample_manifest.interface.input)

    def test_to_json_from_json(self, sample_manifest):
        j = sample_manifest.to_json()
        m = BlockManifest.from_json(j)
        assert m.name == sample_manifest.name
        assert m.version == sample_manifest.version

    def test_validate_valid(self, sample_manifest):
        errors = sample_manifest.validate()
        assert len(errors) == 0

    def test_validate_invalid_name(self):
        m = BlockManifest(
            name="invalid_name",  # lowercase not allowed
            version="1.0.0",
            type="FUNCTION",
        )
        errors = m.validate()
        assert len(errors) > 0

    def test_compute_source_hash(self, sample_source):
        h = compute_source_hash(sample_source)
        assert len(h) == 64
        assert all(c in "0123456789abcdef" for c in h)


# Lock file tests

class TestLockFile:
    def test_create_empty(self):
        lock = LockFile()
        assert len(lock.entries) == 0

    def test_add_entry(self):
        lock = LockFile()
        entry = LockEntry(name="PID", version="1.0.0", sha256="abc123")
        lock.add_or_update(entry)
        assert len(lock.entries) == 1
        assert lock.entries[0].name == "PID"

    def test_update_entry(self):
        lock = LockFile()
        lock.add_or_update(LockEntry(name="PID", version="1.0.0", sha256="abc"))
        lock.add_or_update(LockEntry(name="PID", version="1.1.0", sha256="def"))
        assert len(lock.entries) == 1
        assert lock.entries[0].version == "1.1.0"

    def test_remove_entry(self):
        lock = LockFile()
        lock.add_or_update(LockEntry(name="PID", version="1.0.0", sha256="abc"))
        assert lock.remove("PID")
        assert len(lock.entries) == 0

    def test_remove_not_found(self):
        lock = LockFile()
        assert not lock.remove("NONEXIST")

    def test_get_entry(self):
        lock = LockFile()
        lock.add_or_update(LockEntry(name="PID", version="1.0.0", sha256="abc"))
        entry = lock.get("PID")
        assert entry is not None
        assert entry.version == "1.0.0"

    def test_save_load(self, tmp_path):
        lock = LockFile()
        lock.add_or_update(LockEntry(name="PID", version="1.0.0", sha256="abc"))
        lock_path = tmp_path / "lib.lock.yaml"
        lock.save(lock_path)
        assert lock_path.exists()

        loaded = LockFile.load(lock_path)
        assert len(loaded.entries) == 1
        assert loaded.entries[0].name == "PID"

    def test_load_nonexistent(self, tmp_path):
        lock = LockFile.load(tmp_path / "nonexistent.yaml")
        assert len(lock.entries) == 0


# Registry service tests

class TestRegistryService:
    def test_register_block(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        block = svc.register_block(sample_manifest, sample_source)
        assert block.manifest.name == "PID"
        assert block.storage_path.exists()

    def test_register_duplicate(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        with pytest.raises(RegistryError):
            svc.register_block(sample_manifest, sample_source)

    def test_get_block(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        block = svc.get_block("PID", "1.0.0")
        assert block is not None
        assert block.manifest.name == "PID"

    def test_get_block_not_found(self, registry_dir):
        svc = RegistryService(registry_dir)
        block = svc.get_block("NONEXIST", "1.0.0")
        assert block is None

    def test_list_blocks(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        blocks = svc.list_blocks()
        assert len(blocks) == 1

    def test_list_blocks_with_filter(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        blocks = svc.list_blocks(name_filter="PID")
        assert len(blocks) == 1
        blocks = svc.list_blocks(name_filter="NONEXIST")
        assert len(blocks) == 0

    def test_unregister_block(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        assert svc.unregister_block("PID", "1.0.0")
        assert svc.get_block("PID", "1.0.0") is None

    def test_unregister_not_found(self, registry_dir):
        svc = RegistryService(registry_dir)
        assert not svc.unregister_block("NONEXIST", "1.0.0")

    def test_search_blocks(self, registry_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir)
        svc.register_block(sample_manifest, sample_source)
        results = svc.search_blocks("PID")
        assert len(results) == 1
        results = svc.search_blocks("control")
        assert len(results) == 1
        results = svc.search_blocks("NONEXIST")
        assert len(results) == 0

    def test_register_with_lock_file(self, registry_dir, project_dir, sample_manifest, sample_source):
        svc = RegistryService(registry_dir, project_dir)
        svc.register_block(sample_manifest, sample_source)
        lock_path = project_dir / "lib.lock.yaml"
        assert lock_path.exists()
        lock = LockFile.load(lock_path)
        assert len(lock.entries) == 1


# Admission gate tests

class TestAdmissionGate:
    def test_check_no_analysis(self, sample_manifest):
        gate = AdmissionGate()
        result = gate.check(sample_manifest)
        assert result.passed
        assert len(result.warnings) > 0

    def test_check_pass(self, sample_manifest):
        sample_manifest.analysis = AnalysisResult(
            wcet_cycles=100,
            stack_depth=10,
            is_pure=True,
            loop_bound=5,
        )
        gate = AdmissionGate()
        result = gate.check(sample_manifest)
        assert result.passed
        assert result.checks["wcet"]
        assert result.checks["stack_depth"]

    def test_check_wcet_fail(self, sample_manifest):
        sample_manifest.analysis = AnalysisResult(wcet_cycles=2000)
        gate = AdmissionGate(max_wcet=1000)
        result = gate.check(sample_manifest)
        assert not result.passed
        assert not result.checks["wcet"]

    def test_check_stack_fail(self, sample_manifest):
        sample_manifest.analysis = AnalysisResult(stack_depth=300)
        gate = AdmissionGate(max_stack_depth=256)
        result = gate.check(sample_manifest)
        assert not result.passed
        assert not result.checks["stack_depth"]

    def test_check_pure_required(self, sample_manifest):
        sample_manifest.analysis = AnalysisResult(is_pure=False)
        gate = AdmissionGate(require_pure=True)
        result = gate.check(sample_manifest)
        assert not result.passed
        assert not result.checks["pure"]

    def test_check_pure_not_required(self, sample_manifest):
        sample_manifest.analysis = AnalysisResult(is_pure=False)
        gate = AdmissionGate(require_pure=False)
        result = gate.check(sample_manifest)
        assert result.passed
