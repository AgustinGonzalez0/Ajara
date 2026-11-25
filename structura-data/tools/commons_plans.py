"""Planos con licencia libre de Wikimedia Commons (prueba realista y posible entrenamiento).

Solo se aceptan licencias que permiten uso comercial sin "compartir igual":
dominio público, CC0 y CC BY (2.0/2.5/3.0/4.0). Se descartan CC BY-SA, NC, ND y GFDL.
Cada imagen queda con su autor, licencia y enlace en ``metadata.jsonl`` (atribución CC BY).

Uso::

    python -m tools.commons_plans --output ../data/external/commons_plans --limit 400
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://commons.wikimedia.org/w/api.php"
UA = "STRUCTURA-dataset-research/0.1 (offline floor-plan research tool)"
CATEGORIES = ["Floor plans", "Floor plans of houses", "Floor plans of houses in the United States",
              "Floor plans of houses in the United Kingdom", "Floor plans of houses in Iran",
              "Art Nouveau house plans in Catalonia", "Floor plans of houses in Lambert's suburban architecture",
              "Architectural drawings of houses", "Floor plans of churches", "Floor plans of schools"]
OK_LICENSE = re.compile(r"^(public domain|pd\b|pd-|cc0|cc[- ]?by[- ]?(2\.0|2\.5|3\.0|4\.0)?)$", re.I)


def license_ok(short: str) -> bool:
    s = (short or "").strip().lower()
    if any(k in s for k in ("sa", "nc", "nd", "gfdl", "fair use")) and not s.startswith("public domain"):
        return False
    return bool(OK_LICENSE.match(s)) or s.startswith("public domain") or s.startswith("pd")


def _fetch(url: str, timeout: int = 60, tries: int = 6) -> bytes:
    """GET con reintentos: ante 429/503 espera lo que pide el servidor (o 2^n s)."""
    import urllib.error

    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 503) or k == tries - 1:
                raise
            wait = float(e.headers.get("Retry-After") or 2 ** (k + 2))
            time.sleep(min(wait, 120))
    raise RuntimeError("sin respuesta")


def _get(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json", "maxlag": 5})
    return json.loads(_fetch(url).decode("utf-8"))


def category_files(cat: str, cap: int = 2000) -> list[str]:
    titles, cont = [], {}
    while len(titles) < cap:
        d = _get({"action": "query", "list": "categorymembers", "cmtitle": f"Category:{cat}", "cmtype": "file",
                  "cmlimit": 500, **cont})
        titles += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        if "continue" not in d:
            break
        cont = d["continue"]
        time.sleep(0.5)
    return titles


def file_info(titles: list[str]) -> list[dict]:
    out = []
    for i in range(0, len(titles), 50):
        d = _get({"action": "query", "titles": "|".join(titles[i:i + 50]), "prop": "imageinfo",
                  "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 2000})
        for page in d.get("query", {}).get("pages", {}).values():
            ii = (page.get("imageinfo") or [{}])[0]
            meta = ii.get("extmetadata", {})

            def m(k):
                return re.sub(r"<[^>]+>", "", (meta.get(k) or {}).get("value", "")).strip()

            out.append({"title": page.get("title"), "mime": ii.get("mime"), "width": ii.get("width"),
                        "height": ii.get("height"), "thumb": ii.get("thumburl"), "page": ii.get("descriptionurl"),
                        "license": m("LicenseShortName"), "license_url": m("LicenseUrl"), "artist": m("Artist"),
                        "credit": m("Credit"), "description": m("ImageDescription")[:300]})
        time.sleep(1.5)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--output", required=True)
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--min-side", type=int, default=800)
    a = ap.parse_args(argv)
    out = Path(a.output)
    (out / "images").mkdir(parents=True, exist_ok=True)
    titles: list[str] = []
    for c in CATEGORIES:
        try:
            got = category_files(c)
        except Exception as e:
            print(f"  categoría {c}: {e}", file=sys.stderr)
            continue
        titles += [t for t in got if t not in titles]
        print(f"  {c}: {len(got)} archivos", flush=True)
    infos = file_info(titles)
    keep = [i for i in infos if i["mime"] in ("image/jpeg", "image/png") and license_ok(i["license"])
            and min(i["width"] or 0, i["height"] or 0) >= a.min_side and i["thumb"]]
    rejected = {}
    for i in infos:
        if i not in keep:
            rejected[i["license"] or "?"] = rejected.get(i["license"] or "?", 0) + 1
    print(f"{len(infos)} con metadatos, {len(keep)} con licencia apta y tamaño suficiente")
    meta_path = out / "metadata.jsonl"
    done = {json.loads(l)["title"] for l in meta_path.read_text(encoding="utf-8").splitlines()} if meta_path.exists() else set()
    n = len(done)
    with open(meta_path, "a", encoding="utf-8") as fh:
        for i in keep:
            if n >= a.limit:
                break
            if i["title"] in done:
                continue
            name = f"cm_{n:04d}" + (".png" if i["mime"] == "image/png" else ".jpg")
            try:
                (out / "images" / name).write_bytes(_fetch(i["thumb"], timeout=120))
            except Exception as e:
                print(f"  falló {i['title']}: {e}", file=sys.stderr)
                continue
            fh.write(json.dumps({**i, "file": name}, ensure_ascii=False) + "\n")
            n += 1
            time.sleep(2.0)
    (out / "rechazadas_por_licencia.json").write_text(json.dumps(rejected, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{n} imágenes en {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
