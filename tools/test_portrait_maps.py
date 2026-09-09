#!/usr/bin/env python3
"""Tests for the offline map pipeline and the reference lighting model.

    python3 tools/test_portrait_maps.py

Deliberately dependency-light (unittest, not pytest) so it runs anywhere the
pipeline itself runs. The Swift side has its own suite under Tests/.
"""

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from portrait_maps import (  # noqa: E402
    LAYERS,
    build_maps,
    cavity_ao,
    dome_relief,
    normals_from_depth,
    relief_for_layer,
    synthesize_placeholder,
)
from relight_reference import LightRig, shade, wrap_diffuse  # noqa: E402
from PIL import Image  # noqa: E402


def rect_mask(h=200, w=200, pad=40):
    m = np.zeros((h, w), np.float32)
    m[pad:h - pad, pad:w - pad] = 1.0
    return m


class DomeReliefTests(unittest.TestCase):

    def test_peaks_inside_and_is_zero_outside(self):
        mask = rect_mask()
        relief = dome_relief(mask)
        self.assertAlmostEqual(float(relief[mask < 0.5].max()), 0.0, places=6)
        self.assertGreater(float(relief[100, 100]), 0.8)
        self.assertFalse(np.isnan(relief).any())

    def test_empty_mask_is_handled(self):
        relief = dome_relief(np.zeros((32, 32), np.float32))
        self.assertEqual(relief.shape, (32, 32))
        self.assertAlmostEqual(float(relief.max()), 0.0)

    def test_no_medial_axis_crease(self):
        """Regression: an unsmoothed distance transform ridges along the medial
        axis of any non-circular shape, and those ridges light up as hard
        diamond facets as soon as a key light crosses them.

        A rectangle's medial axis runs along its centre line. Compare the second
        derivative there against the surrounding surface - a crease shows up as
        a curvature spike."""
        mask = rect_mask(200, 300, 40)
        relief = dome_relief(mask)

        row = relief[100, 60:240]
        curvature = np.abs(np.diff(row, n=2))
        self.assertLess(
            float(curvature.max()), 5e-3,
            "curvature spike along the medial axis - the dome is creasing",
        )

    def test_softness_scales_with_shape_size(self):
        """A fixed pixel blur is far too small on a face and far too large on a
        hair strand, so smoothing has to be relative to the mask."""
        small = dome_relief(rect_mask(80, 80, 16))
        large = dome_relief(rect_mask(600, 600, 120))
        for relief in (small, large):
            self.assertAlmostEqual(float(relief.max()), 1.0, places=3)


class NormalTests(unittest.TestCase):

    def test_normals_are_unit_length(self):
        mask = rect_mask()
        depth = dome_relief(mask) * 0.2
        normals = normals_from_depth(depth, mask, strength=2.0)
        lengths = np.linalg.norm(normals, axis=-1)
        np.testing.assert_allclose(lengths, 1.0, atol=1e-5)

    def test_flat_region_faces_the_viewer(self):
        mask = np.ones((64, 64), np.float32)
        normals = normals_from_depth(np.full((64, 64), 0.5, np.float32), mask, 2.0)
        np.testing.assert_allclose(normals[32, 32], [0, 0, 1], atol=1e-5)

    def test_orientation_convention(self):
        """+Y up (OpenGL). Depth rising to the right must tilt the normal to
        -X; depth rising down-screen must tilt it to +Y. Get this backwards and
        the whole portrait lights from the wrong side."""
        h = w = 64
        mask = np.ones((h, w), np.float32)

        ramp_x = np.tile(np.linspace(0, 1, w, dtype=np.float32), (h, 1))
        n = normals_from_depth(ramp_x, mask, strength=2.0)
        self.assertLess(float(n[32, 32, 0]), -0.01)

        ramp_y = np.tile(np.linspace(0, 1, h, dtype=np.float32)[:, None], (1, w))
        n = normals_from_depth(ramp_y, mask, strength=2.0)
        self.assertGreater(float(n[32, 32, 1]), 0.01)


class AmbientOcclusionTests(unittest.TestCase):

    def test_crevice_is_darker_than_a_ridge(self):
        h = w = 128
        coverage = np.ones((h, w), np.float32)
        depth = np.full((h, w), 0.5, np.float32)
        depth[:, 60:68] = 0.2          # a groove
        depth[:, 20:28] = 0.8          # a ridge

        ao = cavity_ao(depth, coverage, radius=10.0)
        self.assertLess(float(ao[64, 64]), float(ao[64, 24]))
        self.assertTrue(((ao >= 0) & (ao <= 1)).all())


class LayerCompositionTests(unittest.TestCase):

    def setUp(self):
        self.albedo, self.masks = synthesize_placeholder()
        self.images, self.meta = build_maps(self.albedo, self.masks)

    def test_produces_every_map_the_runtime_loads(self):
        for key in ("albedo", "depth", "normal", "ao", "layers", "coverage"):
            self.assertIn(key, self.images)
        self.assertEqual(self.images["coverage"].mode, "RGBA")
        self.assertEqual(self.meta["coverageChannels"], [l.name for l in LAYERS])

    def test_layers_are_ordered_back_to_front(self):
        indices = [layer["index"] for layer in self.meta["layers"]]
        self.assertEqual(indices, sorted(indices))
        bases = [layer["base"] for layer in self.meta["layers"]]
        self.assertEqual(bases, sorted(bases))

    def test_coverage_sums_to_one_across_layer_seams(self):
        """Regression: the layer masks abut exactly, so once their edges are
        softened both sides of a seam fall to ~0.5 and `over` compositing lands
        on ~0.75 alpha - a dark outline tracing every boundary. Each layer is
        grown under the layers in front of it to close that gap."""
        cov = np.asarray(self.images["coverage"], np.float32) / 255.0
        silhouette = np.asarray(self.albedo, np.float32)[..., 3] / 255.0 > 0.5

        # Composite back to front the way the shader does.
        alpha = np.zeros(cov.shape[:2], np.float32)
        for slot in range(4):
            alpha = cov[..., slot] + alpha * (1.0 - cov[..., slot])

        interior = silhouette & (
            np.asarray(self.images["ao"]).astype(np.float32) >= 0
        )
        self.assertGreater(
            float(np.percentile(alpha[interior], 1.0)), 0.97,
            "seam gap in composited coverage - layer boundaries will show as dark outlines",
        )

    def test_outer_silhouette_is_not_fattened(self):
        """Growing layers under their neighbours must not spill past the
        outside edge, or the character gains a halo."""
        cov = np.asarray(self.images["coverage"], np.float32) / 255.0
        silhouette = np.asarray(self.albedo, np.float32)[..., 3] / 255.0 > 0.5
        outside = ~silhouette
        # Allow the one-pixel antialiasing band, but nothing beyond it.
        from scipy.ndimage import binary_dilation
        far_outside = outside & ~binary_dilation(silhouette, iterations=3)
        self.assertLess(float(cov[far_outside].max()), 0.02)


class MeasuredDepthTests(unittest.TestCase):

    def test_measured_depth_is_preferred_over_the_dome(self):
        mask = rect_mask()
        # A ramp is nothing like a dome, so the two must differ clearly.
        measured = np.tile(np.linspace(0, 1, mask.shape[1], dtype=np.float32), (mask.shape[0], 1))
        from_measured = relief_for_layer(mask, measured)
        from_dome = relief_for_layer(mask, None)
        self.assertGreater(float(np.abs(from_measured - from_dome).mean()), 0.05)

    def test_degenerate_measured_depth_falls_back_to_the_dome(self):
        mask = rect_mask()
        flat = np.full(mask.shape, 0.5, np.float32)
        relief = relief_for_layer(mask, flat)
        self.assertGreater(float(relief.max()), 0.5)   # a dome, not a constant

    def test_metadata_records_which_was_used(self):
        albedo, masks = synthesize_placeholder()
        _, meta = build_maps(albedo, masks)
        self.assertEqual(meta["reliefSource"], "mask-dome")

        measured = np.random.default_rng(0).random(albedo.size[::-1]).astype(np.float32)
        _, meta = build_maps(albedo, masks, measured)
        self.assertEqual(meta["reliefSource"], "measured")


class ShadingModelTests(unittest.TestCase):

    def flat(self, n=(0.0, 0.0, 1.0)):
        albedo = np.full((1, 1, 3), 0.5, np.float32)
        normal = np.array(n, np.float32).reshape(1, 1, 3)
        ao = np.ones((1, 1), np.float32)
        return albedo, normal, ao

    def test_wrap_zero_is_plain_lambert(self):
        for ndl in (-0.5, 0.0, 0.3, 1.0):
            self.assertAlmostEqual(
                float(wrap_diffuse(np.array(ndl), 0.0)), max(ndl, 0.0), places=6
            )

    def test_wrap_lifts_the_terminator(self):
        """The point of wrapped diffuse: a surface just past 90 degrees still
        receives light, which is what keeps skin from reading as plastic."""
        self.assertEqual(float(wrap_diffuse(np.array(-0.2), 0.0)), 0.0)
        self.assertGreater(float(wrap_diffuse(np.array(-0.2), 0.5)), 0.0)

    def test_facing_the_key_is_brighter_than_facing_away(self):
        rig = LightRig()
        rig.key_dir = np.array([0.0, 0.0, 1.0], np.float32)

        toward = shade(*self.flat((0.0, 0.0, 1.0)), rig)
        away = shade(*self.flat((0.0, 0.0, -1.0)), rig)
        self.assertGreater(float(toward.mean()), float(away.mean()))

    def test_output_stays_in_range(self):
        rig = LightRig()
        rig.key_intensity = 4.0
        rig.exposure = 1.6
        lit = shade(*self.flat(), rig)
        self.assertTrue(((lit >= 0) & (lit <= 1)).all())

    def test_exposure_scales_the_result(self):
        rig = LightRig()
        rig.exposure = 1.0
        base = float(shade(*self.flat(), rig).mean())
        rig.exposure = 0.5
        dimmed = float(shade(*self.flat(), rig).mean())
        self.assertAlmostEqual(dimmed, base * 0.5, places=4)

    def test_zero_direction_does_not_produce_nan(self):
        rig = LightRig()
        rig.key_dir = np.zeros(3, np.float32)
        lit = shade(*self.flat(), rig)
        self.assertFalse(np.isnan(lit).any())




class HairSolverTests(unittest.TestCase):
    """The hair chain. See tools/hair_spring.py for the model."""

    def setUp(self):
        from hair_spring import HairParams, HairSolver, StrandSpec
        self.HairParams, self.HairSolver, self.StrandSpec = HairParams, HairSolver, StrandSpec
        self.specs = [
            StrandSpec(root_u=0.30, root_v=0.15, tip_v=0.60, layer="hair_front"),
            StrandSpec(root_u=0.70, root_v=0.15, tip_v=0.60, layer="hair_front"),
        ]

    def sway(self, solver, seconds=2.0, fps=120.0, sway_until=1.4):
        dt = 1.0 / fps
        trace = []
        for i in range(int(seconds * fps)):
            t = i * dt
            offset = np.sin(t * 4.2) * 0.02 if t < sway_until else 0.0
            solver.step(dt, (offset, 0.0))
            trace.append((t, offset, solver.offsets().copy()))
        return trace

    def test_motion_reaches_the_tip(self):
        """Regression: with a soft spring along the segment axis the segment
        stretches and swallows the motion, so the tip never moves - the ends go
        dead exactly where hair should be liveliest. The hard length constraint
        is what drags each node along with its parent."""
        solver = self.HairSolver(self.specs, nodes=5)
        trace = self.sway(solver)

        root = max(abs(o[0, 0, 0]) for _, _, o in trace)
        tip = max(abs(o[0, 4, 0]) for _, _, o in trace)
        self.assertGreater(tip, root,
                           "tip swings less than the root - motion is not propagating")

    def test_tip_overshoots_the_root(self):
        """Momentum carried through the chain should make the ends swing wider
        than the head that drove them."""
        solver = self.HairSolver(self.specs, nodes=5)
        trace = self.sway(solver)
        root = max(abs(o[0, 0, 0]) for _, _, o in trace)
        tip = max(abs(o[0, 4, 0]) for _, _, o in trace)
        self.assertGreater(tip / max(root, 1e-9), 1.5)

    def test_energy_decays_after_the_head_stops(self):
        """Regression: solving bend after length leaves a length error behind,
        and Verlet reads it back as velocity next step. The chain then pumps its
        own energy and the tip rings louder every swing instead of settling."""
        solver = self.HairSolver(self.specs, nodes=5)
        trace = self.sway(solver, seconds=4.0)

        tail = [(t, o[0, 4, 0]) for t, _, o in trace if t >= 1.5]
        # Below roughly a pixel (1e-3 UV at 1024 px) the chain has settled and
        # the extrema detector is picking up float32 noise rather than motion.
        noise_floor = 2e-3
        extrema = [
            abs(tail[i][1]) for i in range(1, len(tail) - 1)
            if (tail[i][1] - tail[i - 1][1]) * (tail[i + 1][1] - tail[i][1]) < 0
            and abs(tail[i][1]) >= noise_floor
        ]
        self.assertGreaterEqual(len(extrema), 5, "tip barely oscillates")

        # The head stops mid-swing, so momentum already in the chain keeps
        # building for a swing or two before decay starts - that is the
        # follow-through, and how many swings it takes depends on chain length.
        # Anchor on the peak rather than a fixed skip count: what must never
        # happen is amplitude growing again after it.
        peak = extrema.index(max(extrema))
        self.assertLess(peak, len(extrema) - 3, "tip never starts decaying")
        for earlier, later in zip(extrema[peak:], extrema[peak + 1:]):
            self.assertLessEqual(later, earlier * 1.02,
                                 "tip amplitude grew after the peak - solver is injecting energy")

    def test_chain_returns_to_rest(self):
        solver = self.HairSolver(self.specs, nodes=5)
        self.sway(solver, seconds=8.0)
        self.assertLess(float(np.abs(solver.offsets()).max()), 2e-3)

    def test_segment_lengths_are_preserved(self):
        """The length constraint is solved last, so the pose leaving the solver
        must satisfy it exactly."""
        solver = self.HairSolver(self.specs, nodes=5)
        self.sway(solver, seconds=1.5)

        rest = solver.rest_length
        actual = np.linalg.norm(solver.position[:, 1:] - solver.position[:, :-1], axis=-1)
        np.testing.assert_allclose(actual, rest, rtol=0.02)

    def test_motion_is_frame_rate_independent(self):
        """Fixed 120 Hz substeps: a variable-dt spring changes its effective
        stiffness with frame rate, and hair that stiffens when the app is busy
        is very noticeable.

        Compared at the settled steady state rather than mid-swing. A frame rate
        that does not divide the substep rate evenly simulates a few
        milliseconds more or less over a given wall-clock span, so sampling a
        chain that is still ringing catches different phases and says nothing
        about the solver."""
        results = []
        for fps in (24.0, 30.0, 60.0, 120.0):
            solver = self.HairSolver(self.specs, nodes=5)
            dt = 1.0 / fps
            for _ in range(int(6.0 * fps)):
                solver.step(dt, (0.02, 0.0))
            results.append(solver.offsets()[0, 4].copy())

        for other in results[1:]:
            np.testing.assert_allclose(results[0], other, atol=1e-5)

    def test_offsets_are_clamped(self):
        params = self.HairParams(max_offset=0.02)
        solver = self.HairSolver(self.specs, nodes=5, params=params)
        for _ in range(200):
            solver.step(1 / 120, (0.5, 0.5))     # absurd head motion
        self.assertLessEqual(float(np.linalg.norm(solver.offsets(), axis=-1).max()),
                             params.max_offset * 1.01)


class DisplacementFieldTests(unittest.TestCase):

    def setUp(self):
        from hair_spring import HairSolver, StrandSpec, displacement_field
        self.displacement_field = displacement_field
        self.StrandSpec = StrandSpec
        self.HairSolver = HairSolver

    def test_rest_pose_produces_no_displacement(self):
        specs = [self.StrandSpec(0.5, 0.2, 0.7, "hair_front")]
        solver = self.HairSolver(specs, nodes=5)
        field = self.displacement_field((64, 64), specs, solver.offsets())
        np.testing.assert_allclose(field, 0.0, atol=1e-6)

    def test_field_interpolates_between_chain_nodes(self):
        """The field reads node 0 at and above the root and the last node at the
        tip, blending between them down v. Clamping above the root is what makes
        the hairline travel with the head rather than sliding across it."""
        specs = [self.StrandSpec(0.5, 0.25, 0.75, "hair_front")]
        offsets = np.zeros((1, 5, 2), np.float32)
        offsets[0, :, 0] = np.linspace(0.0, 0.04, 5)   # ramp root -> tip

        field = self.displacement_field((101, 101), specs, offsets)

        # Rows map to v = row / (h - 1), so row 25 is exactly rootV and row 75
        # exactly tipV.
        self.assertAlmostEqual(float(field[0, 50, 0]), 0.0, places=5)    # above root
        self.assertAlmostEqual(float(field[25, 50, 0]), 0.0, places=5)   # at root
        self.assertAlmostEqual(float(field[75, 50, 0]), 0.04, places=5)  # at tip
        self.assertAlmostEqual(float(field[100, 50, 0]), 0.04, places=5) # below tip, clamped

        midpoint = float(field[50, 50, 0])
        self.assertAlmostEqual(midpoint, 0.02, places=4)

    def test_falloff_is_widest_at_the_strand_root(self):
        """Gaussian in u, so a strand's influence fades with distance rather
        than dragging a hard column of pixels."""
        specs = [self.StrandSpec(0.5, 0.2, 0.8, "hair_front")]
        offsets = np.zeros((1, 5, 2), np.float32)
        offsets[0, :, 0] = 0.02

        field = self.displacement_field((64, 64), specs, offsets)
        # A single strand normalises to full influence everywhere; add a second
        # at rest so the weighting is actually observable.
        specs.append(self.StrandSpec(0.9, 0.2, 0.8, "hair_front"))
        offsets = np.concatenate([offsets, np.zeros((1, 5, 2), np.float32)])
        field = self.displacement_field((64, 64), specs, offsets)

        near = abs(float(field[32, 32, 0]))    # u = 0.50, at the moving strand
        far = abs(float(field[32, 58, 0]))     # u = 0.91, at the still one
        self.assertGreater(near, far)

    def test_no_strands_is_a_zero_field(self):
        field = self.displacement_field((32, 32), [], np.zeros((0, 5, 2), np.float32))
        self.assertEqual(field.shape, (32, 32, 2))
        self.assertAlmostEqual(float(np.abs(field).max()), 0.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
