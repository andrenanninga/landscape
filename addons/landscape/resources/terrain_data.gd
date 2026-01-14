@tool
class_name TerrainData
extends Resource

signal data_changed

# Corner indices
enum Corner { NW = 0, NE = 1, SE = 2, SW = 3 }

# Grid configuration
var _skip_resize: bool = false

@export var grid_width: int = 8:
	set(value):
		var old_width := grid_width
		grid_width = maxi(1, value)
		if not _skip_resize:
			_resize_grid(old_width, grid_depth)

@export var grid_depth: int = 8:
	set(value):
		var old_depth := grid_depth
		grid_depth = maxi(1, value)
		if not _skip_resize:
			_resize_grid(grid_width, old_depth)

@export var cell_size: float = 1.0:
	set(value):
		cell_size = maxf(0.1, value)
		data_changed.emit()

@export var height_step: float = 0.25:
	set(value):
		height_step = maxf(0.1, value)
		data_changed.emit()

@export var max_slope_steps: int = 1:
	set(value):
		max_slope_steps = maxi(1, value)

# Cell data storage
# Each cell has: 4 top corners + 4 floor corners + 1 texture index = 9 ints
# Layout: [top_nw, top_ne, top_se, top_sw, floor_nw, floor_ne, floor_se, floor_sw, texture]
# Total size: grid_width * grid_depth * 9
@export var cells: PackedInt32Array = PackedInt32Array()

const CELL_DATA_SIZE := 9
const TOP_OFFSET := 0
const FLOOR_OFFSET := 4
const TEXTURE_OFFSET := 8


func _init() -> void:
	_resize_grid(0, 0)


# Restore full grid state (used for undo/redo)
func restore_grid_state(width: int, depth: int, cell_data: PackedInt32Array) -> void:
	_skip_resize = true
	grid_width = width
	grid_depth = depth
	_skip_resize = false
	cells = cell_data
	data_changed.emit()


func _resize_grid(old_width: int, old_depth: int) -> void:
	var new_size := grid_width * grid_depth * CELL_DATA_SIZE
	if cells.size() == new_size:
		return

	var old_cells := cells.duplicate()
	cells.resize(new_size)
	cells.fill(0)

	# Copy overlapping data from old grid to new grid
	if old_cells.size() > 0 and old_width > 0 and old_depth > 0:
		var copy_width := mini(old_width, grid_width)
		var copy_depth := mini(old_depth, grid_depth)

		for z in copy_depth:
			for x in copy_width:
				var old_idx := (z * old_width + x) * CELL_DATA_SIZE
				var new_idx := (z * grid_width + x) * CELL_DATA_SIZE
				for i in CELL_DATA_SIZE:
					cells[new_idx + i] = old_cells[old_idx + i]

	data_changed.emit()


func _cell_index(x: int, z: int) -> int:
	return (z * grid_width + x) * CELL_DATA_SIZE


func is_valid_cell(x: int, z: int) -> bool:
	return x >= 0 and x < grid_width and z >= 0 and z < grid_depth


# Top corner accessors
func get_top_corner(x: int, z: int, corner: Corner) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + TOP_OFFSET + corner]


func set_top_corner(x: int, z: int, corner: Corner, height: int) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + TOP_OFFSET + corner
	if cells[idx] != height:
		cells[idx] = height
		data_changed.emit()


func get_top_corners(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + TOP_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_top_corners(x: int, z: int, corners: Array[int]) -> void:
	if not is_valid_cell(x, z) or corners.size() != 4:
		return
	var idx := _cell_index(x, z) + TOP_OFFSET
	var changed := false
	for i in 4:
		if cells[idx + i] != corners[i]:
			cells[idx + i] = corners[i]
			changed = true
	if changed:
		data_changed.emit()


# Floor corner accessors
func get_floor_corner(x: int, z: int, corner: Corner) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + FLOOR_OFFSET + corner]


func set_floor_corner(x: int, z: int, corner: Corner, height: int) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + FLOOR_OFFSET + corner
	if cells[idx] != height:
		cells[idx] = height
		data_changed.emit()


func get_floor_corners(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + FLOOR_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_floor_corners(x: int, z: int, corners: Array[int]) -> void:
	if not is_valid_cell(x, z) or corners.size() != 4:
		return
	var idx := _cell_index(x, z) + FLOOR_OFFSET
	var changed := false
	for i in 4:
		if cells[idx + i] != corners[i]:
			cells[idx + i] = corners[i]
			changed = true
	if changed:
		data_changed.emit()


# Texture accessor
func get_texture_index(x: int, z: int) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + TEXTURE_OFFSET]


func set_texture_index(x: int, z: int, texture: int) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + TEXTURE_OFFSET
	if cells[idx] != texture:
		cells[idx] = texture
		data_changed.emit()


# Convert height steps to world units
func steps_to_world(steps: int) -> float:
	return steps * height_step


# Raise/lower all top corners of a cell
func raise_cell(x: int, z: int, delta: int = 1) -> void:
	if not is_valid_cell(x, z):
		return
	var corners := get_top_corners(x, z)
	for i in 4:
		corners[i] += delta
	set_top_corners(x, z, corners)


# Raise/lower all floor corners of a cell
func raise_floor(x: int, z: int, delta: int = 1) -> void:
	if not is_valid_cell(x, z):
		return
	var corners := get_floor_corners(x, z)
	for i in 4:
		corners[i] += delta
	set_floor_corners(x, z, corners)


# Check if slope within a cell is valid (edge-adjacent corners don't differ by more than max_slope_steps)
func is_valid_slope(corners: Array[int]) -> bool:
	# Only check edge-adjacent pairs, not diagonals
	# NW=0, NE=1, SE=2, SW=3
	# Edges: NW-NE, NE-SE, SE-SW, SW-NW
	var edge_pairs := [[0, 1], [1, 2], [2, 3], [3, 0]]
	for pair in edge_pairs:
		if absi(corners[pair[0]] - corners[pair[1]]) > max_slope_steps:
			return false
	return true


# Get world-space corner positions for a cell's top surface
func get_top_world_corners(x: int, z: int) -> Array[Vector3]:
	var base_x := x * cell_size
	var base_z := z * cell_size
	var corners := get_top_corners(x, z)
	return [
		Vector3(base_x, steps_to_world(corners[Corner.NW]), base_z),                      # NW
		Vector3(base_x + cell_size, steps_to_world(corners[Corner.NE]), base_z),          # NE
		Vector3(base_x + cell_size, steps_to_world(corners[Corner.SE]), base_z + cell_size), # SE
		Vector3(base_x, steps_to_world(corners[Corner.SW]), base_z + cell_size),          # SW
	]


# Get world-space corner positions for a cell's floor surface
func get_floor_world_corners(x: int, z: int) -> Array[Vector3]:
	var base_x := x * cell_size
	var base_z := z * cell_size
	var corners := get_floor_corners(x, z)
	return [
		Vector3(base_x, steps_to_world(corners[Corner.NW]), base_z),                      # NW
		Vector3(base_x + cell_size, steps_to_world(corners[Corner.NE]), base_z),          # NE
		Vector3(base_x + cell_size, steps_to_world(corners[Corner.SE]), base_z + cell_size), # SE
		Vector3(base_x, steps_to_world(corners[Corner.SW]), base_z + cell_size),          # SW
	]
