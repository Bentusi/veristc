"""VeriIDE Desktop application entry point.

Usage:
    python -m veri_ide.desktop.app
    veride-desktop          (after pip install -e .)

Starts the embedded FastAPI server, then launches the PySide6 window.
"""

import sys


def main():
    from PySide6.QtWidgets import QApplication
    from PySide6.QtCore import Qt

    from .launcher import FastAPILauncher
    from .main_window import MainWindow

    app = QApplication(sys.argv)
    app.setApplicationName("VeriIDE")
    app.setApplicationVersion("0.1.0")
    app.setStyle("Fusion")

    launcher = FastAPILauncher()
    launcher.start()

    window = MainWindow(base_url=launcher.base_url)
    window.show()

    exit_code = app.exec()

    launcher.stop()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
