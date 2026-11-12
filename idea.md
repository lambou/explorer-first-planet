3d lowpoly game 
open world procedurally generated.
should be a sphere like earth but not fully rendered. it must be generated layer and we need at least 20 layers, inspired by the minecraft system.
just like earth planet, we have sea, ground, beatch, deep sea, ocean floor, mountain, forest, different biome, cloud, cave and many other, the goal is the world is generated based on a seed, but from a level to another we have controlled generation to avoid too much randomness, as we want coherent world.
we want so ratio inspired by earth, like surface available, and surface covered by water, from the macro level to the micro level.
depending on the sea deep the water is for example different, place with vegetation has different soil, desert has different soil so we can have ocean in the middle of a desert, high montain has snow, we need an actual source of like that will act like the son and rotate around the game's planet. forest has its density but inside forest they are common thing we can find like clairiere, waterfall and to have a water fall we need place where a geography allow it, so based on the ground layer we can know if aplace can develop forest or water fall or thing like that we want a coherent world and we want to move step by step layer by layer until we reach the trees which is out of the 20 layers. so we want a part of the world, top north to be cold for the same reason antartica is cold, the middle to be hot and we need some place more tropical, posibility of ilands etc.

we want to use godot, and blender if possible but the point is to have a destructible world like mine craft to dig and see whats under.
the exploration will just be a ball that will mouve and bounce on the world (physic). the game world must be visible chunk by chunk depending on the player possition in the most efficient way.

the separation of concern must be key. we want on the game screen a panel that shows the player cordinate, the ground level from the 0 =sea level, -y bottom +y top depending on the world size sphere we may have the max depth and max height

we must start by the ground, which means the depth for the ocean, the caves system, the canyons, montains iland everything must be taken from the seed, and next we'll add water.

we want to move small steps by small test until we reach like 200k steps

---

# Completed specification (v1)

Engine: **Godot 4.7** (GDScript, GL Compatibility renderer). Blender is optional, only for later props (trees, rocks); the terrain is fully procedural.

## Core decisions
- **Planet**: sphere, 1 m resolution near the player. The original planet design multiplied by WORLD_SCALE = 20: radius 5,120 m (a lap is 32 km, about 24 min at the ball's 22 m/s cap), mountains up to about +1,300 m (limit +1,600), ocean floor to about -980 m, solid to the core. Same shape and mountains as the small planet, but the player (a 1 m ball) is 20x smaller relative to it, so the ground looks flat around the player and the mountains are far away. Macro layers scale with the planet; micro relief (45 m, 9 m and 3 m bumps) stays at human scale. Pole axis = +Y (cold north/south, hot equator).
- **Smooth low-poly, NOT cubes**: the world is a signed density field on a 1 m grid, meshed per 16^3 chunk with Surface Nets (smooth surface, flat-shaded triangles = low-poly look). Destructible: digging carves spheres out of the field, placing adds spheres. Edits are a sparse overlay of density samples on top of the seed, so a save file is only the seed plus the edits.
- **Streaming**: chunks are generated and meshed on worker threads, only within the view radius of the player. Chunks that are fully air or fully solid are skipped. Gravity is radial. The camera "up" is the radial direction.
- **Determinism**: world = f(seed). Each layer derives its own noise seeds from the world seed and its layer index.
- **Controlled generation**: layers run macro -> micro. Each layer only reads what earlier layers wrote (continent -> relief -> mountains ...), so features stay coherent.
- **Earth ratios**: the sea threshold is calibrated from the seed so that LAND_RATIO = 29% of the surface is land (about 71% water), at every seed.
- **Separation of concerns**: `core/` constants, `gen/` pure terrain functions (no scene code), `world/` chunks/meshing/streaming, `player/` ball and camera, `ui/` display only, `main.gd` wires everything. `tests/` runs headless.

## Streaming: only what the player can reach is solid, everything else is a thin surface
- **Near (VoxelWorld)**: full-detail 3D chunks (16 m, smooth surface, destructible, with physics) only within 64 m of the player AND only the chunks that contain the ground surface. Rock below the surface is never built while the player is on top of the ground; digging builds the chunks you reach on demand.
- **Underground only when underground**: caves and the rock around the player (within 28 m, in 3D) are built only while the player is below the ground surface. Caves are at least about 5 m wide and sealed near the surface.
- **Far (FarTerrain)**: a quadtree of low-poly surface patches on a cube-sphere (12 x 12 cells per patch, one height per vertex, no volume, no underground, no physics). Patches get coarser with distance, are not built behind the horizon, are skipped where the full-detail chunks already cover the ground, and use skirts to hide cracks between detail levels. Only the shape of the ground matters from afar. A patch costs about 3 ms to build (about 100x cheaper than a 3D chunk), so the whole visible planet loads in seconds.

## Light (per surface, like reality)
- **Direct sun**: real shadow maps. A surface is lit when the sun can reach it, wherever the player is (a sunlit beach stays sunlit while you stand under an umbrella). Terrain chunks and far terrain both cast shadows, so mountains and overhangs shade the ground, and a shaft only gets a sunlit patch when it points at the sun.
- **Sky light**: lights each surface according to how much open sky that surface sees (baked into the mesh at build time as vertex alpha, read as ambient occlusion). Open ground sees the sky; a dug shaft wall sees only the opening (falls off with depth); a cave ceiling blocks it. No global "player is underground" darkening and no light attached to the ball.
- **Known approximations**: sky exposure uses one straight-up ray and assumes a shaft opening of about 6 m radius; the sun at the bottom of a shaft deeper than the 64 m chunk range is blocked by the far-terrain surface sheet (the opening is not punched through it yet).

## Surface vs underground (two different worlds)
- **On the ground**: sky, sun, far terrain, mountains and fog, as usual.
- **Underground, sky in sight** (a cave entrance or shaft): normal daylight with real shadows; the far terrain is cut along the line of sight to the sky so the sun and sky really come in through the opening.
- **Underground, enclosed** (no sky in sight): the outside world does not exist: no far terrain, sky, sun, fog, ambient or reflections. The cave is dark, and unbuilt rock is just black, never the outdoors showing through a gap. The player moves through a zone: every chunk in the 5x5x5 cube around them is built, so their surroundings are always complete.
- **Camera**: a few rays and a sweep keep it at a spot that fits in the room (underground at most 7 m from the ball); a second check against the terrain data keeps it out of rock even where nothing is built.
- **Clean ground**: skirts of far patches never cast shadows (they made long thin shadow lines at a low sun), full-detail chunks carry hidden skirts under their edges (closes pinholes caused by float precision), shadows are sharp within 140 m.

## Water (physical, per situation)
- **Ocean**: every sea column (continent value below the shore threshold, plus flooded coastal depressions) holds water up to sea level. The surface is a thin sheet built per chunk (near) and per far patch (distant). Colour deepens with depth (turquoise -> deep blue), waves grow with depth.
- **Beach / shore**: shallow water is clear and almost flat with foam bands travelling up the sand.
- **Caves and holes** (WaterSolver): a hollow space that touches the sea is flooded through its opening. Open to the air somewhere (shaft, mouth above the waterline) = water rises to sea level. Sealed = the air stays trapped and the water only reaches the top of the entrance (diving bell); a cave lower than that is flooded completely. A cave that does not touch the sea stays dry. Digging a tunnel into the sea floods it the same way. Sea caves open along the shoreline (mouths above and below the waterline).
- **Swimming**: buoyancy lifts the ball to the surface, drag slows it, Space swims up, Ctrl dives. Under water the view turns blue-green and murky.
- **Realism rules** (see docs/WATER_PLAN.md): water states calm .. storm by place and time; waves only near the camera, far water flat with soft glitter; Fresnel reflection; the sea bed hidden past ~25 m; underwater visibility ~20 m, light dying by ~200 m. All water code lives in src/water/.
- **Not yet**: rivers and lakes (need a drainage layer that carves valleys and gives flow direction), tides, rain.

## The 22 layers (macro -> micro)
| # | Layer | Status |
|---|---|---|
| 1 | Continents / oceans (calibrated 29% land) | done |
| 2 | Base relief: shelf, slope, abyss, coastal plain, plateau | done |
| 3 | Mountain ranges (ridged, inland only) | done |
| 4 | Islands and archipelagos | done |
| 5 | Canyons / rift valleys | done |
| 6 | Small-scale terrain detail | done |
| 7 | Climate: temperature (latitude, altitude), moisture | done |
| 8 | Caves: tunnels and caverns | done |
| 9 | Surface material: sand, gravel, grass, snow, desert | done |
| 10 | Sea water + ocean depth colours | next |
| 11 | Rivers and lakes (from drainage of layer 2-5) | planned |
| 12 | Rain / moisture refinement | planned |
| 13 | Biomes (desert, tundra, taiga, forest, jungle, savanna, wetland) | planned |
| 14 | Soil and ore strata, aquifers | planned |
| 15 | Coast and cliff features, waterfall sites (steep slope + river) | planned |
| 16 | Vegetation density | planned |
| 17 | Forest structure: clearings, groves, density | planned |
| 18 | Props: rocks, flowers, bushes | planned |
| 19 | Individual trees (beyond the 20 terrain layers) | planned |
| 20 | Clouds and weather | planned |
| 21 | Sun cycle and day/night (basic version done) | partial |
| 22 | Fauna and points of interest | planned |

## Roadmap (small steps, each with a test)
1. **M0 (done)**: project, seed, layers 1-9, chunk streaming, ball physics, HUD, dig/place, sun, headless tests.
2. M1: ground polish: per-biome ground colour, cave entrances, bedrock at the core, save/load of edits.
3. M2: water: sea level fill, ocean depth tint, shore, underwater fog.
4. M3: rivers, lakes, waterfalls.
5. M4: biomes + climate bands (polar, temperate, tropical) and ocean in the middle of a desert.
6. M5: vegetation, forests, clearings, then trees.
7. M6: clouds, weather, LOD for distant terrain, Blender props.

## Run
- Play: open the folder in Godot 4.7 and press F5, or `Godot --path . -- --seed=1234`.
- Test: `Godot --headless --path . -s res://tests/run_tests.gd`
- Controls: WASD roll, Space jump, F fly (to explore), R respawn, mouse look, wheel zoom, LMB dig (sphere), RMB place (sphere), Esc free mouse.
