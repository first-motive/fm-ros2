"""Plain fallback widgets — fm_tui's look when nish-tui is not installed.

These twins mirror the nish-tui widget API (``Header(title)``,
``BorderedPanel(..., title=)``, ``LogView.log_line(severity, message)``) so the
theming layer can swap one set for the other without touching the app. They use
only stock Textual colours, so fm_tui still runs and stays readable bare.
"""

from __future__ import annotations

from rich.text import Text
from textual.containers import Container
from textual.widgets import RichLog, Static

# Severity -> stock colour. Plain twins have no palette to draw from, so these
# are generic terminal colours rather than the nish-tui hexes.
_SEVERITY_COLOUR = {
    "debug": "grey62",
    "info": "green",
    "warn": "yellow",
    "error": "red",
}


class Header(Static):
    """Plain title bar."""

    DEFAULT_CSS = """
    Header {
        text-style: bold;
        height: 1;
        padding: 0 1;
    }
    """

    def __init__(self, title: str = "", **kwargs) -> None:
        super().__init__(title, **kwargs)


class BorderedPanel(Container):
    """Plain titled container with a rounded border."""

    DEFAULT_CSS = """
    BorderedPanel {
        border: round #4d4d4d;
        height: auto;
        padding: 0 1;
    }
    """

    def __init__(self, *children, title: str = "", **kwargs) -> None:
        super().__init__(*children, **kwargs)
        self.border_title = title


class LogView(RichLog):
    """Plain scrolling log; colours lines by severity with stock colours."""

    DEFAULT_CSS = """
    LogView {
        height: 1fr;
    }
    """

    def __init__(self, **kwargs) -> None:
        kwargs.setdefault("markup", False)
        kwargs.setdefault("wrap", True)
        super().__init__(**kwargs)

    def log_line(self, severity: str, message: str) -> None:
        colour = _SEVERITY_COLOUR.get(severity.lower(), "white")
        line = Text()
        line.append(f"{severity.upper():<5} ", style=f"bold {colour}")
        line.append(message, style=colour)
        self.write(line)
