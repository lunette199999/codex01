#!/usr/bin/env python3
"""Render an animated preview: layered compositing, parallax, hair springs.

Mirrors what the Metal renderer does per frame - each layer resampled at its
own offset and composited back to front - so this doubles as the reference for
the shader's layer path, not just a picture.

    python3 tools/render_preview.py assets/placeholder --name mannequin

Hair layers are additionally warped by the strand displacement field, which is
the difference between hair that swings and a hair-shaped sheet of card that
slides.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates

sys.path.insert(0, str(Path(__file__).parent))

from hair_spring import HairParams, HairSolver, StrandSpec, displacement_field  # noqa: E402
from relight_reference import LightRig, saturate, shade, srgb_decode, srgb_encode  # noqa: E402


def sample(image: np.ndarray, rows: np.ndarray, cols: np.ndarray) -> np.ndarray:
    """Bilinear resample, edge-clamped, over the trailing channel axis."""
    if image.ndim == 2:
        return map_coordinates(image, [rows, cols], order=1, mode="nearest")
    channels = [
        map_coordinates(image[..., c], [rows, cols], order=1, mode="nearest")
        for c in range(image.shape[-1])
    ]
    return np.stack(channels, axis=-1)


class PreviewRenderer:
    def __init__(self, map_dir: Path, name: str, scale: float = 0.5):
        manifest = json.loads((map_dir / f"{name}.maps.json").read_text())
        self.manifest = manifest
        self.layers = sorted(manifest["layers"], key=lambda l: l["index"])
        self.channels = manifest["coverageChannels"]

        def load(suffix: str, mode: str) -> np.ndarray:
            """Load a map, resizing each channel independently.

            Resizing an RGBA image as a unit premultiplies colour by alpha. The
            coverage map stores one layer's data per channel rather than colour
            plus transparency, so that silently zeroes every layer that does not
            overlap the one in the alpha slot - the face and body simply vanish.
            Splitting first keeps each channel meaning what it says.
            """
            img = Image.open(map_dir / f"{name}.{suffix}.png").convert(mode)
            if scale == 1.0:
                return np.asarray(img, np.float32) / 255.0

            size = (max(int(img.width * scale), 1), max(int(img.height * scale), 1))
            bands = [b.resize(size, Image.LANCZOS) for b in img.split()]
            stacked = np.stack([np.asarray(b, np.float32) for b in bands], axis=-1)
            return (stacked if stacked.shape[-1] > 1 else stacked[..., 0]) / 255.0

        albedo = load("albedo", "RGBA")
        self.albedo = srgb_decode(albedo[..., :3])
        self.alpha = albedo[..., 3]
        normal = load("normal", "RGB") * 2.0 - 1.0
        length = np.linalg.norm(normal, axis=-1, keepdims=True)
        self.normal = np.divide(normal, length, out=np.zeros_like(normal), where=length > 1e-6)
        self.ao = load("ao", "L")
        self.coverage = load("coverage", "RGBA")

        self.height, self.width = self.ao.shape
        rows, cols = np.mgrid[0:self.height, 0:self.width]
        self.rows = rows.astype(np.float32)
        self.cols = cols.astype(np.float32)

        strands = [
            StrandSpec(s["rootU"], s["rootV"], s["tipV"], s["layer"])
            for s in manifest.get("strands", [])
        ]
        self.strands_by_layer: dict[str, list[StrandSpec]] = {}
        for spec in strands:
            self.strands_by_layer.setdefault(spec.layer, []).append(spec)

        self.solvers = {
            layer: HairSolver(specs, nodes=manifest.get("strandNodes", 5),
                              params=HairParams())
            for layer, specs in self.strands_by_layer.items()
        }

    def frame(self, rig: LightRig, parallax: tuple[float, float],
              parallax_scale: float = 1.0) -> Image.Image:
        out = np.zeros((self.height, self.width, 3), np.float32)
        out_alpha = np.zeros((self.height, self.width), np.float32)

        for layer in self.layers:
            slot = self.channels.index(layer["name"])

            # Rigid per-layer parallax, in UV.
            du = parallax[0] * layer["parallax"] * parallax_scale
            dv = parallax[1] * layer["parallax"] * parallax_scale

            shift_cols = np.full_like(self.cols, du * self.width)
            shift_rows = np.full_like(self.rows, -dv * self.height)

            # Hair additionally gets the per-pixel strand field.
            solver = self.solvers.get(layer["name"])
            if solver is not None:
                field = displacement_field(
                    (self.height, self.width),
                    self.strands_by_layer[layer["name"]],
                    solver.offsets(),
                )
                shift_cols = shift_cols + field[..., 0] * self.width
                shift_rows = shift_rows + field[..., 1] * self.height

            # Sampling is the inverse of the motion: to move content by +d, read
            # from -d.
            rows = self.rows - shift_rows
            cols = self.cols - shift_cols

            albedo = sample(self.albedo, rows, cols)
            normal = sample(self.normal, rows, cols)
            ao = sample(self.ao, rows, cols)
            coverage = sample(self.coverage[..., slot], rows, cols)
            coverage = coverage * sample(self.alpha, rows, cols)

            lit = shade(albedo, normal, ao, rig)

            c = coverage[..., None]
            out = lit * c + out * (1.0 - c)
            out_alpha = coverage + out_alpha * (1.0 - coverage)

        rgba = np.concatenate([srgb_encode(out), out_alpha[..., None]], axis=-1)
        return Image.fromarray((saturate(rgba) * 255).astype(np.uint8), "RGBA")

    def animate(self, frames: int = 60, fps: float = 24.0,
                rig: LightRig | None = None) -> list[Image.Image]:
        """A head sway that stops abruptly, so the hair's lag and spring-back
        are both visible. A continuous sine hides exactly the behaviour the
        chains exist to produce."""
        rig = rig or LightRig()
        dt = 1.0 / fps
        images = []

        for solver in self.solvers.values():
            solver.reset()

        # Settle the chains under gravity before recording.
        for _ in range(int(fps * 1.5)):
            for solver in self.solvers.values():
                solver.step(dt, (0.0, 0.0))

        for i in range(frames):
            t = i / fps
            # Sway for the first 1.4s, then hold still.
            if t < 1.4:
                sway = np.sin(t * 4.2) * 0.020
                bob = np.sin(t * 2.1) * 0.006
            else:
                sway, bob = 0.0, 0.0

            for solver in self.solvers.values():
                solver.step(dt, (sway, bob))

            images.append(self.frame(rig, (sway * 0.5, bob * 0.5)))

        return images


def flatten(image: Image.Image, background=(42, 44, 49)) -> Image.Image:
    ground = Image.new("RGB", image.size, background)
    ground.paste(image, (0, 0), image)
    return ground


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map_dir", type=Path)
    ap.add_argument("--name", default="portrait")
    ap.add_argument("--out", type=Path, default=Path("validation"))
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--scale", type=float, default=0.5)
    args = ap.parse_args(argv)

    args.out.mkdir(parents=True, exist_ok=True)
    renderer = PreviewRenderer(args.map_dir, args.name, scale=args.scale)

    print(f"solving {sum(len(s) for s in renderer.strands_by_layer.values())} strands "
          f"across {len(renderer.solvers)} hair layers")

    frames = [flatten(f) for f in renderer.animate(frames=args.frames, fps=args.fps)]
    path = args.out / f"{args.name}.hair.gif"
    frames[0].save(
        path, save_all=True, append_images=frames[1:],
        duration=int(1000 / args.fps), loop=0, optimize=True,
    )
    print(f"wrote {path} ({path.stat().st_size / 1024:.0f} KB, {len(frames)} frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
