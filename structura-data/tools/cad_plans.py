"""Planos de AutoCAD (DXF) → plantas renderizadas + máscaras derivadas de las CAPAS.

Los DWG se convierten antes a DXF con LibreDWG (``dwg2dxf``; herramienta de PC, no se
distribuye). Las etiquetas salen de la convención de capas del dibujante ("Muros",
"Ventanas", "Puertas", "Columnas", "Escalera", "Ladrillo Hueco", ...): son etiquetas
**débiles** (dependen de que el dibujo esté ordenado por capas) y se revisan visualmente.

Pasos:
1. Primitivas con la capa efectiva (los bloques en la capa "0" heredan la del INSERT).
2. Agrupado en láminas por proximidad (cada archivo trae plantas, cortes, vistas, carátula).
3. Una lámina es PLANTA si los muros forman caras delgadas en ambas direcciones y hay aberturas.
4. Escala desde el espesor mediano de muro medido (no se confía en $INSUNITS).
5. Máscaras: muros (rayados + caras delgadas entre líneas de muro), ventanas (rectángulo del
   grupo de líneas), puertas (vano bisagra→jamba calculado desde el arco: convención "vano"),
   columnas y escaleras (caras cerradas).
"""
from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

logging.getLogger("ezdxf").setLevel(logging.ERROR)

CLASS_RULES: list[tuple[str, re.Pattern]] = [
    ("ignore", re.compile(r"enu|enum|text|cota|dim|eje|nivel|ventilac", re.I)),
    ("wall", re.compile(r"^(b\.?\s*a\.?\s*)?(a-)?(muros?|muro trombe|muros defint\.?|hatch muro|ladrillos?( hueco)?|a-corte-ladrillos)$", re.I)),
    ("column", re.compile(r"^(b\.?\s*a\.?\s*)?(es-|a\. r\.e\.\s*)?(colum(nas?|nass)?\.?( perimetrales| new)?|columna)$", re.I)),
    ("window", re.compile(r"^(b\.?\s*a\.?\s*)?(a-simb-)?ventanas?$", re.I)),
    ("door", re.compile(r"^(b\.?\s*a\.?\s*)?(a-simb-)?(puertas?( interiores| exterior)?|carp puert embutida)$", re.I)),
    ("opening", re.compile(r"^(ventypuertas|puertas y ventanas|aberturas|carpinterias?|a-carpinterias)$", re.I)),
    ("stairs", re.compile(r"^(a-simb-)?escaleras?$", re.I)),
]


def layer_class(layer: str) -> str | None:
    name = layer.strip()
    for cls, pat in CLASS_RULES:
        if pat.search(name) if cls == "ignore" else pat.match(name):
            return None if cls == "ignore" else cls
    return None


@dataclass
class Prim:
    layer: str
    cls: str | None
    kind: str            # line | fill (se dibuja) | region (solo etiqueta) | text
    geom: Any            # shapely
    color: tuple[int, int, int] = (0, 0, 0)
    has_arc: bool = False


def _aci_rgb(doc, layer: str, entity) -> tuple[int, int, int]:
    from ezdxf import colors

    try:
        if entity.dxf.hasattr("true_color"):
            r, g, b = colors.int2rgb(entity.dxf.true_color)
            return (r, g, b)
        c = entity.dxf.color
        if c in (0, 256):
            c = doc.layers.get(layer).color if doc.layers.has_entry(layer) else 7
        if c == 7 or c <= 0 or c > 255:
            return (0, 0, 0)
        r, g, b = colors.aci2rgb(c)
        return (int(r), int(g), int(b))
    except Exception:
        return (0, 0, 0)


def load_primitives(dxf_path: str | Path, *, flatten: float = 0.0, max_depth: int = 8) -> list[Prim]:
    """Primitivas de modelspace con bloques explotados. ``flatten`` en unidades del dibujo
    (0 = automático según la extensión)."""
    import ezdxf
    from ezdxf import bbox
    from ezdxf import path as ezpath
    from shapely.geometry import LineString, Polygon

    doc = ezdxf.readfile(str(dxf_path))
    msp = doc.modelspace()
    if not flatten:
        b = bbox.extents(msp, fast=True)
        flatten = max(b.size.x, b.size.y) / 20000 if b.has_data else 0.01
    prims: list[Prim] = []

    def add_path(p, layer, color, cls, has_arc, closed_fill=False, fill_kind="fill"):
        pts = [(v.x, v.y) for v in p.flattening(flatten)]
        if len(pts) < 2:
            return
        if closed_fill and len(pts) >= 4:
            try:
                poly = Polygon(pts)
                if not poly.is_valid:
                    poly = poly.buffer(0)
                if not poly.is_empty and poly.area > 0:
                    prims.append(Prim(layer, cls, fill_kind, poly, color, has_arc))
                    return
            except Exception:
                pass
        prims.append(Prim(layer, cls, "line", LineString(pts), color, has_arc))

    def walk(entities, parent_layer: str | None, depth: int):
        for e in entities:
            t = e.dxftype()
            layer = e.dxf.layer if e.dxf.hasattr("layer") else "0"
            if parent_layer is not None and layer == "0":
                layer = parent_layer
            cls = layer_class(layer)
            color = _aci_rgb(doc, layer, e)
            try:
                if t == "INSERT":
                    if depth < max_depth:
                        walk(e.virtual_entities(), layer, depth + 1)
                elif t in ("TEXT", "MTEXT", "ATTRIB"):
                    prims.append(Prim(layer, None, "text", e, color))
                elif t in ("DIMENSION", "ARC_DIMENSION", "LEADER", "MLEADER"):
                    if depth < max_depth:
                        walk(e.virtual_entities(), layer, depth + 1)
                elif t == "HATCH":
                    solid = bool(e.dxf.solid_fill)
                    for bp in e.paths:
                        try:
                            p = ezpath.from_hatch_boundary_path(bp, ocs=e.ocs(), elevation=e.dxf.elevation.z)
                        except Exception:
                            continue
                        # Relleno sólido: se dibuja. Patrón: el contorno solo sirve para etiquetar.
                        add_path(p, layer, color, cls, False, closed_fill=True, fill_kind="fill" if solid else "region")
                    if not solid:
                        try:
                            from ezdxf.render import hatching
                            for a, b in hatching.hatch_entity(e):
                                prims.append(Prim(layer, None, "line", LineString([(a.x, a.y), (b.x, b.y)]), color))
                        except Exception:
                            pass
                elif t == "SOLID" or t == "TRACE":
                    vs = [e.dxf.vtx0, e.dxf.vtx1, e.dxf.vtx3, e.dxf.vtx2]
                    poly = Polygon([(v.x, v.y) for v in vs]).buffer(0)
                    if not poly.is_empty:
                        prims.append(Prim(layer, cls, "fill", poly, color))
                elif t in ("LINE", "ARC", "CIRCLE", "ELLIPSE", "LWPOLYLINE", "POLYLINE", "SPLINE"):
                    p = ezpath.make_path(e)
                    add_path(p, layer, color, cls, t in ("ARC",) or (t in ("LWPOLYLINE", "POLYLINE") and _has_bulge(e)))
            except Exception:
                continue

    walk(msp, None, 0)
    return prims


def _has_bulge(e) -> bool:
    try:
        if e.dxftype() == "LWPOLYLINE":
            return any(abs(b) > 1e-6 for *_, b in e.get_points("xyseb"))
        return any(abs(v.dxf.bulge) > 1e-6 for v in e.vertices)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Láminas
# ---------------------------------------------------------------------------

def cluster_sheets(prims: list[Prim], gap: float) -> list[list[int]]:
    """Agrupa primitivas cuyas cajas (agrandadas en ``gap``) se tocan."""
    from shapely import STRtree, box

    boxes = []
    for p in prims:
        g = p.geom
        if p.kind == "text":
            try:
                ins = g.dxf.insert
                boxes.append(box(ins.x, ins.y, ins.x, ins.y).buffer(gap))
            except Exception:
                boxes.append(box(0, 0, 0, 0))
            continue
        x0, y0, x1, y1 = g.bounds
        boxes.append(box(x0 - gap, y0 - gap, x1 + gap, y1 + gap))
    tree = STRtree(boxes)
    parent = list(range(len(prims)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    pairs = tree.query(boxes, predicate="intersects")
    for i, j in zip(*pairs):
        a, b = find(int(i)), find(int(j))
        if a != b:
            parent[a] = b
    groups: dict[int, list[int]] = {}
    for i in range(len(prims)):
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=len, reverse=True)


@dataclass
class Sheet:
    index: int
    prims: list[Prim]
    bounds: tuple[float, float, float, float]
    wall_width: float
    stats: dict[str, Any] = field(default_factory=dict)


def _thin_faces(lines, max_width: float):
    """Caras de la red de líneas cuyo ancho equivalente 2A/P es ≤ max_width."""
    from shapely.ops import polygonize, unary_union

    if not lines:
        return [], []
    noded = unary_union(lines)
    faces = list(polygonize(noded))
    thin, other = [], []
    for f in faces:
        if f.area <= 0:
            continue
        w = 2 * f.area / f.length
        (thin if w <= max_width else other).append(f)
    return thin, other


def estimate_wall_width(prims: list[Prim]) -> float | None:
    """Espesor de muro típico (unidades del dibujo) desde rellenos y caras de muro."""
    from shapely.ops import polygonize, unary_union

    widths = []
    for p in prims:
        if p.cls == "wall" and p.kind in ("fill", "region") and p.geom.length > 0:
            widths.append(2 * p.geom.area / p.geom.length)
    lines = [p.geom for p in prims if p.cls == "wall" and p.kind == "line"]
    if lines:
        try:
            for f in polygonize(unary_union(lines)):
                if f.area > 0 and f.length > 0:
                    r = f.minimum_rotated_rectangle
                    c = list(r.exterior.coords)
                    a, b = math.dist(c[0], c[1]), math.dist(c[1], c[2])
                    if max(a, b) > 3 * min(a, b) > 0:
                        widths.append(2 * f.area / f.length)
        except Exception:
            pass
    if len(widths) < 5:
        return None
    return float(np.median(widths))


def find_plan_sheets(prims: list[Prim], *, min_walls: int = 30) -> list[Sheet]:
    xs = [p.geom.bounds for p in prims if p.kind != "text"]
    if not xs:
        return []
    arr = np.array(xs)
    extent = max(arr[:, 2].max() - arr[:, 0].min(), arr[:, 3].max() - arr[:, 1].min())
    sheets = []
    for k, idx in enumerate(cluster_sheets(prims, gap=extent * 0.004)):
        ps = [prims[i] for i in idx]
        counts: dict[str, int] = {}
        for p in ps:
            if p.cls:
                counts[p.cls] = counts.get(p.cls, 0) + 1
        if counts.get("wall", 0) < min_walls or counts.get("window", 0) + counts.get("door", 0) + counts.get("opening", 0) < 2:
            continue
        w = estimate_wall_width(ps)
        if not w:
            continue
        geo = [p.geom.bounds for p in ps if p.kind != "text"]
        g = np.array(geo)
        bounds = (float(g[:, 0].min()), float(g[:, 1].min()), float(g[:, 2].max()), float(g[:, 3].max()))
        size = max(bounds[2] - bounds[0], bounds[3] - bounds[1])
        # Una planta mide decenas de espesores de muro; descarta detalles y carátulas.
        if not (25 * w <= size <= 1500 * w):
            continue
        thin, _ = _thin_faces([p.geom for p in ps if p.cls == "wall" and p.kind == "line"], 2.5 * w)
        fills = [p.geom for p in ps if p.cls == "wall" and p.kind in ("fill", "region")]
        horiz = vert = 0
        for f in thin + fills:
            x0, y0, x1, y1 = f.bounds
            if x1 - x0 > 3 * (y1 - y0):
                horiz += 1
            elif y1 - y0 > 3 * (x1 - x0):
                vert += 1
        # Planta: muros en ambas direcciones (una vista o un corte tiene pocos verticales delgados).
        if horiz < 4 or vert < 4:
            continue
        sheets.append(Sheet(k, ps, bounds, w, {"counts": counts, "thin_h": horiz, "thin_v": vert}))
    return sheets


# ---------------------------------------------------------------------------
# Etiquetas
# ---------------------------------------------------------------------------

def _clusters(geoms, tol: float):
    from shapely import STRtree

    if not geoms:
        return []
    buf = [g.buffer(tol) for g in geoms]
    tree = STRtree(buf)
    parent = list(range(len(geoms)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    a, b = tree.query(buf, predicate="intersects")
    for i, j in zip(a, b):
        ri, rj = find(int(i)), find(int(j))
        if ri != rj:
            parent[ri] = rj
    out: dict[int, list[int]] = {}
    for i in range(len(geoms)):
        out.setdefault(find(i), []).append(i)
    return list(out.values())


def _door_vano(group: list[Prim], t: float):
    """Vano de una puerta dibujada con arco: segmento bisagra→jamba extruido un espesor
    de muro hacia el lado opuesto al barrido."""
    from shapely.geometry import LineString, Point, Polygon

    arcs = [p.geom for p in group if p.has_arc and p.kind == "line"]
    if not arcs:
        return None
    arc = max(arcs, key=lambda g: g.length)
    pts = np.array(arc.coords)
    a, b = pts[0], pts[-1]
    mid = pts[len(pts) // 2]
    # Centro del círculo por tres puntos.
    ax, ay, bx, by, cx, cy = *a, *mid, *b
    d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-12:
        return None
    ux = ((ax**2 + ay**2) * (by - cy) + (bx**2 + by**2) * (cy - ay) + (cx**2 + cy**2) * (ay - by)) / d
    uy = ((ax**2 + ay**2) * (cx - bx) + (bx**2 + by**2) * (ax - cx) + (cx**2 + cy**2) * (bx - ax)) / d
    h = np.array([ux, uy])
    r = float(np.linalg.norm(a - h))
    if r <= 0:
        return None
    # La hoja es una línea desde la bisagra; la jamba es el extremo del arco que NO toca la hoja.
    leaf_end = None
    for p in group:
        if p.kind != "line" or p.has_arc:
            continue
        c = np.array(p.geom.coords)
        for q0, q1 in ((c[0], c[-1]), (c[-1], c[0])):
            if np.linalg.norm(q0 - h) < 0.15 * r and abs(np.linalg.norm(q1 - h) - r) < 0.2 * r:
                leaf_end = q1
    if leaf_end is not None:
        jamb = a if np.linalg.norm(a - leaf_end) > np.linalg.norm(b - leaf_end) else b
    else:
        jamb = b
    u = jamb - h
    n = np.array([-u[1], u[0]]) / max(np.linalg.norm(u), 1e-12)
    if np.dot(mid - h, n) > 0:  # el barrido va hacia +n → el muro hacia -n
        n = -n
    poly = Polygon([tuple(h), tuple(jamb), tuple(jamb + n * t), tuple(h + n * t)])
    return poly if poly.is_valid and poly.area > 0 else None


def sheet_labels(sheet: Sheet) -> dict[str, list]:
    """Polígonos por clase (unidades del dibujo)."""
    from shapely.ops import unary_union

    w = sheet.wall_width
    ps = sheet.prims
    out: dict[str, list] = {"wall": [], "door": [], "window": [], "column": [], "stairs": []}
    wall_lines = [p.geom for p in ps if p.cls == "wall" and p.kind == "line"]
    thin, _ = _thin_faces(wall_lines, 2.5 * w)
    out["wall"] += thin
    out["wall"] += [p.geom for p in ps if p.cls == "wall" and p.kind in ("fill", "region") and 2 * p.geom.area / max(p.geom.length, 1e-9) <= 3 * w]

    col_lines = [p.geom for p in ps if p.cls == "column" and p.kind == "line"]
    _, col_faces_all = _thin_faces(col_lines, 0)
    out["column"] += [f for f in col_faces_all if f.area <= (5 * w) ** 2]
    out["column"] += [p.geom for p in ps if p.cls == "column" and p.kind in ("fill", "region") and p.geom.area <= (5 * w) ** 2]

    groups: dict[str, list[Prim]] = {"window": [], "door": [], "opening": []}
    for p in ps:
        if p.cls in groups and p.kind in ("line", "fill", "region"):
            groups[p.cls].append(p)
    for cls in ("window", "door", "opening"):
        items = groups[cls]
        for g in _clusters([p.geom for p in items], tol=0.15 * w):
            grp = [items[i] for i in g]
            has_arc = any(p.has_arc for p in grp)
            target = cls if cls != "opening" else ("door" if has_arc else "window")
            if target == "door":
                v = _door_vano(grp, w)
                if v is not None:
                    out["door"].append(v)
                continue
            geom = unary_union([p.geom for p in grp])
            r = geom.minimum_rotated_rectangle
            if r.geom_type != "Polygon":
                continue
            c = list(r.exterior.coords)
            if len(c) < 3:  # rectángulo degenerado (trazos colineales)
                continue
            a, b = math.dist(c[0], c[1]), math.dist(c[1], c[2])
            if min(a, b) <= 3 * w and max(a, b) <= 40 * w:
                out["window"].append(r)

    st_lines = [p.geom for p in ps if p.cls == "stairs" and p.kind == "line"]
    if st_lines:
        for g in _clusters(st_lines, tol=0.5 * w):
            hull = unary_union([st_lines[i] for i in g]).convex_hull
            if hull.geom_type == "Polygon" and hull.area >= (4 * w) ** 2:
                out["stairs"].append(hull)
    return out


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

def render_sheet(sheet: Sheet, *, wall_px: float, color_mode: str = "black", margin_px: int = 40,
                 max_side: int = 4096, text: bool = True):
    """Imagen BGR + máscara de la lámina. ``wall_px`` fija la escala (espesor de muro en px)."""
    import cv2

    from .common import load_class_schema

    schema = load_class_schema()
    x0, y0, x1, y1 = sheet.bounds
    s = wall_px / sheet.wall_width
    s = min(s, (max_side - 2 * margin_px) / max(x1 - x0, y1 - y0))
    W = int(math.ceil((x1 - x0) * s)) + 2 * margin_px
    H = int(math.ceil((y1 - y0) * s)) + 2 * margin_px
    F = 8

    def pts(coords):
        a = np.asarray(coords, float)[:, :2]
        q = np.empty_like(a)
        q[:, 0] = (a[:, 0] - x0) * s + margin_px
        q[:, 1] = (y1 - a[:, 1]) * s + margin_px
        return np.round(q * F).astype(np.int32)

    img = np.full((H, W, 3), 255, np.uint8)

    def col(p):
        if color_mode == "black":
            return (20, 20, 20)
        r, g, b = p.color
        if (r, g, b) in ((255, 255, 255), (255, 255, 0)):
            return (60, 60, 60)
        return (b, g, r)

    for p in sheet.prims:
        if p.kind == "fill":
            for poly in getattr(p.geom, "geoms", [p.geom]):
                if poly.geom_type != "Polygon":
                    continue
                cv2.fillPoly(img, [pts(poly.exterior.coords)], col(p), cv2.LINE_AA, 3)
        elif p.kind == "line":
            th = 2 if p.cls == "wall" and wall_px >= 10 else 1
            cv2.polylines(img, [pts(p.geom.coords)], False, col(p), th, cv2.LINE_AA, 3)
        elif p.kind == "text" and text:
            _draw_text(img, p, pts, col(p))

    mask = np.zeros((H, W), np.uint8)
    labels = sheet_labels(sheet)
    # Muros dibujados como pares de líneas paralelas (sin jambas que cierren caras): se
    # rellena entre paralelas a menos de ~1,4 espesores con cierres horizontal y vertical.
    # Los vanos (≥ 0,6 m) no se puentean porque el núcleo mide un espesor y medio.
    wl = np.zeros((H, W), np.uint8)
    for p in sheet.prims:
        if p.cls == "wall" and p.kind == "line":
            cv2.polylines(wl, [pts(p.geom.coords)], False, 255, 1, cv2.LINE_8, 3)
    k = max(3, int(round(1.4 * sheet.wall_width * s)))
    closed = cv2.morphologyEx(wl, cv2.MORPH_CLOSE, np.ones((k, 1), np.uint8)) |         cv2.morphologyEx(wl, cv2.MORPH_CLOSE, np.ones((1, k), np.uint8))
    # Solo cuenta como muro lo que quedó relleno (no las líneas sueltas).
    filled = cv2.morphologyEx(closed, cv2.MORPH_OPEN, np.ones((max(2, k // 3),) * 2, np.uint8))
    for name in schema.priority:
        layer = np.zeros((H, W), np.uint8)
        if name == "wall":
            layer |= filled
        for g in labels.get(name, []):
            for poly in getattr(g, "geoms", [g]):
                if poly.geom_type != "Polygon":
                    continue
                cv2.fillPoly(layer, [pts(poly.exterior.coords)], 255, cv2.LINE_8, 3)
                for hole in poly.interiors:
                    cv2.fillPoly(layer, [pts(hole.coords)], 0, cv2.LINE_8, 3)
        mask[layer > 0] = schema.id_of(name)
    return img, mask, {"px_per_unit": s, "labels": {k: len(v) for k, v in labels.items()}}


def _draw_text(img, p: Prim, pts, color):
    import cv2

    try:
        from ezdxf.addons import text2path

        for path in text2path.make_paths_from_entity(p.geom):
            for sub in path.sub_paths():
                c = [(v.x, v.y) for v in sub.flattening(0.01)]
                if len(c) >= 2:
                    cv2.polylines(img, [pts(c)], False, color, 1, cv2.LINE_AA, 3)
    except Exception:
        pass
