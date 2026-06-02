"""Smoke test: package imports cleanly."""

import importlib


def test_import():
    importlib.import_module("fm_vlta_dataset.dataset_manager")
