@tool
class_name TerrainData
extends Resource

signal data_changed

# Corner indices. Parameters take plain ints because a `Corner`-typed parameter collides with
# Godot's global Corner enum when called from other scripts.
enum Corner { NW = 0, NE = 1, SE = 2, SW = 3 }

enum Surface {
	TOP = 0, NORTH = 1, EAST = 2, SOUTH = 3, WEST = 4,
	FENCE_NORTH = 5, FENCE_EAST = 6, FENCE_SOUTH = 7, FENCE_WEST = 8
}

enum Rotation { ROT_0 = 0, ROT_90 = 1, ROT_180 = 2, ROT_270 = 3 }

# How tiles are positioned vertically on walls and fences
enum WallAlign { WORLD = 0, TOP = 1, BOTTOM = 2, STRETCH = 3 }

# Edge indices used for walls and fences
enum Edge { NORTH = 0, EAST = 1, SOUTH = 2, WEST = 3 }

# Wall vertices as seen from outside the cell, in the order of get_surface_world_corners
enum WallVertex { TOP_LEFT = 0, TOP_RIGHT = 1, BOTTOM_RIGHT = 2, BOTTOM_LEFT = 3 }

# Per edge: [left corner, right corner] as seen from outside the cell, and the
# corners of the neighbouring cell that coincide with them.
const EDGE_CORNERS := [
	[Corner.NW, Corner.NE],
	[Corner.NE, Corner.SE],
	[Corner.SE, Corner.SW],
	[Corner.SW, Corner.NW],
]
const NEIGHBOR_EDGE_CORNERS := [
	[Corner.SW, Corner.SE],
	[Corner.NW, Corner.SW],
	[Corner.NE, Corner.NW],
	[Corner.SE, Corner.NE],
]
const EDGE_NEIGHBOR_OFFSET := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

# Cell layout, CELL_DATA_SIZE ints per cell:
#   0-3    top corner heights in steps (NW, NE, SE, SW)
#   4-7    floor corner heights in steps
#   8-12   packed tiles for TOP, NORTH, EAST, SOUTH, WEST (see TilePacking)
#   13-16  packed fence heights per edge (bits 0-15 left corner, bits 16-31 right corner)
#   17-20  packed fence tiles per edge
#   21-24  top vertex colors (RGBA32)
#   25-28  floor vertex colors (RGBA32)
#   29-44  wall vertex colors (RGBA32), 4 per edge N, E, S, W in WallVertex order
const CELL_DATA_SIZE := 45
const TOP_OFFSET := 0
const FLOOR_OFFSET := 4
const TILE_OFFSET := 8
const FENCE_HEIGHT_OFFSET := 13
const FENCE_TILE_OFFSET := 17
const TOP_VERTEX_COLOR_OFFSET := 21
const FLOOR_VERTEX_COLOR_OFFSET := 25
const WALL_VERTEX_COLOR_OFFSET := 29
const WALL_VERTEX_COUNT := 4

# Scenes saved before wall vertex colors existed use this many ints per cell
const LEGACY_CELL_DATA_SIZE := 29

# Opaque white as a signed int32, which is how PackedInt32Array stores 0xFFFFFFFF
const DEFAULT_VERTEX_COLOR := -1

# A wall vertex without a colour of its own shows the top or floor corner colour it touches.
# Painted colours are always opaque, so their packed value can never be zero.
const INHERITED_VERTEX_COLOR := 0

const TILE_INDEX_MASK := TilePacking.TILE_INDEX_MASK
const ERASED_TILE_INDEX := 0xFFFF
const TILE_ROTATION_MASK := TilePacking.TILE_ROTATION_MASK
const TILE_ROTATION_SHIFT := TilePacking.TILE_ROTATION_SHIFT
const TILE_FLIP_H_BIT := TilePacking.TILE_FLIP_H_BIT
const TILE_FLIP_V_BIT := TilePacking.TILE_FLIP_V_BIT
const DIAGONAL_FLIP_BIT := TilePacking.DIAGONAL_FLIP_BIT
const TILE_WALL_ALIGN_MASK := TilePacking.TILE_WALL_ALIGN_MASK
const TILE_WALL_ALIGN_SHIFT := TilePacking.TILE_WALL_ALIGN_SHIFT

const FENCE_HEIGHT_LEFT_MASK := 0xFFFF
const FENCE_HEIGHT_RIGHT_MASK := 0xFFFF0000
const FENCE_HEIGHT_RIGHT_SHIFT := 16
const MAX_FENCE_HEIGHT := 0xFFFF

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
		_mark_changed()

@export var height_step: float = 0.25:
	set(value):
		height_step = maxf(0.1, value)
		_mark_changed()

@export var max_slope_steps: int = 1:
	set(value):
		max_slope_steps = maxi(1, value)

@export var cells: PackedInt32Array = PackedInt32Array():
	set(value):
		cells = _upgrade_legacy_cells(value)


func _init() -> void:
	_resize_grid(0, 0)


# ============================================================================
# CHANGE NOTIFICATION
# ============================================================================

# Suppresses data_changed until end_batch() so multi-cell edits rebuild the mesh once
func begin_batch() -> void:
	_batch_mode = true
	_batch_changed = false


func end_batch() -> void:
	_batch_mode = false
	if _batch_changed:
		_batch_changed = false
		data_changed.emit()


func _mark_changed() -> void:
	if _batch_mode:
		_batch_changed = true
	else:
		data_changed.emit()


# PackedInt32Array stores values as signed 32-bit, so anything packed with the high bit
# set must be normalized before comparing against stored data
static func _to_int32(value: int) -> int:
	value &= 0xFFFFFFFF
	if value >= 0x80000000:
		value -= 0x100000000
	return value


func _set_cell_value(idx: int, value: int) -> bool:
	value = _to_int32(value)
	if cells[idx] == value:
		return false
	cells[idx] = value
	return true


func _set_cell_values(idx: int, values: Array[int]) -> bool:
	var changed := false
	for i in values.size():
		if cells[idx + i] != values[i]:
			cells[idx + i] = values[i]
			changed = true
	return changed


# ============================================================================
# GRID SIZE
# ============================================================================

# Restore full grid state (used for undo/redo)
func restore_grid_state(width: int, depth: int, cell_data: PackedInt32Array) -> void:
	_skip_resize = true
	grid_width = width
	grid_depth = depth
	_skip_resize = false
	cells = cell_data
	data_changed.emit()


func _resize_grid(old_width: int, old_depth: int) -> void:
	var unchanged := old_width == grid_width and old_depth == grid_depth
	if unchanged and cells.size() == grid_width * grid_depth * CELL_DATA_SIZE:
		return

	cells = _remap_cells(cells, old_width, old_depth, grid_width, grid_depth, 0, 0)
	data_changed.emit()


# Resize grid with offset, allowing growth/crop from any direction
# offset_x: positive = grow west (shift data east), negative = crop west (shift data west)
# offset_z: positive = grow north (shift data south), negative = crop north (shift data north)
func resize_with_offset(new_width: int, new_depth: int, offset_x: int, offset_z: int) -> void:
	new_width = maxi(1, new_width)
	new_depth = maxi(1, new_depth)

	var remapped := _remap_cells(cells, grid_width, grid_depth, new_width, new_depth, offset_x, offset_z)

	_skip_resize = true
	grid_width = new_width
	grid_depth = new_depth
	_skip_resize = false
	cells = remapped
	data_changed.emit()


# Appends the wall vertex colour slots to cell data saved with the previous layout
func _upgrade_legacy_cells(data: PackedInt32Array) -> PackedInt32Array:
	var cell_count := grid_width * grid_depth
	if data.size() != cell_count * LEGACY_CELL_DATA_SIZE:
		return data

	var out := _blank_cells(grid_width, grid_depth)
	for cell in cell_count:
		var old_idx := cell * LEGACY_CELL_DATA_SIZE
		var new_idx := cell * CELL_DATA_SIZE
		for i in LEGACY_CELL_DATA_SIZE:
			out[new_idx + i] = data[old_idx + i]

	return out


static func _blank_cells(width: int, depth: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(width * depth * CELL_DATA_SIZE)
	out.fill(0)

	for cell in width * depth:
		var idx := cell * CELL_DATA_SIZE
		for i in 4:
			out[idx + TOP_VERTEX_COLOR_OFFSET + i] = DEFAULT_VERTEX_COLOR
			out[idx + FLOOR_VERTEX_COLOR_OFFSET + i] = DEFAULT_VERTEX_COLOR

	return out


# Builds a fresh grid of new dimensions and copies over every old cell that lands inside it
static func _remap_cells(old_cells: PackedInt32Array, old_width: int, old_depth: int, new_width: int, new_depth: int, offset_x: int, offset_z: int) -> PackedInt32Array:
	var out := _blank_cells(new_width, new_depth)
	if old_cells.size() < old_width * old_depth * CELL_DATA_SIZE:
		return out

	for old_z in old_depth:
		var new_z := old_z + offset_z
		if new_z < 0 or new_z >= new_depth:
			continue
		for old_x in old_width:
			var new_x := old_x + offset_x
			if new_x < 0 or new_x >= new_width:
				continue

			var old_idx := (old_z * old_width + old_x) * CELL_DATA_SIZE
			var new_idx := (new_z * new_width + new_x) * CELL_DATA_SIZE
			for i in CELL_DATA_SIZE:
				out[new_idx + i] = old_cells[old_idx + i]

	return out


func _cell_index(x: int, z: int) -> int:
	return (z * grid_width + x) * CELL_DATA_SIZE


func is_valid_cell(x: int, z: int) -> bool:
	return x >= 0 and x < grid_width and z >= 0 and z < grid_depth


# ============================================================================
# HEIGHTS
# ============================================================================

func get_top_corner(x: int, z: int, corner: int) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + TOP_OFFSET + corner]


func set_top_corner(x: int, z: int, corner: int, height: int) -> void:
	if not is_valid_cell(x, z):
		return
	if _set_cell_value(_cell_index(x, z) + TOP_OFFSET + corner, height):
		_mark_changed()


func get_top_corners(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + TOP_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_top_corners(x: int, z: int, corners: Array[int]) -> void:
	if not is_valid_cell(x, z) or corners.size() != 4:
		return
	if _set_cell_values(_cell_index(x, z) + TOP_OFFSET, corners):
		_mark_changed()


func get_floor_corner(x: int, z: int, corner: int) -> int:
	if not is_valid_cell(x, z):
		return 0
	return cells[_cell_index(x, z) + FLOOR_OFFSET + corner]


func set_floor_corner(x: int, z: int, corner: int, height: int) -> void:
	if not is_valid_cell(x, z):
		return
	if _set_cell_value(_cell_index(x, z) + FLOOR_OFFSET + corner, height):
		_mark_changed()


func get_floor_corners(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + FLOOR_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_floor_corners(x: int, z: int, corners: Array[int]) -> void:
	if not is_valid_cell(x, z) or corners.size() != 4:
		return
	if _set_cell_values(_cell_index(x, z) + FLOOR_OFFSET, corners):
		_mark_changed()


# Lowers any floor corner that ended up above its top corner
func clamp_floor_to_top(x: int, z: int) -> void:
	if not is_valid_cell(x, z):
		return

	var top := get_top_corners(x, z)
	var floor := get_floor_corners(x, z)
	for i in 4:
		floor[i] = mini(floor[i], top[i])

	set_floor_corners(x, z, floor)


# Raise/lower all top corners of a cell
func raise_cell(x: int, z: int, delta: int = 1) -> void:
	var corners := get_top_corners(x, z)
	for i in 4:
		corners[i] += delta
	set_top_corners(x, z, corners)


# Raise/lower all floor corners of a cell
func raise_floor(x: int, z: int, delta: int = 1) -> void:
	var corners := get_floor_corners(x, z)
	for i in 4:
		corners[i] += delta
	set_floor_corners(x, z, corners)


# Check that edge-adjacent corners don't differ by more than max_slope_steps (diagonals are free)
func is_valid_slope(corners: Array[int]) -> bool:
	for i in 4:
		if absi(corners[i] - corners[(i + 1) % 4]) > max_slope_steps:
			return false
	return true


func steps_to_world(steps: int) -> float:
	return steps * height_step


# ============================================================================
# VERTEX COLORS
# ============================================================================

static func pack_vertex_color(color: Color) -> int:
	return _to_int32(color.to_rgba32())


static func unpack_vertex_color(packed: int) -> Color:
	return Color.hex(packed & 0xFFFFFFFF)


func get_top_vertex_color(x: int, z: int, corner: int) -> Color:
	if not is_valid_cell(x, z):
		return Color.WHITE
	return unpack_vertex_color(cells[_cell_index(x, z) + TOP_VERTEX_COLOR_OFFSET + corner])


func set_top_vertex_color(x: int, z: int, corner: int, color: Color) -> void:
	if not is_valid_cell(x, z):
		return
	if _set_cell_value(_cell_index(x, z) + TOP_VERTEX_COLOR_OFFSET + corner, pack_vertex_color(color)):
		_mark_changed()


func get_top_vertex_colors(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR]
	var idx := _cell_index(x, z) + TOP_VERTEX_COLOR_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_top_vertex_colors(x: int, z: int, colors: Array[int]) -> void:
	if not is_valid_cell(x, z) or colors.size() != 4:
		return
	if _set_cell_values(_cell_index(x, z) + TOP_VERTEX_COLOR_OFFSET, colors):
		_mark_changed()


func get_floor_vertex_color(x: int, z: int, corner: int) -> Color:
	if not is_valid_cell(x, z):
		return Color.WHITE
	return unpack_vertex_color(cells[_cell_index(x, z) + FLOOR_VERTEX_COLOR_OFFSET + corner])


func set_floor_vertex_color(x: int, z: int, corner: int, color: Color) -> void:
	if not is_valid_cell(x, z):
		return
	if _set_cell_value(_cell_index(x, z) + FLOOR_VERTEX_COLOR_OFFSET + corner, pack_vertex_color(color)):
		_mark_changed()


func get_floor_vertex_colors(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR, DEFAULT_VERTEX_COLOR]
	var idx := _cell_index(x, z) + FLOOR_VERTEX_COLOR_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_floor_vertex_colors(x: int, z: int, colors: Array[int]) -> void:
	if not is_valid_cell(x, z) or colors.size() != 4:
		return
	if _set_cell_values(_cell_index(x, z) + FLOOR_VERTEX_COLOR_OFFSET, colors):
		_mark_changed()


# ============================================================================
# WALL VERTEX COLORS
# ============================================================================

# The cell corner a wall vertex sits on
static func wall_vertex_corner(edge: int, vertex: int) -> int:
	var side := 1 if vertex == WallVertex.TOP_RIGHT or vertex == WallVertex.BOTTOM_RIGHT else 0
	return EDGE_CORNERS[edge][side]


static func is_wall_vertex_top(vertex: int) -> bool:
	return vertex == WallVertex.TOP_LEFT or vertex == WallVertex.TOP_RIGHT


func _wall_color_index(x: int, z: int, edge: int, vertex: int) -> int:
	return _cell_index(x, z) + WALL_VERTEX_COLOR_OFFSET + edge * WALL_VERTEX_COUNT + vertex


func has_wall_vertex_color(x: int, z: int, edge: int, vertex: int) -> bool:
	if not is_valid_cell(x, z):
		return false
	return cells[_wall_color_index(x, z, edge, vertex)] != INHERITED_VERTEX_COLOR


# Falls back to the top or floor corner colour the vertex touches while it is unpainted
func get_wall_vertex_color(x: int, z: int, edge: int, vertex: int) -> Color:
	if not is_valid_cell(x, z):
		return Color.WHITE

	var packed := cells[_wall_color_index(x, z, edge, vertex)]
	if packed != INHERITED_VERTEX_COLOR:
		return unpack_vertex_color(packed)

	var corner := wall_vertex_corner(edge, vertex)
	if is_wall_vertex_top(vertex):
		return get_top_vertex_color(x, z, corner)
	return get_floor_vertex_color(x, z, corner)


func set_wall_vertex_color(x: int, z: int, edge: int, vertex: int, color: Color) -> void:
	if not is_valid_cell(x, z):
		return

	var opaque := Color(color.r, color.g, color.b, 1.0)
	if _set_cell_value(_wall_color_index(x, z, edge, vertex), pack_vertex_color(opaque)):
		_mark_changed()


# Makes the vertex inherit its corner colour again
func clear_wall_vertex_color(x: int, z: int, edge: int, vertex: int) -> void:
	if not is_valid_cell(x, z):
		return
	if _set_cell_value(_wall_color_index(x, z, edge, vertex), INHERITED_VERTEX_COLOR):
		_mark_changed()


func get_wall_vertex_colors(x: int, z: int, edge: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [INHERITED_VERTEX_COLOR, INHERITED_VERTEX_COLOR, INHERITED_VERTEX_COLOR, INHERITED_VERTEX_COLOR]
	var idx := _wall_color_index(x, z, edge, 0)
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


func set_wall_vertex_colors(x: int, z: int, edge: int, colors: Array[int]) -> void:
	if not is_valid_cell(x, z) or colors.size() != WALL_VERTEX_COUNT:
		return
	if _set_cell_values(_wall_color_index(x, z, edge, 0), colors):
		_mark_changed()


# ============================================================================
# TILES
# ============================================================================

static func pack_tile(tile_index: int, rotation: Rotation = Rotation.ROT_0, flip_h: bool = false, flip_v: bool = false, wall_align: WallAlign = WallAlign.WORLD) -> int:
	return TilePacking.pack(tile_index, rotation, flip_h, flip_v, wall_align)


static func unpack_tile(packed: int) -> Dictionary:
	return TilePacking.unpack(packed)


static func is_fence_surface(surface: Surface) -> bool:
	return surface >= Surface.FENCE_NORTH


static func fence_edge_from_surface(surface: Surface) -> int:
	if surface < Surface.FENCE_NORTH:
		return -1
	return surface - Surface.FENCE_NORTH


static func fence_surface_from_edge(edge: int) -> Surface:
	return (Surface.FENCE_NORTH + edge) as Surface


# Packed tile for any surface, including fence surfaces. Top tiles never report wall
# alignment because those bits hold the diagonal flip flag.
func get_tile_packed(x: int, z: int, surface: Surface) -> int:
	if not is_valid_cell(x, z):
		return 0
	if is_fence_surface(surface):
		return get_fence_tile_packed(x, z, fence_edge_from_surface(surface))

	var packed := cells[_cell_index(x, z) + TILE_OFFSET + surface]
	if surface == Surface.TOP:
		packed &= ~TILE_WALL_ALIGN_MASK
	return packed


func set_tile_packed(x: int, z: int, surface: Surface, packed: int) -> void:
	if not is_valid_cell(x, z):
		return
	if is_fence_surface(surface):
		set_fence_tile_packed(x, z, fence_edge_from_surface(surface), packed)
		return

	var idx := _cell_index(x, z) + TILE_OFFSET + surface
	if surface == Surface.TOP:
		packed = (packed & ~TILE_WALL_ALIGN_MASK) | (cells[idx] & DIAGONAL_FLIP_BIT)

	if _set_cell_value(idx, packed):
		_mark_changed()


func get_tile_index(x: int, z: int, surface: Surface) -> int:
	return TilePacking.get_tile_index(get_tile_packed(x, z, surface))


func get_tile_rotation(x: int, z: int, surface: Surface) -> Rotation:
	return TilePacking.get_rotation(get_tile_packed(x, z, surface)) as Rotation


func get_tile_flip_h(x: int, z: int, surface: Surface) -> bool:
	return TilePacking.get_flip_h(get_tile_packed(x, z, surface))


func get_tile_flip_v(x: int, z: int, surface: Surface) -> bool:
	return TilePacking.get_flip_v(get_tile_packed(x, z, surface))


func set_tile(x: int, z: int, surface: Surface, tile_index: int, rotation: Rotation = Rotation.ROT_0, flip_h: bool = false, flip_v: bool = false, wall_align: WallAlign = WallAlign.WORLD) -> void:
	set_tile_packed(x, z, surface, pack_tile(tile_index, rotation, flip_h, flip_v, wall_align))


# Packed tiles for TOP, NORTH, EAST, SOUTH, WEST
func get_all_tiles_packed(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0, 0]
	var idx := _cell_index(x, z) + TILE_OFFSET
	return [cells[idx] & ~TILE_WALL_ALIGN_MASK, cells[idx + 1], cells[idx + 2], cells[idx + 3], cells[idx + 4]]


# ============================================================================
# DIAGONAL FLIP (stored in the top tile)
# ============================================================================

func get_diagonal_flip(x: int, z: int) -> bool:
	if not is_valid_cell(x, z):
		return false
	return TilePacking.has_diagonal_flip(cells[_cell_index(x, z) + TILE_OFFSET])


func set_diagonal_flip(x: int, z: int, flip: bool) -> void:
	if not is_valid_cell(x, z):
		return
	var idx := _cell_index(x, z) + TILE_OFFSET
	if _set_cell_value(idx, TilePacking.set_diagonal_flip(cells[idx], flip)):
		_mark_changed()


func toggle_diagonal_flip(x: int, z: int) -> void:
	set_diagonal_flip(x, z, not get_diagonal_flip(x, z))


# ============================================================================
# WORLD-SPACE GEOMETRY
# ============================================================================

func get_world_corners(x: int, z: int, heights: Array[int]) -> Array[Vector3]:
	var base_x := x * cell_size
	var base_z := z * cell_size
	return [
		Vector3(base_x, steps_to_world(heights[Corner.NW]), base_z),
		Vector3(base_x + cell_size, steps_to_world(heights[Corner.NE]), base_z),
		Vector3(base_x + cell_size, steps_to_world(heights[Corner.SE]), base_z + cell_size),
		Vector3(base_x, steps_to_world(heights[Corner.SW]), base_z + cell_size),
	]


func get_top_world_corners(x: int, z: int) -> Array[Vector3]:
	return get_world_corners(x, z, get_top_corners(x, z))


func get_floor_world_corners(x: int, z: int) -> Array[Vector3]:
	return get_world_corners(x, z, get_floor_corners(x, z))


# Four corners of any surface, ordered clockwise when viewed from outside the cell
# (walls and fences: top-left, top-right, bottom-right, bottom-left)
func get_surface_world_corners(x: int, z: int, surface: Surface) -> Array[Vector3]:
	if surface == Surface.TOP:
		return get_top_world_corners(x, z)
	if is_fence_surface(surface):
		return get_fence_world_corners(x, z, surface)

	var edge: int = surface - Surface.NORTH
	var left: int = EDGE_CORNERS[edge][0]
	var right: int = EDGE_CORNERS[edge][1]
	var top := get_top_world_corners(x, z)
	var floor := get_floor_world_corners(x, z)
	return [top[left], top[right], floor[right], floor[left]]


# ============================================================================
# FENCES
# ============================================================================

static func fence_neighbor(x: int, z: int, edge: int) -> Vector2i:
	var offset: Vector2i = EDGE_NEIGHBOR_OFFSET[edge]
	return Vector2i(x + offset.x, z + offset.y)


static func opposite_edge(edge: int) -> int:
	return (edge + 2) % 4


# Fence heights for an edge as [left, right] in steps above the fence base.
# Left/right corners per edge are listed in EDGE_CORNERS.
func get_fence_heights(x: int, z: int, edge: int) -> Array[int]:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return [0, 0]
	var packed := cells[_cell_index(x, z) + FENCE_HEIGHT_OFFSET + edge]
	return [packed & FENCE_HEIGHT_LEFT_MASK, (packed & FENCE_HEIGHT_RIGHT_MASK) >> FENCE_HEIGHT_RIGHT_SHIFT]


# Sets fence heights for an edge. A physical edge can hold only one fence, so any fence
# the neighbour has on the shared edge is removed along with its tile.
func set_fence_heights(x: int, z: int, edge: int, left: int, right: int) -> void:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return

	left = clampi(left, 0, MAX_FENCE_HEIGHT)
	right = clampi(right, 0, MAX_FENCE_HEIGHT)

	var changed := false
	if left > 0 or right > 0:
		changed = _clear_neighbor_fence(x, z, edge)

	var packed := left | (right << FENCE_HEIGHT_RIGHT_SHIFT)
	if _set_cell_value(_cell_index(x, z) + FENCE_HEIGHT_OFFSET + edge, packed):
		changed = true

	if changed:
		_mark_changed()


func _clear_neighbor_fence(x: int, z: int, edge: int) -> bool:
	var neighbor := fence_neighbor(x, z, edge)
	if not is_valid_cell(neighbor.x, neighbor.y):
		return false

	var neighbor_idx := _cell_index(neighbor.x, neighbor.y)
	var neighbor_edge := opposite_edge(edge)
	var changed := _set_cell_value(neighbor_idx + FENCE_HEIGHT_OFFSET + neighbor_edge, 0)
	if _set_cell_value(neighbor_idx + FENCE_TILE_OFFSET + neighbor_edge, 0):
		changed = true
	return changed


func get_fence_tile_packed(x: int, z: int, edge: int) -> int:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return 0
	return cells[_cell_index(x, z) + FENCE_TILE_OFFSET + edge]


func set_fence_tile_packed(x: int, z: int, edge: int, packed: int) -> void:
	if not is_valid_cell(x, z) or edge < 0 or edge > 3:
		return
	if _set_cell_value(_cell_index(x, z) + FENCE_TILE_OFFSET + edge, packed):
		_mark_changed()


func has_fence(x: int, z: int, edge: int) -> bool:
	var heights := get_fence_heights(x, z, edge)
	return heights[0] > 0 or heights[1] > 0


func clear_fence(x: int, z: int, edge: int) -> void:
	set_fence_heights(x, z, edge, 0, 0)


# Packed fence tiles for edges N, E, S, W
func get_all_fence_tiles_packed(x: int, z: int) -> Array[int]:
	if not is_valid_cell(x, z):
		return [0, 0, 0, 0]
	var idx := _cell_index(x, z) + FENCE_TILE_OFFSET
	return [cells[idx], cells[idx + 1], cells[idx + 2], cells[idx + 3]]


# Height in steps that a fence on this edge stands on, per corner as [left, right].
# The base is the higher of the two cells sharing the edge so the fence is never buried.
func get_fence_base_heights(x: int, z: int, edge: int) -> Array[int]:
	var top := get_top_corners(x, z)
	var left: int = EDGE_CORNERS[edge][0]
	var right: int = EDGE_CORNERS[edge][1]

	var neighbor := fence_neighbor(x, z, edge)
	if not is_valid_cell(neighbor.x, neighbor.y):
		return [top[left], top[right]]

	var neighbor_top := get_top_corners(neighbor.x, neighbor.y)
	var neighbor_left: int = NEIGHBOR_EDGE_CORNERS[edge][0]
	var neighbor_right: int = NEIGHBOR_EDGE_CORNERS[edge][1]
	return [maxi(top[left], neighbor_top[neighbor_left]), maxi(top[right], neighbor_top[neighbor_right])]


# Four corners of a fence face: top-left, top-right, bottom-right, bottom-left
# (clockwise when viewed from outside the cell)
func get_fence_world_corners(x: int, z: int, surface: Surface) -> Array[Vector3]:
	var edge := fence_edge_from_surface(surface)
	if edge < 0 or not is_valid_cell(x, z):
		return [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]

	var positions := get_top_world_corners(x, z)
	var left_pos: Vector3 = positions[EDGE_CORNERS[edge][0]]
	var right_pos: Vector3 = positions[EDGE_CORNERS[edge][1]]
	var base := get_fence_base_heights(x, z, edge)
	var fence_h := get_fence_heights(x, z, edge)

	var base_left := steps_to_world(base[0])
	var base_right := steps_to_world(base[1])
	return [
		Vector3(left_pos.x, base_left + steps_to_world(fence_h[0]), left_pos.z),
		Vector3(right_pos.x, base_right + steps_to_world(fence_h[1]), right_pos.z),
		Vector3(right_pos.x, base_right, right_pos.z),
		Vector3(left_pos.x, base_left, left_pos.z),
	]
