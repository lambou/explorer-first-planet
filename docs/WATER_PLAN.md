# Water plan and change log

Water is its own module: everything lives in `src/water/`. The rest of the game only calls its small API
(see "Module boundary"). Goal: believable, cheap, never a simulation. Detail only near the player, minimal far away.

## References (lab/water-ref) and what each one teaches
| Reference | Rule we take from it |
|---|---|
| Lake with floating dock | CALM water is a near-mirror of the sky; reflections stretch vertically; only fine ripples |
| Aerial blue hole | depth reads as colour: clear turquoise shelf -> nearly black centre; bottom visible only on the shelf |
| Baikal diver | UNDERWATER visibility is ~10-15 m; everything farther dissolves into uniform teal; light dims with depth |
| Lake Superior coast | far open water = flat deep blue, NO visible waves; bottom only visible in the shallows; glitter is sparse and soft |
| Deep-lake drowning photo | opaque dark water: you cannot see below the surface |

## Physics shortcuts we use (and their source)
- Surface = Fresnel mix of (sky reflection + sun glint) and body colour. F0 of water = 0.02.
- Sun glint comes from slope statistics (Cox & Munk 1954): mean-square slope = 0.003 + 0.00512 * wind. We use an "agitation" 0..1
  instead of wind speed. Resolved waves only near the camera; with distance the lost wave detail turns into roughness
  (Bruneton, Neyret, Holzschuch 2010), so far water stays flat and shows a broad soft glitter.
- Under the surface: Beer-Lambert absorption (red dies first, blue last), visibility perimeter by fog, sun dims ~exp(-depth/70):
  nearly dark below ~200 m.

## Module boundary (src/water/)
| File | Responsibility | Talks to |
|---|---|---|
| water_material.gd | the surface shader (looks, LOD, states) | meshes' UV (depth, kind) |
| water_mesher.gd | surface mesh of one chunk from water levels | chunk data |
| water_solver.gd | cave / hole flooding rules | chunk data, generator |
| water_system.gd | owner: material, solver scheduling, queries (level, submersion), state uniforms | VoxelWorld, FarTerrain |
| water_state.gd | calm / agitated state by place and time | water_system |
| underwater_effect.gd | camera under water: visibility, light, colour | main (environment) |
Outside code may only use: `WaterSystem.setup/tick/water_level_at/submersion`, `UnderwaterEffect.apply`, `WaterState.agitation_at`.

## Done
- W1  sea surface (near chunks + far patches), depth colour, shore foam
- W2  cave / hole flooding rules (vented = sea level, sealed = entrance top, low cave = full), sea caves, digging floods
- W3  swimming: buoyancy, drag, dive, underwater tint
- W4  module split into src/water/, WaterSystem owns scheduling and queries (VoxelWorld only forwards)
- W5  surface shader rebuilt: Fresnel + Cox-Munk roughness, wave detail faded with distance (far = flat, rough), states
- W6  water states (calm .. storm) by place and slow time; shore surf scales with it
- W7  transparency from depth (Beer-Lambert path), the sea bed is hidden past ~25 m
- W8  underwater: visibility perimeter, absorption colour, light dying with depth

- W9a rivers v1 (layer 10): river channels follow noise lines on low land, bed and water level depend on the distance to the coast so they always drop towards the sea, one continuous channel (hollows filled, hills cut), river-kind water (shallow, clear, silt-green). Sun now turns in 8 minutes.

## Known gaps of the done steps (to revisit)
- W9b (done): river extent follows the channel factor interpolated per sample (smooth edges), and every river vertex now carries the river kind, so the colour is uniform (the dark patches were river water mis-labelled as cave water because averaged levels lost their marker).
- W9b gaps: No flow direction/animation yet, no lakes, no tributaries (rivers do not merge), rivers appear only on lowland up to ~100-300 m height, and they do not yet carry water into the sea as a visible river mouth.
- W9c (done): rivers are a layer ON TOP of the finished ground (l10_rivers.gd). The seed only decides where; the water level is the lowest bank in a 14 m ring minus 0.4 m, the channel is cut to level - 1.3 m, and a river does not exist where holding the water would need a gorge (> 3-8 m cut). Rivers fade out between 35 and 65 m altitude (no water on grassy hillsides). Replaces the old coast-distance bed rule that left water hanging on slopes. Water is never below 0 just because of level 0: sea only in ocean / coastal columns, caves only when connected to the sea (solver fills only up to its level).
- W9c gaps: rivers are rare (about 0.05% of land columns) and only in low coastal plains; no flow, tributaries, lakes, mouths or waterfalls yet; real drainage (carving a valley down to the river) would give more rivers.
- W5: the sun glitter is a soft vertical column that follows the sun; from a high camera it looks plausible but I have not compared it
  numerically against a reference photo. Far open water is flat by design (matches the Lake Superior photo).
- W7: the bottom of a lake is visible in the shallows only; I tuned the absorption by eye against the blue-hole photo.
- W8: Snell's window (the bright circle seen from below) and caustics are not done (W11). Underwater far silhouettes still show faintly.
- States: no wind direction yet; waves travel in fixed directions.

## Planned
- W9   rivers: drainage layer (carved valleys, flow direction, flow-stretched ripples) and lakes (basins that fill to their spill level)
- W10  waterfalls where a river meets a steep drop
- W11  underwater floor: caustics on shallow sand (cheap scrolling pattern), god-rays near the surface
- W12  suspended particles ("marine snow") that give a sense of motion and depth
- W13  underwater props: kelp/coral instancing near the player only, fish schools as GPU particles
- W14  sound hooks (above / below, near surf) and surface interaction (ripples from the ball)
- W15  tides and rain, weather driving the agitation state
- W16  ice: frozen water in cold latitudes
- W17  water in dug holes spreading gradually (animated fill instead of instant)
