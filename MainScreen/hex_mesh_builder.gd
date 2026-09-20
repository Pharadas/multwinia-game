class_name HexMeshBuilder
extends RefCounted

## Fast replacement for the per-tile SurfaceTool mesh building in
## hex_tile.gd. Same tessellation (6 wedges x hex_detail^2 triangles per
## hex, barycentric grid), same heights, same vertex cache - but writes
## straight into PackedVector*Arrays with an index buffer instead of making
## ~9 Variant-boxed SurfaceTool calls per triangle, and computes normals
## analytically instead of running generate_normals().
##
## Visual output matches the old path exactly:
## - Winding: the old _add_tri emitted (a, c, b); this emits the same order.
## - Normals: SurfaceTool.generate_normals() gives every vertex the
##   normalized SUM of the unit face normals of all triangles touching its
##   position (all vertices share one smoothing group here). This builder
##   accumulates exactly that - unit face normal per triangle - into one
##   vertex per unique position, then normalizes the sum. Duplicate
##   positions in the old non-indexed mesh received the same accumulated
##   sum via the smooth-group hash, so the shaded result is identical.
## - Tangents are dropped (the hex_sector shader never used them); UVs are
##   now planar image-space coordinates instead of the old (0,0) junk.
##
## Reuse ONE builder (with ONE Heightfield) across the whole grid pass:
## it holds the shared vertex cache that guarantees seam-free tiling.

var heightfield: Heightfield

## Every vertex of this tile gets this sector color (the spawner's choice,
## previously passed down into SurfaceTool.set_color per triangle).
var tile_color := Color.WHITE

## Local origin of the tile currently being built: the tile node sits at
## (center_u, 0, center_v) * scale, and mesh vertices must be relative to it.
var _local_origin := Vector3.ZERO

## Per-tile quantized-position -> vertex index, for indexed geometry.
var _tile_indices: Dictionary = {}


func _init(hf: Heightfield) -> void:
	heightfield = hf


## Builds one hex tile's ArrayMesh in local space
## (origin = the tile node's position). Caller places the node at
## Vector3(center_u, 0, center_v) * scale.
func build(
	center_u: float, center_v: float,
	hex_size: float, hex_detail: int,
	scale: float,
	mat: Material
) -> ArrayMesh:
	if hex_detail < 1:
		hex_detail = 1
	var n := hex_detail
	_local_origin = Vector3(center_u * scale, 0.0, center_v * scale)
	_tile_indices.clear()

	var corner_uv: Array[Vector2] = []
	for i in range(6):
		var angle := deg_to_rad(60.0 * float(i))
		corner_uv.append(Vector2(center_u + hex_size * cos(angle), center_v + hex_size * sin(angle)))

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for w in range(6):
		_build_wedge(corner_uv[w], corner_uv[(w + 1) % 6], center_u, center_v,
				n, scale, verts, norms, colors, uvs, indices)

	# Normalize accumulated normals (matches generate_normals' final pass).
	for i in range(norms.size()):
		var len_sq := norms[i].length_squared()
		if len_sq > 1e-12:
			norms[i] = norms[i] / sqrt(len_sq)
		else:
			norms[i] = Vector3.UP  # degenerate; practically unreachable

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mat != null:
		mesh.surface_set_material(0, mat)
	return mesh


## Tessellates the wedge (hex center -> corner a -> corner b) into
## n^2 small triangles using the same barycentric grid as the old
## _add_wedge, appending unique vertices and indexed triangles.
func _build_wedge(
	a_uv: Vector2, b_uv: Vector2,
	center_u: float, center_v: float,
	n: int, scale: float,
	verts: PackedVector3Array, norms: PackedVector3Array,
	colors: PackedColorArray, uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	# Row i holds n + 1 - i vertex indices, from the (center->a) edge inward.
	var grid: Array = []
	for row_i in range(n + 1):
		var row_points := PackedInt32Array()
		for col_i in range(n + 1 - row_i):
			var w_center := float(n - row_i - col_i) / float(n)
			var w_a := float(row_i) / float(n)
			var w_b := float(col_i) / float(n)
			var pu := center_u * w_center + a_uv.x * w_a + b_uv.x * w_b
			var pv := center_v * w_center + a_uv.y * w_a + b_uv.y * w_b
			row_points.append(_vertex_index(pu, pv, scale, verts, norms, colors, uvs))
		grid.append(row_points)

	for row_i in range(n):
		var this_row: PackedInt32Array = grid[row_i]
		var next_row: PackedInt32Array = grid[row_i + 1]
		for col_i in range(n - row_i):
			_add_tri(this_row[col_i], this_row[col_i + 1], next_row[col_i],
					verts, norms, indices)
			if col_i < n - row_i - 1:
				_add_tri(this_row[col_i + 1], next_row[col_i + 1], next_row[col_i],
						verts, norms, indices)


## Returns the vertex index for image-space (u, v): dedupes via the
## quantized position cache (shared with Heightfield.get_vertex, so
## neighboring tiles' shared corners land on identical vertices).
func _vertex_index(
	u: float, v: float, scale: float,
	verts: PackedVector3Array, norms: PackedVector3Array,
	colors: PackedColorArray, uvs: PackedVector2Array
) -> int:
	var key := Heightfield.vertex_key(u, v)
	var idx: int = _tile_indices.get(key, -1)
	if idx != -1:
		return idx
	var pos := heightfield.get_vertex(u, v, scale)
	idx = verts.size()
	verts.append(pos - _local_origin)
	norms.append(Vector3.ZERO)
	colors.append(tile_color)
	uvs.append(Vector2(u, v))
	_tile_indices[key] = idx
	return idx


## Accumulates one triangle's unit face normal into its three vertices and
## appends the indices with the old path's winding (a, c, b).
func _add_tri(
	ia: int, ib: int, ic: int,
	verts: PackedVector3Array, norms: PackedVector3Array,
	indices: PackedInt32Array
) -> void:
	var fn := (verts[ic] - verts[ia]).cross(verts[ib] - verts[ia])
	var len_sq := fn.length_squared()
	if len_sq > 1e-12:
		fn = fn / sqrt(len_sq)
		norms[ia] += fn
		norms[ib] += fn
		norms[ic] += fn
	indices.append(ia)
	indices.append(ic)
	indices.append(ib)
