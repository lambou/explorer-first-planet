# Grass plan

Goal: a cozy game needs real grass. Many kinds (meadow, tall, dry, tufts, sea grass under water), seeded and coherent with
the rest of the world, swaying in the wind, soft and warm to look at, cheap enough to cover the ground around the player
at 60 fps, and built so the climate layer can later put snow, frost or wetness on it.

We do it step by step. This file records the research, the rules, what is done and what is planned.

## Research (what the industry does, and what it means here)

| Source | What it says | What we take |
|---|---|---|
| Godot docs and community (GodotGrass, hexaquo grass series, godotshaders) | Grass = `MultiMesh` (GPU instancing). Culling is per whole MultiMesh, so use small chunks and a custom AABB. A MultiMesh draws every instance at one LOD, so distance LOD = thin out or switch buffer. | One MultiMesh per chunk per grass type (a few dozen draw calls in total), AABB set by hand, distance thinning in the shader. |
| Ghost of Tsushima (GDC, Sucker Punch) | Individual blades with their own look and motion, generated on the GPU; fewer, wider blades at distance; flat texture far away. | Blade clumps with per-blade bend/lean; far away fewer blades (shader thinning); the terrain colour itself is the far grass. |
| Breath of the Wild style (godotshaders, hexaquo part 3) | Wind in the vertex shader from a scrolling noise; tips move most (`bend = t^2`); a push away from the character; cheap triangle/sine waves are enough. | Procedural value-noise gust field + flutter in the vertex shader, no textures; player push is step G2. |
| Godot Compatibility renderer notes | No compute shaders, no indirect draw; colours / custom data of a MultiMesh are 16-bit; MultiMesh visibility AABB must be given by us. | Placement is done on the worker thread (like rocks) and uploaded as one buffer; per-instance data in `INSTANCE_CUSTOM`; custom AABB. |
| GPU Gems 3 ch. 16 (vegetation animation) | Bending must be limited or the illusion breaks; cheap waves approximate sines. | Small bend, with a flutter on top. |

Sources: godotshaders.com (stylized multimesh grass, grass with wind and deformation), hexaquo.at grass rendering series (parts 1-4),
github.com/2Retr0/GodotGrass, GDC Vault "Procedural Grass in Ghost of Tsushima", NVIDIA GPU Gems 3 ch. 16, Godot docs (MultiMesh,
optimizing 3D performance).

Art direction (from text only, my tools do not return pictures): soft and warm, candy-ish colours (Animal Crossing), gentle wind and
desaturated autumn tones (A Short Hike), warm sunset palettes (Spiritfarer). No hard noise, no harsh contrast: blades are
lighter at the tip, darker at the root, tinted by the ground under them. If you drop reference screenshots in
`docs/references/grass/` I can look at them and tune the palette against them.

## Design rules

1. **Grass is a layer on top of the ground, seed related.** Which kinds grow where comes from seeded noise (patches), the
   climate (moisture, temperature) and the ground colour the surface layer already decided (green = grass can grow; sand, rock,
   snow = none). Same seed = same meadows. Each world also gets its own small hue / saturation shift of the palette.
2. **Blades are real (opaque) geometry**, no alpha textures: no overdraw problems, no sorting, shadows and fog just work.
   A clump = 5-9 tapered blades, 3 triangles each (about 18-27 triangles), several clump variants per kind.
3. **One MultiMesh per chunk per kind**, built on the worker thread together with the chunk (placement + one buffer).
   The main thread only assigns the buffer.
4. **Everything animated lives in the vertex shader** (wind, gusts, flutter, sea current, distance thinning). Nothing runs per
   frame on the CPU except setting three global shader values (wind, player position, later snow).
5. **Distance:** shader thinning (each clump has a random number; it shrinks to nothing when the distance says "keep less than
   that"), the chunk node has a visibility range, so far chunks are not drawn at all. The terrain colour carries the far field.
6. **Surface only.** Grass sits on the natural ground; when the player digs, the instances whose ground is gone are removed
   (cheap re-filter of the stored buffer), never regenerated on the main thread.
7. **Climate-ready:** each instance carries its ground colour and a random value; a global `grass_snow` shader value (0..1)
   will whiten and shorten the blades (G4). Sea grass uses the same shader in "water" mode.
8. **Authored meshes later:** the clump meshes are made in code now (no Blender here); the catalog loads a mesh by name, so models
   made in Blender (.glb) can replace them without touching the placement.

## Steps

* G1 (done): the grass layer: `GrassType` / `GrassCatalog` (5 kinds + seeded palette), `GrassField` (what grows where), `GrassMeshes`
  (procedural clumps of 21-30 triangles, 2 variants per kind), `GrassMaterial` (wind shader), `GrassPlacer` (per chunk, worker thread,
  about 3.5 ms), `GrassSystem` (owner, shared wind / player / light values, refilter on edits), hook into chunk streaming, tests.
  Lessons learned (all fixed, keep them in mind for the next steps):
  - the per-instance colour of a MultiMesh without colours is garbage and is multiplied into the vertex COLOR: the position along the
    blade is carried in UV.y instead (this was the black and white blades);
  - the bend is brought into the clump's own axes with normalised axes and one scale, never with an inverse or a division by a squared axis;
  - the grass is lit by hand in its shader (sun and ambient values come from main each frame, so night, dusk and the underwater dimming
    reach it): the engine lighting of thin double-sided blades is unreliable;
  - the grass around the player is trodden down (shorter) so the ball is never hidden in it.
* G2: the player pushes the grass aside (global `grass_player`), gust waves that visibly run across a meadow, stronger wind in storms
  (shared with the water state).
* G3: cozy accents: clover, small flowers, mushrooms, seed heads, per-patch colour variation, dew / backlight tuning.
* G4: climate: `grass_snow` (blades whiten and shorten), frost, wet (darker), dry season; the climate layer feeds the global values.
* G5: performance pass with real frame-time measurements (instances per chunk, draw calls, thinning distances), a mid-range
  variant with fewer, wider blades, instance budget per frame for chunk building.
* G6: authored clump meshes from Blender (.glb) loaded by name; notes on the export settings.
* G7: sea grass details (kelp, caustics tint), grass on river banks, wetland reeds.

## Known gaps / decisions to make later

* No reference images yet (see above).
* Grass does not grow on cave floors (no light); sinkhole bowls get none yet.
* Rocks and grass are kept apart by distance only; no flattening of grass under rocks.
