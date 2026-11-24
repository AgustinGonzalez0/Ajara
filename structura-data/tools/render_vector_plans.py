"""Renderiza planos vectoriales como dibujos de arquitectura variados + máscara EXACTA.

Por qué: no hay planos reales anotados todavía. Las fuentes vectoriales abiertas
(Swiss Dwellings) traen la geometría real de miles de plantas; dibujándolas con estilos
distintos (muros macizos, rayados, en contorno o grises; puertas con arco, dobles,
corredizas o solo el vano; ventanas de 1 o 2 líneas; escaleras con huellas; muebles,
textos, cotas y ejes) se obtiene un dataset con etiquetas perfectas y apariencia variada.

La máscara sale de los polígonos, no del dibujo: no hay error de anotación.

Convención de puertas: ``door_label="vano"`` (por defecto) etiqueta el rectángulo del
vano dentro del muro, que es como vienen las fuentes. ``"vano_y_barrido"`` suma el
sector de giro de la hoja. La convención oficial está PENDIENTE (D-17); como el dataset
se regenera en minutos, cambiarla no obliga a re-anotar nada.
"""
from __future__ import annotations

import math
import random
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from shapely import affinity
from shapely.geometry import LineString, MultiLineString, Polygon
from shapely.ops import unary_union

from .common import ClassSchema, DatasetError, load_class_schema
from .vector_sources import VectorPlan

DOOR_LABELS = ("vano", "vano_y_barrido")
SHIFT = 3  # precisión subpíxel de OpenCV (1/8 px)
_F = 1 << SHIFT

_FONTS_DIR = Path(__file__).resolve().parents[2] / "structura-mobile" / "assets" / "fonts"

ROOM_TEXT_ES = {
    "BEDROOM": ["DORMITORIO", "DORM.", "HABITACIÓN"], "ROOM": ["DORMITORIO", "HABITACIÓN", "ESTUDIO"],
    "LIVING_ROOM": ["ESTAR", "LIVING"], "LIVING_DINING": ["LIVING COMEDOR", "ESTAR-COMEDOR"],
    "DINING": ["COMEDOR"], "KITCHEN": ["COCINA"], "KITCHEN_DINING": ["COCINA COMEDOR"],
    "BATHROOM": ["BAÑO", "TOILETTE"], "CORRIDOR": ["PASILLO", "CIRCULACIÓN", "HALL"],
    "CORRIDORS_AND_HALLS": ["HALL"], "BALCONY": ["BALCÓN", "TERRAZA"], "LOGGIA": ["GALERÍA"],
    "STOREROOM": ["DEPÓSITO", "BAULERA"], "STAIRCASE": ["PALIER"], "OFFICE": ["OFICINA", "ESTUDIO"],
    "TERRACE": ["TERRAZA"], "GARAGE": ["COCHERA"], "WASH_AND_DRY_ROOM": ["LAVADERO"],
    "GARDEN": ["JARDÍN"], "LOBBY": ["HALL DE ACCESO"],
}
ROOM_TEXT_EN = {"BEDROOM": "BEDROOM", "ROOM": "ROOM", "LIVING_ROOM": "LIVING", "KITCHEN": "KITCHEN",
                "BATHROOM": "BATH", "CORRIDOR": "HALL", "BALCONY": "BALCONY", "STOREROOM": "STORAGE"}


class RenderSkipped(Exception):
    """El plano no es apto (sin muros, demasiado chico o demasiado grande)."""


@dataclass
class Style:
    px_per_m: float
    margin_m: float
    paper: tuple[int, int, int]
    ink: tuple[int, int, int]
    line_px: int
    wall: str           # solid | gray | hatch | outline | mixed
    wall_gray: int
    hatch_spacing_m: float
    hatch_angle: float
    door: str           # arc | arc_dashed | gap | sliding | mixed
    door_threshold: bool
    window: str         # one_line | two_lines | filled
    window_sill: bool
    column: str         # solid | cross | hatch
    stairs_arrow: bool
    fixtures: bool
    floor_pattern: bool
    room_text: str      # none | es | es_area | en
    font: str           # hershey | roboto
    text_m: float
    dimensions: int     # 0, 1 o 2 lados con cotas
    grid_axes: bool
    title: bool
    synthetic_columns: bool  # columnas agregadas en extremos de muros gruesos (aumento declarado)
    tilt_deg: float
    lowres: float
    blur: float
    gradient: float
    jpeg_quality: int


def sample_style(rng: random.Random, *, px_per_m: float | None = None) -> Style:
    def pick(options: dict[str, float]) -> str:
        return rng.choices(list(options), weights=list(options.values()))[0]

    ink_v = rng.randint(0, 70)
    ink = (ink_v, ink_v, ink_v)
    if rng.random() < 0.08:  # tinta azul oscura (copias heliográficas, CAD)
        ink = (rng.randint(90, 140), rng.randint(40, 70), rng.randint(10, 40))
    pv = rng.randint(236, 255)
    paper = (max(0, pv - rng.randint(0, 10)), max(0, pv - rng.randint(0, 5)), pv)  # BGR, levemente cálido
    return Style(
        px_per_m=px_per_m or math.exp(rng.uniform(math.log(38), math.log(115))),
        margin_m=rng.uniform(0.6, 1.4),
        paper=paper, ink=ink,
        line_px=rng.choice([1, 1, 2, 2, 3]),
        wall=pick({"solid": 0.34, "gray": 0.14, "hatch": 0.18, "outline": 0.2, "mixed": 0.14}),
        wall_gray=rng.randint(90, 185),
        hatch_spacing_m=rng.uniform(0.05, 0.11), hatch_angle=rng.choice([45.0, -45.0, 45.0, 30.0]),
        door=pick({"arc": 0.5, "arc_dashed": 0.1, "gap": 0.12, "sliding": 0.06, "mixed": 0.22}),
        door_threshold=rng.random() < 0.35,
        window=pick({"one_line": 0.35, "two_lines": 0.4, "filled": 0.25}),
        window_sill=rng.random() < 0.3,
        column=pick({"solid": 0.6, "cross": 0.2, "hatch": 0.2}),
        stairs_arrow=rng.random() < 0.6,
        fixtures=rng.random() < 0.75,
        floor_pattern=rng.random() < 0.15,
        room_text=pick({"none": 0.15, "es": 0.35, "es_area": 0.4, "en": 0.1}),
        font=pick({"hershey": 0.5, "roboto": 0.5}),
        text_m=rng.uniform(0.16, 0.32),
        dimensions=rng.choices([0, 1, 2], weights=[0.4, 0.3, 0.3])[0],
        grid_axes=rng.random() < 0.1,
        title=rng.random() < 0.2,
        synthetic_columns=rng.random() < 0.35,
        tilt_deg=rng.uniform(-1.5, 1.5) if rng.random() < 0.2 else 0.0,
        lowres=rng.uniform(0.5, 0.8) if rng.random() < 0.2 else 0.0,
        blur=rng.uniform(0.4, 1.1) if rng.random() < 0.35 else 0.0,
        gradient=rng.uniform(0.05, 0.22) if rng.random() < 0.2 else 0.0,
        jpeg_quality=rng.randint(40, 90) if rng.random() < 0.3 else 0,
    )


# ---------------------------------------------------------------------------
# Geometría
# ---------------------------------------------------------------------------

def polys(g: Any) -> list[Polygon]:
    if g is None or g.is_empty:
        return []
    if g.geom_type == "Polygon":
        return [g]
    if hasattr(g, "geoms"):
        return [p for x in g.geoms for p in polys(x)]
    return []


def dominant_angle(walls: list[Polygon]) -> float:
    """Orientación dominante de los muros (grados en [0, 90)), ponderada por largo."""
    hist = np.zeros(180)
    for w in walls:
        r = w.minimum_rotated_rectangle
        if r.geom_type != "Polygon":
            continue
        c = list(r.exterior.coords)
        for a, b in zip(c, c[1:]):
            length = math.dist(a, b)
            if length > 0:
                ang = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 90.0
                hist[int(ang * 2) % 180] += length
    if not hist.any():
        return 0.0
    smooth = hist + np.roll(hist, 1) + np.roll(hist, -1)
    return float(np.argmax(smooth)) / 2.0 + 0.25


def rect_frame(poly: Polygon) -> tuple[np.ndarray, np.ndarray, np.ndarray, float, float]:
    """Rectángulo mínimo: centro, eje largo u, eje corto n, largo y ancho."""
    r = poly.minimum_rotated_rectangle
    c = np.array(r.exterior.coords[:4])
    e0, e1 = c[1] - c[0], c[2] - c[1]
    l0, l1 = float(np.hypot(*e0)), float(np.hypot(*e1))
    if l0 >= l1:
        u, w, t, n = e0 / max(l0, 1e-9), l0, l1, e1 / max(l1, 1e-9)
    else:
        u, w, t, n = e1 / max(l1, 1e-9), l1, l0, e0 / max(l0, 1e-9)
    return c.mean(axis=0), u, n, w, t


@dataclass
class Prepared:
    layers: dict[str, list[Polygon]]
    fixtures: list[tuple[str, Polygon]]
    rooms: list[tuple[str, Polygon]]
    bounds: tuple[float, float, float, float]


def prepare(plan: VectorPlan) -> Prepared:
    """Escala a metros y alinea los muros con los ejes (los planos se dibujan ortogonales a la hoja)."""
    k = plan.meters_per_unit
    walls = [p for g in plan.layers.get("wall", []) for p in polys(g)]
    if not walls:
        raise RenderSkipped(f"{plan.plan_id}: sin muros")
    angle = dominant_angle(walls)

    def tf(g: Any) -> Any:
        if k != 1.0:
            g = affinity.scale(g, xfact=k, yfact=k, origin=(0, 0))
        return affinity.rotate(g, -angle, origin=(0, 0)) if angle else g

    layers = {name: [p for g in plan.layers.get(name, []) for p in polys(tf(g))] for name in plan.layers}
    fixtures = [(t, p) for t, g in plan.fixtures for p in polys(tf(g))]
    rooms = [(t, p) for t, g in plan.rooms for p in polys(tf(g))]
    every = [p for v in layers.values() for p in v]
    b = unary_union(every).bounds
    return Prepared(layers, fixtures, rooms, b)


# ---------------------------------------------------------------------------
# Rasterización
# ---------------------------------------------------------------------------

class Canvas:
    def __init__(self, bounds: tuple[float, float, float, float], s: float, margin_px: int, paper: tuple[int, int, int]):
        self.minx, self.miny, self.maxx, self.maxy = bounds
        self.s = s
        self.m = margin_px
        self.w = int(math.ceil((self.maxx - self.minx) * s)) + 2 * margin_px
        self.h = int(math.ceil((self.maxy - self.miny) * s)) + 2 * margin_px
        self.img = np.empty((self.h, self.w, 3), np.uint8)
        self.img[:] = paper

    def px(self, x: float, y: float) -> tuple[float, float]:
        return (x - self.minx) * self.s + self.m, (self.maxy - y) * self.s + self.m

    def pts(self, coords: Any) -> np.ndarray:
        a = np.asarray(coords, dtype=np.float64)[:, :2]
        out = np.empty_like(a)
        out[:, 0] = (a[:, 0] - self.minx) * self.s + self.m
        out[:, 1] = (self.maxy - a[:, 1]) * self.s + self.m
        return np.round(out * _F).astype(np.int32)

    # --- capas binarias (máscara) y de cobertura (dibujo con antialias)
    def layer(self, geoms: list[Polygon], aa: bool = False) -> np.ndarray:
        out = np.zeros((self.h, self.w), np.uint8)
        lt = cv2.LINE_AA if aa else cv2.LINE_8
        for p in geoms:
            cv2.fillPoly(out, [self.pts(p.exterior.coords)], 255, lt, SHIFT)
            for hole in p.interiors:
                cv2.fillPoly(out, [self.pts(hole.coords)], 0, lt, SHIFT)
        return out

    def blend(self, coverage: np.ndarray, color: tuple[int, int, int], origin: tuple[int, int] = (0, 0)) -> None:
        x0, y0 = origin
        h, w = coverage.shape
        region = self.img[y0:y0 + h, x0:x0 + w]
        a = coverage.astype(np.float32)[..., None] / 255.0
        region[:] = (region * (1 - a) + np.array(color, np.float32) * a).astype(np.uint8)

    def local_layer(self, geoms: list[Polygon], aa: bool = True) -> tuple[np.ndarray, tuple[int, int]]:
        """Capa recortada a la caja de las geometrías (mucho más rápida que el lienzo entero)."""
        b = unary_union(geoms).bounds if len(geoms) > 1 else geoms[0].bounds
        (xa, ya), (xb, yb) = self.px(b[0], b[3]), self.px(b[2], b[1])
        x0, y0 = max(0, int(xa) - 2), max(0, int(ya) - 2)
        x1, y1 = min(self.w, int(math.ceil(xb)) + 3), min(self.h, int(math.ceil(yb)) + 3)
        out = np.zeros((max(1, y1 - y0), max(1, x1 - x0)), np.uint8)
        lt = cv2.LINE_AA if aa else cv2.LINE_8
        off = np.array([x0 * _F, y0 * _F], np.int32)
        for p in geoms:
            cv2.fillPoly(out, [self.pts(p.exterior.coords) - off], 255, lt, SHIFT)
            for hole in p.interiors:
                cv2.fillPoly(out, [self.pts(hole.coords) - off], 0, lt, SHIFT)
        return out, (x0, y0)

    def fill(self, geoms: list[Polygon], color: tuple[int, int, int]) -> None:
        if geoms:
            cov, origin = self.local_layer(geoms)
            self.blend(cov, color, origin)

    def stroke(self, coords: Any, color: tuple[int, int, int], thickness: int = 1, closed: bool = False) -> None:
        cv2.polylines(self.img, [self.pts(coords)], closed, color, max(1, int(thickness)), cv2.LINE_AA, SHIFT)

    def outline(self, geoms: list[Polygon], color: tuple[int, int, int], thickness: int) -> None:
        for p in geoms:
            self.stroke(p.exterior.coords, color, thickness, True)
            for hole in p.interiors:
                self.stroke(hole.coords, color, thickness, True)

    def dashed(self, a: np.ndarray, b: np.ndarray, color, thickness: int, dash_m: float, gap_m: float) -> None:
        length = float(np.hypot(*(b - a)))
        if length <= 0:
            return
        d = (b - a) / length
        t = 0.0
        while t < length:
            e = min(length, t + dash_m)
            self.stroke([a + d * t, a + d * e], color, thickness)
            t = e + gap_m


def _mix(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a * (1 - t) + b * t)) for a, b in zip(c1, c2))  # type: ignore[return-value]


def _hatch_layer(shape: tuple[int, int], spacing_px: float, angle_deg: float, thickness: int = 1) -> np.ndarray:
    h, w = shape
    out = np.zeros((h, w), np.uint8)
    spacing_px = max(3.0, spacing_px)
    a = math.radians(angle_deg)
    d = np.array([math.cos(a), -math.sin(a)])
    nrm = np.array([-d[1], d[0]])
    diag = math.hypot(w, h)
    center = np.array([w / 2, h / 2])
    k = -diag / 2
    while k < diag / 2:
        p = center + nrm * k
        p0, p1 = p - d * diag, p + d * diag
        cv2.line(out, (int(p0[0] * _F), int(p0[1] * _F)), (int(p1[0] * _F), int(p1[1] * _F)), 255, thickness,
                 cv2.LINE_AA, SHIFT)
        k += spacing_px
    return out


# --- texto -------------------------------------------------------------------

_HERSHEY = [cv2.FONT_HERSHEY_SIMPLEX, cv2.FONT_HERSHEY_DUPLEX, cv2.FONT_HERSHEY_PLAIN, cv2.FONT_HERSHEY_COMPLEX_SMALL]
_ASCII = str.maketrans("ÁÉÍÓÚÑáéíóúñ²", "AEIOUNaeioun2")


def text_stamp(text: str, size_px: int, font: str, rng: random.Random, bold: bool = False) -> np.ndarray:
    """Cobertura (uint8) de un texto. Roboto si está disponible; si no, Hershey (sin acentos)."""
    size_px = int(max(7, min(48, size_px)))
    if font == "roboto":
        path = _FONTS_DIR / ("roboto-bold.ttf" if bold else "roboto-regular.ttf")
        if path.exists():
            from PIL import Image, ImageDraw, ImageFont

            f = ImageFont.truetype(str(path), size_px)
            x0, y0, x1, y1 = f.getbbox(text)
            im = Image.new("L", (max(1, x1 - x0 + 2), max(1, y1 - y0 + 2)), 0)
            ImageDraw.Draw(im).text((-x0 + 1, -y0 + 1), text, font=f, fill=255)
            return np.array(im)
    face = rng.choice(_HERSHEY)
    t = text.translate(_ASCII)
    scale = cv2.getFontScaleFromHeight(face, size_px, 1)
    th = 2 if bold and size_px > 14 else 1
    (tw, tht), base = cv2.getTextSize(t, face, scale, th)
    im = np.zeros((tht + base + 4, tw + 4), np.uint8)
    cv2.putText(im, t, (2, tht + 2), face, scale, 255, th, cv2.LINE_AA)
    return im


def paste_text(cv: Canvas, stamp: np.ndarray, cx: float, cy: float, color, rotate: bool = False) -> None:
    if rotate:
        stamp = np.ascontiguousarray(np.rot90(stamp))
    h, w = stamp.shape
    x0, y0 = int(round(cx - w / 2)), int(round(cy - h / 2))
    xa, ya, xb, yb = max(0, x0), max(0, y0), min(cv.w, x0 + w), min(cv.h, y0 + h)
    if xa >= xb or ya >= yb:
        return
    a = stamp[ya - y0:yb - y0, xa - x0:xb - x0].astype(np.float32)[..., None] / 255.0
    region = cv.img[ya:yb, xa:xb].astype(np.float32)
    cv.img[ya:yb, xa:xb] = (region * (1 - a) + np.array(color, np.float32) * a).astype(np.uint8)


def _fmt_m(v: float) -> str:
    return f"{v:.2f}".replace(".", ",")


# ---------------------------------------------------------------------------
# Elementos
# ---------------------------------------------------------------------------

def _draw_walls(cv: Canvas, st: Style, walls: list[Polygon], openings: list[Polygon], rng: random.Random) -> None:
    body = unary_union(walls)
    if openings:
        body = body.difference(unary_union(openings).buffer(1e-4))
    geoms = polys(body)
    lw = st.line_px
    mode = st.wall
    if mode == "mixed":  # muros gruesos macizos o rayados, tabiques en contorno
        thick = [g for g in geoms if _thickness(g) >= 0.2]
        thin = [g for g in geoms if _thickness(g) < 0.2]
        _fill_walls(cv, st, thick, rng.choice(["solid", "hatch", "gray"]), lw)
        _fill_walls(cv, st, thin, "outline", lw)
    else:
        _fill_walls(cv, st, geoms, mode, lw)


def _thickness(p: Polygon) -> float:
    _, _, _, w, t = rect_frame(p)
    # Para polígonos en L o T el rectángulo mínimo exagera: aproximación área / largo.
    return min(t, p.area / max(w, 1e-9))


def _hatch_fill(cv: Canvas, geoms: list[Polygon], spacing_px: float, angle: float, color) -> None:
    cov, origin = cv.local_layer(geoms)
    hatch = _hatch_layer(cov.shape, spacing_px, angle)
    cv.blend((hatch.astype(np.uint16) * cov // 255).astype(np.uint8), color, origin)


def _fill_walls(cv: Canvas, st: Style, geoms: list[Polygon], mode: str, lw: int) -> None:
    if not geoms:
        return
    if mode == "solid":
        cv.fill(geoms, st.ink)
    elif mode == "gray":
        cv.fill(geoms, (st.wall_gray,) * 3)
        cv.outline(geoms, st.ink, lw)
    elif mode == "hatch":
        _hatch_fill(cv, geoms, st.hatch_spacing_m * cv.s, st.hatch_angle, st.ink)
        cv.outline(geoms, st.ink, lw)
    else:  # outline
        cv.outline(geoms, st.ink, lw)


def _door_symbol(cv: Canvas, st: Style, door: Polygon, rng: random.Random, mode: str) -> Polygon | None:
    """Dibuja el símbolo y devuelve el sector de barrido (para la convención alternativa)."""
    c, u, n, w, t = rect_frame(door)
    thin = max(1, st.line_px - 1)
    if st.door_threshold:
        for sgn in (-1, 1):
            a, b = c - u * w / 2 + n * sgn * t / 2, c + u * w / 2 + n * sgn * t / 2
            cv.stroke([a, b], st.ink, thin)
    if mode == "gap" or w < 0.45:
        return None
    if mode == "sliding":
        for k, sgn in ((-1, -1), (1, 1)):
            a = c + u * k * w * 0.2 + n * sgn * t * 0.2
            leaf = Polygon([a - u * w * 0.32 - n * 0.02, a + u * w * 0.32 - n * 0.02,
                            a + u * w * 0.32 + n * 0.02, a - u * w * 0.32 + n * 0.02])
            cv.outline([leaf], st.ink, thin)
        return None
    side = rng.choice([-1, 1])
    leaves = [(1, w)] if (w <= 1.25 or rng.random() < 0.35) else [(1, w / 2), (-1, w / 2)]
    hinge_end = rng.choice([-1, 1])
    sectors = []
    for k, (sgn_end, lw_) in enumerate(leaves):
        e = hinge_end * sgn_end
        hinge = c + u * e * w / 2 + n * side * t / 2
        leaf_end = hinge + n * side * lw_
        jamb = hinge - u * e * lw_
        a0 = math.atan2(*(leaf_end - hinge)[::-1])
        a1 = math.atan2(*(jamb - hinge)[::-1])
        d = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        arc = [hinge + lw_ * np.array([math.cos(a0 + d * i / 24), math.sin(a0 + d * i / 24)]) for i in range(25)]
        cv.stroke([hinge, leaf_end], st.ink, st.line_px)
        if mode == "arc_dashed":
            for i in range(0, 24, 2):
                cv.stroke(arc[i:i + 2], st.ink, thin)
        else:
            cv.stroke(arc, st.ink, thin)
        sectors.append(Polygon([hinge, *arc]))
    return unary_union(sectors) if sectors else None


def _window_symbol(cv: Canvas, st: Style, win: Polygon) -> None:
    c, u, n, w, t = rect_frame(win)
    thin = max(1, st.line_px - 1)
    if st.window == "filled":
        cv.fill([win], _mix(st.paper, (205, 215, 225), 0.8))
    cv.outline([win], st.ink, thin)
    offsets = [0.0] if st.window == "one_line" else [-t / 6, t / 6]
    if st.window == "filled":
        offsets = [0.0]
    for o in offsets:
        cv.stroke([c - u * w / 2 + n * o, c + u * w / 2 + n * o], st.ink, thin)
    if st.window_sill:
        o = t / 2 + 0.05
        cv.stroke([c - u * (w / 2 + 0.05) + n * o, c + u * (w / 2 + 0.05) + n * o], st.ink, thin)


def _stairs_symbol(cv: Canvas, st: Style, poly: Polygon, rng: random.Random) -> None:
    c, u, n, w, t = rect_frame(poly)
    thin = max(1, st.line_px - 1)
    cv.outline([poly], st.ink, st.line_px)
    tread = rng.uniform(0.25, 0.31)
    k = -w / 2 + tread
    lines = []
    while k < w / 2 - 0.05:
        p = c + u * k
        lines.append([tuple(p - n * (t + 1)), tuple(p + n * (t + 1))])
        k += tread
    if lines:
        clipped = MultiLineString(lines).intersection(poly)
        for g in getattr(clipped, "geoms", [clipped]):
            if g.geom_type == "LineString" and not g.is_empty:
                cv.stroke(list(g.coords), st.ink, thin)
    if st.stairs_arrow and w > 1.2:
        a, b = c - u * (w / 2 - 0.2), c + u * (w / 2 - 0.2)
        cv.stroke([a, b], st.ink, thin)
        head = 0.18
        cv.stroke([b - u * head + n * head * 0.6, b, b - u * head - n * head * 0.6], st.ink, thin)
    if rng.random() < 0.3 and w > 1.5:  # línea de corte
        m = c + u * rng.uniform(-w / 4, w / 4)
        cv.stroke([m - n * t / 2 - u * 0.15, m - u * 0.05, m + u * 0.05, m + n * t / 2 + u * 0.15], st.ink, thin)


def _column_symbol(cv: Canvas, st: Style, col: Polygon) -> None:
    if st.column == "solid":
        cv.fill([col], st.ink)
        return
    cv.outline([col], st.ink, st.line_px)
    if st.column == "cross":
        c = list(col.minimum_rotated_rectangle.exterior.coords)
        cv.stroke([c[0], c[2]], st.ink, 1)
        cv.stroke([c[1], c[3]], st.ink, 1)
    else:
        _hatch_fill(cv, [col], max(3.0, 0.05 * cv.s), 45.0, st.ink)


def _fixture_symbol(cv: Canvas, color, kind: str, poly: Polygon) -> None:
    cv.outline([poly], color, 1)
    c, u, n, w, t = rect_frame(poly)
    if kind in ("TOILET", "SINK") and w > 0.2:
        cx, cy = cv.px(*c)
        ang = -math.degrees(math.atan2(u[1], u[0]))
        cv2.ellipse(cv.img, ((cx, cy), (w * cv.s * 0.7, t * cv.s * 0.6), ang), color, 1, cv2.LINE_AA)
    elif kind == "BATHTUB":
        inner = poly.buffer(-min(0.06, t / 4))
        cv.outline(polys(inner), color, 1)
    elif kind in ("SHOWER", "ELEVATOR"):
        r = list(poly.minimum_rotated_rectangle.exterior.coords)
        cv.stroke([r[0], r[2]], color, 1)
        cv.stroke([r[1], r[3]], color, 1)


def _dimension_chain(cv: Canvas, st: Style, walls: list[Polygon], side: str, rng: random.Random) -> None:
    b = (cv.minx, cv.miny, cv.maxx, cv.maxy)
    horizontal = side in ("top", "bottom")
    off = rng.uniform(0.45, 0.8)
    band = 1.2
    xs = []
    for wpoly in walls:
        x0, y0, x1, y1 = wpoly.bounds
        if horizontal:
            near = (y1 >= b[3] - band) if side == "top" else (y0 <= b[1] + band)
            if near:
                xs += [x0, x1]
        else:
            near = x0 <= b[0] + band
            if near:
                xs += [y0, y1]
    lo, hi = (b[0], b[2]) if horizontal else (b[1], b[3])
    xs = sorted(set([lo, hi] + xs))
    ticks = []
    for x in xs:
        if not ticks or x - ticks[-1] >= 0.5:
            ticks.append(x)
    if len(ticks) < 2:
        return
    thin = 1
    color = _mix(st.ink, st.paper, 0.15)
    tick = 0.12
    size = int(max(8, min(30, rng.uniform(0.15, 0.22) * cv.s)))

    def P(along: float, across: float) -> np.ndarray:
        if horizontal:
            return np.array([along, across])
        return np.array([across, along])

    base = (b[3] + off) if side == "top" else (b[1] - off) if side == "bottom" else (b[0] - off)
    cv.stroke([P(ticks[0], base), P(ticks[-1], base)], color, thin)
    toward = -1 if side in ("top",) else 1
    for x in ticks:
        cv.stroke([P(x, base + 0.15), P(x, base + toward * (off - 0.15))], color, thin)  # línea de extensión
        cv.stroke([P(x - tick / 2, base - tick / 2), P(x + tick / 2, base + tick / 2)], color, thin + 1)
    for a, c in zip(ticks, ticks[1:]):
        stamp = text_stamp(_fmt_m(c - a), size, st.font, rng)
        mid = P((a + c) / 2, base + (0.13 if side != "bottom" else -0.13) * (1 if horizontal else -1))
        px, py = cv.px(*mid)
        if horizontal:
            py -= stamp.shape[0] / 2 if side == "top" else -stamp.shape[0] / 2
        else:
            px -= stamp.shape[0] / 2
        if (c - a) * cv.s > stamp.shape[1] * 0.9 or not horizontal:
            paste_text(cv, stamp, px, py, color, rotate=not horizontal)


def _grid_axes(cv: Canvas, st: Style, rng: random.Random) -> None:
    color = _mix(st.ink, st.paper, 0.45)
    step = rng.uniform(3.0, 6.0)
    r = 0.3
    for i, x in enumerate(np.arange(cv.minx + 0.3, cv.maxx, step)):
        a, b = np.array([x, cv.miny - 0.2]), np.array([x, cv.maxy + cv.m / cv.s - 2 * r - 0.1])
        cv.dashed(a, b, color, 1, 0.6, 0.15)
        cx, cy = cv.px(x, cv.maxy + cv.m / cv.s - r - 0.05)
        cv2.circle(cv.img, (int(cx), int(cy)), int(r * cv.s), color, 1, cv2.LINE_AA)
        paste_text(cv, text_stamp(chr(65 + i % 26), int(r * cv.s), st.font, rng), cx, cy, color)


# ---------------------------------------------------------------------------
# Plano completo
# ---------------------------------------------------------------------------

def synthetic_columns(walls: list[Polygon], rng: random.Random, share: float = 0.35) -> list[Polygon]:
    """Columnas como en una estructura de hormigón armado: cuadradas, en extremos e
    intersecciones de muros gruesos, algo más anchas que el muro. Es un AUMENTO: las
    fuentes suizas casi no tienen columnas y los planos latinoamericanos sí."""
    points: list[np.ndarray] = []
    sizes: list[float] = []
    for wpoly in walls:
        c, u, n, w, t = rect_frame(wpoly)
        if not (0.12 <= t <= 0.45 and w >= 1.0):
            continue
        for e in (-1, 1):
            p = c + u * e * (w / 2 - t / 2)
            if all(float(np.hypot(*(p - q))) > 0.5 for q in points):
                points.append(p)
                sizes.append(t)
    out = []
    for p, t in zip(points, sizes):
        if rng.random() < share:
            side = min(0.45, max(0.2, t * rng.uniform(1.0, 1.6)))
            h = side / 2
            out.append(Polygon([(p[0] - h, p[1] - h), (p[0] + h, p[1] - h), (p[0] + h, p[1] + h), (p[0] - h, p[1] + h)]))
    return out


@dataclass
class RenderResult:
    image: np.ndarray       # BGR uint8
    mask: np.ndarray        # uint8, IDs de config/classes.yaml
    px_per_m: float
    style: dict[str, Any]
    counts: dict[str, int]


def render_plan(plan: VectorPlan, seed: int, *, door_label: str = "vano", style: Style | None = None,
                max_side: int = 4096, min_px_per_m: float = 25.0,
                schema: ClassSchema | None = None) -> RenderResult:
    if door_label not in DOOR_LABELS:
        raise DatasetError(f"door_label inválido {door_label!r}; opciones {DOOR_LABELS}")
    schema = schema or load_class_schema()
    rng = random.Random(seed)
    pr = prepare(plan)
    st = style or sample_style(rng)
    minx, miny, maxx, maxy = pr.bounds
    ext = max(maxx - minx, maxy - miny)
    if ext < 2.5:
        raise RenderSkipped(f"{plan.plan_id}: plano demasiado chico ({ext:.1f} m)")
    margin_m = st.margin_m + (0.9 if st.dimensions else 0) + (0.9 if st.grid_axes else 0) + (0.6 if st.title else 0)
    s = min(st.px_per_m, (max_side - 8) / (ext + 2 * margin_m))
    if s < min_px_per_m:
        raise RenderSkipped(f"{plan.plan_id}: demasiado grande para {max_side} px ({ext:.0f} m)")
    st.px_per_m = s
    cv = Canvas(pr.bounds, s, int(math.ceil(margin_m * s)), st.paper)
    L = pr.layers
    walls, doors, windows = L.get("wall", []), L.get("door", []), L.get("window", [])
    cols, stairs, rails = L.get("column", []), L.get("stairs", []), L.get("railing", [])
    n_synthetic = 0
    if st.synthetic_columns:
        extra = synthetic_columns(walls, rng)
        n_synthetic = len(extra)
        cols = cols + extra
    soft = _mix(st.ink, st.paper, 0.35)

    # Fondo: ejes, solados, artefactos, barandas, escaleras (debajo de los muros).
    if st.grid_axes:
        _grid_axes(cv, st, rng)
    if st.floor_pattern:
        for kind, room in pr.rooms:
            if kind in ("BATHROOM", "KITCHEN") and room.area > 1:
                x0, y0, x1, y1 = room.bounds
                step = 0.3
                grid = [[(x, y0), (x, y1)] for x in np.arange(x0, x1, step)] + \
                       [[(x0, y), (x1, y)] for y in np.arange(y0, y1, step)]
                inter = MultiLineString(grid).intersection(room)
                for g in getattr(inter, "geoms", [inter]):
                    if g.geom_type == "LineString" and not g.is_empty:
                        cv.stroke(list(g.coords), _mix(st.ink, st.paper, 0.8), 1)
    if st.fixtures:
        for kind, f in pr.fixtures:
            _fixture_symbol(cv, soft, kind, f)
    for r in rails:
        cv.outline([r], soft, 1)
    for p in stairs:
        _stairs_symbol(cv, st, p, rng)

    _draw_walls(cv, st, walls, doors + windows, rng)
    for wnd in windows:
        _window_symbol(cv, st, wnd)
    swings = []
    for d in doors:
        mode = st.door if st.door != "mixed" else rng.choice(["arc", "arc", "arc", "gap", "sliding", "arc_dashed"])
        sector = _door_symbol(cv, st, d, rng, mode)
        if sector is not None:
            swings.append(sector)
    for c in cols:
        _column_symbol(cv, st, c)

    # Textos y cotas.
    if st.room_text != "none":
        for kind, room in pr.rooms:
            if room.area < 2.0:
                continue
            if st.room_text == "en":
                label = ROOM_TEXT_EN.get(kind)
            else:
                opts = ROOM_TEXT_ES.get(kind)
                label = rng.choice(opts) if opts else None
            if not label:
                continue
            pt = room.representative_point()
            cx, cy = cv.px(pt.x, pt.y)
            size = int(st.text_m * s)
            stamp = text_stamp(label, size, st.font, rng, bold=rng.random() < 0.4)
            if stamp.shape[1] > (room.bounds[2] - room.bounds[0]) * s * 1.1:
                continue
            paste_text(cv, stamp, cx, cy, st.ink)
            if st.room_text == "es_area":
                area = f"{room.area:.2f}".replace(".", ",") + (" m²" if st.font == "roboto" else " m2")
                a_stamp = text_stamp(area, int(size * 0.8), st.font, rng)
                paste_text(cv, a_stamp, cx, cy + stamp.shape[0] * 1.1, st.ink)
    sides = rng.sample(["top", "bottom", "left"], st.dimensions) if st.dimensions else []
    for side in sides:
        _dimension_chain(cv, st, walls, side, rng)
    if st.title:
        t = rng.choice(["PLANTA BAJA", "PLANTA TIPO", "PLANTA ALTA", "PLANTA GENERAL"]) + \
            rng.choice(["", "  ESC. 1:100", "  ESC 1:50", " - ESCALA 1:100"])
        stamp = text_stamp(t, int(0.35 * s), st.font, rng, bold=True)
        paste_text(cv, stamp, cv.w / 2, cv.h - cv.m * 0.35, st.ink)

    # Máscara exacta por prioridad (config/classes.yaml).
    door_geoms = doors if door_label == "vano" else polys(unary_union(doors + swings))
    class_geoms = {"wall": walls, "door": door_geoms, "window": windows, "column": cols, "stairs": stairs}
    mask = np.zeros((cv.h, cv.w), np.uint8)
    for name in schema.priority:
        g = class_geoms.get(name, [])
        if g:
            mask[cv.layer(g) > 0] = schema.id_of(name)

    image = _degrade(cv.img, st, rng)
    if st.tilt_deg:
        image, mask = _tilt(image, mask, st.tilt_deg, st.paper)
    counts = {k: len(v) for k, v in class_geoms.items()}
    counts["column_synthetic"] = n_synthetic
    return RenderResult(image, mask, s, asdict(st), counts)


def _degrade(img: np.ndarray, st: Style, rng: random.Random) -> np.ndarray:
    out = img
    if st.lowres:
        h, w = out.shape[:2]
        small = cv2.resize(out, (max(1, int(w * st.lowres)), max(1, int(h * st.lowres))), interpolation=cv2.INTER_AREA)
        out = cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR)
    if st.blur:
        out = cv2.GaussianBlur(out, (0, 0), st.blur)
    if st.gradient:
        h, w = out.shape[:2]
        ang = rng.uniform(0, 2 * math.pi)
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        g = (xx / max(1, w) - 0.5) * math.cos(ang) + (yy / max(1, h) - 0.5) * math.sin(ang)
        field = 1.0 - st.gradient * (g - g.min()) / max(1e-6, float(g.max() - g.min()))
        out = np.clip(out.astype(np.float32) * field[..., None], 0, 255).astype(np.uint8)
    if st.jpeg_quality:
        ok, buf = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, st.jpeg_quality])
        if ok:
            out = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return out


def _tilt(image: np.ndarray, mask: np.ndarray, deg: float, paper) -> tuple[np.ndarray, np.ndarray]:
    h, w = mask.shape
    m = cv2.getRotationMatrix2D((w / 2, h / 2), deg, 1.0)
    image = cv2.warpAffine(image, m, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                           borderValue=tuple(int(v) for v in paper))
    mask = cv2.warpAffine(mask, m, (w, h), flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return image, mask
