"""Utilidades compartidas por STRUCTURA DATASET TOOLS.

Todas las herramientas leen y escriben datos a través de este módulo para
garantizar:

1. Rutas Unicode en Windows (``cv2.imread``/``cv2.imwrite`` fallan con
   caracteres como ``ñ``; aquí se usa ``imdecode``/``imencode``).
2. Una única forma de decodificar imágenes, de modo que los píxeles anotados,
   la máscara y los tiles provienen exactamente de la misma decodificación.
3. Escrituras atómicas: un corte a mitad de proceso no deja PNG/JSON truncados.
4. Validación estricta de identificadores, booleanos y metadatos: nunca se
   infieren escalas, unidades ni dimensiones.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np
import yaml

from . import __version__

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CLASSES_PATH = PACKAGE_ROOT / "config" / "classes.yaml"

# Identificadores seguros para nombres de archivo en Windows (sin espacios,
# sin caracteres reservados, sin acentos) y razonablemente cortos.
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
SOURCE_TYPES = ("digital", "scanned", "photo", "unknown")
UNITS = ("mm", "cm", "m", "in", "ft", "unknown")
UNIT_ALIASES = {
    "meters": "m", "meter": "m", "metros": "m", "metro": "m",
    "centimeters": "cm", "centimetros": "cm", "centímetros": "cm",
    "millimeters": "mm", "milimetros": "mm", "milímetros": "mm",
    "inches": "in", "inch": "in", "pulgadas": "in", "feet": "ft", "foot": "ft", "pies": "ft",
}
DPI_SOURCES = ("pdf_render", "file_header", "manual", "unknown")
METADATA_SCHEMA_VERSION = 1
TOOL_VERSION = __version__

# Subcarpetas del dataset final (compatibles con core/data.py del prototipo).
DATASET_DIRS = ("images", "masks", "metadata", "plans", "splits")
SPLIT_NAMES = ("train", "validation", "test")


class DatasetError(Exception):
    """Error de datos que debe detener la herramienta con un mensaje claro."""


# ---------------------------------------------------------------------------
# Esquema de clases
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class ClassSchema:
    names: tuple[str, ...]                       # índice = ID de clase
    priority: tuple[str, ...]                    # de menor a mayor prioridad
    expected_overlaps: frozenset[frozenset[str]]

    @property
    def num_classes(self) -> int:
        return len(self.names)

    @property
    def valid_ids(self) -> frozenset[int]:
        return frozenset(range(len(self.names)))

    @property
    def label_to_id(self) -> dict[str, int]:
        return {name: idx for idx, name in enumerate(self.names)}

    def id_of(self, name: str) -> int:
        return self.names.index(name)

    def is_expected_overlap(self, a: str, b: str) -> bool:
        return frozenset((a, b)) in self.expected_overlaps


def load_class_schema(path: str | os.PathLike | None = None) -> ClassSchema:
    """Carga y valida ``config/classes.yaml``."""
    p = Path(path) if path else DEFAULT_CLASSES_PATH
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except FileNotFoundError as exc:
        raise DatasetError(f"No existe el esquema de clases: {p}") from exc
    except yaml.YAMLError as exc:
        raise DatasetError(f"YAML inválido en {p}: {exc}") from exc

    by_id: dict[int, str] = {}
    for entry in data.get("classes") or []:
        cid, name = entry.get("id"), entry.get("name")
        if not isinstance(cid, int) or isinstance(cid, bool) or not isinstance(name, str) or not name:
            raise DatasetError(f"{p}: entrada de clase inválida {entry!r}")
        if cid in by_id:
            raise DatasetError(f"{p}: ID de clase duplicado {cid}")
        by_id[cid] = name
    if not by_id or sorted(by_id) != list(range(len(by_id))):
        raise DatasetError(f"{p}: los IDs deben ser contiguos desde 0; hay {sorted(by_id)}")
    names = tuple(by_id[i] for i in range(len(by_id)))
    if names[0] != "background":
        raise DatasetError(f"{p}: el ID 0 debe ser 'background'")
    if len(set(names)) != len(names):
        raise DatasetError(f"{p}: nombres de clase duplicados")
    if len(names) > 255:
        raise DatasetError(f"{p}: máximo 255 clases para máscaras uint8")

    priority = tuple(data.get("overlap_priority") or names[1:])
    if sorted(priority) != sorted(names[1:]):
        raise DatasetError(f"{p}: overlap_priority debe listar exactamente las clases {list(names[1:])}")

    expected = set()
    for pair in data.get("expected_overlaps") or []:
        if len(pair) != 2 or any(x not in names[1:] for x in pair):
            raise DatasetError(f"{p}: par expected_overlaps inválido {pair!r}")
        expected.add(frozenset(pair))
    return ClassSchema(names, priority, frozenset(expected))


# ---------------------------------------------------------------------------
# Validación de valores
# ---------------------------------------------------------------------------
_TRUE = {"true", "1", "yes", "y", "si", "sí"}
_FALSE = {"false", "0", "no", "n", ""}


def parse_bool(value: Any, field: str = "valor") -> bool:
    """Booleano estricto. ``bool("false")`` es True en Python; aquí no."""
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, (int, np.integer)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        v = value.strip().lower()
        if v in _TRUE:
            return True
        if v in _FALSE:
            return False
    raise DatasetError(f"{field}: booleano inválido {value!r} (usar true/false)")


def parse_optional_positive_float(value: Any, field: str) -> float | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if isinstance(value, bool):
        raise DatasetError(f"{field}: número inválido {value!r}")
    try:
        number = float(str(value).replace(",", ".")) if isinstance(value, str) else float(value)
    except (TypeError, ValueError) as exc:
        raise DatasetError(f"{field}: número inválido {value!r}") from exc
    if not np.isfinite(number) or number <= 0:
        raise DatasetError(f"{field}: debe ser > 0, recibido {value!r}")
    return number


def validate_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not ID_PATTERN.match(value):
        raise DatasetError(
            f"{field} inválido {value!r}: usar 1-64 caracteres [A-Za-z0-9_-], "
            "sin espacios ni acentos, comenzando con letra o número")
    return value


def validate_choice(value: Any, choices: Iterable[str], field: str, default: str | None = None) -> str:
    if (value is None or value == "") and default is not None:
        return default
    choices = tuple(choices)
    if value not in choices:
        raise DatasetError(f"{field} inválido {value!r}; opciones: {', '.join(choices)}")
    return value


def normalize_plan_info(info: dict[str, Any]) -> dict[str, Any]:
    """Normaliza y valida la información de procedencia de un plano.

    Reglas que protegen contra escalas inventadas:
      * ``scale_verified`` es False salvo declaración explícita.
      * ``scale_verified=True`` exige unidades conocidas y ``scale_px_per_unit``.
    """
    plan_id = validate_id(info.get("source_plan_id"), "source_plan_id")
    ctx = f"plano {plan_id}"
    units = info.get("units")
    if isinstance(units, str):
        units = UNIT_ALIASES.get(units.strip().lower(), units.strip().lower())
    info = {**info, "units": units}
    out = {
        "source_plan_id": plan_id,
        "project_id": validate_id(info.get("project_id"), f"{ctx}: project_id"),
        "source_type": validate_choice(info.get("source_type"), SOURCE_TYPES, f"{ctx}: source_type", "unknown"),
        "units": validate_choice(info.get("units"), UNITS, f"{ctx}: units", "unknown"),
        "scale_verified": parse_bool(info.get("scale_verified"), f"{ctx}: scale_verified"),
        "scale_px_per_unit": parse_optional_positive_float(info.get("scale_px_per_unit"), f"{ctx}: scale_px_per_unit"),
        "dpi": parse_optional_positive_float(info.get("dpi"), f"{ctx}: dpi"),
        "dpi_source": validate_choice(info.get("dpi_source"), DPI_SOURCES, f"{ctx}: dpi_source", "unknown"),
    }
    if out["dpi"] is None and out["dpi_source"] != "unknown":
        raise DatasetError(f"{ctx}: dpi_source={out['dpi_source']} pero dpi está vacío")
    if out["scale_verified"]:
        if out["units"] == "unknown":
            raise DatasetError(f"{ctx}: scale_verified=true requiere units conocidas")
        if out["scale_px_per_unit"] is None:
            raise DatasetError(f"{ctx}: scale_verified=true requiere scale_px_per_unit medido")
    return out


# ---------------------------------------------------------------------------
# E/S de imágenes (Unicode-safe, una sola decodificación)
# ---------------------------------------------------------------------------
def decode_image(path: str | os.PathLike, flags: int = cv2.IMREAD_UNCHANGED) -> np.ndarray | None:
    """Decodifica una imagen desde disco; devuelve None si está corrupta."""
    data = Path(path).read_bytes()
    if not data:
        return None
    return cv2.imdecode(np.frombuffer(data, dtype=np.uint8), flags)


def composite_on_white(bgra: np.ndarray) -> np.ndarray:
    """Compone una imagen BGRA sobre fondo blanco (papel), determinísticamente."""
    alpha = bgra[:, :, 3:4].astype(np.float32) / 255.0
    color = bgra[:, :, :3].astype(np.float32)
    out = color * alpha + 255.0 * (1.0 - alpha)
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def require_png(path: str | os.PathLike, role: str) -> Path:
    p = Path(path)
    if p.suffix.lower() != ".png":
        raise DatasetError(
            f"{role} debe ser PNG ({p.name}). Convertí PDF/JPG/TIFF con tools.import_plans "
            "para que anotación, máscara y tiles usen exactamente los mismos píxeles.")
    if not p.is_file():
        raise DatasetError(f"No existe {role}: {p}")
    return p


def load_plan_image(path: str | os.PathLike) -> np.ndarray:
    """Lee una imagen de plano como BGR uint8 HxWx3.

    Gris → BGR; BGRA → compuesta sobre blanco; >8 bits → error (usar import_plans).
    """
    img = decode_image(path)
    if img is None:
        raise DatasetError(f"Imagen ilegible o corrupta: {path}")
    if img.dtype != np.uint8:
        raise DatasetError(f"{path}: profundidad {img.dtype} no soportada; convertir con tools.import_plans")
    if img.ndim == 2:
        return cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    if img.ndim == 3 and img.shape[2] == 3:
        return img
    if img.ndim == 3 and img.shape[2] == 4:
        return composite_on_white(img)
    raise DatasetError(f"{path}: formato de canales no soportado {img.shape}")


def load_mask(path: str | os.PathLike) -> np.ndarray:
    """Lee una máscara de IDs: debe ser PNG de un canal uint8 (sin paleta)."""
    mask = decode_image(path)
    if mask is None:
        raise DatasetError(f"Máscara ilegible o corrupta: {path}")
    if mask.ndim != 2:
        raise DatasetError(
            f"{path}: máscara multicanal {mask.shape}; se requiere grayscale de un canal "
            "(las máscaras con paleta/color de labelme_export no son válidas)")
    if mask.dtype != np.uint8:
        raise DatasetError(f"{path}: máscara {mask.dtype}; se requiere uint8")
    return mask


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def encode_png(array: np.ndarray) -> bytes:
    ok, buf = cv2.imencode(".png", array, [cv2.IMWRITE_PNG_COMPRESSION, 3])
    if not ok:
        raise OSError("No se pudo codificar PNG")
    return buf.tobytes()


def write_png(path: str | os.PathLike, array: np.ndarray) -> bytes:
    """Escribe un PNG de forma atómica y devuelve los bytes escritos."""
    data = encode_png(array)
    _atomic_write_bytes(Path(path), data)
    return data


def write_json(path: str | os.PathLike, obj: Any) -> None:
    text = json.dumps(obj, indent=2, ensure_ascii=False) + "\n"
    _atomic_write_bytes(Path(path), text.encode("utf-8"))


def read_json(path: str | os.PathLike) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str | os.PathLike) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def array_digest(array: np.ndarray) -> str:
    """Hash del contenido decodificado (incluye forma y tipo)."""
    h = hashlib.sha256(f"{array.shape}|{array.dtype}|".encode())
    h.update(np.ascontiguousarray(array).tobytes())
    return h.hexdigest()


def class_pixel_counts(mask: np.ndarray, num_classes: int) -> list[int]:
    counts = np.bincount(mask.ravel(), minlength=num_classes)
    return [int(c) for c in counts[:num_classes]]


# ---------------------------------------------------------------------------
# Registro de planos (plans.csv)
# ---------------------------------------------------------------------------
REGISTRY_FIELDS = [
    "source_plan_id", "project_id", "source_type", "image", "annotation",
    "units", "scale_verified", "scale_px_per_unit", "dpi", "dpi_source",
    "source_file", "source_page", "source_sha256", "image_sha256",
    "width", "height", "notes",
]
REGISTRY_REQUIRED = {"source_plan_id", "project_id", "source_type", "image"}


def read_registry(path: str | os.PathLike) -> tuple[list[dict[str, str]], str]:
    """Lee plans.csv (UTF-8, con o sin BOM). Detecta ',' o ';' (Excel en español)."""
    p = Path(path)
    if not p.is_file():
        raise DatasetError(f"No existe el registro de planos: {p}")
    text = p.read_text(encoding="utf-8-sig")
    first = text.splitlines()[0] if text.strip() else ""
    delimiter = ";" if first.count(";") > first.count(",") else ","
    reader = csv.DictReader(io.StringIO(text), delimiter=delimiter)
    columns = set(reader.fieldnames or [])
    missing = REGISTRY_REQUIRED - columns
    if missing:
        raise DatasetError(f"{p}: faltan columnas {sorted(missing)}")
    rows = []
    for row in reader:
        clean = {k.strip(): (v or "").strip() for k, v in row.items() if k}
        if not any(clean.values()) or clean.get("source_plan_id", "").startswith("#"):
            continue
        rows.append(clean)
    return rows, delimiter


def write_registry(path: str | os.PathLike, rows: list[dict[str, Any]], delimiter: str = ",") -> None:
    buf = io.StringIO()
    extra = sorted({k for r in rows for k in r} - set(REGISTRY_FIELDS))
    writer = csv.DictWriter(buf, fieldnames=REGISTRY_FIELDS + extra, delimiter=delimiter, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow({k: "" if v is None else v for k, v in row.items()})
    _atomic_write_bytes(Path(path), buf.getvalue().encode("utf-8-sig"))


def resolve_relative(base_dir: Path, value: str) -> Path:
    p = Path(value)
    return p if p.is_absolute() else (base_dir / p)


def to_registry_path(base_dir: Path, target: Path) -> str:
    """Ruta relativa al registro si es posible (portabilidad entre PCs)."""
    try:
        return Path(os.path.relpath(target.resolve(), base_dir.resolve())).as_posix()
    except ValueError:  # otra unidad en Windows
        return str(target.resolve())


# ---------------------------------------------------------------------------
# Metadatos de tiles
# ---------------------------------------------------------------------------
def load_tile_metadata(metadata_dir: str | os.PathLike) -> dict[str, dict[str, Any]]:
    """Carga metadata/*.json indexado por tile_id (o nombre de archivo)."""
    records: dict[str, dict[str, Any]] = {}
    for path in sorted(Path(metadata_dir).glob("*.json")):
        try:
            data = read_json(path)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise DatasetError(f"{path.name}: JSON inválido: {exc}") from exc
        if not isinstance(data, dict):
            raise DatasetError(f"{path.name}: la metadata debe ser un objeto JSON")
        records[path.stem] = data
    return records


def consistency_errors(records: dict[str, dict[str, Any]]) -> list[str]:
    """Errores de coherencia entre tiles que provocarían fuga entre splits."""
    errors = []
    plan_project: dict[str, set] = {}
    hash_plans: dict[str, set] = {}
    for rec in records.values():
        plan = rec.get("source_plan_id")
        plan_project.setdefault(plan, set()).add(rec.get("project_id"))
        if rec.get("source_image_sha256"):
            hash_plans.setdefault(rec["source_image_sha256"], set()).add(plan)
    for plan, projects in sorted(plan_project.items(), key=lambda kv: str(kv[0])):
        if len(projects) > 1:
            errors.append(f"plano {plan} aparece en varios proyectos {sorted(map(str, projects))}")
    for digest, plans in sorted(hash_plans.items()):
        if len(plans) > 1:
            errors.append(f"la misma imagen fuente (sha256 {digest[:12]}…) está registrada como "
                          f"planos distintos {sorted(map(str, plans))}: duplicado → fuga entre splits")
    return errors
