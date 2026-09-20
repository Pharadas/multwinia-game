class_name Heightfield
extends RefCounted

## Fast bilinear height sampling over the main screen's NoiseTexture2D
## heightmap. Mirrors HexTile._sample_height's math and its `r * 4.0 *
## height_scale` scaling exactly, but works on a PackedFloat32Array copy of
## the image's red channel instead of calling Image.get_pixel() per corner
## (4 marshaled Variant calls per sample -> 1 indexed read per corner).
##
## Also owns the vertex-position cache: the same quantized-key trick the
## terrain generator used (string "%d_%d" keys) but with integer keys, so
## neighboring hexes sharing a corner produce bit-identical positions
## without hashing strings millions of times.

var _width: int = 0
var _depth: int = 0
var _samples: PackedFloat32Array = PackedFloat32Array()
var _height_scale: float = 0.0
## Heightmap-to-terrain-space ratio baked into every sample: the image
## coordinate plus the sample height (pre-scale) and the full world Y.
var _sample_width: float = 0.0
var _sample_depth: float = 0.0

## Quantized (u,v) -> precomputed world position Vector3(u*s, y, v*s).
## Grid-quantized keys: image-space coordinates quantized to a 1/1024 grid,
## which for a 512-wide image is exactly the sub-pixel lattice the old
## string cache quantized to (roundi(u * 100) collapsed all real corners of
## a grid this size to ~1 hash per position anyway). Integer keys hash far
## faster than "%d_%d" string keys.
var vertices: Dictionary = {}


## One-time setup from the generated noise image. Call before build().
func initialize(img: Image, height_scale: float) -> void:
	_width = img.get_width()
	_depth = img.get_height()
	_height_scale = height_scale
	_sample_width = float(_width)
	_sample_depth = float(_depth)
	var n := _width * _depth
	_samples.resize(n)
	# Copy the red channel once. get_pixel() marshals a full Color per call;
	# decoding the raw data buffer once is orders of magnitude faster than
	# millions of get_pixel calls during mesh building.
	var data := img.get_data()
	var fmt := img.get_format()
	var nchan := _bytes_per_channel(fmt)
	if nchan == 1:
		# Single-channel format: the byte IS the 0..1 red value.
		for i in n:
			_samples[i] = float(data[i]) / 255.0
	elif nchan == 4:
		# RGBA8 (Godot's default for NoiseTexture2D): every 4th byte.
		for i in n:
			_samples[i] = float(data[i * 4]) / 255.0
	else:
		# Anything else (L8A8, RGB8, float formats...): generic per-pixel
		# fallback, still correct, just not the fast path.
		for i in n:
			_samples[i] = img.get_pixel(i % _width, i / _width).r


## -1 = unsupported for the fast path (falls back to get_pixel per pixel).
static func _bytes_per_channel(fmt: int) -> int:
	# Image.FORMAT_L8 == 0, Image.FORMAT_RGBA8 == 4 in Godot 4.
	if fmt == 0:
		return 1
	if fmt == 4:
		return 4
	return -1


## Quantized (u,v) key shared by Heightfield.get_vertex and the mesh
## builder: image-space coordinates quantized to a 1/1024 grid. For map-
## sized hex grids every real corner lands on its own lattice point, while
## two float paths arriving at the "same" corner collapse to one key - the
## old string cache's guarantee, without hashing strings.
static func vertex_key(u: float, v: float) -> int:
	return (roundi(u * 1024.0) & 0xFFFFF) | (roundi(v * 1024.0) << 20)


## Bilinear height at image-space (u, v) - same contract as
## HexTile._sample_height, including the * 4.0 * height_scale and clamping.
func sample(u: float, v: float) -> float:
	var fx: float = clamp(u + _sample_width * 0.5, 0.0, _sample_width - 1.0)
	var fz: float = clamp(v + _sample_depth * 0.5, 0.0, _sample_depth - 1.0)
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, _width - 1)
	var z1 := mini(z0 + 1, _depth - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var c00 := _samples[z0 * _width + x0]
	var c10 := _samples[z0 * _width + x1]
	var c01 := _samples[z1 * _width + x0]
	var c11 := _samples[z1 * _width + x1]
	var top := lerpf(c00, c10, tx)
	var bottom := lerpf(c01, c11, tx)
	return lerpf(top, bottom, tz) * 4.0 * _height_scale


## Cached world-space position for image-space (u, v): Vector3(u * s, height, v * s).
## `scale` must be the terrain's mesh_scale. Neighboring hexes that compute
## the "same" corner through different float paths get bit-identical
## positions because the key is the quantized lattice point.
func get_vertex(u: float, v: float, scale: float) -> Vector3:
	var key := vertex_key(u, v)
	var cached: Variant = vertices.get(key)
	if cached != null:
		return cached
	var vert := Vector3(u * scale, sample(u, v), v * scale)
	vertices[key] = vert
	return vert
