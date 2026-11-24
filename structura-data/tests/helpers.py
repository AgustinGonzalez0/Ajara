"""Utilidades de test: carpetas temporales con nombres Unicode."""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path


class TempDirTestCase(unittest.TestCase):
    """Cada test corre en una carpeta temporal con 'ñ' y espacios en la ruta,
    para detectar regresiones de rutas Unicode en Windows."""

    def setUp(self) -> None:
        base = Path(tempfile.mkdtemp(prefix="structura_test_"))
        self.root = base / "datos año ñ"
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
