class_name ChunkSampler
extends RefCounted
## Reading a chunk's padded arrays at a local position (the chunk's own data, no world lookups, safe on a worker thread).

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED

## Index of the sample nearest to a local position (positions are clamped into the padded block).
static func index_at(lp: Vector3) -> int:
	var x := clampi(roundi(lp.x), -1, S)
	var y := clampi(roundi(lp.y), -1, S)
	var z := clampi(roundi(lp.z), -1, S)
	return (x + 1) + P * ((y + 1) + P * (z + 1))

## Trilinear density at a local position (positive = solid).
static func density(dens: PackedFloat32Array, lp: Vector3) -> float:
	var x := clampf(lp.x, -0.999, S - 0.001)
	var y := clampf(lp.y, -0.999, S - 0.001)
	var z := clampf(lp.z, -0.999, S - 0.001)
	var ix := floori(x)
	var iy := floori(y)
	var iz := floori(z)
	var fx := x - ix
	var fy := y - iy
	var fz := z - iz
	var b := (ix + 1) + P * ((iy + 1) + P * (iz + 1))
	return lerpf(lerpf(lerpf(dens[b], dens[b + 1], fx), lerpf(dens[b + P], dens[b + P + 1], fx), fy),
		lerpf(lerpf(dens[b + P * P], dens[b + P * P + 1], fx), lerpf(dens[b + P * P + P], dens[b + P * P + P + 1], fx), fy), fz)

## Height (metres above sea level) from the chunk's height lattice (4 m nodes, see PlanetGenerator) at a WORLD position.
static func lattice_height(hlat: PackedFloat32Array, l0: Vector3i, wp: Vector3) -> float:
	const LAT := 4
	const LN := 7
	var fx := clampf(wp.x / LAT - l0.x, 0.0, LN - 1.001)
	var fy := clampf(wp.y / LAT - l0.y, 0.0, LN - 1.001)
	var fz := clampf(wp.z / LAT - l0.z, 0.0, LN - 1.001)
	var ix := floori(fx)
	var iy := floori(fy)
	var iz := floori(fz)
	var tx := fx - ix
	var ty := fy - iy
	var tz := fz - iz
	var b := ix + LN * (iy + LN * iz)
	var ll := LN * LN
	var c00 := lerpf(hlat[b], hlat[b + 1], tx)
	var c10 := lerpf(hlat[b + LN], hlat[b + LN + 1], tx)
	var c01 := lerpf(hlat[b + ll], hlat[b + ll + 1], tx)
	var c11 := lerpf(hlat[b + ll + LN], hlat[b + ll + LN + 1], tx)
	return lerpf(lerpf(c00, c10, ty), lerpf(c01, c11, ty), tz)
