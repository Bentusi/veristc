"""Main window for VeriIDE Desktop.

Layout: left sidebar (project tree + page nav) | center QWebEngineView
Bottom: status bar. Pages are loaded from the embedded FastAPI server.
"""

from PySide6.QtCore import QUrl, Qt, Signal
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QSplitter,
    QTreeWidget, QTreeWidgetItem, QPushButton, QLabel, QFrame,
    QStatusBar, QSizePolicy,
)
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtGui import QFont


_PAGES = [
    ("index.html", "Home", "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"),
    ("graph-editor.html", "Graph Editor", "M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z"),
    ("waveform-viewer.html", "Simulation", "M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z"),
    ("download-wizard.html", "Download", "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"),
]


class MainWindow(QMainWindow):
    """VeriIDE main window with sidebar navigation and web engine view."""

    def __init__(self, base_url: str, parent=None):
        super().__init__(parent)
        self.base_url = base_url
        self.setWindowTitle("VeriIDE")
        self.setMinimumSize(1200, 800)
        self.resize(1400, 900)
        self._build_ui()
        self._build_sidebar()
        self.navigate_to("index.html")

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        layout.addWidget(splitter)

        self.sidebar = QWidget()
        self.sidebar.setFixedWidth(220)
        self.sidebar.setStyleSheet(
            "QWidget { background: #1e1e2e; color: #cdd6f4; }"
        )
        splitter.addWidget(self.sidebar)

        self.web_view = QWebEngineView()
        self.web_view.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        splitter.addWidget(self.web_view)

        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)

        status = QStatusBar()
        status.setStyleSheet("QStatusBar { background: #181825; color: #a6adc8; }")
        self.setStatusBar(status)
        self.status_label = QLabel("Ready")
        status.addWidget(self.status_label)

    def _build_sidebar(self):
        layout = QVBoxLayout(self.sidebar)
        layout.setContentsMargins(12, 16, 12, 12)
        layout.setSpacing(8)

        brand = QLabel("VeriIDE")
        brand.setFont(QFont("Segoe UI", 16, QFont.Weight.Bold))
        brand.setStyleSheet("color: #89b4fa; padding: 8px 0 16px 0;")
        layout.addWidget(brand)

        nav_label = QLabel("NAVIGATION")
        nav_label.setFont(QFont("Segoe UI", 9, QFont.Weight.DemiBold))
        nav_label.setStyleSheet("color: #6c7086; padding: 8px 0 4px 0;")
        layout.addWidget(nav_label)

        for page_file, title, _icon in _PAGES:
            btn = QPushButton(title)
            btn.setStyleSheet(
                "QPushButton { text-align: left; padding: 10px 12px; "
                "background: transparent; color: #cdd6f4; border: none; "
                "border-radius: 6px; font-size: 13px; }"
                "QPushButton:hover { background: #313244; }"
                "QPushButton:pressed { background: #45475a; }"
            )
            btn.clicked.connect(lambda checked, f=page_file: self.navigate_to(f))
            layout.addWidget(btn)

        layout.addStretch()

        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("color: #313244;")
        layout.addWidget(sep)

        info = QLabel("v0.1.0\nPySide6 + FastAPI")
        info.setFont(QFont("Segoe UI", 9))
        info.setStyleSheet("color: #585b70; padding: 8px 0;")
        layout.addWidget(info)

    def navigate_to(self, page: str) -> None:
        """Load a frontend page in the web engine view."""
        url = QUrl(f"{self.base_url}/static/{page}")
        self.web_view.setUrl(url)
        self.status_label.setText(f"Loaded: {page}")
