#!/usr/bin/env python3
"""Inline the portrait maps into web/sandbox.html to make a standalone file.

The repo copy fetches its maps over HTTP so editing the shader does not mean
re-encoding a megabyte of PNG every save. This produces the shareable build:
one file, no server, nothing to resolve.

    python3 tools/bundle_sandbox.py --out dist/relight-bench.html
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

MARKER = "const EMBEDDED_MAPS = null; /* __EMBEDDED_MAPS__ */"
KINDS = ("albedo", "normal", "ao", "coverage")


def data_uri(path: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, default=Path("web/sandbox.html"))
    ap.add_argument("--maps", type=Path, default=Path("assets/placeholder"))
    ap.add_argument("--name", default="mannequin")
    ap.add_argument("--out", type=Path, default=Path("dist/relight-bench.html"))
    args = ap.parse_args(argv)

    html = args.source.read_text(encoding="utf-8")
    if MARKER not in html:
        print(f"error: marker not found in {args.source}", file=sys.stderr)
        return 1

    maps = {}
    for kind in KINDS:
        path = args.maps / f"{args.name}.{kind}.png"
        if not path.exists():
            print(f"error: missing {path}", file=sys.stderr)
            return 1
        maps[kind] = data_uri(path)

    html = html.replace(MARKER, f"const EMBEDDED_MAPS = {json.dumps(maps)};")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(html, encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
