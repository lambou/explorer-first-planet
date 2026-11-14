# Swimming, diving, underwater flight and living water: plan

Status: steps 1-5 IMPLEMENTED and tested with `--oceantest` plus blind screenshot reviews. Known open points: the swimming wake still shows a
bright contact glow / no clear V (blind review: ACCEPTABLE leaning BAD), the floating-idle displacement cue is weak (ACCEPTABLE), boots look
detached under water because the character's parts float by design. Everything else in sections 3-6 is in the code.
(Original text follows.) Nothing below was changed after the implementation. Written after testing the current game (`--oceantest`, src/debug/ocean_test.gd)
and a small amount of research. Every number below is a starting value to be tuned against screenshots, not a final truth.

## 1. What the tests showed (current game)

| # | Observation (from the logs and frames) | Where it comes from |
|---|---|---|
| T1 | Idle at the surface the character lies FACE DOWN (lean 1.1 rad) with the head, torso and boots mostly under the water: from the side only a thin sliver and the tool show above the water (frame S1). | player_character.gd `_animate_body`: `lean += 1.1 * _swim` |
| T2 | The swim stroke keeps cycling at idle (`_swim_t += delta * (4 + speed*1.2) * _swim`), so a still swimmer paddles at full rate. | player_character.gd |
| T3 | Floating at the surface the body bobs 0.1-0.4 m on a flat water plane; the water does not react at all (no ring, no foam at the waterline, no wake while moving). | frames S1/S2, water_material.gd (waves are normal-only, no input from the player) |
| T4 | W swims along the FLAT heading only: you cannot swim where you look (no up/down by view). The only ways down/up are Ctrl and Space. | ball_player.gd `wish` is flat |
| T5 | Idle UNDER water he rises by himself at 3.4 m/s (buoyancy) until he hits the surface, Ctrl dive is 7.6 m/s, Space up is 9 m/s. Fast and arcade-like; no neutral hover. | ocean test log, ball_player.gd forces |
| T6 | The camera has no water logic: it keeps its 2.6 m lift and orbit distance, so while the swimmer is under water the camera is still ABOVE the surface, looking at him through the opaque surface from above (frame C), until the camera itself dips (main.gd `_under`, hysteresis ±0.1 m). | orbit_camera.gd, main.gd |
| T7 | (already fixed this session) flight state is stale in water, the surface Space pop-out and the swim/air pose flicker at the surface, no cape under water, bubbles for underwater flight. | |

## 2. Research (what similar games do, and how sure I am)

Sources are linked at the end. The search tool returned forum posts, guides and short articles, NOT developer talks, so most of this is
secondary; where I extrapolate I say so.

- **Keep the camera in the water with the swimmer.** A level-design reference advises: while swimming keep the camera under water with the
  player, do not let it pop out unless the player is on the surface, and keep a clear distinction between "in water" and "on land".
  Fits T6 directly.
- **ABZÛ**: the camera follows the diver predictively so the player does not have to move it, and it stays level (does not roll with the
  diver). Steering is in the diver's local space, not pitch-locked like a flight sim. Fits the idea of steering by the view while swimming.
- **Genshin Impact / Tomb Raider / FFXIV**: a separate DIVE input (Ctrl in Genshin, a dive button in Tomb Raider, FFXIV has "swimming" vs
  "diving"), surface swimming is its own state, and early games had a 180-degree flip underwater. Fits "Ctrl = dive" staying, with the surface
  as a distinct state.
- **Crossing the water line (Unity forum / Crest docs)**: switching the underwater look by the camera height alone makes the surface block
  the view at the line; a known fix is to lower the camera slightly while it crosses; Crest adds a thin meniscus line at the intersection and
  blends the look over a short distance. Our UnderwaterEffect already blends over ±0.12 m, so what is missing is the camera side.
- **Water that reacts**: the cheap pattern repeated in several Godot / Three.js sources is a small set of ripple "slots" (position, start time,
  strength) fed to the water shader, each ring fading as exp(-t * decay) (one write-up quotes eight concurrent ripples at 60 fps on a
  mobile-class GPU), OR a top-down ripple texture drawn around the player and sampled by the shader. I could NOT find how Breath of the Wild
  builds its water interaction (no primary source in the results), so I do not claim to copy it; one fan write-up only confirms that
  swimming leaves waves and foam is an expected look.

## 3. States and transitions (swimmer)

States, decided each physics step from `sub` (metres of water above the body centre) and the keys:

| State | Entered when | Left when |
|---|---|---|
| AIR | sub < -0.5 | sub > -0.3 (falling in) |
| SURFACE | -0.3 <= sub < 1.0 and Ctrl not held | Ctrl held, or sub >= 1.2 (hysteresis 0.2) |
| DIVE | Ctrl held at the surface, or sub >= 1.2 | sub < 0.6 and no Ctrl and the swimmer is rising |
| DEEP | sub >= 2.5 | sub < 2.0 |

`ball.swimming` (already added, hysteresis 0.3 / 0.1) stays the master "in water" flag; the new state is an enum `SwimState` kept in the ball
and READ by the character, the camera and the fx.

### Controls while in water (separate from ground and air-flight, as already agreed)
- **SURFACE**: W/A/S/D move flat (as now), speed 2.2 m/s walk-swim, 3.6 m/s with Shift. No auto-dive when looking down.
- **Ctrl (hold)**: dive. Vertical speed eases up to 3.5 m/s over 0.5 s (T5 says 7.6 is too fast), the body pitches head-first.
- **DIVE / DEEP**: W moves along the VIEW direction in 3D (like flight): the mouse steers up/down exactly as for flight (aim cursor against
  the top / bottom of the dashed circle changes `swim_pitch`), Space nudges up, Ctrl nudges down, A/D strafe level. Shift = fast swim 1.7x.
- **Buoyancy** (T5): neutral underwater (drift up at only 0.4 m/s when idle), so he can hold a depth. Near the surface (sub < 1.5) a gentle lift
  brings him to floating level. Space at the surface keeps the cap from the previous fix (no pop-out).
- Leaving by swimming up and out: pushing against the surface with W while pitched up and Space held > 0.3 s = a small hop onto a ledge is NOT in
  scope; getting out of the sea means reaching a shore (walk out when `sub` < 0.2 and the ground is under the feet).
- Flight keeps its own file section (`_fly_step`); swimming gets `_swim_step` the same way (a function per mode, nothing shared but the
  helpers).

## 4. Camera between the states (orbit_camera.gd)

All values smoothed with `1 - exp(-delta * rate)`; the camera reads `ball.swim_state` and `ball.render_pos()`.

| State | Camera lift (m above pivot) | Distance | Pitch | Notes |
|---|---|---|---|---|
| AIR / ground | 2.6 (as now) | player's choice | player's | unchanged |
| SURFACE | 2.6 -> 1.4 (rate 3) | 0.9x | slightly lower (-0.1 rad) | stays ABOVE the water so the waterline reads |
| DIVE | 1.4 -> 0.6 (rate 2.5) | 0.9x | follows `swim_pitch` (like the flight camera: weight `_swim_w`) | the camera enters the water just after the head |
| DEEP | 0.6 | 0.85x | follows `swim_pitch`, level (never rolls) | camera kept at least 0.5 m BELOW the surface while the swimmer is more than 1.5 m deep |
| back up to SURFACE | reverses | | | the camera breaks the surface with the head, never earlier |

Details:
- **Crossing the water line**: while |camera sub| < 0.3, push the camera 0.15 m toward the swimmer's side of the surface (lower when he is under,
  higher when he is above) so the opaque surface never covers the swimmer at the line (the Unity trick). UnderwaterEffect already blends
  over ±0.12 m.
- **Predictive follow** (ABZÛ): add a lead of `velocity * 0.25 s`, clamped to 2.5 m, to the camera's focus point in DIVE / DEEP.
- **Flight into water**: the flight camera weight (`_fly_w`) and the swim weight blend by the same smoothing, so diving from the air into
  the sea does not snap.
- **Never** change `cam.pitch` that the player chose: the swim offsets are added on top and fade out when the state ends.

## 5. Character animation per state (player_character.gd)

Weights: `_swim` (existing), plus `_surf` (surface), `_dive` (head-first dive). Idle gating fixes T2.

| State | Body | Arms | Legs / boots | Rate |
|---|---|---|---|---|
| SURFACE idle ("treading") | UPRIGHT, lean 0.15, head + sprout above the water line, body bobs ±3 cm with the water | slow sculling, hands sweep out and in at the waterline (figure of eight, 1.6 rad/s) | small alternating pedal kicks under the body | 1.2 rad/s |
| SURFACE moving | leans forward 0.7 (head up, chest low), turns into the heading | alternate over-reach strokes | flutter kick | 3 + speed * 1.2 |
| DIVE | jackknife: lean eases to 1.5 then follows `swim_pitch` | both hands together forward | kick in turns, boots stay behind | 4 |
| DEEP idle | floats slightly head-up (lean 0.5), slow sway | arms out, drifting | slow scissor | 1.0 |
| DEEP swimming | prone along `swim_pitch`, streamlined | stroke | flutter | 4 + speed * 1.2 |
| Underwater FLIGHT (done) | prone, hands together, boots kicking | | | |

- The stroke phase advances only with `rate * amplitude`, where amplitude = idle (0.35) + 0.65 * smoothstep(0.2, 2.0, speed): a still swimmer
  barely moves.
- The tool stays in the right hand in every swim state (hand follows the grip as on the ground); today it does not in the swim pose (the arm
  override ignores the grip), which the underwater review flagged as "detached".
- The waterline hides the part of the body below it: the opaque surface already does that from above; from the side the surface must be
  slightly transparent near the body (see 6c) so the body does not look cut.

## 6. Water that reacts to the player (water_material.gd, new water_ripples.gd)

### 6a. Ripple slots (core, cheap)
- New `WaterRipples` (RefCounted, in src/water/): a ring buffer of 8 slots `{pos: Vector3 (world), t0: float, strength: float, kind}`.
  API: `add(pos, strength, kind)`, `upload(material, time)` (writes uniform arrays `rip_pos[8]` (vec4: xyz + strength), `rip_t0[8]`).
  Outside code may only call `WaterSystem.add_ripple(pos, strength)` (keeps the module boundary of docs/WATER_PLAN.md).
- Shader: for each slot add to the wave gradient `g` a radial term
  `ring = sin((r - c * age) * k) * exp(-age * 1.6) * exp(-r * 0.35) * strength`, c = 1.8 m/s, k = 5.0, gradient along (p - slot). Slots
  with `age > 3.5 s` or t0 < 0 are skipped (the "-100" trick from the research). The loop is a fixed 8-iteration loop (documented exception to
  the "no loops" line in the shader header).
- Emitters (PlayerCharacter / BallPlayer, via fx):
  - **Entry splash** (falling or flying in): strength 1.0 + speed/15 (clamped 2.5), plus the existing droplets.
  - **Exit**: strength 0.6.
  - **Wake**: while at the surface and speed > 0.5, every 0.14 s two slots 0.3 m left and right of the body, strength 0.35 + speed * 0.08, which
    makes a V behind him.
  - **Idle bob**: every 1.3 s one slot at the body, strength 0.18 (a floating swimmer is never perfectly still).
  - **Underwater swimming near the surface** (sub < 1.5): a weak slot above him every 0.25 s.
  - **Flying low over the water** (|sub| < 1.5): the foam trail already added gets a ripple slot every 0.1 s.

### 6b. Foam
- The ripple term also drives a foam mask near the centre of each slot for the first 0.5 s (`foam += smoothstep(...) * strength`), so a splash
  leaves a white ring that thins out, instead of only droplets.

### 6c. Contact ring at the waterline
- One flat ring mesh (unshaded, alpha) at the surface plane under the swimmer, scale = body radius * 1.05, alpha by how still he is; it
  makes the body look like it displaces the water rather than sitting behind a sheet. A second, softer outer ring pulses with the idle bob.

### 6d. Better water movement in general (user request)
Current: four fixed-direction normal-only wave trains (water_material.gd), no wind direction (listed in WATER_PLAN known gaps), a flat mesh,
so a swimmer bobbing 0.1-0.4 m moves against a plane that never moves.
- **Phase W-a (shader only, safe)**: a slow wind direction (angle drifts with `WaterState`), waves travel along it, a second layer of small
  cross ripples, foam streaks aligned with the wind in higher states. Normal-only, no physics change.
- **Phase W-b (physics-consistent swell)**: vertical vertex displacement of 0.05 to 0.25 m (scaled by agitation) from the same cosine sum evaluated
  on the CPU in `WaterSystem.submersion()`, so the swimmer's buoyancy and the camera follow the visible surface. Needs first checking the mesh
  resolution in water_mesher.gd: if a water quad is larger than about 2 m the displacement will look faceted; then it only applies in a ring
  around the player where the mesh can be refined, or W-b is dropped. Decision after reading the mesher, before any code.

## 7. Implementation order, with a test and a blind review per step

1. **Swim idle + stroke gating + tool in hand** (5): character only. Test: ocean test idle frames from the side and the back at a close
   camera (extend `--oceantest` with `dist=3`).
2. **SwimState + `_swim_step` + controls** (3): ball only. Test numbers: dive speed, hold depth, neutral drift, surface hold, W along pitch.
3. **Camera states** (4). Test: scripted dive and surfacing, log the camera's height above the surface frame by frame (must never show the
   swimmer through the opaque surface at the line), screenshots at -1, 0, +1 m crossings.
4. **Ripples 6a/6b/6c** + emitters. Test: frames 0.2 s, 0.6 s, 1.2 s after an entry; wake while swimming; idle bob.
5. **Wind and swell W-a, then W-b if the mesher allows** (6d).
6. Each step: parse check, `--oceantest` log, screenshots, and the frames go to a fresh reviewer with no context (as agreed); a step
   counts as passed only if the reviewer passes it, otherwise it is reported as failed.

## 8. Open questions for the user (defaults in brackets)
1. Steering underwater: use the mouse-at-the-circle pitch steering like flight [yes], or W/Space/Ctrl only?
2. Idle underwater: neutral hover with a slow drift up [yes], or sink slowly, or rise to the surface as today?
3. Dive input: hold Ctrl [yes], or a tap that dives to a fixed depth?
4. Swell (W-b): worth the extra complexity if the mesher is coarse [decide after reading the mesher]?
5. Should swimming get the same "no cape / own animation" separation from flying that exists now [yes, as planned]?

## Sources
- Camera and level-design advice (keep the camera under water with the swimmer): https://subscription.packtpub.com/book/game-development/9781118877166/16/ch16lvl1sec56/special-case-cameras
- ABZÛ swimming controls prototype (predictive camera, level camera): https://jpoff.itch.io/abzu-swimming-controls
- ABZÛ fluid motion: https://giantsquidstudios.com/Fluid-Motion-in-ABZU
- Genshin Impact diving (Ctrl to dive): https://primagames.com/gaming/how-to-swim-underwater-in-genshin-impact
- FFXIV swimming and diving: https://ffxiv.consolegameswiki.com/wiki/Swimming_and_Diving
- Tomb Raider dive: https://tombraiderwiki.org/index.php/Dive
- Crossing the water line (Unity forum): https://discussions.unity.com/t/smooth-underwater-transition/432569
- Crest seamless above/below water transition: https://crest.readthedocs.io/en/4.14/user/underwater.html
- Ripple slots with exponential decay in a Godot shader: https://lostrabbitdigital.pages.dev/blog/bikiniheaven-water-ripple-shaders-godot.html
- Screen-space ripples driven by world-space player movement: https://discourse.threejs.org/t/screen-space-water-ripples-with-world-space-player-movement-in-three-js/87814
- Godot dynamic water with object interaction: https://github.com/CaptainProton42/DynamicWaterDemo
