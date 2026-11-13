# Rocks plan

Goal: rocks of many kinds (granite, basalt, gold, diamond, uranium, ... and unknown ones) lying on every kind of
ground (land, sea bed, cave floors), in different sizes, made of layers, harvested by BREAKING (the pieces fall
as debris and vanish), obeying gravity. Seed-related and coherent. Must not cost frame rate.

## Design rules (the cheap tricks)

1. **Rocks are not terrain voxels.** They are objects placed on top of the ground by a deterministic function of
   (world seed, chunk coordinate). Nothing is stored for a rock that has not been touched.
2. **One draw call per chunk.** All rocks of a chunk are baked into one mesh (vertex colours, flat shaded, the
   same material as the terrain, so shadows, underwater darkening and fog just work). Breaking a rock only
   rebuilds that chunk's small rock mesh (a few hundred triangles).
3. **Built on the worker thread** together with the chunk (placement + baking), never on the main thread.
4. **Only near chunks have rocks** (the same 48 m the terrain streams). Far terrain shows none.
5. **Collision: one trimesh per chunk**, from the same baked mesh.
6. **Persistence:** only the exceptions are stored: broken rocks (by id) and moved rocks (by id -> new place).
7. **Gravity** is not simulated for all rocks. A rock is checked for support only when terrain (or the rock
   below it) changes near it; only then does it become a short falling object.
8. **Debris** is a small pooled set (<= 64 pieces) animated in script for ~2 s, then removed.

## Geology (why it is coherent)

* **Province noise** (2D, from the seed) splits the planet into patches; each base rock (granite, basalt,
  limestone, sandstone, slate, marble, obsidian, quartzite) owns a place in that province space, picked per
  seed. The nearest one is the rock lying there. So granite country, limestone country, ... are real regions.
* **Ores** are veins: a low-frequency 3D noise per ore type (seeded). Where the vein value is high, a rock has
  that ore as its core. Each ore has hosts (gold in igneous/metamorphic, coal in sedimentary, uranium in granite),
  a minimum depth (diamond only deep / in caves), altitude and sea rules, and a rarity.
* **Unknown types:** every world also generates a few exotic types from the seed: their own name, colour,
  hardness, density, hosts, depth and traits (radioactive, magnetic, brittle, glowing, ...). The catalog is
  data driven, so adding a real type later is one entry.
* **Layers:** a rock is a list of layers from the outside in: weathered host shell, then the core (an ore or
  gem). Breaking removes the shell first, then the core.
* **Size:** power-law: many pebbles, some rocks, few boulders, rare massive ones.
* **Where:** all ground. Candidate points are chosen inside the chunk, then projected onto the floor found in
  the chunk's density field, so land, sea bed and cave floors all use the same code.

## Steps (each ends with tests)

* R1 (done): `RockType`, `RockCatalog` (fixed types + seeded unknown ones), tests.
* R2 (done): `RockField` (province, veins, rules) and `RockPlacer` (deterministic per chunk), tests.
* R3 (done): `RockMesher` (bake per chunk), hook into chunk build and streaming, one collision trimesh per chunk, screenshots checked (winding clockwise = Godot front face; ore patches clustered, not speckled).
* R4 (done): LMB breaks the rock under the crosshair when it is nearer than the ground; layer by layer (shell comes off, core is left smaller, then it breaks); harvest units per layer into an inventory shown in the panel; `RockDebris` (one MultiMesh, <= 96 pieces, ~2 s, recycled); broken / chipped rocks remembered by id and applied when a chunk is rebuilt.
* R5 (done): debris also flies off where the terrain is dug (ground colour / stone).
* R4b (done, replaces the first version with dents): rocks are SCULPTED like the ground. Every blow takes a round BITE out of
  the rock where the cursor points (a sphere subtracted along every ray from the rock's centre, stored in the rock's own
  frame and persisted); the rock keeps its size and is eaten from where it is hit; picking and the cursor ring use the
  real bitten surface, so the next blow lands deeper. Bitten rocks use a finer mesh (1280 triangles from 0.6 m). Blows on
  the same bite sink and widen it. A thin core nub (22% of the size) stays until the last blow. Fresh fracture shows
  inside a bite (the core, or lighter rock).
* R4c (done): a MOUSE-AIMED TOOL instead of the fixed "+": the mouse stays captured and drives a virtual cursor
  that roams inside an ACTION PERIMETER (a faint dashed circle, 30% of the window height, around the player). Inside
  it the cursor aims the tool; pushing the mouse past the circle's edge turns the camera like before (only the
  outward push turns it). A ring on the surface under the cursor (ground or rock) shows where and how big the blow
  lands (white / yellow in reach, red out of reach: refused). LMB (hold to repeat) breaks the rock under the cursor,
  else digs; RMB places stone. The panel names the target (rock type, layers, size, blows left). Esc frees the
  system mouse, a click returns. Launch options `--aim=x,y` and `--hit=N` reproduce a view and its blows.
* R4d (done): coherent breaking. Blows needed = max(1, hardness x layer volume share x size^2.4 x 1.6): a 0.5 m granite
  rock takes 1 blow, 1 m takes 5, 2.5 m takes 44, 5 m takes 229; the hardest stones take longer at the same size.
  The bite of each blow is sized from that (bigger / harder rock = more, smaller bites) and a feedback rule keeps what is
  left of the rock (volume under the surface) close to the blows left, however the player aims: a bite that took too
  little digs on, one that took too much is cut back. The last blow removes the remnant, and a rock with almost
  nothing left is gone. A shell is bitten the same way; on its last blow it falls away and leaves the core.
* R4f (done): FARMING A ROCK, first blow to last, checked blow by blow (`--seq=prefix` launch option saves a picture and the numbers after every blow).
  Found and fixed: (1) sliding the vertices of the whole sphere into a bite bunched them into thin fans (5-8% slivers) and showed as spikes;
  (2) pressing them out of the bite made the rock GROW; (3) sliding along the bite axis stretched the crater walls. The fix is a real re-mesh:
  a bitten rock is turned into a density field (lumpy blob minus the bite spheres, rims rounded with a smooth minimum, grid scaled to the
  rock so a bite is ~2.5 cells wide) and meshed with Surface Nets (`RockCut`), tiny floating shards dropped. Result: about 1-2% slivers, the
  triangle count follows the rock down (2640 -> 1500 -> 820 -> 427 -> a few), nothing outside the original rock. It is built on a worker
  thread (140-250 ms for a big rock); the quick ray-based shape shows for the first frames, then the re-meshed one swaps in. Also fixed:
  inverted normals on the cut shape (found by the new test), fresh-fracture colour spilling over the whole rock (now only on the crater floor),
  and the aim patch folding into a wedge fan on a cratered rock (it now looks for the real surface along the target's normal).
* R4e (done): REACH. The tool only reaches 4.5 m from the ball (red ring and refused blows beyond it), for rocks and for the ground.
* R6 (done): GRAVITY. Every surface rock is either FIXED (partly sunk into the floor: it bends the floor, never moves) or LOOSE
  (it rests on top: a rigid body). The check is event driven: when the ground is dug / filled, only the loose rocks
  within reach of the edit test whether they are still supported (solid ground under their lower half). An unsupported
  rock becomes a FALLING BODY (one small node each, approximated as a sphere: radial gravity, sampling the density
  field, bouncing, rolling down slopes, resting) and when it comes to rest it is put back in the chunk it lies in. The
  new place is stored with the rock (persistent). Nothing is simulated for rocks that are not falling.
* R10 (done): BURIED DEPOSITS. Under the ground lie rocks (often ore, any size up to huge) in a POCKET of exactly their shape:
  on a coarse world grid (40 m cells, seeded) a cell may hold a deposit at 5-150 m under the natural surface (a smooth
  ellipsoid in any orientation, power-law size). While the chunk is generated underground, the pocket is carved into
  the density field (a hollow slightly smaller than the rock, so the rock hides its walls and digging never fights it)
  and the rock is placed in it; digging around it reveals it, and when the support is gone it falls like any rock.
  INDICATORS: tiny pieces of the deposit's ore lie on the surface above it (more, and a little bigger, the bigger the
  deposit), so a pebble of gold means a big body of gold below. Cost: a cell lookup and a hollow test per chunk.
  Measured: 102 loose / 74 fixed rocks around the spawn; the support check of an edit costs ~0.3 ms; a dropped rock
  comes to rest in ~1.6 s; the deposits cost ~0.5 ms per chunk (pocket carve + indicators) on the worker thread.
  Not done yet: rocks resting on other rocks (a stack falls only when the ground fails, not when the rock below is
  broken), falling rocks do not push the player or other rocks, buried bodies are only built where the underground
  is (their pocket is only carved when caves are), far terrain shows no rocks.
* R7: performance measurement (frame time with rocks on/off, build time per chunk), tuning of density.
* R8: tuning of the geology (balance of types, rarity, depth rules), underwater and cave checks.
* R9: later: boulders as far landmarks, rock weathering by water (texture only), more traits (radioactivity,
  magnetism), tools and hardness.

## Known gaps / decisions to make later

* How tools relate to hardness (hits needed now, a pick later).
* What the harvested items are used for (inventory, crafting): only a counter for now.
* Water only changes the texture of rocks (darkening/wetness), never their placement.
