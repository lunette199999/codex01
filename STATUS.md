# STATUS — verification state and ownership

Snapshot for handoff. Read this before trusting anything in the package.

Written by Claude. The counterpart agent (Codex) owns the native desktop app
and the character assets; this package owns post-processing effects only.

---

## 1. Ownership split

| Area | Owner | This package |
|---|---|---|
| Native desktop app, window, audio, menus | **Codex** | not touched |
| Character assets, portrait/expression images | **Codex** | not touched |
| Reference material and likeness decisions | **Codex** | not touched |
| Lighting model, depth/normal maps, layer compositing | **Claude** | this package |
| Hair motion algorithm (as an alternative) | **Claude** | this package |

Nothing here modifies or replaces anything in the existing app. `RelightKit`
is a standalone SwiftPM library with its own renderer.

---

## 2. Verification state — read this carefully

Three distinct levels. Do not treat them as equivalent.

### RUN AND VERIFIED

Executed in this environment, output inspected.

| Component | Evidence |
|---|---|
| `tools/portrait_maps.py` | Generates the 11-file map set; 36-test suite passes |
| `tools/relight_reference.py` | Rendered `validation/mannequin.lit.png` and `.sweep.png`; inspected |
| `tools/hair_spring.py` | Solver measured: 2.6 Hz tip oscillation, 0.76 decay/swing, 2.65x tip overshoot, frame-rate independent to 1e-5 across 24/30/60/120 fps |
| `tools/render_preview.py` | Rendered `validation/mannequin.hair.gif`, 72 frames; inspected |
| `tools/test_portrait_maps.py` | **36/36 pass** |
| `web/sandbox.html` (GLSL) | Compiled and rendered in Chromium; screenshotted; controls exercised |

### WRITTEN, NOT COMPILED

No Swift toolchain in the build environment, and Metal is macOS-only. These are
written carefully and their logic is mirrored by verified Python/GLSL, but they
have **never been compiled or executed**. Expect to fix build errors.

| Component | Risk |
|---|---|
| `Sources/RelightKit/*.swift` (5 files) | Syntax/API errors; SwiftPM resource handling for the `.metal` |
| `Sources/RelightKit/Resources/Relight.metal` | MSL compile errors; the GLSL twin compiles, which covers most of the shared logic |
| `Tests/RelightKitTests/*.swift` (17 tests) | Never run |

The one silent-failure risk worth knowing: `RelightUniforms` is read by the
shader at fixed byte offsets. A field added or reordered produces a subtly
wrong image rather than a crash. `testUniformStrideMatchesShader` pins the size
at 176 bytes — run it first.

### NOT ATTEMPTED

- Integration into the existing desktop app
- Any run against a real character asset
- Any run at the app's 24 fps window rate on device
- Performance/thermal measurement on Apple Silicon
- Expression switching between map sets

---

## 3. What is complete — lighting

Verified against the placeholder.

- **Wrapped diffuse** key and fill. Softens the terminator; the single largest
  factor in skin not reading as plastic.
- **Terminator-band scatter** as a cheap subsurface stand-in, gated by the key
  term so an unlit side does not fluoresce.
- **Blinn specular**, suppressed where the key does not reach so it never
  floats over shadow.
- **Fresnel rim** with an independent direction.
- **Cavity AO**, applied to ambient and fill but not key.
- **Linear-space shading**, sRGB on presentation. Compositing lit colour in
  gamma space is the usual cause of chalky midtones.
- **Environment model**: NOAA solar position (elevation + azimuth), colour
  temperature from sun elevation, four indoor presets, and an ambient term that
  can be blended from a sample of the desktop behind the window.

The model exists three times — numpy, Metal, GLSL — with identical parameter
names. **`tools/relight_reference.py` is canonical.** Change it there, confirm
the render, then port.

## 4. What is complete — spatial / depth

- **Four ordered depth bands** (hair_back / body / face / hair_front) rather
  than one continuous depth surface. A single estimated relief melts hair, face
  and collar together, turns every silhouette into a ramp, and lets nothing move
  independently.
- **Per-layer parallax** with independent weights; the spread between them is
  the depth cue.
- **Correct occlusion**, from explicit ordering rather than a depth buffer.
- **Antialiased per-layer coverage**, with each layer grown under the layers in
  front of it. Without that the softened edges of two abutting layers each fall
  to ~0.5 at a seam and `over` compositing lands on ~0.75 alpha — a dark
  outline tracing every boundary.
- **Depth-derived normals**, computed per layer inside its own mask so a layer
  boundary is never read as a near-vertical wall and lit as a hard bright edge.

### Depth provenance — important

The manifest records `reliefSource`:

- `"measured"` — from a monocular depth model. Real surface.
- `"mask-dome"` — **estimated**. A distance-transform dome, not measured
  geometry. It has no eye sockets, so a face relit from it inflates.

The placeholder is `"mask-dome"`. **Any real character should use `--depth`
with a measured map.** Do not present mask-dome depth as recovered structure.

---

## 5. Hair — ALTERNATIVE IMPLEMENTATION, NOT A REPLACEMENT

The app's existing hair motion (`Motion.swift`: three force-based spring
segments per side driving a local 2D image warp) **remains the active
implementation**. Nothing in this package calls it or changes it.

`HairSpring.swift` / `hair_spring.py` is a second approach for comparison:

| | Existing (Motion.swift) | Alternative (HairSpring) |
|---|---|---|
| Structure | 3 segments per side | chain per strand, roots from the mask |
| Integration | force-based, explicit velocity | Verlet + positional constraints |
| Authoring | segments placed by hand | derived automatically from masks |
| Tip behaviour | side moves largely as a unit | ~2.6x overshoot, trails and settles last |
| Cost | a few CPU springs | one `exp()` + short loop per pixel per hair layer |
| Verified on device | yes | **no** |

Three modelling errors were found and fixed while building it, each now pinned
by a regression test — worth knowing if you evaluate or re-tune it:

1. **Soft springs along the segment axis** let segments stretch and absorb the
   motion; the tip barely moved. Tip/root amplitude went 0.02x → 2.6x once
   length became a hard constraint.
2. **Bend solved after length** left a length error that Verlet read back as
   velocity — the chain pumped its own energy and rang louder each swing
   (−17.9, +21.3, −40.8). Order is now bend, then length.
3. **Bend magnitude** applies per constraint iteration per substep, so an
   intuitively-sized 0.34 was ~12x too stiff and the chain moved as a rigid rod.
   Effective time constant is ~`1 / (120 * iterations * bend)`; 0.0278 puts the
   upper chain near 0.15 s and the tip near 0.6 s.

Adopting it is a decision for whoever owns the app. It is not a consequence of
merging this package.

---

## 6. Front-facing constraint — enforced

Requirement: upright head and neck, facing the viewer, no tilt.

This holds **structurally**, not by tuning:

- **The pipeline is translation-only.** Parallax offsets a layer's quad; the
  hair field offsets sample coordinates. There is no rotation term anywhere in
  the uniform block or either shader, so no combination of settings can tilt
  the head.
- **Only hair moves.** A layer with `hair: false` gets an all-zero hair uniform
  block, and a zero `params.w` disables displacement in the shader. The face
  and body cannot be deformed by the strand system under any parameters.

Pinned by four tests. The strongest asserts that face pixels are
**bit-identical** between a frame with the hair fully displaced and a frame at
rest, while the hair itself differs — so any deformation leaking into the face
fails the suite:

- Python: `FrontFacingInvariantTests` (4 tests, run and passing)
- Swift: `FrontFacingInvariantTests` (2 tests, written, not run)

The constraint is not encoded in the character asset here — the placeholder is
symmetric and frontal by construction. Correcting selfie-camera angle in a real
asset is upstream authoring work and belongs with whoever owns the assets.

---

## 7. Running it

```sh
python3 -m pip install numpy pillow scipy

python3 tools/portrait_maps.py assets/placeholder --synthetic --name mannequin --save-masks
python3 tools/relight_reference.py assets/placeholder --name mannequin
python3 tools/render_preview.py  assets/placeholder --name mannequin
python3 tools/test_portrait_maps.py          # 36 tests

swift build && swift test                    # macOS only; NOT YET RUN
```

Tuning bench: serve the repo root and open `/web/sandbox.html`, or run
`python3 tools/bundle_sandbox.py` for a standalone single file.

## 8. Adding a real character

1. RGBA albedo, **unlit** — bake no lighting in; a baked highlight fights the
   live one.
2. Four masks, one per layer.
3. A measured depth map (Depth Anything V2, Marigold). Strongly recommended;
   see §4.

```sh
python3 tools/portrait_maps.py assets/mychar --name mychar \
    --albedo albedo.png --depth depth.png \
    --mask hair_back=hb.png --mask body=body.png \
    --mask face=face.png --mask hair_front=hf.png
```

Strand roots are derived from the hair masks automatically. No extra authoring.

## 9. Known limitations

- Strand chains are 2D in UV. Hair crossing in front of and behind a shoulder
  needs more layers or per-strand depth.
- `depth.png` is written but nothing samples it at runtime yet.
- Image-warp hair stretches the texture between strands when neighbours
  diverge. Visible on the placeholder's smooth blob; less so on hair with real
  strand detail. `blendSigma` trades this against per-strand independence.
- No expression blending between map sets.
- The mask-dome depth fallback is an estimate. See §4.
