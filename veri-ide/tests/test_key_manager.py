"""
Tests for key management service.
"""
import pytest
import tempfile
from pathlib import Path

from veri_ide.backend.deploy.key_manager import KeyManager, KeyManagerError


class TestKeyManager:
    """Tests for KeyManager."""

    def test_generate_key(self):
        """Test generating a new key."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            name = manager.generate_key("test_key")

            assert name == "test_key"
            assert manager.key_exists("test_key")

            key_bytes = manager.load_key("test_key")
            assert len(key_bytes) == 32

    def test_generate_key_duplicate(self):
        """Test generating duplicate key raises error."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            with pytest.raises(KeyManagerError, match="already exists"):
                manager.generate_key("test_key")

    def test_load_key(self):
        """Test loading a key."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            key_bytes = manager.load_key("test_key")
            assert len(key_bytes) == 32
            assert isinstance(key_bytes, bytes)

    def test_load_key_not_found(self):
        """Test loading non-existent key raises error."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)

            with pytest.raises(KeyManagerError, match="not found"):
                manager.load_key("nonexistent")

    def test_load_key_hex(self):
        """Test loading key as hex string."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            key_hex = manager.load_key_hex("test_key")
            assert len(key_hex) == 64
            assert all(c in "0123456789abcdef" for c in key_hex)

    def test_delete_key(self):
        """Test deleting a key."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            assert manager.delete_key("test_key")
            assert not manager.key_exists("test_key")
            assert not manager.delete_key("test_key")  # Already deleted

    def test_list_keys(self):
        """Test listing keys."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("key1")
            manager.generate_key("key2")
            manager.generate_key("key3")

            keys = manager.list_keys()
            assert len(keys) == 3
            assert "key1" in keys
            assert "key2" in keys
            assert "key3" in keys

    def test_key_exists(self):
        """Test checking key existence."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            assert manager.key_exists("test_key")
            assert not manager.key_exists("nonexistent")

    def test_get_key_info(self):
        """Test getting key metadata."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            info = manager.get_key_info("test_key")
            assert info["name"] == "test_key"
            assert info["size"] == 64  # 64 hex chars
            assert "path" in info
            assert "created" in info
            assert "modified" in info

    def test_get_key_info_not_found(self):
        """Test getting info for non-existent key."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)

            with pytest.raises(KeyManagerError, match="not found"):
                manager.get_key_info("nonexistent")

    def test_key_file_permissions(self):
        """Test that key files have restrictive permissions."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            manager.generate_key("test_key")

            key_path = Path(tmpdir) / "test_key.key"
            stat = key_path.stat()
            # Check that only owner can read/write (0600)
            assert stat.st_mode & 0o777 == 0o600

    def test_keys_dir_permissions(self):
        """Test that keys directory has restrictive permissions."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)
            stat = Path(tmpdir).stat()
            # Check that only owner can access (0700)
            assert stat.st_mode & 0o777 == 0o700

    def test_generate_multiple_keys(self):
        """Test generating multiple keys."""
        with tempfile.TemporaryDirectory() as tmpdir:
            manager = KeyManager(keys_dir=tmpdir)

            for i in range(10):
                manager.generate_key(f"key_{i}")

            keys = manager.list_keys()
            assert len(keys) == 10

            # All keys should be unique
            key_values = set()
            for name in keys:
                key_hex = manager.load_key_hex(name)
                assert key_hex not in key_values
                key_values.add(key_hex)
