"""Smoke test: package imports cleanly."""

import importlib


def test_import():
    importlib.import_module("fm_bringup.bringup")
