class_name TreeInst
extends RefCounted
## One tree. Made by TreePlacer (deterministic), baked into the chunk's tree mesh by TreeMeshes, cut by TreeSystem.

const STANDING := 0
const FALLING := 1          # in the air: drawn by TreePhysics, not by the chunk
const FALLEN := 2           # lying on the ground as a trunk: harvested log by log

var id := 0
var pos := Vector3.ZERO     # the foot of the trunk on the ground
var up := Vector3.UP        # the planet's radial direction there: trees grow straight up
var type_id := 0
var height := 10.0
var trunk_r := 0.3          # radius at the foot
var canopy_r := 3.0
var yaw := 0.0
var shape := 0              # seed of its own shape (lumps, branch angles, lean)
var state := STANDING
# damage while standing: the notch the blows cut into the trunk
var hits := 0.0
var hit_h := 1.0            # height of the notch above the foot
var hit_dir := Vector3.RIGHT  # horizontal direction the notch faces
# once fallen
var axis := Vector3.RIGHT   # from the foot along the lying trunk
var shift := Vector3.ZERO   # where the lying trunk's foot is, relative to `pos` (it moves when the ground under it is dug away)
var length := 8.0           # trunk length when it fell
var remaining := 8.0        # what is left after chopping (cut off from the tip end)
var size := 0.4             # blocker radius for the grass placer (it keeps clear of the trunk)

func to_state() -> Dictionary:
	return {"hits": hits, "hit_h": hit_h, "hit_dir": hit_dir, "state": state, "axis": axis, "length": length, "remaining": remaining, "shift": shift}

func apply_state(d: Dictionary) -> void:
	hits = d.hits
	hit_h = d.hit_h
	hit_dir = d.hit_dir
	state = d.state
	axis = d.axis
	length = d.length
	remaining = d.remaining
	shift = d.get("shift", Vector3.ZERO)
