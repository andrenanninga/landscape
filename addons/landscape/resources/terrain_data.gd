@tool
class_name TerrainData
extends Resource

signal data_changed

# Corner indices
enum Corner { NW = 0, NE = 1, SE = 2, SW = 3 }

# Surface types for tile painting
enum Surface { TOP = 0, NORTH = 1, EAST = 2, SOUTH = 3, WEST = 4 }

# Tile rotation values
enum Rotation { ROT_0 = 0, ROT_90 = 1, ROT_180 = 2, ROT_270 = 3 }

# Grid configuration
var _skip_resize: bool = false
var _batch_mode: bool = false
var _batch_changed: bool = false

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
# Each cell has: 4 top corners + 4 floor corners + 5 tile values = 13 ints
# Layout: [top_nw, top_ne, top_se, top_sw, floor_nw, floor_ne, floor_se, floor_sw,
#          tile_top, tile_north, tile_east, tile_south, tile_west]
# Each tile value is packed: bits 0-7 = tile index, bits 8-9 = rotation, bit 10 = flip_h, bit 11 = flip_v
# Total size: grid_width * grid_depth * 13
@export var cells: PackedInt32Array = PackedInt32Array()

const CELL_DATA_SIZE := 13
const TOP_OFFSET := 0
const FLOOR_OFFSET := 4
const TILE_OFFSET := 8  # Start of tile data (5 surfaces: top, north, east, south, west)

# Bit packing constants for tile values
const TILE_INDEX_MASK := 0xFFFF      # Bits 0-15: tile index (0-65535)
const TILE_ROTATION_MASK := 0x30000  # Bits 16-17: rotation (0-3)
const TILE_ROTATION_SHIFT := 16
const TILE_FLIP_H_BIT := 0x40000     # Bit 18: flip horizontal
const TILE_FLIP_V_BIT := 0x80000     # Bit 19: flip vertical
const DIAGONAL_FLIP_BIT := 0x100000  # Bit 20: flip diagonal (stored in top tile only)


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
		if _batch_mode:
			_batch_changed = true
		else:
			data_changed.emit()


func begin_batch() -> void:
	_batch_mode = true
	_batch_changed = false


func end_batch() -> void:
	_batch_mode = false
	if _batch_changed:
		_batch_changed = false
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


# Tile packing/unpacking utilities
static func pack_tile(tile_index: int, rotation: Rotation = Rotation.ROT_0, flip_h: bool = false, flip_v: bool = false) -> int:
	var packed := tile_index & TILE_INDEX_MASK
	packed |= (rotation << TILE_ROTATION_SHIFT)
	if flip_h:
		packed |= TILE_FLIP_H_BIT
	if flip_v:
		packed |= TILE_FLIP_V_BIT
	return packed


static func unpack_tile(packed: int) -> Dictionary:
	return {
		"tile_index": packed & TILE_INDEX_MASK,
		"rotation": (packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT,
		"flip_h": (packed & TILE_FLIP_H_BIT) != 0,
		"flip_v": (packed & TILE_FLIP_V_BIT) != 0,
	}


# Tile accessors - get raw packed value
func get_tile_packed(x: int, z: int, surface: Surface) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + TILE_OFFSET + surface]


func set_tile_packed(x: int, z: int, surface: Surface, packed: int) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + TILE_OFFSET + surface
	if cells[idx] != packed:
		cells[idx] = packed
		data_changed.emit()


# Tile accessors - convenience methods for individual components
func get_tile_index(x: int, z: int, surface: Surface) -> int:
	return get_tile_packed(x, z, surface) & TILE_INDEX_MASK


func get_tile_rotation(x: int, z: int, surface: Surface) -> Rotation:
	var packed := get_tile_packed(x, z, surface)
	return ((packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT) as Rotation


func get_tile_flip_h(x: int, z: int, surface: Surface) -> bool:
	return (get_tile_packed(x, z, surface) & TILE_FLIP_H_BIT) != 0


func get_tile_flip_v(x: int, z: int, surface: Surface) -> bool:
	return (get_tile_packed(x, z, surface) & TILE_FLIP_V_BIT) != 0


func set_tile(x: int, z: int, surface: Surface, tile_index: int, rotation: Rotation = Rotation.ROT_0, flip_h: bool = false, flip_v: bool = false) -> void:
	set_tile_packed(x, z, surface, pack_tile(tile_index, rotation, flip_h, flip_v))


# Diagonal flip accessors (stored in top tile's bit 12)
func get_diagonal_flip(x: int, z: int) -> bool:
	if not is_valid_cell(x, z):
		return false
	return (cells[_cell_index(x, z) + TILE_OFFSET] & DIAGONAL_FLIP_BIT) != 0


func set_diagonal_flip(x: int, z: int, flip: bool) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + TILE_OFFSET
	var old_value := cells[idx]
	var new_value: int
	if flip:
		new_value = old_value | DIAGONAL_FLIP_BIT
	else:
		new_value = old_value & ~DIAGONAL_FLIP_BIT
	if old_value != new_value:
		cells[idx] = new_value
		if _batch_mode:
			_batch_changed = true
		else:
			data_changed.emit()


func toggle_diagonal_flip(x: int, z: int) -> void:
	set_diagonal_flip(x, z, not get_diagonal_flip(x, z))


# Get all 5 tile values for a cell (packed)
func get_all_tiles_packed(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0, 0]
	var idx := _cell_index(x, z) + TILE_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3], cells[idx + 4]]


func set_all_tiles_packed(x: int, z: int, tiles: Array[int]) -> void:
	if not is_valid_cell(x, z) or tiles.size() != 5:
		return
	var idx := _cell_index(x, z) + TILE_OFFSET
	var changed := false
	for i in 5:
		if cells[idx + i] != tiles[i]:
			cells[idx + i] = tiles[i]
			changed = true
	if changed:
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


# Get world-space corner positions for any surface of a cell
# Returns 4 corners in order suitable for drawing a quad (clockwise when viewed from outside)
func get_surface_world_corners(x: int, z: int, surface: Surface) -> Array[Vector3]:
	var base_x := x * cell_size
	var base_z := z * cell_size
	var top := get_top_corners(x, z)
	var floor := get_floor_corners(x, z)

	match surface:
		Surface.TOP:
			return [
				Vector3(base_x, steps_to_world(top[Corner.NW]), base_z),
				Vector3(base_x + cell_size, steps_to_world(top[Corner.NE]), base_z),
				Vector3(base_x + cell_size, steps_to_world(top[Corner.SE]), base_z + cell_size),
				Vector3(base_x, steps_to_world(top[Corner.SW]), base_z + cell_size),
			]
		Surface.NORTH:
			# North wall: along z=0 edge (NW to NE), top to floor
			return [
				Vector3(base_x, steps_to_world(top[Corner.NW]), base_z),
				Vector3(base_x + cell_size, steps_to_world(top[Corner.NE]), base_z),
				Vector3(base_x + cell_size, steps_to_world(floor[Corner.NE]), base_z),
				Vector3(base_x, steps_to_world(floor[Corner.NW]), base_z),
			]
		Surface.SOUTH:
			# South wall: along z=cell_size edge (SW to SE), top to floor
			return [
				Vector3(base_x + cell_size, steps_to_world(top[Corner.SE]), base_z + cell_size),
				Vector3(base_x, steps_to_world(top[Corner.SW]), base_z + cell_size),
				Vector3(base_x, steps_to_world(floor[Corner.SW]), base_z + cell_size),
				Vector3(base_x + cell_size, steps_to_world(floor[Corner.SE]), base_z + cell_size),
			]
		Surface.EAST:
			# East wall: along x=cell_size edge (NE to SE), top to floor
			return [
				Vector3(base_x + cell_size, steps_to_world(top[Corner.NE]), base_z),
				Vector3(base_x + cell_size, steps_to_world(top[Corner.SE]), base_z + cell_size),
				Vector3(base_x + cell_size, steps_to_world(floor[Corner.SE]), base_z + cell_size),
				Vector3(base_x + cell_size, steps_to_world(floor[Corner.NE]), base_z),
			]
		Surface.WEST:
			# West wall: along x=0 edge (NW to SW), top to floor
			return [
				Vector3(base_x, steps_to_world(top[Corner.SW]), base_z + cell_size),
				Vector3(base_x, steps_to_world(top[Corner.NW]), base_z),
				Vector3(base_x, steps_to_world(floor[Corner.NW]), base_z),
				Vector3(base_x, steps_to_world(floor[Corner.SW]), base_z + cell_size),
			]

	# Fallback to top surface
	return get_top_world_corners(x, z)
