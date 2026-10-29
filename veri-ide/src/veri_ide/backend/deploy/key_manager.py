"""
Key management: generate, store, load, and delete HMAC-SHA256 keys.

Keys are 32 bytes (64 hex chars), stored as files with 0600 permissions.
"""
import os
import secrets
import stat
from pathlib import Path
from typing import Any


class KeyManagerError(Exception):
    """Raised when key management fails."""
    pass


class KeyManager:
    """Service for managing HMAC-SHA256 keys."""

    def __init__(self, keys_dir: str | Path | None = None):
        """
        Initialize key manager.

        Args:
            keys_dir: Directory to store keys (default: ~/.veride/keys/)
        """
        if keys_dir:
            self.keys_dir = Path(keys_dir)
        else:
            self.keys_dir = Path.home() / ".veride" / "keys"

        self.keys_dir.mkdir(parents=True, exist_ok=True)
        # Ensure directory permissions are restrictive
        os.chmod(self.keys_dir, stat.S_IRWXU)  # 0700

    def generate_key(self, name: str) -> str:
        """
        Generate a new random 32-byte key.

        Args:
            name: Key name (used as filename)

        Returns:
            Key name

        Raises:
            KeyManagerError: If key already exists
        """
        key_path = self.keys_dir / f"{name}.key"
        if key_path.exists():
            raise KeyManagerError(f"Key already exists: {name}")

        # Generate 32 random bytes
        key_bytes = secrets.token_bytes(32)
        key_hex = key_bytes.hex()

        # Write with restrictive permissions
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IRUSR | stat.S_IWUSR)
        try:
            os.write(fd, key_hex.encode())
        finally:
            os.close(fd)

        return name

    def load_key(self, name: str) -> bytes:
        """
        Load a key by name.

        Args:
            name: Key name

        Returns:
            32-byte key

        Raises:
            KeyManagerError: If key not found or invalid
        """
        key_path = self.keys_dir / f"{name}.key"
        if not key_path.exists():
            raise KeyManagerError(f"Key not found: {name}")

        with open(key_path, "r") as f:
            key_hex = f.read().strip()

        try:
            key_bytes = bytes.fromhex(key_hex)
        except ValueError:
            raise KeyManagerError(f"Invalid key format: {name}")

        if len(key_bytes) != 32:
            raise KeyManagerError(f"Invalid key length: {len(key_bytes)} bytes (expected 32)")

        return key_bytes

    def load_key_hex(self, name: str) -> str:
        """
        Load a key as hex string.

        Args:
            name: Key name

        Returns:
            64-character hex string
        """
        key_bytes = self.load_key(name)
        return key_bytes.hex()

    def delete_key(self, name: str) -> bool:
        """
        Delete a key.

        Args:
            name: Key name

        Returns:
            True if deleted, False if not found
        """
        key_path = self.keys_dir / f"{name}.key"
        if key_path.exists():
            key_path.unlink()
            return True
        return False

    def list_keys(self) -> list[str]:
        """
        List all key names.

        Returns:
            List of key names
        """
        return [
            p.stem for p in self.keys_dir.glob("*.key")
        ]

    def key_exists(self, name: str) -> bool:
        """
        Check if a key exists.

        Args:
            name: Key name

        Returns:
            True if exists
        """
        return (self.keys_dir / f"{name}.key").exists()

    def get_key_info(self, name: str) -> dict[str, Any]:
        """
        Get key metadata.

        Args:
            name: Key name

        Returns:
            Dict with name, path, size, created, modified
        """
        key_path = self.keys_dir / f"{name}.key"
        if not key_path.exists():
            raise KeyManagerError(f"Key not found: {name}")

        stat = key_path.stat()
        return {
            "name": name,
            "path": str(key_path),
            "size": stat.st_size,
            "created": stat.st_ctime,
            "modified": stat.st_mtime,
        }
