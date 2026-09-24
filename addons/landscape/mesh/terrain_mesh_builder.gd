@tool
class_name TerrainMeshBuilder
extends RefCounted

## Builds the terrain ArrayMesh from TerrainData with SurfaceTool.
##
## Every vertex carries the surface type in its color alpha (see SURFACE_* below, divided
## by SURFACE_TYPE_COUNT - 1) and the vertex tint in RGB. Wall and fence vertices also
## carry the wall's top and bottom Y in UV2 so the shader can align tiles to the wall.

const SURFACE_TOP := 0
const SURFACE_NORTH := 1
const SURFACE_EAST := 2
const SURFACE_SOUTH := 3
const SURFACE_WEST := 4
const SURFACE_FLOOR := 5
const SURFACE_FENCE_NORTH := 6
const SURFACE_FENCE_EAST := 7
const SURFACE_FENCE_SOUTH := 8
const SURFACE_FENCE_WEST := 9
const SURFACE_TYPE_COUNT := 10

var _terrain_data: TerrainData
var _st: SurfaceTool


func build_mesh(terrain_data: TerrainData) -> ArrayMesh:
	_terrain_data = terrain_data
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_st.set_smooth_group(-1)

	for z in terrain_data.grid_depth:
		for x in terrain_data.grid_width:
			_add_cell(x, z)

	_st.generate_normals(false)
	_st.generate_tangents()

	return _st.commit()


func _add_cell(x: int, z: int) -> void:
	var top_corners := _terrain_data.get_top_world_corners(x, z)
	var floor_corners := _terrain_data.get_floor_world_corners(x, z)

	_add_top_face(top_corners, x, z)

	if _has_visible_floor(x, z):
		_add_floor_face(floor_corners, x, z)

	for edge in 4:
		_add_wall(x, z, edge, top_corners, floor_corners)

	for edge in 4:
		if _terrain_data.has_fence(x, z, edge):
			_add_fence(x, z, edge, top_corners)


func _has_visible_floor(x: int, z: int) -> bool:
	var top := _terrain_data.get_top_corners(x, z)
	var floor := _terrain_data.get_floor_corners(x, z)
	for i in 4:
		if top[i] != floor[i]:
			return true
	return false


# Whether the quad is split along the NW-SE diagonal (otherwise NE-SW). Picks the
# diagonal with the smaller height difference to avoid twisted quads, unless overridden.
func _use_nw_se_diagonal(corners: Array[Vector3], x: int, z: int) -> bool:
	var diag1_diff := absf(corners[0].y - corners[2].y)
	var diag2_diff := absf(corners[1].y - corners[3].y)
	var use_nw_se := diag1_diff <= diag2_diff
	if _terrain_data.get_diagonal_flip(x, z):
		use_nw_se = not use_nw_se
	return use_nw_se


func _horizontal_uvs(corners: Array[Vector3]) -> Array[Vector2]:
	var uv_scale := 1.0 / _terrain_data.cell_size
	var uvs: Array[Vector2] = []
	for c in corners:
		uvs.append(Vector2(c.x * uv_scale, c.z * uv_scale))
	return uvs


func _add_top_face(corners: Array[Vector3], x: int, z: int) -> void:
	var uv := _horizontal_uvs(corners)
	var vc: Array[Color] = []
	for i in 4:
		vc.append(_terrain_data.get_top_vertex_color(x, z, i))

	# Corner order: 0=NW, 1=NE, 2=SE, 3=SW
	if _use_nw_se_diagonal(corners, x, z):
		_add_triangle(corners[0], corners[1], corners[2], uv[0], uv[1], uv[2], SURFACE_TOP, vc[0], vc[1], vc[2])
		_add_triangle(corners[0], corners[2], corners[3], uv[0], uv[2], uv[3], SURFACE_TOP, vc[0], vc[2], vc[3])
	else:
		_add_triangle(corners[0], corners[1], corners[3], uv[0], uv[1], uv[3], SURFACE_TOP, vc[0], vc[1], vc[3])
		_add_triangle(corners[1], corners[2], corners[3], uv[1], uv[2], uv[3], SURFACE_TOP, vc[1], vc[2], vc[3])


# Floor faces are seen from below, so the winding is reversed
func _add_floor_face(corners: Array[Vector3], x: int, z: int) -> void:
	var uv := _horizontal_uvs(corners)
	var vc: Array[Color] = []
	for i in 4:
		vc.append(_terrain_data.get_floor_vertex_color(x, z, i))

	if _use_nw_se_diagonal(corners, x, z):
		_add_triangle(corners[0], corners[2], corners[1], uv[0], uv[2], uv[1], SURFACE_FLOOR, vc[0], vc[2], vc[1])
		_add_triangle(corners[0], corners[3], corners[2], uv[0], uv[3], uv[2], SURFACE_FLOOR, vc[0], vc[3], vc[2])
	else:
		_add_triangle(corners[0], corners[3], corners[1], uv[0], uv[3], uv[1], SURFACE_FLOOR, vc[0], vc[3], vc[1])
		_add_triangle(corners[1], corners[3], corners[2], uv[1], uv[3], uv[2], SURFACE_FLOOR, vc[1], vc[3], vc[2])


# Wall on one edge, from this cell's top down to the neighbour's top (or this cell's
# floor, whichever is higher). Outer edges get a wall all the way down to the floor.
func _add_wall(x: int, z: int, edge: int, top: Array[Vector3], floor: Array[Vector3]) -> void:
	var left: int = TerrainData.EDGE_CORNERS[edge][0]
	var right: int = TerrainData.EDGE_CORNERS[edge][1]
	var surface_type := SURFACE_NORTH + edge

	var vc_top_left := _terrain_data.get_wall_vertex_color(x, z, edge, TerrainData.WallVertex.TOP_LEFT)
	var vc_top_right := _terrain_data.get_wall_vertex_color(x, z, edge, TerrainData.WallVertex.TOP_RIGHT)
	var vc_floor_left := _terrain_data.get_wall_vertex_color(x, z, edge, TerrainData.WallVertex.BOTTOM_LEFT)
	var vc_floor_right := _terrain_data.get_wall_vertex_color(x, z, edge, TerrainData.WallVertex.BOTTOM_RIGHT)

	var bottom_left := floor[left]
	var bottom_right := floor[right]

	var neighbor := TerrainData.fence_neighbor(x, z, edge)
	if _terrain_data.is_valid_cell(neighbor.x, neighbor.y):
		var neighbor_top := _terrain_data.get_top_world_corners(neighbor.x, neighbor.y)
		var neighbor_left: Vector3 = neighbor_top[TerrainData.NEIGHBOR_EDGE_CORNERS[edge][0]]
		var neighbor_right: Vector3 = neighbor_top[TerrainData.NEIGHBOR_EDGE_CORNERS[edge][1]]
		bottom_left.y = maxf(bottom_left.y, neighbor_left.y)
		bottom_right.y = maxf(bottom_right.y, neighbor_right.y)

	_add_wall_quad(top[left], top[right], bottom_left, bottom_right, surface_type, vc_top_left, vc_top_right, vc_floor_left, vc_floor_right)


func _add_wall_quad(top1: Vector3, top2: Vector3, bottom1: Vector3, bottom2: Vector3, surface_type: int, vc_top1: Color, vc_top2: Color, vc_bottom1: Color, vc_bottom2: Color) -> void:
	if top1.y <= bottom1.y and top2.y <= bottom2.y:
		return

	var uv_scale := 1.0 / _terrain_data.cell_size
	var uv_top1 := Vector2(0.0, top1.y * uv_scale)
	var uv_top2 := Vector2(1.0, top2.y * uv_scale)
	var uv_bottom1 := Vector2(0.0, bottom1.y * uv_scale)
	var uv_bottom2 := Vector2(1.0, bottom2.y * uv_scale)

	# Per-vertex wall bounds (top Y, bottom Y) interpolate correctly across sloped walls
	var bounds1 := Vector2(top1.y, bottom1.y)
	var bounds2 := Vector2(top2.y, bottom2.y)

	_add_triangle_with_uv2(top1, bottom2, top2, uv_top1, uv_bottom2, uv_top2, bounds1, bounds2, bounds2, surface_type, vc_top1, vc_bottom2, vc_top2)
	_add_triangle_with_uv2(top1, bottom1, bottom2, uv_top1, uv_bottom1, uv_bottom2, bounds1, bounds1, bounds2, surface_type, vc_top1, vc_bottom1, vc_bottom2)


# Fence on one edge: a double-sided quad standing on the higher of the two cells that
# share the edge, so it is never buried by the neighbour.
func _add_fence(x: int, z: int, edge: int, top_corners: Array[Vector3]) -> void:
	var fence_h := _terrain_data.get_fence_heights(x, z, edge)
	var base := _terrain_data.get_fence_base_heights(x, z, edge)
	var left: int = TerrainData.EDGE_CORNERS[edge][0]
	var right: int = TerrainData.EDGE_CORNERS[edge][1]

	var base_left := Vector3(top_corners[left].x, _terrain_data.steps_to_world(base[0]), top_corners[left].z)
	var base_right := Vector3(top_corners[right].x, _terrain_data.steps_to_world(base[1]), top_corners[right].z)
	var top_left := base_left + Vector3(0.0, _terrain_data.steps_to_world(fence_h[0]), 0.0)
	var top_right := base_right + Vector3(0.0, _terrain_data.steps_to_world(fence_h[1]), 0.0)

	var vc_left := _terrain_data.get_top_vertex_color(x, z, left)
	var vc_right := _terrain_data.get_top_vertex_color(x, z, right)

	_add_fence_quad(top_left, top_right, base_right, base_left, SURFACE_FENCE_NORTH + edge, vc_left, vc_right)


func _add_fence_quad(top_left: Vector3, top_right: Vector3, bottom_right: Vector3, bottom_left: Vector3, surface_type: int, vc_left: Color, vc_right: Color) -> void:
	if top_left.y <= bottom_left.y and top_right.y <= bottom_right.y:
		return

	var uv_scale := 1.0 / _terrain_data.cell_size
	var uv_top_left := Vector2(0.0, top_left.y * uv_scale)
	var uv_top_right := Vector2(1.0, top_right.y * uv_scale)
	var uv_bottom_left := Vector2(0.0, bottom_left.y * uv_scale)
	var uv_bottom_right := Vector2(1.0, bottom_right.y * uv_scale)

	var bounds_left := Vector2(top_left.y, bottom_left.y)
	var bounds_right := Vector2(top_right.y, bottom_right.y)

	# Front face (outward from the cell)
	_add_triangle_with_uv2(top_left, bottom_right, top_right, uv_top_left, uv_bottom_right, uv_top_right, bounds_left, bounds_right, bounds_right, surface_type, vc_left, vc_right, vc_right)
	_add_triangle_with_uv2(top_left, bottom_left, bottom_right, uv_top_left, uv_bottom_left, uv_bottom_right, bounds_left, bounds_left, bounds_right, surface_type, vc_left, vc_left, vc_right)

	# Back face (reversed winding)
	_add_triangle_with_uv2(top_left, top_right, bottom_right, uv_top_left, uv_top_right, uv_bottom_right, bounds_left, bounds_right, bounds_right, surface_type, vc_left, vc_right, vc_right)
	_add_triangle_with_uv2(top_left, bottom_right, bottom_left, uv_top_left, uv_bottom_right, uv_bottom_left, bounds_left, bounds_right, bounds_left, surface_type, vc_left, vc_right, vc_left)


func _add_triangle(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2, surface_type: int, vc1: Color, vc2: Color, vc3: Color) -> void:
	_add_triangle_with_uv2(v1, v2, v3, uv1, uv2, uv3, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, surface_type, vc1, vc2, vc3)


func _add_triangle_with_uv2(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2, uv2_1: Vector2, uv2_2: Vector2, uv2_3: Vector2, surface_type: int, vc1: Color, vc2: Color, vc3: Color) -> void:
	var surface_alpha := float(surface_type) / float(SURFACE_TYPE_COUNT - 1)

	_st.set_color(Color(vc1.r, vc1.g, vc1.b, surface_alpha))
	_st.set_uv(uv1)
	_st.set_uv2(uv2_1)
	_st.add_vertex(v1)

	_st.set_color(Color(vc2.r, vc2.g, vc2.b, surface_alpha))
	_st.set_uv(uv2)
	_st.set_uv2(uv2_2)
	_st.add_vertex(v2)

	_st.set_color(Color(vc3.r, vc3.g, vc3.b, surface_alpha))
	_st.set_uv(uv3)
	_st.set_uv2(uv2_3)
	_st.add_vertex(v3)
