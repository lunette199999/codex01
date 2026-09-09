#!/usr/bin/env python3
"""Reference implementation of the 2.5D relighting model.

This is the canonical definition. `Sources/RelightKit/Relight.metal` and
`web/sandbox.html` are both ports of the maths in `shade()` below, and they use
the same parameter names so the three stay comparable. When the model changes,
change it here first, confirm the render, then port.

Running this file renders a contact sheet of the placeholder under a moving key
light, which is the quickest way to see whether a change helped or hurt.

    python3 tools/relight_reference.py assets/placeholder --name mannequin
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

import numpy as np
from PIL import Image


def _v(*xs: float) -> np.ndarray:
    return np.array(xs, dtype=np.float32)


@dataclass
class LightRig:
    """Three-point rig plus ambient. Directions point *toward* the light."""

    key_dir: np.ndarray = field(default_factory=lambda: _v(-0.45, 0.35, 0.82))
    key_color: np.ndarray = field(default_factory=lambda: _v(1.00, 0.96, 0.90))
    key_intensity: float = 1.05

    fill_dir: np.ndarray = field(default_factory=lambda: _v(0.55, -0.10, 0.83))
    fill_color: np.ndarray = field(default_factory=lambda: _v(0.72, 0.80, 0.95))
    fill_intensity: float = 0.32

    rim_dir: np.ndarray = field(default_factory=lambda: _v(0.30, 0.55, -0.78))
    rim_color: np.ndarray = field(default_factory=lambda: _v(1.00, 0.94, 0.86))
    rim_intensity: float = 0.55
    rim_power: float = 2.6

    ambient_color: np.ndarray = field(default_factory=lambda: _v(0.34, 0.38, 0.46))
    ambient_intensity: float = 0.55

    # Wrapped diffuse. Higher = light bends further around the terminator, which
    # is what stops skin reading as hard plastic. 0 is plain Lambert.
    key_wrap: float = 0.45
    fill_wrap: float = 0.70

    # Cheap single-scatter stand-in: warmth that blooms in the terminator band
    # only. Real SSS is a diffusion profile; at portrait scale this reads close
    # enough and costs three instructions.
    sss_color: np.ndarray = field(default_factory=lambda: _v(0.62, 0.20, 0.14))
    sss_intensity: float = 0.42
    sss_power: float = 2.2

    spec_intensity: float = 0.18
    spec_gloss: float = 28.0

    # Overall stop adjustment, applied last. The environment model drives this
    # so a bright afternoon and a dim room differ in level, not only in hue.
    exposure: float = 1.0

    def normalised(self) -> "LightRig":
        out = LightRig(**{k: (v.copy() if isinstance(v, np.ndarray) else v)
                          for k, v in self.__dict__.items()})
        for name in ("key_dir", "fill_dir", "rim_dir"):
            d = getattr(out, name)
            setattr(out, name, d / max(float(np.linalg.norm(d)), 1e-6))
        return out

    def to_json(self) -> dict:
        return {k: (v.tolist() if isinstance(v, np.ndarray) else v)
                for k, v in asdict(self).items()}


def saturate(x: np.ndarray | float) -> np.ndarray:
    return np.clip(x, 0.0, 1.0)


def wrap_diffuse(ndl: np.ndarray, wrap: float) -> np.ndarray:
    """Lambert with the terminator pushed around the form.

    (N.L + w) / (1 + w) keeps the peak at 1.0 while lifting the shadow edge, so
    the falloff on a cheek runs long and soft instead of stopping dead at 90
    degrees. The single most valuable line in the whole model for skin.
    """
    return saturate((ndl + wrap) / (1.0 + wrap))


def shade(
    albedo: np.ndarray,   # HxWx3 float [0,1], unlit
    normal: np.ndarray,   # HxWx3 float, unit length, +Y up, +Z toward viewer
    ao: np.ndarray,       # HxW float [0,1]
    rig: LightRig,
) -> np.ndarray:
    """Core shading. Ported verbatim to Relight.metal and the WebGL sandbox."""
    rig = rig.normalised()
    view = _v(0.0, 0.0, 1.0)
    ao3 = ao[..., None]

    n_dot_key = np.einsum("...c,c->...", normal, rig.key_dir)[..., None]
    n_dot_fill = np.einsum("...c,c->...", normal, rig.fill_dir)[..., None]
    n_dot_rim = np.einsum("...c,c->...", normal, rig.rim_dir)[..., None]
    n_dot_view = np.einsum("...c,c->...", normal, view)[..., None]

    diffuse_key = wrap_diffuse(n_dot_key, rig.key_wrap) * rig.key_intensity
    diffuse_fill = wrap_diffuse(n_dot_fill, rig.fill_wrap) * rig.fill_intensity

    # Scatter blooms where the surface turns away from the key but has not gone
    # fully dark - the ear-and-nostril glow. Gated by the key term so an
    # unlit side does not fluoresce.
    scatter = np.power(saturate(1.0 - np.abs(n_dot_key)), rig.sss_power)
    scatter = scatter * saturate(diffuse_key) * rig.sss_intensity

    half = rig.key_dir + view
    half = half / max(float(np.linalg.norm(half)), 1e-6)
    n_dot_half = saturate(np.einsum("...c,c->...", normal, half)[..., None])
    specular = np.power(n_dot_half, rig.spec_gloss) * rig.spec_intensity
    # No specular where the key does not reach, or it floats over shadow.
    specular = specular * saturate(np.sign(n_dot_key))

    fresnel = np.power(saturate(1.0 - n_dot_view), rig.rim_power)
    rim = fresnel * saturate(n_dot_rim) * rig.rim_intensity

    ambient = rig.ambient_color * rig.ambient_intensity * ao3

    lit = albedo * (ambient + rig.key_color * diffuse_key + rig.fill_color * diffuse_fill * ao3)
    lit = lit + albedo * rig.sss_color * scatter
    lit = lit + rig.key_color * specular
    lit = lit + rig.rim_color * rim
    return saturate(lit * rig.exposure)


# --- io / preview ----------------------------------------------------------


def load_maps(map_dir: Path, name: str):
    albedo_img = Image.open(map_dir / f"{name}.albedo.png").convert("RGBA")
    albedo = np.asarray(albedo_img, np.float32) / 255.0
    normal = np.asarray(Image.open(map_dir / f"{name}.normal.png").convert("RGB"), np.float32)
    normal = normal / 255.0 * 2.0 - 1.0
    length = np.linalg.norm(normal, axis=-1, keepdims=True)
    normal = np.divide(normal, length, out=np.zeros_like(normal), where=length > 1e-6)
    ao = np.asarray(Image.open(map_dir / f"{name}.ao.png").convert("L"), np.float32) / 255.0
    meta = json.loads((map_dir / f"{name}.maps.json").read_text())
    return albedo[..., :3], albedo[..., 3], normal, ao, meta


def srgb_encode(x: np.ndarray) -> np.ndarray:
    """Shade in linear, present in sRGB. Skipping this is why a lot of hand-
    rolled relighting looks chalky in the midtones."""
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(np.maximum(x, 1e-8), 1 / 2.4) - 0.055)


def srgb_decode(x: np.ndarray) -> np.ndarray:
    return np.where(x <= 0.04045, x / 12.92, np.power((x + 0.055) / 1.055, 2.4))


def render(map_dir: Path, name: str, rig: LightRig) -> Image.Image:
    albedo, alpha, normal, ao, _ = load_maps(map_dir, name)
    lit = shade(srgb_decode(albedo), normal, ao, rig)
    rgba = np.concatenate([srgb_encode(lit), alpha[..., None]], axis=-1)
    return Image.fromarray((saturate(rgba) * 255).astype(np.uint8), "RGBA")


def contact_sheet(map_dir: Path, name: str, columns: int = 5) -> Image.Image:
    """Key light swung left to right, which is the test that matters: the nose
    shadow should cross the face and the form should stay solid throughout."""
    frames = []
    for i in range(columns):
        t = i / (columns - 1)
        angle = np.pi * (0.82 - 0.64 * t)
        rig = LightRig()
        rig.key_dir = _v(float(np.cos(angle)), 0.34, float(abs(np.sin(angle))) * 0.9 + 0.25)
        frames.append(render(map_dir, name, rig))

    w, h = frames[0].size
    scale = 0.42
    tw, th = int(w * scale), int(h * scale)
    sheet = Image.new("RGB", (tw * columns, th), (26, 27, 30))
    for i, f in enumerate(frames):
        sheet.paste(f.resize((tw, th), Image.LANCZOS), (i * tw, 0), f.resize((tw, th), Image.LANCZOS))
    return sheet


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map_dir", type=Path)
    ap.add_argument("--name", default="portrait")
    ap.add_argument("--out", type=Path, default=Path("validation"))
    args = ap.parse_args(argv)

    args.out.mkdir(parents=True, exist_ok=True)
    render(args.map_dir, args.name, LightRig()).save(args.out / f"{args.name}.lit.png")
    contact_sheet(args.map_dir, args.name).save(args.out / f"{args.name}.sweep.png")
    (args.out / "default-rig.json").write_text(json.dumps(LightRig().to_json(), indent=2) + "\n")
    print(f"wrote {args.out}/{args.name}.lit.png and {args.name}.sweep.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
