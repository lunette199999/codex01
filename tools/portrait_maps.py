#!/usr/bin/env python3
"""Build the map set consumed by the 2.5D relighting runtime.

The runtime does not do monocular depth estimation at load time. It consumes a
small set of precomputed maps, produced here once per character asset:

    <name>.albedo.png    RGBA, unlit base colour (lighting is added at runtime)
    <name>.depth.png     16-bit grayscale, 0 = far, 65535 = near
    <name>.normal.png    RGB, OpenGL convention (+Y up), z packed in blue
    <name>.ao.png        8-bit grayscale cavity occlusion, 255 = unoccluded
    <name>.layers.png    8-bit palette-ish layer id, 0 = background
    <name>.maps.json     layer table + parameters the shader needs

Why layered depth rather than a single estimated relief:

A monocular depth map over a whole portrait produces one continuous surface, so
hair, face and collar melt into each other. Every silhouette becomes a smooth
ramp instead of an edge, and nothing can move independently. Splitting the
portrait into a few ordered layers gives correct occlusion, lets each layer
parallax on its own, and confines depth gradients to within a layer so the
normals stay clean at the edges.

Usage:

    # generate a neutral placeholder mannequin and its maps
    python3 tools/portrait_maps.py --synthetic assets/placeholder

    # build maps for a real asset from an albedo + per-layer masks
    python3 tools/portrait_maps.py build assets/mychar \
        --albedo albedo.png --mask hair_back=hb.png --mask body=body.png \
        --mask face=face.png --mask hair_front=hf.png
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from scipy.ndimage import binary_dilation, distance_transform_edt, gaussian_filter

from hair_spring import derive_strands


# --- layer table -----------------------------------------------------------
#
# Ordered back to front. `base` is the layer's resting depth in [0,1]; `relief`
# is how much the in-layer dome adds on top of it. The gaps between `base`
# values are what the runtime uses as parallax separation, so they matter more
# than the absolute numbers.


@dataclass(frozen=True)
class Layer:
    name: str
    index: int
    base: float
    relief: float
    normal_strength: float
    # How far this layer slides per unit of parallax input. Front hair moves
    # most, background hair least; this is what produces the depth cue.
    parallax: float
    # Hair layers get strand chains and a per-pixel displacement field; the
    # face and body stay rigid so features never wobble.
    hair: bool = False


LAYERS: tuple[Layer, ...] = (
    Layer("hair_back", 1, base=0.20, relief=0.06, normal_strength=1.6, parallax=-0.35, hair=True),
    Layer("body", 2, base=0.35, relief=0.10, normal_strength=1.2, parallax=0.15),
    Layer("face", 3, base=0.55, relief=0.22, normal_strength=2.4, parallax=0.55),
    Layer("hair_front", 4, base=0.78, relief=0.08, normal_strength=2.0, parallax=1.00, hair=True),
)

LAYERS_BY_NAME = {layer.name: layer for layer in LAYERS}

# Nodes per strand chain. Five is enough for a visible root-to-tip delay
# without the solver cost mattering.
STRAND_NODES = 5


# --- map math --------------------------------------------------------------


def dome_relief(mask: np.ndarray, softness: float = 0.42) -> np.ndarray:
    """Fallback height field that bulges toward the middle of a mask.

    Only used when no measured depth is supplied. Takes the euclidean distance
    to the mask edge, renormalises so the deepest interior point sits at 1.0,
    and shapes it into a spherical cap - a plain distance transform gives a
    cone, the sqrt shaping gives a sphere cross-section.

    The blur afterwards is not cosmetic. A distance transform of any
    non-circular shape ridges along its medial axis, and those ridges light up
    as hard diamond facets the moment a key light moves across them. `softness`
    is a fraction of the shape's own half-width, so the smoothing scales with
    the mask instead of being a fixed pixel count that is far too small on a
    face and far too large on a hair strand.
    """
    if not mask.any():
        return np.zeros_like(mask, dtype=np.float32)

    dist = distance_transform_edt(mask).astype(np.float32)
    peak = float(dist.max())
    if peak <= 0.0:
        return np.zeros_like(dist)

    d = np.clip(dist / peak, 0.0, 1.0)
    cap = np.sqrt(np.clip(1.0 - (1.0 - d) ** 2, 0.0, 1.0))

    if softness > 0.0:
        sigma = max(peak * softness, 1.0)
        cap = gaussian_filter(cap, sigma=sigma)
        # The blur pulls the peak down and bleeds past the edge; renormalise
        # inside the mask so `relief` stays a predictable 0..1 multiplier.
        inside = cap * mask
        top = float(inside.max())
        if top > 1e-6:
            cap = inside / top

    return (cap * mask).astype(np.float32)


def normals_from_depth(
    depth: np.ndarray, mask: np.ndarray, strength: float
) -> np.ndarray:
    """Per-layer surface normals, OpenGL convention (+Y up), float32 HxWx3.

    Computed inside the mask only. Sampling across a layer boundary would see
    the depth step between layers as a near-vertical wall and light it as a hard
    bright edge, which is the classic giveaway of a fake-3D portrait. Blurring
    the masked depth first keeps mask aliasing out of the gradient.
    """
    d = gaussian_filter(depth * mask, sigma=1.5)

    # np.gradient returns (d/drow, d/dcol) for a 2D array.
    dz_dy, dz_dx = np.gradient(d.astype(np.float32))

    # Image rows increase downward, so a depth increase down-screen tilts the
    # normal up-screen: n = normalize(-dz/dx, +dz/dy, 1/strength)
    s = max(strength, 1e-4)
    nx = -dz_dx * 255.0
    ny = dz_dy * 255.0
    nz = np.full_like(nx, 1.0 / s)

    n = np.stack([nx, ny, nz], axis=-1)
    length = np.linalg.norm(n, axis=-1, keepdims=True)
    n = np.divide(n, length, out=np.zeros_like(n), where=length > 1e-8)

    # Outside the mask, fall back to facing the viewer so compositing is clean.
    flat = np.zeros_like(n)
    flat[..., 2] = 1.0
    m = mask[..., None].astype(np.float32)
    return (n * m + flat * (1.0 - m)).astype(np.float32)


def cavity_ao(depth: np.ndarray, coverage: np.ndarray, radius: float = 14.0) -> np.ndarray:
    """Cheap ambient occlusion: how far a pixel sits below its neighbourhood.

    Not a real occlusion integral, but for a portrait it lands the shadow in the
    places that read as depth anyway - under the jaw, beside the nose, where
    hair meets the face - and it costs one blur.
    """
    local = gaussian_filter(depth * coverage, sigma=radius)
    weight = gaussian_filter(coverage, sigma=radius)
    local = np.divide(local, weight, out=np.zeros_like(local), where=weight > 1e-4)

    delta = depth - local
    ao = np.clip(0.5 + delta * 3.5, 0.0, 1.0)
    ao = gaussian_filter(ao, sigma=2.0)
    return np.where(coverage > 0.5, ao, 1.0).astype(np.float32)


def relief_for_layer(
    mask: np.ndarray, measured: np.ndarray | None
) -> np.ndarray:
    """In-layer surface detail, normalised to 0..1 inside the mask.

    With a measured depth map (Depth Anything V2, Marigold, a scan) this is the
    real surface and the mask only decides ordering. Without one it falls back
    to the mask dome, which is fine for schematic assets and wrong for faces -
    a dome has no eye sockets, so a relit face inflates. Supply measured depth
    for anything that needs to read as a person.
    """
    if measured is None:
        return dome_relief(mask)

    inside = measured[mask > 0.5]
    if inside.size == 0:
        return np.zeros_like(mask, dtype=np.float32)

    lo, hi = float(np.percentile(inside, 1.0)), float(np.percentile(inside, 99.0))
    if hi - lo < 1e-6:
        return dome_relief(mask)

    norm = np.clip((measured - lo) / (hi - lo), 0.0, 1.0)
    return (gaussian_filter(norm, sigma=1.0) * mask).astype(np.float32)


def build_maps(
    albedo: Image.Image,
    masks: dict[str, np.ndarray],
    measured: np.ndarray | None = None,
) -> tuple[dict[str, Image.Image], dict]:
    """Compose per-layer masks into the runtime map set."""
    w, h = albedo.size
    depth = np.zeros((h, w), np.float32)
    normal = np.zeros((h, w, 3), np.float32)
    normal[..., 2] = 1.0
    layer_id = np.zeros((h, w), np.uint8)
    coverage = np.zeros((h, w), np.float32)

    used: list[Layer] = []
    for layer in LAYERS:  # back to front, so nearer layers overwrite
        mask = masks.get(layer.name)
        if mask is None or not mask.any():
            continue
        used.append(layer)

        relief = relief_for_layer(mask, measured)
        layer_depth = (layer.base + relief * layer.relief) * mask
        layer_normal = normals_from_depth(layer_depth, mask, layer.normal_strength)

        m = mask.astype(bool)
        depth[m] = layer_depth[m]
        normal[m] = layer_normal[m]
        layer_id[m] = layer.index
        coverage[m] = 1.0

    ao = cavity_ao(depth, coverage)

    # Per-layer coverage packed one layer per channel (R=hair_back, G=body,
    # B=face, A=hair_front). The renderer draws each layer as its own quad with
    # its own parallax offset, so it needs a filterable coverage value per
    # layer; comparing against the integer id map instead would alias every
    # layer boundary the moment the layers start sliding against each other.
    cov = np.zeros((h, w, 4), np.float32)
    for slot, layer in enumerate(LAYERS):
        m = masks.get(layer.name)
        if m is None:
            continue
        binary = m > 0.5

        # Grow each layer underneath the layers in front of it. The masks abut
        # exactly, so once their edges are softened both fall to ~0.5 at a seam
        # and `over` compositing lands on ~0.75 alpha there - a dark outline
        # tracing every layer boundary. Growing only where a nearer layer will
        # cover the result keeps the outer silhouette exact.
        nearer = np.zeros_like(binary)
        for other in LAYERS[slot + 1:]:
            other_mask = masks.get(other.name)
            if other_mask is not None:
                nearer |= other_mask > 0.5

        grown = binary | (binary_dilation(binary, iterations=2) & nearer)
        cov[..., slot] = grown.astype(np.float32)

    cov = gaussian_filter(cov, sigma=(0.6, 0.6, 0.0))

    encoded = {
        "depth": Image.fromarray((np.clip(depth, 0, 1) * 65535).astype(np.uint16)),
        "normal": Image.fromarray(
            (np.clip(normal * 0.5 + 0.5, 0, 1) * 255).astype(np.uint8), "RGB"
        ),
        "ao": Image.fromarray((np.clip(ao, 0, 1) * 255).astype(np.uint8), "L"),
        "layers": Image.fromarray(layer_id, "L"),
        "coverage": Image.fromarray((np.clip(cov, 0, 1) * 255).astype(np.uint8), "RGBA"),
        "albedo": albedo,
    }

    # Strand roots for the hair chains, derived from the masks so a new
    # character needs no extra authoring step.
    strands = []
    for layer in LAYERS:
        if not layer.hair:
            continue
        mask = masks.get(layer.name)
        if mask is None or not mask.any():
            continue
        count = 6 if layer.name == "hair_front" else 5
        strands.extend(
            spec.to_json() for spec in derive_strands(mask, layer.name, count=count)
        )

    meta = {
        "width": w,
        "height": h,
        "normalConvention": "opengl+y",
        "depthRange": [0.0, 1.0],
        "layers": [asdict(layer) for layer in used],
        "reliefSource": "measured" if measured is not None else "mask-dome",
        "coverageChannels": [layer.name for layer in LAYERS],
        "strands": strands,
        "strandNodes": STRAND_NODES,
    }
    return encoded, meta


# --- placeholder mannequin -------------------------------------------------
#
# A neutral stand-in so the whole pipeline runs with no character asset. It is
# deliberately schematic - the point is to have a lighting test target with a
# known silhouette, a dome, and one sharp feature (the nose) whose shadow you
# can watch swing as the key light moves. Same role as a Lambertian sphere.

PLACEHOLDER_SIZE = (768, 1024)
PLACEHOLDER_COLOURS = {
    "hair_back": (58, 50, 44),
    "body": (90, 100, 114),
    "face": (200, 174, 155),
    "hair_front": (74, 64, 56),
}


def _mask_from_shapes(size, shapes) -> np.ndarray:
    img = Image.new("L", size, 0)
    draw = ImageDraw.Draw(img)
    for kind, box in shapes:
        getattr(draw, kind)(box, fill=255)
    return (np.asarray(img, dtype=np.float32) / 255.0)


def synthesize_placeholder() -> tuple[Image.Image, dict[str, np.ndarray]]:
    w, h = PLACEHOLDER_SIZE
    cx = w // 2

    hair_back = _mask_from_shapes(
        PLACEHOLDER_SIZE,
        [
            ("ellipse", (cx - 218, 130, cx + 218, 640)),
            ("ellipse", (cx - 196, 380, cx + 196, 800)),
        ],
    )
    body = _mask_from_shapes(
        PLACEHOLDER_SIZE,
        [
            ("ellipse", (cx - 316, 700, cx + 316, 1180)),
            ("rectangle", (cx - 58, 520, cx + 58, 760)),
        ],
    )
    face = _mask_from_shapes(
        PLACEHOLDER_SIZE,
        [
            ("ellipse", (cx - 152, 190, cx + 152, 580)),
            ("rectangle", (cx - 54, 520, cx + 54, 700)),
        ],
    )
    hair_front = _mask_from_shapes(
        PLACEHOLDER_SIZE,
        [
            ("ellipse", (cx - 168, 150, cx + 168, 400)),
            ("ellipse", (cx - 186, 210, cx - 118, 660)),
            ("ellipse", (cx + 118, 210, cx + 186, 660)),
        ],
    )

    # Resolve overlaps front-to-back so each pixel belongs to exactly one layer.
    hair_front = np.clip(hair_front, 0, 1)
    face = np.clip(face - hair_front, 0, 1)
    body = np.clip(body - face - hair_front, 0, 1)
    hair_back = np.clip(hair_back - face - body - hair_front, 0, 1)

    masks = {
        "hair_back": hair_back,
        "body": body,
        "face": face,
        "hair_front": hair_front,
    }

    rgba = np.zeros((h, w, 4), np.uint8)
    for layer in LAYERS:
        m = masks[layer.name] > 0.5
        rgba[m, :3] = PLACEHOLDER_COLOURS[layer.name]
        rgba[m, 3] = 255

    # A little albedo break-up so flat fills do not read as vector art.
    rng = np.random.default_rng(7)
    noise = rng.normal(0.0, 3.0, (h, w, 1))
    rgba[..., :3] = np.clip(rgba[..., :3].astype(np.float32) + noise, 0, 255).astype(np.uint8)

    return Image.fromarray(rgba, "RGBA"), masks


def add_face_features(masks: dict[str, np.ndarray]) -> np.ndarray:
    """Extra depth detail for the face layer: brow ridge and nose.

    Returned as an additive height field in the same units as `dome_relief`, so
    the key light produces a moving nose shadow. Without at least one crisp
    feature a relit portrait looks like an inflated balloon.
    """
    face = masks["face"]
    h, w = face.shape
    cx = w // 2
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)

    nose = np.exp(-(((xx - cx) / 26.0) ** 2) - (((yy - 430) / 88.0) ** 2))
    tip = np.exp(-(((xx - cx) / 38.0) ** 2) - (((yy - 494) / 30.0) ** 2))
    brow = np.exp(-(((xx - cx) / 130.0) ** 2) - (((yy - 330) / 22.0) ** 2))

    return ((nose * 0.55 + tip * 0.40 + brow * 0.25) * face).astype(np.float32)


# --- io --------------------------------------------------------------------


def write_maps(out_dir: Path, name: str, images: dict[str, Image.Image], meta: dict) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for key, img in images.items():
        img.save(out_dir / f"{name}.{key}.png")
    (out_dir / f"{name}.maps.json").write_text(json.dumps(meta, indent=2) + "\n")


def load_mask(path: Path, size: tuple[int, int]) -> np.ndarray:
    img = Image.open(path).convert("L")
    if img.size != size:
        img = img.resize(size, Image.LANCZOS)
    return (np.asarray(img, dtype=np.float32) / 255.0 > 0.5).astype(np.float32)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out_dir", type=Path, help="directory to write the map set into")
    parser.add_argument("--name", default="portrait", help="basename for the map files")
    parser.add_argument("--synthetic", action="store_true", help="generate the placeholder mannequin")
    parser.add_argument("--albedo", type=Path, help="RGBA albedo for a real asset")
    parser.add_argument(
        "--depth",
        type=Path,
        help="measured depth map (grayscale, brighter = nearer) from a monocular "
             "depth model; strongly recommended for real faces",
    )
    parser.add_argument(
        "--mask",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help=f"layer mask; NAME one of {', '.join(l.name for l in LAYERS)}",
    )
    args = parser.parse_args(argv)

    if args.synthetic:
        albedo, masks = synthesize_placeholder()
        images, meta = build_maps(albedo, masks)

        # Fold the schematic face features into the depth/normal maps.
        features = add_face_features(masks)
        depth = np.asarray(images["depth"], dtype=np.float32) / 65535.0
        depth = depth + features * LAYERS_BY_NAME["face"].relief
        face_normal = normals_from_depth(depth, masks["face"], LAYERS_BY_NAME["face"].normal_strength)

        normal = np.asarray(images["normal"], dtype=np.float32) / 255.0 * 2.0 - 1.0
        m = masks["face"][..., None] > 0.5
        normal = np.where(m, face_normal, normal)

        coverage = sum(masks.values())
        images["depth"] = Image.fromarray((np.clip(depth, 0, 1) * 65535).astype(np.uint16))
        images["normal"] = Image.fromarray(
            (np.clip(normal * 0.5 + 0.5, 0, 1) * 255).astype(np.uint8), "RGB"
        )
        images["ao"] = Image.fromarray(
            (np.clip(cavity_ao(depth, np.clip(coverage, 0, 1)), 0, 1) * 255).astype(np.uint8), "L"
        )
        meta["source"] = "synthetic-placeholder"
    else:
        if not args.albedo:
            parser.error("--albedo is required unless --synthetic is given")
        albedo = Image.open(args.albedo).convert("RGBA")
        masks = {}
        for entry in args.mask:
            if "=" not in entry:
                parser.error(f"--mask expects NAME=PATH, got {entry!r}")
            key, path = entry.split("=", 1)
            if key not in LAYERS_BY_NAME:
                parser.error(f"unknown layer {key!r}")
            masks[key] = load_mask(Path(path), albedo.size)
        if not masks:
            parser.error("at least one --mask is required")

        measured = None
        if args.depth:
            d = Image.open(args.depth).convert("F")
            if d.size != albedo.size:
                d = d.resize(albedo.size, Image.LANCZOS)
            measured = np.asarray(d, np.float32)
            span = float(measured.max() - measured.min())
            measured = (measured - measured.min()) / span if span > 1e-6 else measured * 0.0

        images, meta = build_maps(albedo, masks, measured)
        meta["source"] = str(args.albedo)

    write_maps(args.out_dir, args.name, images, meta)
    print(f"wrote {len(images) + 1} files to {args.out_dir}/ ({meta['width']}x{meta['height']})")
    for layer in meta["layers"]:
        print(f"  layer {layer['index']} {layer['name']:<11} base={layer['base']:.2f} parallax={layer['parallax']:+.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
