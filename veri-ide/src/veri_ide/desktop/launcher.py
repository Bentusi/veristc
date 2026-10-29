"""FastAPI server lifecycle management for the desktop app.

Starts uvicorn in a background thread, polls /health until ready,
and provides clean shutdown on app exit.
"""

import asyncio
import threading
import time
import urllib.request
import urllib.error
from typing import Optional


class FastAPILauncher:
    """Manages the embedded FastAPI server lifecycle."""

    def __init__(self, host: str = "127.0.0.1", port: int = 8000):
        self.host = host
        self.port = port
        self._thread: Optional[threading.Thread] = None
        self._server = None

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def start(self, timeout: float = 15.0) -> None:
        """Start the FastAPI server in a background thread."""
        from ..api.server import app
        import uvicorn

        config = uvicorn.Config(app, host=self.host, port=self.port, log_level="warning")
        self._server = uvicorn.Server(config)

        def _run():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                loop.run_until_complete(self._server.serve())
            finally:
                try:
                    loop.close()
                except Exception:
                    pass

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()

        self._wait_ready(timeout)

    def _wait_ready(self, timeout: float) -> None:
        """Poll /health until the server responds or timeout."""
        deadline = time.monotonic() + timeout
        url = f"{self.base_url}/health"
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(url, timeout=2):
                    return
            except (urllib.error.URLError, OSError):
                time.sleep(0.3)
        raise RuntimeError(f"FastAPI server did not become ready within {timeout}s")

    def stop(self, timeout: float = 5.0) -> None:
        """Signal the server to shut down and wait for the thread."""
        if self._server is not None:
            self._server.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout=timeout)
            if self._thread.is_alive():
                pass  # daemon thread will be killed on process exit
        self._server = None
        self._thread = None
