#!/usr/bin/env python3
"""Per-strand hair chains, and the displacement field they drive.

STATUS: ALTERNATIVE IMPLEMENTATION - NOT A REPLACEMENT.

The shipping app's hair motion lives in its own Motion.swift (three spring
segments per side, force-based, driving a local 2D image warp). That remains
the active implementation. This is a second approach offered for comparison,
wired into RelightKit's renderer only; nothing here is called from the existing
app. See STATUS.md for what has and has not been verified.

The layer renderer moves each depth band as a rigid quad. That reads as
cardboard: hair with real weight does not translate, it lags at the root and
swings at the tip, and neighbouring strands do not move in lockstep.

This is the same force-based formulation as Motion.swift in the existing app -
stiffness decaying toward the tip, fixed 120 Hz substeps decoupled from the
display rate - extended from three segments per side into a chain per strand,
with the chains blended into a smooth displacement field the shader samples.

Everything is in UV space (0..1 across the image) so the solver is resolution
independent and the same numbers work in Python, Swift and GLSL.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

SUBSTEP_HZ = 120.0


@dataclass
class StrandSpec:
    """Where one strand hangs. Derived from the hair mask, not hand-authored."""
    root_u: float
    root_v: float
    tip_v: float
    layer: str

    def to_json(self) -> dict:
        return {"rootU": self.root_u, "rootV": self.root_v,
                "tipV": self.tip_v, "layer": self.layer}


@dataclass
class HairParams:
    """Defaults tuned to read as loose, medium-length hair.

    `bend_decay` is what makes it look like hair rather than a pendulum: the
    upper chain holds its shape while the tip goes slack, so the ends swing
    widest and settle last. A uniform chain reads as a rope no matter how the
    other numbers are set.
    """
    gravity: float = 0.42          # UV units per second squared
    damping: float = 0.010         # velocity lost per 120 Hz substep
    # Applied once per constraint iteration per substep, so the effective time
    # constant is ~1/(120 Hz * iterations * bend). These values put the upper
    # chain near 0.15 s and the tip near 0.6 s, which is what makes the ends
    # trail and settle last. An intuitively-sized value like 0.3 here is ~12x
    # too stiff and the chain moves as a rigid rod.
    bend: float = 0.0278
    bend_decay: float = 0.707      # per node toward the tip
    constraint_iterations: int = 2
    # How far a root follows head motion. Below 1.0 the scalp slides slightly
    # under the hair, which is what actually happens.
    root_follow: float = 0.85
    max_offset: float = 0.075      # UV clamp, stops any blow-up reaching the screen


class HairSolver:
    """Verlet chains of nodes hanging from strand roots.

    Node 0 is pinned to its root and driven directly by head motion. Below it,
    two constraints do the work:

    - a hard length constraint, solved root outward. This is what carries motion
      down the chain: moving the root physically drags every node after it in
      the same pass. A soft spring along the segment axis instead lets the
      segment stretch and swallow the motion, so the tip never moves - the ends
      go dead exactly where hair should be liveliest.
    - a soft bend constraint pulling each segment back toward hanging straight
      down, weakening toward the tip. This is the spring-back, and its weakness
      at the ends is what makes them trail.

    Verlet rather than explicit velocity so the positional constraints feed back
    into momentum for free: a node dragged by the length constraint keeps the
    speed that drag gave it, which is where the follow-through comes from.
    """

    def __init__(self, strands: list[StrandSpec], nodes: int = 5,
                 params: HairParams | None = None):
        self.strands = strands
        self.node_count = max(nodes, 2)
        self.params = params or HairParams()

        count = len(strands)
        self.rest = np.zeros((count, self.node_count, 2), np.float64)
        for s, strand in enumerate(strands):
            span = strand.tip_v - strand.root_v
            for k in range(self.node_count):
                t = k / (self.node_count - 1)
                self.rest[s, k] = (strand.root_u, strand.root_v + span * t)

        self.position = self.rest.copy()
        self.previous = self.rest.copy()
        self._accumulator = 0.0

        self.node_bend = np.array(
            [self.params.bend * (self.params.bend_decay ** k)
             for k in range(self.node_count)], np.float64
        )
        self._rest_length = np.linalg.norm(
            self.rest[:, 1:] - self.rest[:, :-1], axis=-1
        )

    @property
    def rest_length(self) -> np.ndarray:
        return self._rest_length

    def reset(self) -> None:
        self.position = self.rest.copy()
        self.previous = self.rest.copy()
        self._accumulator = 0.0

    def step(self, delta: float, head_offset: tuple[float, float] = (0.0, 0.0)) -> None:
        """Advance by `delta` seconds using fixed substeps.

        The substep rate is fixed so the motion is identical whether the window
        is running at 24, 30 or 60 fps - a variable-dt spring changes its
        effective stiffness with frame rate, and hair that stiffens when the app
        is busy is very noticeable.
        """
        self._accumulator += max(delta, 0.0)
        dt = 1.0 / SUBSTEP_HZ

        # Bound the catch-up so a stalled frame cannot spend seconds solving.
        max_steps = 16
        steps = 0
        while self._accumulator >= dt and steps < max_steps:
            self._substep(dt, head_offset)
            self._accumulator -= dt
            steps += 1
        if steps == max_steps:
            self._accumulator = 0.0

    def _substep(self, dt: float, head_offset: tuple[float, float]) -> None:
        p = self.params
        offset = np.array(head_offset, np.float64) * p.root_follow

        # 1. Verlet integration. Velocity is implicit in (position - previous),
        #    so the constraints below alter momentum as a side effect.
        velocity = (self.position - self.previous) * (1.0 - p.damping)
        self.previous = self.position.copy()
        acceleration = np.zeros_like(self.position)
        acceleration[..., 1] = p.gravity
        self.position = self.position + velocity + acceleration * dt * dt

        # 2. Roots are driven, not simulated.
        self.position[:, 0] = self.rest[:, 0] + offset

        for _ in range(max(p.constraint_iterations, 1)):
            # 3. Bend first, pulling each segment back toward vertical. This
            #    moves a node off its correct radius, which is fine because...
            for k in range(1, self.node_count):
                hanging = self.position[:, k - 1].copy()
                hanging[:, 1] += self._rest_length[:, k - 1]
                self.position[:, k] += (hanging - self.position[:, k]) * self.node_bend[k]

            # 4. ...length is solved last, root outward, so the pose that leaves
            #    this function always satisfies the hard constraint exactly.
            #    Solving bend afterwards instead leaves a length error behind,
            #    and Verlet reads that error back as velocity on the next step -
            #    the chain pumps its own energy and the tip rings louder every
            #    swing instead of settling.
            for k in range(1, self.node_count):
                delta = self.position[:, k] - self.position[:, k - 1]
                distance = np.linalg.norm(delta, axis=-1, keepdims=True)
                target = self._rest_length[:, k - 1][:, None]
                correction = delta * (1.0 - target / np.maximum(distance, 1e-9))
                self.position[:, k] -= correction

        # 5. Clamp against the rest pose. Better to cap and stay plausible than
        #    to let an unstable step throw strands across the screen.
        delta = self.position - self.rest
        magnitude = np.linalg.norm(delta, axis=-1, keepdims=True)
        excess = magnitude > p.max_offset
        if excess.any():
            scaled = np.divide(delta, np.maximum(magnitude, 1e-9)) * p.max_offset
            self.position = np.where(excess, self.rest + scaled, self.position)
            self.previous = np.where(excess, self.position, self.previous)

    def offsets(self) -> np.ndarray:
        """Per-node displacement from rest, shape (strands, nodes, 2)."""
        return (self.position - self.rest).astype(np.float32)


def derive_strands(mask: np.ndarray, layer: str, count: int = 5,
                   inset: float = 0.08, min_span: float = 0.06) -> list[StrandSpec]:
    """Place strand roots across a hair mask automatically.

    Columns are sampled across the mask's horizontal extent; each root sits at
    the topmost covered pixel in its column and the tip at the lowest. Deriving
    these from the mask rather than hand-authoring them means a new character
    needs no extra authoring step - drop in the masks and the strands follow.
    """
    ys, xs = np.nonzero(mask > 0.5)
    if xs.size == 0:
        return []

    h, w = mask.shape
    x_min, x_max = int(xs.min()), int(xs.max())
    span = x_max - x_min
    if span < 4:
        return []

    strands: list[StrandSpec] = []
    for i in range(count):
        t = inset + (1.0 - 2 * inset) * (i / max(count - 1, 1))
        x = int(round(x_min + t * span))
        column = np.nonzero(mask[:, x] > 0.5)[0]
        if column.size < 8:
            continue
        top, bottom = int(column.min()), int(column.max())
        # Reject slivers. Where a column is nearly all occluded by a nearer
        # layer only a few rows survive, and a near-zero-length chain cannot
        # move while still pulling weight in the blend - it flattens the field
        # exactly where the hair should be swinging most.
        if (bottom - top) / h < min_span:
            continue
        strands.append(StrandSpec(
            root_u=x / w, root_v=top / h, tip_v=bottom / h, layer=layer
        ))
    return strands


def displacement_field(shape: tuple[int, int], strands: list[StrandSpec],
                       offsets: np.ndarray, sigma: float = 0.16) -> np.ndarray:
    """Blend per-strand chain offsets into a smooth per-pixel field.

    Gaussian falloff in u so neighbouring strands overlap rather than each
    dragging a hard column of pixels with it; linear interpolation down v
    between the chain's nodes. Above a strand's root the offset is zero by
    construction, which is what pins the hairline.

    Returned as (H, W, 2) in UV units.
    """
    h, w = shape
    field = np.zeros((h, w, 2), np.float32)
    if not strands:
        return field

    weight_total = np.zeros((h, w), np.float32)
    vs = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None]
    us = np.linspace(0.0, 1.0, w, dtype=np.float32)[None, :]

    node_count = offsets.shape[1]
    for s, strand in enumerate(strands):
        weight = np.exp(-(((us - strand.root_u) / sigma) ** 2)).astype(np.float32)
        weight = np.broadcast_to(weight, (h, w))

        span = max(strand.tip_v - strand.root_v, 1e-5)
        t = np.clip((vs - strand.root_v) / span, 0.0, 1.0) * (node_count - 1)
        lo = np.clip(np.floor(t).astype(np.int32), 0, node_count - 1)
        hi = np.clip(lo + 1, 0, node_count - 1)
        frac = (t - lo).astype(np.float32)

        for axis in range(2):
            values = offsets[s, :, axis]
            interpolated = values[lo] * (1 - frac) + values[hi] * frac
            field[..., axis] += weight * np.broadcast_to(interpolated, (h, w))

        weight_total += weight

    return field / np.maximum(weight_total, 1e-5)[..., None]


def load_strands(manifest_path: Path) -> dict[str, list[StrandSpec]]:
    """Read the strand table written into a `.maps.json` sidecar."""
    manifest = json.loads(Path(manifest_path).read_text())
    grouped: dict[str, list[StrandSpec]] = {}
    for entry in manifest.get("strands", []):
        spec = StrandSpec(entry["rootU"], entry["rootV"], entry["tipV"], entry["layer"])
        grouped.setdefault(spec.layer, []).append(spec)
    return grouped
