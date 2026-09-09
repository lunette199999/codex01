# RelightKit

A 2.5D relighting stack for a macOS desktop character. Takes a still portrait
and gives it dynamic lighting, layered parallax and environment response — the
"good shader pack" effect, on an asset that never rotates.

Character-agnostic by design: nothing in here knows or cares who is in the
texture. A neutral placeholder mannequin ships with it so the whole pipeline
runs end to end before any character exists.

**Tune it in the browser:** [Relight Bench](https://claude.ai/code/artifact/1cd05591-96c4-401b-a009-00af37f6178e)
runs the same lighting model in WebGL, with live controls and a JSON export
that drops straight into `LightRig`.

## What it does

| | |
|---|---|
| Dynamic key/fill/rim | Move the light, get real highlight and shadow shifts |
| Wrapped diffuse + fake SSS | Skin that reads as skin rather than plastic |
| Layered parallax | Hair occludes and reveals the face instead of shearing as one sheet |
| Environment response | Time-of-day sun, indoor presets, ambient picked up from the desktop behind the window |
| Cavity AO | Contact darkening under the jaw, beside the nose, where hair meets face |
| Per-strand hair | Verlet chains, so the ends trail and spring back instead of the layer sliding rigidly |

## Why layers instead of one depth map

Monocular depth over a whole portrait produces a single continuous surface, so
hair, face and collar melt into each other. Every silhouette becomes a smooth
ramp instead of an edge, and nothing can move independently — which is the
ceiling a single-plane image warp hits.

Splitting into four ordered bands fixes all three problems at once:

```
hair_back   base 0.20   parallax -0.35
body        base 0.35   parallax +0.15
face        base 0.55   parallax +0.55
hair_front  base 0.78   parallax +1.00
```

Each is drawn as its own quad, back to front, with its own offset. Occlusion is
correct because the ordering is explicit. Disocclusion is hidden because what a
moving layer reveals is the layer already drawn behind it. Depth gradients stay
inside a band, so normals stay clean at the edges. The spread between the
parallax weights is the depth cue — the absolute numbers barely matter.

## Layout

```
tools/portrait_maps.py       offline: masks (+ optional measured depth) -> map set
tools/relight_reference.py   the lighting model in numpy - canonical definition
tools/hair_spring.py         strand chains + displacement field - canonical
tools/render_preview.py      animated preview; reference for the layer path
tools/test_portrait_maps.py  32 tests over the map maths, the model and the hair
tools/bundle_sandbox.py      inlines maps into a standalone sandbox build

Sources/RelightKit/
  Resources/Relight.metal    the shader
  LightRig.swift             rig state + uniform packing
  PortraitMaps.swift         map loading, layer table
  RelightRenderer.swift      Metal pipeline, one pass per layer
  EnvironmentLight.swift     solar position, colour temperature, ambient sampling
  HairSpring.swift           Verlet strand chains

web/sandbox.html             WebGL tuning bench (same model)
assets/placeholder/          generated mannequin + its maps
```

The lighting model exists three times — numpy, Metal, GLSL — with identical
parameter names so the versions can be diffed by eye. **`relight_reference.py`
is canonical.** Change it there, confirm the render, then port.

## Running it

```sh
# regenerate the placeholder and its maps
python3 tools/portrait_maps.py assets/placeholder --synthetic --name mannequin

# render a lit frame and a key-light sweep into validation/
python3 tools/relight_reference.py assets/placeholder --name mannequin

# animated preview: layered compositing + parallax + hair springs
python3 tools/render_preview.py assets/placeholder --name mannequin

python3 tools/test_portrait_maps.py
swift test                      # macOS only
```

The sweep contact sheet is the fastest check on a model change: the nose shadow
should cross the face and the form should stay solid throughout.

For the tuning bench locally, serve the repo root and open `/web/sandbox.html`
(it fetches its maps). `python3 tools/bundle_sandbox.py` produces the
standalone single-file build.

## Adding a character

1. Author an RGBA albedo — **unlit**. Bake no lighting into it; the runtime adds
   all of it, and a baked highlight will fight the live one.
2. Author four masks, one per layer. Any segmentation tool, or by hand.
3. Get a depth map from a monocular depth model (Depth Anything V2, Marigold) —
   optional but strongly recommended for faces. The mask-dome fallback has no
   eye sockets, so a face relit from it inflates like a balloon.

```sh
python3 tools/portrait_maps.py assets/mychar --name mychar \
    --albedo albedo.png --depth depth.png \
    --mask hair_back=hb.png --mask body=body.png \
    --mask face=face.png --mask hair_front=hf.png
```

```swift
let maps = try PortraitMaps.load(name: "mychar", in: assetsURL, device: device)
let renderer = try RelightRenderer(device: device)

var environment = EnvironmentLight()
environment.ambientSample = sampledDesktopColor   // optional
renderer.rig = environment.rig(for: .indoor(.screenGlow))
renderer.parallax = idle.advance(by: deltaTime)

renderer.encode(maps: maps, into: encoder)
```

## Notes for integration

The fragment shader outputs **premultiplied** alpha, which is what a
transparent always-on-top `NSWindow` needs — straight alpha fringes against the
desktop behind it.

`EnvironmentLight.ambientSample` expects linear RGB. Capture the region behind
the window (ScreenCaptureKit), average it with `averageColor(of:context:)`, and
smooth the result before use — sampling raw will make the lighting flicker every
time a window scrolls behind it. A few samples a second is plenty.

`windowBearing` is a user preference, not a measurement. It decides whether
morning sun rakes from the left or the right, and there is no way to know it
from the machine.

Under SwiftPM the `.metal` ships as a resource and is compiled at launch, since
SwiftPM has no Metal build rule. In an Xcode target, add the same file to the
target's compile sources and `RelightRenderer` picks up the precompiled default
library instead.

## Not done yet

- Hair spring chains driving the layer offsets (the maths ports from the
  existing 2D implementation; it currently only drives whole-layer parallax)
- Blendshape-style expression blending between map sets
- Depth-aware compositing against a background scene — `depth.png` is written
  but nothing samples it at runtime yet
