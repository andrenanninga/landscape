@tool
class_name TerrainData
extends Resource

signal data_changed

# Corner indices
enum Corner { NW = 0, NE = 1, SE = 2, SW = 3 }

# Surface types for tile painting
enum Surface {
	TOP = 0, NORTH = 1, EAST = 2, SOUTH = 3, WEST = 4,
	FENCE_NORTH = 5, FENCE_EAST = 6, FENCE_SOUTH = 7, FENCE_WEST = 8
}

# Tile rotation values
enum Rotation { ROT_0 = 0, ROT_90 = 1, ROT_180 = 2, ROT_270 = 3 }

# Wall alignment modes (how tiles are positioned vertically on walls)
enum WallAlign { WORLD = 0, TOP = 1, BOTTOM = 2 }

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

const CELL_DATA_SIZE := 21  # Was 13, now includes fence data
const TOP_OFFSET := 0
const FLOOR_OFFSET := 4
const TILE_OFFSET := 8  # Start of tile data (5 surfaces: top, north, east, south, west)
const FENCE_HEIGHT_OFFSET := 13  # 4 fence heights (north, east, south, west)
const FENCE_TILE_OFFSET := 17  # 4 fence tiles (north, east, south, west)

# Bit packing constants for tile values
const TILE_INDEX_MASK := 0xFFFF      # Bits 0-15: tile index (0-65535)
const TILE_ROTATION_MASK := 0x30000  # Bits 16-17: rotation (0-3)
const TILE_ROTATION_SHIFT := 16
const TILE_FLIP_H_BIT := 0x40000     # Bit 18: flip horizontal
const TILE_FLIP_V_BIT := 0x80000     # Bit 19: flip vertical
const DIAGONAL_FLIP_BIT := 0x100000  # Bit 20: flip diagonal (stored in top tile only)
const TILE_WALL_ALIGN_MASK := 0x300000   # Bits 20-21: wall alignment mode (for wall tiles)
const TILE_WALL_ALIGN_SHIFT := 20

# Fence height packing constants (single int32 per edge)
# Bits 0-15: Left corner height (0 = no fence at this corner)
# Bits 16-31: Right corner height
const FENCE_HEIGHT_LEFT_MASK := 0xFFFF
const FENCE_HEIGHT_RIGHT_MASK := 0xFFFF0000
const FENCE_HEIGHT_RIGHT_SHIFT := 16


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
		# Note: Fence auto-delete is disabled because fences now use MAX height of both cells,
		# so they're always visible from at least one side. Users can manually delete with shift+click.
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
		if _batch_mode:
			_batch_changed = true
		else:
			data_changed.emit()


# Tile packing/unpacking utilities
static func pack_tile(tile_index: int, rotation: Rotation = Rotation.ROT_0, flip_h: bool = false, flip_v: bool = false, wall_align: WallAlign = WallAlign.WORLD) -> int:
	var packed := tile_index & TILE_INDEX_MASK
	packed |= (rotation << TILE_ROTATION_SHIFT)
	if flip_h:
		packed |= TILE_FLIP_H_BIT
	if flip_v:
		packed |= TILE_FLIP_V_BIT
	packed |= (wall_align << TILE_WALL_ALIGN_SHIFT)
	return packed


static func unpack_tile(packed: int) -> Dictionary:
	return {
		"tile_index": packed & TILE_INDEX_MASK,
		"rotation": (packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT,
		"flip_h": (packed & TILE_FLIP_H_BIT) != 0,
		"flip_v": (packed & TILE_FLIP_V_BIT) != 0,
		"wall_align": (packed & TILE_WALL_ALIGN_MASK) >> TILE_WALL_ALIGN_SHIFT,
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
		if _batch_mode:
			_batch_changed = true
		else:
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

		Surface.FENCE_NORTH, Surface.FENCE_EAST, Surface.FENCE_SOUTH, Surface.FENCE_WEST:
			return get_fence_world_corners(x, z, surface)

	# Fallback to top surface
	return get_top_world_corners(x, z)


# ============================================================================
# FENCE METHODS
# ============================================================================

# Edge index for fence data (0=north, 1=east, 2=south, 3=west)
static func _fence_edge_from_surface(surface: Surface) -> int:
	match surface:
		Surface.FENCE_NORTH: return 0
		Surface.FENCE_EAST: return 1
		Surface.FENCE_SOUTH: return 2
		Surface.FENCE_WEST: return 3
	return -1


# Get fence heights for an edge as [left_height, right_height] in steps
# Corner mapping for each edge:
# NORTH: NW (left), NE (right)
# EAST: NE (left), SE (right)
# SOUTH: SE (left), SW (right)
# WEST: SW (left), NW (right)
func get_fence_heights(x: int, z: int, edge: int) -> Array[int]:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return [0, 0]
	var packed := cells[_cell_index(x, z) + FENCE_HEIGHT_OFFSET + edge]
	var left := packed & FENCE_HEIGHT_LEFT_MASK
	var right := (packed & FENCE_HEIGHT_RIGHT_MASK) >> FENCE_HEIGHT_RIGHT_SHIFT
	return [left, right]


# Set fence heights for an edge
# Also handles auto-delete: when neighbor tile height >= fence top, fence data is removed
# Also clears any conflicting fence on the neighbor cell (prevents overlapping fences)
func set_fence_heights(x: int, z: int, edge: int, left: int, right: int) -> void:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return

	# Clamp heights to valid range (0-65535 due to 16-bit packing)
	left = clampi(left, 0, 65535)
	right = clampi(right, 0, 65535)

	# Clear any conflicting fence on the neighbor (each physical edge should only have one fence)
	if left > 0 or right > 0:
		_clear_neighbor_fence(x, z, edge)

	var packed := (left & FENCE_HEIGHT_LEFT_MASK) | ((right << FENCE_HEIGHT_RIGHT_SHIFT) & FENCE_HEIGHT_RIGHT_MASK)
	var idx := _cell_index(x, z) + FENCE_HEIGHT_OFFSET + edge
	if cells[idx] != packed:
		cells[idx] = packed
		if _batch_mode:
			_batch_changed = true
		else:
			data_changed.emit()


# Clear any fence on the neighbor cell that shares this edge
func _clear_neighbor_fence(x: int, z: int, edge: int) -> void:
	var neighbor_x := x
	var neighbor_z := z
	var neighbor_edge: int

	# Map our edge to the neighbor's opposite edge
	match edge:
		0:  # NORTH -> neighbor to north's SOUTH
			neighbor_z = z - 1
			neighbor_edge = 2
		1:  # EAST -> neighbor to east's WEST
			neighbor_x = x + 1
			neighbor_edge = 3
		2:  # SOUTH -> neighbor to south's NORTH
			neighbor_z = z + 1
			neighbor_edge = 0
		3:  # WEST -> neighbor to west's EAST
			neighbor_x = x - 1
			neighbor_edge = 1

	if not is_valid_cell(neighbor_x, neighbor_z):
		return

	# Check if neighbor has a fence on the shared edge
	var neighbor_idx := _cell_index(neighbor_x, neighbor_z) + FENCE_HEIGHT_OFFSET + neighbor_edge
	if cells[neighbor_idx] != 0:
		# Clear it (don't emit signal here, the main set will handle it)
		cells[neighbor_idx] = 0
		# Also clear the tile data for that fence
		var tile_idx := _cell_index(neighbor_x, neighbor_z) + FENCE_TILE_OFFSET + neighbor_edge
		cells[tile_idx] = 0


# Get fence tile packed value for an edge
func get_fence_tile_packed(x: int, z: int, edge: int) -> int:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return 0
	return cells[_cell_index(x, z) + FENCE_TILE_OFFSET + edge]


# Set fence tile packed value for an edge
func set_fence_tile_packed(x: int, z: int, edge: int, packed: int) -> void:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return
	var idx := _cell_index(x, z) + FENCE_TILE_OFFSET + edge
	if cells[idx] != packed:
		cells[idx] = packed
		if _batch_mode:
			_batch_changed = true
		else:
			data_changed.emit()


# Check if a fence exists on an edge (either corner height > 0)
func has_fence(x: int, z: int, edge: int) -> bool:
	var heights := get_fence_heights(x, z, edge)
	return heights[0] > 0 or heights[1] > 0


# Clear fence data for an edge (set heights to 0)
func clear_fence(x: int, z: int, edge: int) -> void:
	set_fence_heights(x, z, edge, 0, 0)


# Get all fence heights for a cell as [n_left, n_right, e_left, e_right, s_left, s_right, w_left, w_right]
func get_all_fence_heights(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0, 0, 0, 0, 0]
	var result: Array[int] = []
	for edge in 4:
		var heights := get_fence_heights(x, z, edge)
		result.append(heights[0])
		result.append(heights[1])
	return result


# Get all fence tiles for a cell as packed values
func get_all_fence_tiles_packed(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + FENCE_TILE_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


# Get world-space corner positions for a fence surface
# Returns 4 corners in order: top-left, top-right, bottom-right, bottom-left
# (clockwise when viewed from outside the cell)
# Fence base is at the MAX height of both neighboring cells at each corner
func get_fence_world_corners(x: int, z: int, surface: Surface) -> Array[Vector3]:
	var edge := _fence_edge_from_surface(surface)
	if edge < 0 or not is_valid_cell(x, z):
		return [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]

	var base_x := x * cell_size
	var base_z := z * cell_size
	var top := get_top_corners(x, z)
	var fence_h := get_fence_heights(x, z, edge)

	# Get neighbor's top corners for max height calculation
	var neighbor_top: Array[int] = [0, 0, 0, 0]
	var nx := x
	var nz := z
	match edge:
		0: nz = z - 1  # NORTH
		1: nx = x + 1  # EAST
		2: nz = z + 1  # SOUTH
		3: nx = x - 1  # WEST
	if is_valid_cell(nx, nz):
		neighbor_top = get_top_corners(nx, nz)

	# Base heights at each corner - use MAX of both cells
	# Fence extends UPWARD from the highest point at each corner
	match edge:
		0:  # NORTH: NW (left), NE (right) - neighbor's SW, SE
			var base_left := steps_to_world(maxi(top[Corner.NW], neighbor_top[Corner.SW]))
			var base_right := steps_to_world(maxi(top[Corner.NE], neighbor_top[Corner.SE]))
			var top_left := base_left + steps_to_world(fence_h[0])
			var top_right := base_right + steps_to_world(fence_h[1])
			return [
				Vector3(base_x, top_left, base_z),                      # top-left
				Vector3(base_x + cell_size, top_right, base_z),         # top-right
				Vector3(base_x + cell_size, base_right, base_z),        # bottom-right
				Vector3(base_x, base_left, base_z),                     # bottom-left
			]
		1:  # EAST: NE (left), SE (right) - neighbor's NW, SW
			var base_left := steps_to_world(maxi(top[Corner.NE], neighbor_top[Corner.NW]))
			var base_right := steps_to_world(maxi(top[Corner.SE], neighbor_top[Corner.SW]))
			var top_left := base_left + steps_to_world(fence_h[0])
			var top_right := base_right + steps_to_world(fence_h[1])
			return [
				Vector3(base_x + cell_size, top_left, base_z),                      # top-left
				Vector3(base_x + cell_size, top_right, base_z + cell_size),         # top-right
				Vector3(base_x + cell_size, base_right, base_z + cell_size),        # bottom-right
				Vector3(base_x + cell_size, base_left, base_z),                     # bottom-left
			]
		2:  # SOUTH: SE (left), SW (right) - neighbor's NE, NW
			var base_left := steps_to_world(maxi(top[Corner.SE], neighbor_top[Corner.NE]))
			var base_right := steps_to_world(maxi(top[Corner.SW], neighbor_top[Corner.NW]))
			var top_left := base_left + steps_to_world(fence_h[0])
			var top_right := base_right + steps_to_world(fence_h[1])
			return [
				Vector3(base_x + cell_size, top_left, base_z + cell_size),  # top-left
				Vector3(base_x, top_right, base_z + cell_size),             # top-right
				Vector3(base_x, base_right, base_z + cell_size),            # bottom-right
				Vector3(base_x + cell_size, base_left, base_z + cell_size), # bottom-left
			]
		3:  # WEST: SW (left), NW (right) - neighbor's SE, NE
			var base_left := steps_to_world(maxi(top[Corner.SW], neighbor_top[Corner.SE]))
			var base_right := steps_to_world(maxi(top[Corner.NW], neighbor_top[Corner.NE]))
			var top_left := base_left + steps_to_world(fence_h[0])
			var top_right := base_right + steps_to_world(fence_h[1])
			return [
				Vector3(base_x, top_left, base_z + cell_size),  # top-left
				Vector3(base_x, top_right, base_z),             # top-right
				Vector3(base_x, base_right, base_z),            # bottom-right
				Vector3(base_x, base_left, base_z + cell_size), # bottom-left
			]

	return [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]


# Check and clear fences that are obscured by neighbor tile heights
# Called after set_top_corners to maintain auto-delete behavior
func _check_fence_auto_delete(x: int, z: int) -> void:
	var top := get_top_corners(x, z)

	# Check each edge of this cell and potentially the neighbors
	# Edge 0 (NORTH): Check if neighbor to north (z-1) has SE/SW >= our fence top at NW/NE
	# Edge 1 (EAST): Check if neighbor to east (x+1) has NW/SW >= our fence top at NE/SE
	# Edge 2 (SOUTH): Check if neighbor to south (z+1) has NE/NW >= our fence top at SE/SW
	# Edge 3 (WEST): Check if neighbor to west (x-1) has NE/SE >= our fence top at SW/NW

	# Also check our own fences against neighbor's top heights
	_check_fence_edge_auto_delete(x, z, 0, top)  # North edge
	_check_fence_edge_auto_delete(x, z, 1, top)  # East edge
	_check_fence_edge_auto_delete(x, z, 2, top)  # South edge
	_check_fence_edge_auto_delete(x, z, 3, top)  # West edge

	# Check neighbor's fences that share edges with this cell
	if is_valid_cell(x, z - 1):  # North neighbor's south fence
		var neighbor_top := get_top_corners(x, z - 1)
		_check_fence_edge_auto_delete(x, z - 1, 2, neighbor_top)
	if is_valid_cell(x + 1, z):  # East neighbor's west fence
		var neighbor_top := get_top_corners(x + 1, z)
		_check_fence_edge_auto_delete(x + 1, z, 3, neighbor_top)
	if is_valid_cell(x, z + 1):  # South neighbor's north fence
		var neighbor_top := get_top_corners(x, z + 1)
		_check_fence_edge_auto_delete(x, z + 1, 0, neighbor_top)
	if is_valid_cell(x - 1, z):  # West neighbor's east fence
		var neighbor_top := get_top_corners(x - 1, z)
		_check_fence_edge_auto_delete(x - 1, z, 1, neighbor_top)


func _check_fence_edge_auto_delete(x: int, z: int, edge: int, top: Array[int]) -> void:
	var fence_h := get_fence_heights(x, z, edge)
	if fence_h[0] == 0 and fence_h[1] == 0:
		return  # No fence to check

	# Get neighbor cell and which corners to compare
	var neighbor_x := x
	var neighbor_z := z
	var left_corner: int  # Our corner for left side of fence
	var right_corner: int  # Our corner for right side of fence
	var neighbor_left_corner: int  # Neighbor corner that aligns with our left
	var neighbor_right_corner: int  # Neighbor corner that aligns with our right

	match edge:
		0:  # NORTH
			neighbor_z = z - 1
			left_corner = Corner.NW
			right_corner = Corner.NE
			neighbor_left_corner = Corner.SW
			neighbor_right_corner = Corner.SE
		1:  # EAST
			neighbor_x = x + 1
			left_corner = Corner.NE
			right_corner = Corner.SE
			neighbor_left_corner = Corner.NW
			neighbor_right_corner = Corner.SW
		2:  # SOUTH
			neighbor_z = z + 1
			left_corner = Corner.SE
			right_corner = Corner.SW
			neighbor_left_corner = Corner.NE
			neighbor_right_corner = Corner.NW
		3:  # WEST
			neighbor_x = x - 1
			left_corner = Corner.SW
			right_corner = Corner.NW
			neighbor_left_corner = Corner.SE
			neighbor_right_corner = Corner.NE

	if not is_valid_cell(neighbor_x, neighbor_z):
		return  # No neighbor to check against

	var neighbor_top := get_top_corners(neighbor_x, neighbor_z)

	# Fence top heights (in steps)
	var fence_top_left := top[left_corner] + fence_h[0]
	var fence_top_right := top[right_corner] + fence_h[1]

	# Check if neighbor's top >= fence top at each corner
	var clear_left := neighbor_top[neighbor_left_corner] >= fence_top_left
	var clear_right := neighbor_top[neighbor_right_corner] >= fence_top_right

	# If both corners are obscured, clear the fence
	if clear_left and clear_right:
		clear_fence(x, z, edge)
