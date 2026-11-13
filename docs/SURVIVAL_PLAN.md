# Survival foundation: items, inventory, crafting, tools

The explorer gathers what the planet gives (clay and soil from digging, rock by type, wood by species), carries at most
**100 kg**, and crafts what it needs. The first goal is a **torch**, for the dark. Everything here is plain data + rules with
the world and the screen kept apart, so each piece can grow (a storage building, a furnace, more tools) without touching the others.

## Modules (one job each; arrows = "knows about")

| Folder | Class | Job | Knows about |
|---|---|---|---|
| `src/items/` | `ItemDef`, `ItemCatalog` | what an item *is*: name, weight per unit, colour, tags. Registry; bricks are made on demand | nothing |
| `src/inventory/` | `Inventory` | slots + the 100 kg limit; add / remove / merge / swap | items |
| | `Toolbelt` | the tools owned and the one in hand (worn gear: not counted in the 100 kg) | tools |
| | `PlayerKit` | everything the explorer owns, as data (no nodes: testable headless) | the above |
| `src/crafting/` | `Recipe`, `RecipeBook`, `Crafter` | recipes, what can be made from what is carried, the all-or-nothing craft | items, inventory |
| `src/harvest/` | `Harvester`, `GroundYield` | the bridge world → items: a dig, a rock blow, a wood chop become units in the pack | world results, items |
| `src/tools/` | `ToolDef`, `ToolCatalog` | what a tool is (model, icon, action) | nothing |
| | `ToolUser` | what a tool *does* to the world (dig, break, chop, scoop) | world, harvest |
| | `ToolRig` | the tool in the ball's hand: model, swing, flame light; says when the blow lands | tools, kit |
| `src/ui/` | `Hud`, `InventoryBar`, `ToolBar`, `InventoryMenu`, `ToastFeed`, `SlotView`, `ItemIcon`, `UiTheme` | show the kit; the UI's own keys | kit only (never the world) |
| `tools/blender/` | `build_tools.py` | builds the tool models (`assets/tools/*.glb`) and icons (`assets/icons/*.png`) | nothing |

`main.gd` only wires them: aim → `ToolRig.begin_use` → (the blow lands) `struck` → `ToolUser.use` → `Harvester` → `Inventory` → UI.
The world systems (`RockSystem`, `TreeSystem`) no longer keep an inventory: a blow *reports* what it yielded.

## Rules
- **Weight.** Everything carried weighs; the limit is 100 kg. What does not fit is left behind ("too heavy"). Per unit: clay 1.5 kg,
  sand 1.4, gravel 1.6, snow 0.5, water 1.0 (a litre), rock `0.6 + 0.35 x density` (granite 1.5, iron 2.4, gold 7.4), wood `0.6 + 0.4 x hardness`.
  The numbers live in `Harvester`, `ItemCatalog` and `ToolCatalog` (one place each).
- **What digging gives.** The generator's own layering at the depth of the dig: soil (grass/dirt) → **clay**, beach/desert → sand,
  sea floor → gravel/sand, snow → snow, below the soil → the **rock of that region** (granite, limestone ...). Two units per dig.
- **Rocks and wood.** One item per rock type (`rock:granite`, `rock:gold`) and per wood (`wood:Oak wood`), so what you carry
  says what it is. Ores come out of the same blows as before.
- **Bricks = the stored form.** A brick is about 6 kg of one material pressed together: 4 clay, 4 granite, 1 unit of gold ore → a
  *Gold brick*. Clay loses a quarter of its weight drying. Bricks stack and are what a storage building will hold (later).
- **Torch.** `1 wood + 1 coal/sulfur -> 2 torches` (each burns **15 min**), or `3 wood -> 1 torch` (no fuel needed, burns **5 min**).
  Torches live on the tool belt, each piece with its own fuel. **Nothing burns forever:** only the torch in hand burns (the tool slot
  shows a fuel bar and the time left); a planted torch burns on its own; a torch not in hand and not planted does not. The last 45 s the
  flame and its light sink, then it goes out and is gone. Held, the flame is a real light of its own (a few metres, falling off with
  distance, flickering). `[T]` (or `LMB` with the torch in hand) **plants** one where the mouse points, on the ground or a wall (not a
  ceiling): both hands stay on the pickaxe. `[E]` on a planted torch **picks it up**, keeping the fuel it has left. A torch whose ground is
  dug away falls back to the belt. Nothing is attached to the ball. (`Toolbelt` fuel, `PlacedTorches`, `TorchFlame`.)
- **Tools.** Start: pickaxe (dig, break rocks, chop) and bucket (scoop 5 l at a time, holds 10 l; the water is carried and weighs).
  Models are built in Blender and shown in use: the pickaxe winds up and drives its point into the target, the bucket dips into the water.

## Starting the game (`src/boot/`)
The first scene is `Boot`: the **main menu** (`MainMenu`: title, the explorer turning on a little stage, **Start**, a seed field with a Random button,
Quit), then the **loading screen** (`LoadingScreen`: progress bar, what is being built, a tip) while `main.tscn` builds the world, then the game.
`Boot` only decides when the game starts: the game stays `playing = false` (no input, no mouse hold, no HUD) until the ground around the explorer is built
(`VoxelWorld.area_progress` feeds the bar), then `begin_play()` puts the cursor in the middle and the loading screen fades. Launched with the debugging
options (`--pos`, `--shot` ...) the menu and loading screen are skipped; `--menu` keeps them, `--autoclick=SECONDS` presses Start.
**The mouse is a plain mouse look.** While you play, the mouse is held by the game and turns the camera **at once**: move it up and the view follows up,
down and it follows down. The cross in the middle of the screen is where the tool works: it is white on ground in reach, yellow on a rock or a tree, **red out
of reach**. The character **always faces where the camera faces** (no lag) and his **head tips up and down with the camera** (half of its pitch, at most 0.5
rad); `W` walks where the camera faces, `S` back, `A`/`D` sideways, and the gait follows his real movement relative to that. To click on things (the tool
column, buttons) press **Esc** (the mouse is given back; the next click in the window takes it again) or open the inventory with `Tab` / `I`.
**The hold is decided every frame:** it exists only while the game is being played, its window is the active one, no menu is open and Esc was not pressed; the
moment the window loses focus the mouse is an ordinary cursor again. The debugging runs (any `--option=value`) never take the mouse.
The info panel at the top left is **folded** to one line (`[F3]` or a click on it opens it).

## Saving (`src/save/`)
**Everything done in the world is saved automatically.** What is saved is exactly what play changes (`WorldSnapshot`): the terrain edits (digging, filling), the
rocks that were chipped, broken or moved, the trees that were cut or felled, where the explorer stands, what he carries (the pack, the tools with the fuel left
in each torch, the bar slot), the torches he planted, the time of day and of the year, and the play time. The terrain, rocks, trees, grass and water are made
again from the seed, so a save stays small (compressed, one slot).
`Autosave` saves **1.5 s after any action** (a dig, a harvest, a craft, a planted torch, a felled tree: several in a row make one save), **every 30 s** whatever
happens (his position, the burning torch), **when the window loses focus** and **when the game is closed** (written at once). The snapshot is made on the main
thread (the big terrain edits are copied only when they changed) and written on a **worker thread**, so the game never stutters; the file is written to a
temporary name and moved over the old save, so a crash in the middle of a save never destroys the last good one.
The menu offers **Continue** (with when it was saved and the play time) and **New game** (a second click confirms that it replaces the save). Running
`main.tscn` on its own (F6) goes through the menu too. The file is `user://savegame.dat` (on Windows `%APPDATA%/Godot/app_userdata/Explorer Universe/`).
Not saved: a rock or tree in the air at that very moment (it is saved once it lands), debris, the weather of the water. Debugging runs (`--option=value`) never
save, unless `--save=1`; `--savefile=NAME` uses another file, `--continue` loads the save without the menu.
If the game is stopped from the editor's Stop button the close is not announced to it: at most the last 30 s of walking (or 1.5 s after an action) are lost.

## The explorer (the look)
`BallPlayer` is only physics now: an invisible upright **capsule** (0.6 m radius, from the soles to 1.3 m up) that never tips or rolls: it is stood
on the planet's up every physics step and steered by velocity (walk 3.2 m/s, run 6.5 m/s with `Shift`, quick to start and stop, no grip on slopes). `PlayerCharacter` (`src/player/player_character.gd`) is what you see: an original round
mint-green blob with a leaf sprout, brown boots and cream mitts, from Blender (`tools/blender/build_character.py` -> `assets/character/explorer.glb`),
made of **separate floating parts**: body, two boots, two mitts (no legs or arms between them, a visible gap under the body, half what it was; drawn 1.5x the model, the soles on the ground). It follows the ball,
faces where it walks, and animates from what the ball does: idle (breathing, blinking, the sprout sways), **walk** (3.2 m/s), **run** (hold
`Shift`: it accelerates and runs at once, 6.5 m/s: longer strides, lean, arms trailing), **jump** (stretch up with the boots tucked, hang when
falling, squash on landing, paddling in water), **swing** (wind-up lean, hard lean into the blow, faces the target). The right hand holds the
tool and goes wherever the tool goes.
**The boots follow the ground:** every physics step each boot sends a ray down from where it is and takes the height and the slope of what it
finds (smoothed). On a stair or a slope one boot rests on the upper step and the other on the lower one, each tilted to its surface; in the
air they tuck and hang instead. (Debug: `--stairs=1` builds a step under the character.)
**Trees in the way:** `TreeFade` (`src/trees/tree_fade.gd`) tests the trees near the line from the camera to the player as what they are (trunk,
crown, lying log); a blocking tree fades **as a whole**, trunk and crown together, easing in and out (the shader recognises a tree by the id
baked in every vertex of it). Up to 8 trees at once.
**Gait:** the cycle turns with the distance walked, so the boots never slide: a walk is short quick steps, a run longer steps with high knees; the body
bobs up over each planted boot and squashes at each step, sways and twists with the swinging arms (bigger and pumping when running), the sprout bounces.

## Controls
`WASD` walk (`Shift` run, `Space` jump) · mouse: look around · `LMB` use the tool / swing (where the cross points) · `T` plant a torch · `E` pick it up · `Q` next tool (or click it in the bar when the mouse is free) · `1`-`9` inventory bar slot · `Tab` / `I` inventory + crafting · `F3` info panel · `Esc` closes the inventory, or gives the mouse back.
Bar at the bottom centre = first row of the inventory + weight; tools at the top right.

## Adding things
- **A tool:** a row in `ToolCatalog`, a builder in `tools/blender/build_tools.py` (origin at the grip, handle along +Z), an action in
  `ToolUser` / a pose in `ToolRig` if it moves in a new way.
- **A recipe:** a row in `RecipeBook.all()`. Ingredients are an item or a tag (`wood`, `brickable`, `flammable`).
- **A resource:** nothing for rocks/wood (registered on first harvest); a row in `ItemCatalog` for fixed ones.
- Rebuild the models: `blender -b --python tools/blender/build_tools.py`, then open the project once so Godot imports them.

## Not yet (on purpose)
Storage buildings, the water recipient, drinking, refuelling a torch, more than ~8 lit torches in view (the compatibility renderer ignores extra lights), tool durability, night danger, saving the pack.
`Shift`+`LMB` still places stone with the pickaxe (an old debug aid, free stone): it should become "place a brick".
Debug launch options for screenshots: `--give=clay:6,rock:granite:3` `--tool=ID` `--addtool=torch` `--menu=1` `--use=FRAME` `--plant=FRAME` `--pickup=FRAME` (see `main.gd`).

## The camera (`src/player/orbit_camera.gd`)
Made for an open world, not a plain orbit: it pivots on the character's **body** (0.85 m up) and **2.4 m ahead** of him along the way it faces, so he sits in
the lower part of the screen and what he points at is in view (the lead shrinks where the spot ahead is inside a hill). It is **terrain-aware**: every 0.1 s it
reads the slope of the ground 3-9 m ahead in the terrain data and tilts with it (80% of it): facing a hill it drops lower, up to 0.5 rad, and looks up the slope
and over the crest; facing downhill it rises up to 0.3 rad. (A camera held at a fixed angle to the horizon looks down onto a hillside like onto a wall.)
Where its view is blocked it still finds a clear one (raised, swung round, or along a
tunnel), and whole trees in the way fade (`TreeFade`).
