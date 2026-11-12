class_name RockInst
extends RefCounted
## One rock lying in the world. Made by RockPlacer (deterministic), baked into the chunk's rock mesh by RockMesher.

var id := 0                          # stable 63-bit id: the same rock has the same id in every session (broken ones are stored by it)
var pos := Vector3.ZERO              # world position of the rock's centre
var normal := Vector3.UP             # the ground's up here
var size := 1.0                      # radius in metres
var yaw := 0.0
var shape := 0                       # seed of the lumpy outline
var layers: Array = []               # [[type id, outer radius fraction], ...] from the outside in
var hits := 0.0                      # damage taken (breaking works layer by layer)
var wear := 0.0                      # 0..1: how far the OUTER layer is from breaking (hits / hits needed); more core shows as it grows
var bites: Array = []                # bites taken: Vector4(x, y, z, radius), centre in the rock's own frame (metres from its centre)
var fixed := false                   # partly sunk into the floor (it bends the floor): never falls. Otherwise it is a loose rigid body.
var moved := false                   # it has been displaced (fell): its place is stored with the player's changes
var deposit := false                 # a buried body: a smooth ellipsoid in its own pocket of exactly its shape

## Amplitude of the lumpy outline: buried bodies are smooth ellipsoids (their pocket is a plain analytic shape, cheap to carve).
func lump_amplitude() -> float:
	if deposit:
		return 0.0
	return 0.20 + 0.18 * RockMesher._u(shape, 4)

## Everything needed to bring the rock back later (persistence of what the player changed).
func to_state() -> Dictionary:
	return {"id": id, "pos": pos, "normal": normal, "size": size, "yaw": yaw, "shape": shape, "layers": layers.duplicate(true),
		"hits": hits, "wear": wear, "bites": bites.duplicate(), "fixed": fixed, "deposit": deposit, "moved": moved}

static func from_state(d: Dictionary) -> RockInst:
	var r := RockInst.new()
	r.id = d.id
	r.pos = d.pos
	r.normal = d.normal
	r.size = d.size
	r.yaw = d.yaw
	r.shape = d.shape
	r.layers = d.layers
	r.hits = d.hits
	r.wear = d.wear
	r.bites = d.bites
	r.fixed = d.fixed
	r.deposit = d.deposit
	r.moved = d.moved
	return r

func outer_type() -> int:
	return layers[0][0]

func core_type() -> int:
	return layers[layers.size() - 1][0]

## Hits needed to break the whole rock: bigger = more (area-like growth), every layer counts by its volume share.
func total_hardness(catalog: RockCatalog) -> float:
	var h := 0.0
	var inner := 0.0
	for i in range(layers.size() - 1, -1, -1):
		var frac: float = layers[i][1]
		var t := catalog.by_id(layers[i][0])
		h += t.hardness * (pow(frac, 3.0) - inner)
		inner = pow(frac, 3.0)
	return maxf(h, 0.2) * pow(size, 1.5) * 2.0 + 1.0
