# Flora plan (all plants, from grass to trees to sea life)

Grass (docs/GRASS_PLAN.md) is the first layer of a general vegetation system. The planet is not the same everywhere: tundra moss,
steppe grass, rainforest ferns and trees, mangroves on warm shores, reeds on river banks, kelp in cold seas, coral in warm shallows.
The list can grow to a thousand kinds. We get there layer by layer, and the design below is what keeps that cheap.

## The idea: species are data, shapes are shared

* **Species = one row of data** (later one small resource file each): name, growth form, size range, palette, wind sway, where it
  lives (its NICHE: temperature, moisture, altitude range, slope, ground colour, salinity, water depth, light), density, rarity,
  seasons. Adding the 500th species is a row, not code.
* **Archetypes = the few real meshes** (made in code now, Blender later): blade clump, fern, flower, shrub, bush, palm, conifer,
  broadleaf tree, mangrove (prop roots), reed, lily pad, seagrass ribbon, kelp, coral fan, moss patch... about 20-30 in total.
  Hundreds of species reuse them, changed by colour, size, lean and a few shape numbers in the per-instance data.
* **Draw cost follows the archetypes present in a chunk, not the species**: one MultiMesh per chunk per archetype (and size band).
  A forest of 40 species still costs a handful of draw calls.

## Where each species grows (coherent, seeded)

1. **Biome from climate**: the climate layer already gives temperature and moisture; with height, slope, ground colour and water
   depth they make a niche score for every species at every planting spot. Each spot takes the best few (weighted draw), so
   neighbouring spots mix species naturally.
2. **Flora provinces (seed)**: like the rock provinces, a slow seeded noise splits each climate zone into regions that draw their
   species from different pools, so two planets with the same climate still have different plants, and every world gets its own invented
   species (names, colours, odd traits) as the rocks do.
3. **Layers on top of each other** (each is a planting pass with its own spacing): ground cover (grass, moss, clover) -> low plants
   (flowers, ferns, reeds, mushrooms) -> shrubs -> trees (canopy) -> aquatic (shore, floating, underwater). Higher layers decide
   where lower ones are thinned (shade under a canopy, bare ground in a mangrove, nothing under a rock).
4. **Climate-ready**: one shared set of shader values (snow, frost, wet, dry season, autumn colour) already exists for grass and every
   archetype reads it, so a new species gets seasons for free.

## Performance rules (they decide how many species we can afford)

* Planting is deterministic per chunk on the worker thread; the main thread only assigns buffers.
* Budget per chunk (instances and triangles per layer); the placer stops at the budget, richest species first.
* Distance bands by size: tiny plants only near the player, shrubs farther, trees visible at distance with fewer triangles (and a
  billboard / impostor tier later). The terrain colour carries the far field.
* All motion in the vertex shader with shared wind; no per-plant scripts, no per-plant collision except big trunks (later, simple).
* Edits (digging) filter stored buffers; nothing is replanted on the main thread.

## Decisions (from the user)

* **Trees that block the camera fade out** (a dithered fade in the tree shader, driven by one shared "camera / player" value): cheaper than
  steering the camera around them, and the camera never has to leave the player's chosen angle.
* **Trees come right after the framework (F1).** There are many kinds of trees, so trees are a family of archetypes, not one.

## What the reference images show (lab/grass-ref, five cozy / stylised games)

* **Colour:** light, warm, yellow-green meadows with deeper greens in the shadows; very soft shading; sand-coloured paths and beaches. Our
  grass is darker and more olive than all five: it needs lighter, yellower tips and a brighter base.
* **Grass:** blades are wider, taller and denser than ours, bent in a soft curve, with bright tips (the mowing-game image). A patchy mix of
  short and tall, with bare warm patches between (the garden game).
* **Flowers are the cozy part:** thousands of tiny white / pink / blue flowers scattered over the grass (all four meadow shots). This is the
  cheapest big win: a flower archetype (a few triangles, one colour) scattered like grass, in patches.
* **Shrubs:** round, dense, slightly bumpy blobs of leaves (garden game, forest game), sometimes with small berries or blue flowers.
* **Trees, three looks:**
  1. broadleaf with a thick trunk and big rounded canopy made of leaf clusters (the open-world and garden shots);
  2. stylised pines: stacked cones in dark teal, simple and faceted (the island);
  3. feathery conifers / firs made of frond-like layers, ferns at their feet (the forest shot).
* **Trunks and roots:** thick bases, a few visible branches, a dark patch of soil around the trunk; fallen logs with moss on the ground.
* **Rocks sit in the vegetation:** grass and flowers grow right up to them (ours already keep a small gap).

## Layers (steps), each ends with tests and screenshots

* F1 (done, lighter version): the grass was retuned to the reference colours (lighter, yellower, wider blades) and flowers came in as the
  first low plant (daisies, pink flowers, bluebells, in seeded patches). The full species / archetype / niche framework is built
  for trees first (TreeCatalog / TreeField / TreeInst); grass keeps its own small catalog until step F3 folds it in.
* F2 (done: first version): TREES, a seeded layer (src/trees/).
  - 7 canopy families (broadleaf, round, birch, pine, fir, palm, acacia), 8 species + 3 invented from the seed (11 on seed 1337: an
    invented one is a pink pine); each species lives in a climate niche, each region (province noise, ~400 m) prefers some of the species
    the climate allows; big forests, grove clumps and meadows from the forest noise (~110 m). Dense forest = 10-18 trees per chunk.
  - Baked into ONE mesh per chunk (flat low poly, 150-470 triangles a tree) with one trunk collision shape; planting costs ~1 ms per chunk on the worker.
  - Cutting like rocks: every blow cuts a notch into the trunk and throws chips; blows = wood hardness x trunk thickness squared (a sapling 3, a
    0.9 m trunk 40+); the last blow fells it: it tips over its foot away from the player (TreePhysics), bursts into leaves and lies as a trunk;
    a lying trunk is chopped log by log from its tip (wood goes into the Harvest list), the last blow takes the last piece. Digging the ground
    out from under a tree makes it fall too. Cut and fallen trees are saved by id and survive chunk rebuilds.
  - Camera: trees between the camera and the player, and crowns the camera is inside, fade out in a cheap dither (no transparency).
  - Measured: from an ordinary view the forest edge runs at 60 FPS; inside a dense forest with the camera inside the crowns it dropped to about 40 on
    this machine (fill rate of the overlapping crowns). Ideas if it is too slow: fewer crown clusters near the camera, shadows off for crowns,
    a lower planting density, or fading whole crowns near the camera instead of dithering them.
  - Open forest: planting spacing 4.8 m and crowns 12% smaller (the first 3.7 m was a wall of leaves and 26 FPS inside it; now about 40).
  - Distance LOD: within 16 m the full tree with shadows, beyond it a cheap version (one crown cluster, fewer tiers / fronds, no shadow).
  - FAR FOREST (done): beyond the streamed chunks, flat cutout cards (2 triangles) in 128 m sectors, one draw call each, built on the worker
    thread from the same forest field; a shader draws each canopy family's silhouette; hand-over dither at 44-58 m, drawn to 440 m.
    Cards use their own 8 m grid, so single far trees are not at the exact place of the real ones that appear later.
  - Looking up: the camera tilts its view to the sky (OrbitCamera.tilt) once it is at ground level.
  - Still missing for trees: grass is not thinned under crowns, no shade, branches are not separate pieces, felled trees do not roll on slopes,
    the far cards ignore steepness and felled trees, terrain does not hide what is behind it yet (occlusion culling), shadow cost of unseen trees.
* F3: fold grass and flowers into the species system, then low plants: ferns, clover, mushrooms, moss, fallen logs; shade rules.
* F4: shore and fresh water: reeds and cattails on river banks and shores, lily pads, water grass.
* F5: shrubs and bushes (berries later); cold / dry / wet variants.
* F6: mangroves on warm shores (prop roots in shallow water), salt marsh.
* F7: sea life plants: kelp forests, sea grass meadows by depth and temperature, coral in warm shallows, light-dependent.
* F8: biome extras: desert succulents and cacti, tundra moss and lichen, alpine cushions, jungle vines.
* F9: harvest and interaction (like rocks): cut, pick, seeds; seasons and growth; fallen leaves.
* F10: authored meshes from Blender (.glb by name) replace the code-made archetypes where we want a hand-made look.

## Known gaps / decisions to make later

* How many species per planet (a few dozen visible at once is plenty; the catalog can hold many more).
* How big trees get on this planet (the world is about 5 km in radius: tall trees of 15-30 m look right next to a 1 m ball).
