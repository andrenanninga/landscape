@tool
class_name TerrainMeshBuilder
extends RefCounted

# Surface type constants for vertex color encoding
const SURFACE_TOP := 0
const SURFACE_NORTH := 1
const SURFACE_EAST := 2
const SURFACE_SOUTH := 3
const SURFACE_WEST := 4
const SURFACE_FLOOR := 5

var _terrain_data: TerrainData
var _st: SurfaceTool


func build_mesh(terrain_data: TerrainData) -> ArrayMesh:
	_terrain_data = terrain_data
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(terrain_data.grid_depth):
		for x in range(terrain_data.grid_width):
			_add_cell(x, z)

	_st.generate_normals(false)
	_st.generate_tangents()

	return _st.commit()


func _add_cell(x: int, z: int) -> void:
	var top_corners := _terrain_data.get_top_world_corners(x, z)
	var floor_corners := _terrain_data.get_floor_world_corners(x, z)

	# Add top face
	_add_top_face(top_corners, x, z)

	# Add floor face (if different from top)
	if _has_visible_floor(x, z):
		_add_floor_face(floor_corners, x, z)

	# Add walls to neighbors
	_add_walls(x, z, top_corners, floor_corners)


func _has_visible_floor(x: int, z: int) -> bool:
	var top := _terrain_data.get_top_corners(x, z)
	var floor := _terrain_data.get_floor_corners(x, z)
	for i in 4:
		if top[i] != floor[i]:
			return true
	return false


func _add_top_face(corners: Array[Vector3], x: int, z: int) -> void:
	var nw := corners[0]
	var ne := corners[1]
	var se := corners[2]
	var sw := corners[3]

	# UVs based on world position for tiling
	var uv_scale := 1.0 / _terrain_data.cell_size
	var uv_nw := Vector2(nw.x * uv_scale, nw.z * uv_scale)
	var uv_ne := Vector2(ne.x * uv_scale, ne.z * uv_scale)
	var uv_se := Vector2(se.x * uv_scale, se.z * uv_scale)
	var uv_sw := Vector2(sw.x * uv_scale, sw.z * uv_scale)

	# Choose diagonal to avoid twisted quads
	var diag1_diff := absf(nw.y - se.y)
	var diag2_diff := absf(ne.y - sw.y)

	# Default: use NW-SE diagonal when differences are equal or smaller
	var use_nw_se_diagonal := diag1_diff <= diag2_diff

	# Apply manual diagonal flip override
	if _terrain_data.get_diagonal_flip(x, z):
		use_nw_se_diagonal = not use_nw_se_diagonal

	if use_nw_se_diagonal:
		# NW-SE diagonal
		_add_triangle(nw, ne, se, uv_nw, uv_ne, uv_se, SURFACE_TOP)
		_add_triangle(nw, se, sw, uv_nw, uv_se, uv_sw, SURFACE_TOP)
	else:
		# NE-SW diagonal
		_add_triangle(nw, ne, sw, uv_nw, uv_ne, uv_sw, SURFACE_TOP)
		_add_triangle(ne, se, sw, uv_ne, uv_se, uv_sw, SURFACE_TOP)


func _add_floor_face(corners: Array[Vector3], x: int, z: int) -> void:
	var nw := corners[0]
	var ne := corners[1]
	var se := corners[2]
	var sw := corners[3]

	# UVs based on world position
	var uv_scale := 1.0 / _terrain_data.cell_size
	var uv_nw := Vector2(nw.x * uv_scale, nw.z * uv_scale)
	var uv_ne := Vector2(ne.x * uv_scale, ne.z * uv_scale)
	var uv_se := Vector2(se.x * uv_scale, se.z * uv_scale)
	var uv_sw := Vector2(sw.x * uv_scale, sw.z * uv_scale)

	# Floor faces are rendered from below - reverse winding order
	var diag1_diff := absf(nw.y - se.y)
	var diag2_diff := absf(ne.y - sw.y)

	var use_nw_se_diagonal := diag1_diff <= diag2_diff
	if _terrain_data.get_diagonal_flip(x, z):
		use_nw_se_diagonal = not use_nw_se_diagonal

	if use_nw_se_diagonal:
		_add_triangle(nw, se, ne, uv_nw, uv_se, uv_ne, SURFACE_FLOOR)
		_add_triangle(nw, sw, se, uv_nw, uv_sw, uv_se, SURFACE_FLOOR)
	else:
		_add_triangle(nw, sw, ne, uv_nw, uv_sw, uv_ne, SURFACE_FLOOR)
		_add_triangle(ne, sw, se, uv_ne, uv_sw, uv_se, SURFACE_FLOOR)


func _add_walls(x: int, z: int, top_corners: Array[Vector3], floor_corners: Array[Vector3]) -> void:
	# Wall directions: North (toward -Z), East (+X), South (+Z), West (-X)

	# North wall (edge between NW and NE)
	_add_wall_north(x, z, top_corners, floor_corners)

	# East wall (edge between NE and SE)
	_add_wall_east(x, z, top_corners, floor_corners)

	# South wall (edge between SE and SW)
	_add_wall_south(x, z, top_corners, floor_corners)

	# West wall (edge between SW and NW)
	_add_wall_west(x, z, top_corners, floor_corners)


func _add_wall_north(x: int, z: int, top: Array[Vector3], floor: Array[Vector3]) -> void:
	var neighbor_z := z - 1
	var top_nw := top[0]
	var top_ne := top[1]
	var floor_nw := floor[0]
	var floor_ne := floor[1]

	if _terrain_data.is_valid_cell(x, neighbor_z):
		# Get neighbor's south edge (their SW and SE corners)
		var neighbor_top := _terrain_data.get_top_world_corners(x, neighbor_z)
		var neighbor_sw := neighbor_top[3]  # Their SW aligns with our NW
		var neighbor_se := neighbor_top[2]  # Their SE aligns with our NE

		# Wall needed if our top is higher than neighbor's top
		_add_wall_quad_if_needed(
			top_nw, top_ne, neighbor_sw, neighbor_se,
			floor_nw, floor_ne, SURFACE_NORTH
		)
	else:
		# Outer edge - wall from top to floor
		_add_wall_quad(top_ne, top_nw, floor_ne, floor_nw, SURFACE_NORTH)


func _add_wall_east(x: int, z: int, top: Array[Vector3], floor: Array[Vector3]) -> void:
	var neighbor_x := x + 1
	var top_ne := top[1]
	var top_se := top[2]
	var floor_ne := floor[1]
	var floor_se := floor[2]

	if _terrain_data.is_valid_cell(neighbor_x, z):
		var neighbor_top := _terrain_data.get_top_world_corners(neighbor_x, z)
		var neighbor_nw := neighbor_top[0]  # Their NW aligns with our NE
		var neighbor_sw := neighbor_top[3]  # Their SW aligns with our SE

		_add_wall_quad_if_needed(
			top_ne, top_se, neighbor_nw, neighbor_sw,
			floor_ne, floor_se, SURFACE_EAST
		)
	else:
		_add_wall_quad(top_se, top_ne, floor_se, floor_ne, SURFACE_EAST)


func _add_wall_south(x: int, z: int, top: Array[Vector3], floor: Array[Vector3]) -> void:
	var neighbor_z := z + 1
	var top_se := top[2]
	var top_sw := top[3]
	var floor_se := floor[2]
	var floor_sw := floor[3]

	if _terrain_data.is_valid_cell(x, neighbor_z):
		var neighbor_top := _terrain_data.get_top_world_corners(x, neighbor_z)
		var neighbor_ne := neighbor_top[1]  # Their NE aligns with our SE
		var neighbor_nw := neighbor_top[0]  # Their NW aligns with our SW

		_add_wall_quad_if_needed(
			top_se, top_sw, neighbor_ne, neighbor_nw,
			floor_se, floor_sw, SURFACE_SOUTH
		)
	else:
		_add_wall_quad(top_sw, top_se, floor_sw, floor_se, SURFACE_SOUTH)


func _add_wall_west(x: int, z: int, top: Array[Vector3], floor: Array[Vector3]) -> void:
	var neighbor_x := x - 1
	var top_sw := top[3]
	var top_nw := top[0]
	var floor_sw := floor[3]
	var floor_nw := floor[0]

	if _terrain_data.is_valid_cell(neighbor_x, z):
		var neighbor_top := _terrain_data.get_top_world_corners(neighbor_x, z)
		var neighbor_se := neighbor_top[2]  # Their SE aligns with our SW
		var neighbor_ne := neighbor_top[1]  # Their NE aligns with our NW

		_add_wall_quad_if_needed(
			top_sw, top_nw, neighbor_se, neighbor_ne,
			floor_sw, floor_nw, SURFACE_WEST
		)
	else:
		_add_wall_quad(top_nw, top_sw, floor_nw, floor_sw, SURFACE_WEST)


func _add_wall_quad_if_needed(
	our_top1: Vector3, our_top2: Vector3,
	neighbor_top1: Vector3, neighbor_top2: Vector3,
	our_floor1: Vector3, our_floor2: Vector3,
	surface_type: int
) -> void:
	# Generate wall segments where our top is higher than neighbor's top
	# This creates stepped walls for height differences

	var wall_bottom1 := maxf(our_floor1.y, neighbor_top1.y)
	var wall_bottom2 := maxf(our_floor2.y, neighbor_top2.y)

	# Only draw wall if we're higher than the bottom
	if our_top1.y > wall_bottom1 or our_top2.y > wall_bottom2:
		var bottom1 := Vector3(our_top1.x, wall_bottom1, our_top1.z)
		var bottom2 := Vector3(our_top2.x, wall_bottom2, our_top2.z)
		_add_wall_quad(our_top1, our_top2, bottom1, bottom2, surface_type)


func _add_wall_quad(top1: Vector3, top2: Vector3, bottom1: Vector3, bottom2: Vector3, surface_type: int = SURFACE_NORTH) -> void:
	# Skip degenerate walls
	if top1.y <= bottom1.y and top2.y <= bottom2.y:
		return

	# UV mapping for walls - use Y for vertical, and horizontal distance
	var uv_scale := 1.0 / _terrain_data.cell_size
	var uv_top1 := Vector2(0.0, top1.y * uv_scale)
	var uv_top2 := Vector2(1.0, top2.y * uv_scale)
	var uv_bottom1 := Vector2(0.0, bottom1.y * uv_scale)
	var uv_bottom2 := Vector2(1.0, bottom2.y * uv_scale)

	# Store per-vertex wall bounds in UV2 for wall alignment shader calculations
	# UV2.x = wall top Y at this vertex's horizontal position
	# UV2.y = wall bottom Y at this vertex's horizontal position
	# This allows proper interpolation across sloped walls
	var bounds1 := Vector2(top1.y, bottom1.y)  # Left edge bounds
	var bounds2 := Vector2(top2.y, bottom2.y)  # Right edge bounds

	# Two triangles for quad - reversed winding for outward facing
	# Triangle 1: top1, bottom2, top2
	_add_triangle_with_uv2(top1, bottom2, top2, uv_top1, uv_bottom2, uv_top2, bounds1, bounds2, bounds2, surface_type)
	# Triangle 2: top1, bottom1, bottom2
	_add_triangle_with_uv2(top1, bottom1, bottom2, uv_top1, uv_bottom1, uv_bottom2, bounds1, bounds1, bounds2, surface_type)


func _add_triangle_with_uv2(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2, uv2_1: Vector2, uv2_2: Vector2, uv2_3: Vector2, surface_type: int) -> void:
	# Encode surface type in vertex color (R channel: 0-5 normalized to 0-1)
	var surface_color := Color(float(surface_type) / 5.0, 0.0, 0.0, 1.0)
	_st.set_color(surface_color)
	_st.set_uv(uv1)
	_st.set_uv2(uv2_1)
	_st.add_vertex(v1)
	_st.set_color(surface_color)
	_st.set_uv(uv2)
	_st.set_uv2(uv2_2)
	_st.add_vertex(v2)
	_st.set_color(surface_color)
	_st.set_uv(uv3)
	_st.set_uv2(uv2_3)
	_st.add_vertex(v3)


func _add_triangle(v1: Vector3, v2: Vector3, v3: Vector3, uv1: Vector2, uv2: Vector2, uv3: Vector2, surface_type: int = SURFACE_TOP, uv2_data: Vector2 = Vector2.ZERO) -> void:
	# Encode surface type in vertex color (R channel: 0-5 normalized to 0-1)
	var surface_color := Color(float(surface_type) / 5.0, 0.0, 0.0, 1.0)
	_st.set_color(surface_color)
	_st.set_uv(uv1)
	_st.set_uv2(uv2_data)
	_st.add_vertex(v1)
	_st.set_color(surface_color)
	_st.set_uv(uv2)
	_st.set_uv2(uv2_data)
	_st.add_vertex(v2)
	_st.set_color(surface_color)
	_st.set_uv(uv3)
	_st.set_uv2(uv2_data)
	_st.add_vertex(v3)
