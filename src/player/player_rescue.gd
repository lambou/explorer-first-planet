class_name PlayerRescue
extends Node
## A player who is LOST (deep inside solid ground, with no air anywhere near: he fell through the floor, or a save kept such a place) is put back on
## the surface above that spot. It runs a cheap check a few times a second and does nothing else.
##
## Being buried is NOT being lost: a player who filled a pocket round himself, or dug into a hillside, has air within a few metres and can dig out
## (BallPlayer leaves him alone). Only a body with solid ground in every direction, out to AIR_REACH metres, for LOST_AFTER seconds is rescued,
## so a moment of chunks still being built never triggers it.

signal rescued(depth: float)                  # metres below the ground he was

const LOST_AFTER := 1.5                       # seconds lost before the rescue
const CHECK_EVERY := 0.25
const AIR_REACH := 6.0                        # air nearer than this = not lost (he can dig out)
const SOLID := 0.55                           # density at the body's middle that counts as buried (BallPlayer.BURIED)
const FREE := -0.3                            # density that counts as air

var player: BallPlayer
var world: VoxelWorld
var gen: PlanetGenerator
var _lost_t := 0.0
var _cd := 0.0

func _physics_process(delta: float) -> void:
	if player == null or world == null or gen == null or player.freeze:
		_lost_t = 0.0
		return
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = CHECK_EVERY
	if is_lost(world, player.global_position):
		_lost_t += CHECK_EVERY
		if _lost_t >= LOST_AFTER:
			_lost_t = 0.0
			rescue()
	else:
		_lost_t = 0.0

## Move him to the surface above where he is. Returns how deep below the ground he was.
func rescue() -> float:
	var pos := player.global_position
	var spot := surface_spot(world, gen, pos)
	var depth := spot.length() - pos.length()
	player.linear_velocity = Vector3.ZERO
	player.global_position = spot
	rescued.emit(depth)
	return depth

## Solid ground at the middle of the body AND no air within AIR_REACH metres in any of 26 directions (two distances each).
static func is_lost(w: VoxelWorld, pos: Vector3) -> bool:
	var mid := pos + pos.normalized() * BallPlayer.CAPSULE_CENTRE
	if w.density_at(mid) < SOLID:
		return false
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			for z in [-1, 0, 1]:
				if x == 0 and y == 0 and z == 0:
					continue
				var d := Vector3(x, y, z).normalized()
				if w.density_at(mid + d * (AIR_REACH * 0.5)) < FREE or w.density_at(mid + d * AIR_REACH) < FREE:
					return false
	return true

## A place on the surface above `pos` (the same direction from the planet's centre) where a body fits in air: the natural ground height there, +1.5 m,
## raised in 1 m steps where the ground was built up since. Over the sea it is the water's surface.
static func surface_spot(w: VoxelWorld, g: PlanetGenerator, pos: Vector3) -> Vector3:
	var dir := pos.normalized()
	var col := Column.new()
	g.sample_column(dir, col)
	var p := dir * (WorldConfig.PLANET_RADIUS + maxf(col.height, 0.0) + 1.5)
	for i in 80:
		if w.density_at(p) < FREE and w.density_at(p + dir) < FREE and w.density_at(p + dir * 2.0) < FREE:
			break
		p += dir
	return p
