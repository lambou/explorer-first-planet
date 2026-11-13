# World safety: what the player can do that must never break the game

A player will find every edge of this world. This plan lists the ways a session can end up broken (lost inside the ground, saved in an
impossible state, an unbounded cost), the ONE rule that answers each, where that rule lives, and how it is tested. **Nothing here is built
yet** except what is marked *done*. The rules are written so that later features (a giant creature that throws air blasts and pushes the
player, wind, explosions, a launch pad) go through the same doors and need no new safety code.

## The three principles
1. **One door for movement.** Anything that moves the player other than his own walking (flying, a knockback, a launch, a teleport, a
   respawn) goes through ONE place that clips the move against the terrain data, caps the speed, and keeps him inside the world.
   Nobody else writes `position` or `linear_velocity`.
2. **Nothing impossible is ever saved or loaded.** A save is checked when it is written and again when it is read.
3. **Every pool has a cap and every cap has a test.** Falling rocks, trees, debris, torches, dug samples, saved edits.

## What can break the game, and the answer

| # | Way to break it | The answer | State |
|---|---|---|---|
| 1 | Falls or flies through the floor (fast step, ground not built yet) | **Movement door** (`PlayerMover`): swept move in 0.4 m strides against the terrain data, speed cap `V_MAX` (about 60 m/s), hold while the chunks under him are not built | fly step clipped, *done*; the rest is Phase 1 |
| 2 | Ends up lost deep in solid ground | `PlayerRescue`: lost = solid at the body and no air within 6 m for 1.5 s -> surface above | *done* |
| 3 | A save keeps an impossible place (the player 1.5 km inside the planet) | Save check: position not lost, else `safe_pos` (last place he stood in open air on the ground, written with every save), else the surface above | Phase 2 |
| 4 | Fills the ground around himself (`Shift+LMB` stone) and cannot move | Placing refuses a sphere that overlaps the body (+0.3 m margin). Already buried: he digs out (air within 6 m); never lost | Phase 2 |
| 5 | Digs past the bottom of the world / builds past the top | `_edit_sphere` clamps to the world limits (-5120 m core, +1600 m top); the core layer cannot be dug | to audit: no clamp seen in `_edit_sphere` |
| 6 | Pushed or launched out of the world (a future creature's blast, wind) | Same movement door: speed cap, swept path, altitude ceiling (a soft push back above `MAX_HEIGHT`), and `knockback()` as the only entry | Phase 3 (design only) |
| 7 | Chain-locked by repeated pushes | After a knockback he is immune to the next one for 0.6 s and can steer at once | Phase 3 (design only) |
| 8 | The respawn point itself became invalid (filled, flooded, dug) | `respawn()` validates `spawn_pos` with `PlayerRescue.surface_spot` before using it | Phase 2 |
| 9 | Spawns thousands of bodies / particles | Existing caps (rocks 24, trees 8, debris 96); one test per pool that floods it and checks the cap and the cost | caps *done*, flood tests Phase 4 |
| 10 | Digs the planet into a save of unbounded size and a stall on load | Edit budget metric (samples stored, bytes saved) shown in the debug panel; compaction of the edit overlay if it passes a threshold | Phase 4 |
| 11 | Test tools in the hands of the end user (fly, cave spawn, `[R]`, command-line aids) | `DevTools.enabled` (editor, or a debug build, or `--dev`): the keys and the aids check it and do nothing otherwise | Phase 1 |
| 12 | The camera inside the ground | Cameras never put the view in terrain; a special camera (cave, digging) is a separate camera, switched to by context | camera *done*; special cameras when needed |

## Modules (one job each)

| Class | Job | Knows about |
|---|---|---|
| `PlayerMover` (new) | THE door: `step(velocity, dt)` clips, caps and holds; `knockback(impulse, source)`; `teleport(pos)` validates. Owns `V_MAX`, the ceiling, the "area not built" hold | world data |
| `PlayerRescue` (*done*) | lost check + surface spot | world, generator |
| `SaveGuard` (new) | `check(data)` before writing and after reading: position valid, inventory counts >= 0 and within weight, item ids known, rock and tree states well formed. Repairs what it can, reports what it cannot | save data, rescue |
| `DevTools` (new) | one flag; every debug key and `--` aid asks it | nothing |
| `WorldLimits` (new, tiny) | the top and bottom of the world, `clamp_sample()` used by every edit | world config |

`BallPlayer` keeps only the walking and the capsule; it no longer decides about fast moves. A creature, a wind zone or a launch pad
calls `PlayerMover.knockback()` and never touches the ball.

## Phase 1: close the doors that are open now (small)
- `PlayerMover` with `step()` (the fly clip moves here and also guards a fall faster than `V_MAX`) and the hold while the area is not
  built (`is_area_ready`).
- `DevTools.enabled`; gate `F` (fly), `C` (cave spawn), `R` (respawn, kept for the player as "stuck?" later) and every `--aid`.
- Tests: dive at full speed from 5 m, 500 m and into a chunk that is not built: never inside the ground; the keys do nothing when
  `DevTools.enabled` is false.

## Phase 2: nothing impossible in the save
- `SaveGuard` and `safe_pos` in the save; `respawn()` validates its spawn point; placing stone refuses to overlap the body.
- Clamp every edit to `WorldLimits` and make the core undiggable; check what `carve` does at -5120 m first.
- Tests: a hand-made save with the player 1500 m down, with a negative stack, with an unknown item id, from an older version.

## Phase 3: design for the creature (do not build)
- One entry: `PlayerMover.knockback(impulse, source)`. The mover caps the resulting speed at `V_MAX`, sweeps the path each step, softly
  pushes him back below the altitude ceiling, ignores a second knockback for 0.6 s, and lets him steer from the first frame.
- The creature decides WHAT (strength, direction, damage); the mover decides whether it is allowed to move him. No creature ever sets
  `position`.
- Blasts that push rocks and trees reuse the falling bodies (`RockPhysics`, `TreePhysics`), which already have caps and contacts.
- Test (when built): a blast of any strength never ends with the player lost, outside the world limits, or stuck in a knockback.

## Phase 4: budgets
- Flood tests for each pool; a debug line for samples edited and bytes saved; the compaction of old edits if the budget is passed.

## Cost rules
- Everything that runs every frame is O(strides of one step): the movement clip is at most 10 density lookups at fly speed, none when the
  step is shorter than 0.4 m of free air. `PlayerRescue` runs 4 times a second and costs 52 lookups only while the body is in solid ground.
- `SaveGuard` runs on the worker thread that writes the save (the snapshot is plain data) and once on load.

## Open decisions (need an answer before Phase 2 and 3)
1. A player who is stuck in a sealed pocket with no tool: free "unstuck" after N seconds, or only the dig-out?
2. Should `V_MAX` allow a long fall to hurt (a survival rule) or only be a speed cap?
3. Ceiling: a hard wall at `MAX_HEIGHT`, or a soft push (thin air that slows him)?
4. Should a ground disconnected by digging (a floating chunk of terrain) fall like a rock, stay, or be removed? The rocks and trees fall now;
   the terrain does not.
