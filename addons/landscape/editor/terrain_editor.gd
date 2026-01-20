@tool
class_name TerrainEditor
extends RefCounted

enum Tool { NONE, SCULPT, PAINT, FLIP_DIAGONAL, FLATTEN, MOUNTAIN }
enum HoverMode { CELL, CORNER }

signal tool_changed(new_tool: Tool)
signal hover_changed(cell: Vector2i, corner: int, mode: int)
signal height_changed(height: float, corner: int, mode: int)
signal paint_state_changed()
signal brush_size_changed(new_size: int)

var editor_interface: EditorInterface
var undo_redo: EditorUndoRedoManager

var current_tool: Tool = Tool.NONE:
	set(value):
		var old_tool := current_tool
		current_tool = value
		tool_changed.emit(value)
		if value == Tool.NONE:
			_clear_hover()
		elif old_tool == Tool.PAINT and value != Tool.PAINT:
			# Clear paint preview when switching away from paint tool
			if _terrain:
				_terrain.clear_preview()
			_paint_preview_buffer.clear()

# Paint tool state
var current_paint_tile: int = 0:
	set(value):
		current_paint_tile = value
		paint_state_changed.emit()
		_update_paint_preview()

var current_paint_surface: TerrainData.Surface = TerrainData.Surface.TOP:
	set(value):
		current_paint_surface = value
		paint_state_changed.emit()

var current_paint_rotation: TerrainData.Rotation = TerrainData.Rotation.ROT_0:
	set(value):
		current_paint_rotation = value
		paint_state_changed.emit()
		_update_paint_preview()

var current_paint_flip_h: bool = false:
	set(value):
		current_paint_flip_h = value
		paint_state_changed.emit()
		_update_paint_preview()

var current_paint_flip_v: bool = false:
	set(value):
		current_paint_flip_v = value
		paint_state_changed.emit()
		_update_paint_preview()

var current_paint_random: bool = false:
	set(value):
		current_paint_random = value
		paint_state_changed.emit()
		_update_paint_preview()

var current_paint_wall_align: TerrainData.WallAlign = TerrainData.WallAlign.WORLD:
	set(value):
		current_paint_wall_align = value
		paint_state_changed.emit()
		_update_paint_preview()

# Brush size (1 = 1x1, 2 = 2x2, 3 = 3x3, etc.)
var brush_size: int = 1:
	set(value):
		brush_size = clampi(value, 1, 9)
		brush_size_changed.emit(brush_size)

# Corner detection threshold - distance from corner as fraction of cell size
const CORNER_THRESHOLD := 0.45

var _terrain: LandscapeTerrain
var _hovered_cell: Vector2i = Vector2i(-1, -1)
var _hovered_corner: int = -1
var _brush_corner: int = -1  # Nearest corner for even brush sizes (0=NW, 1=NE, 2=SE, 3=SW)
var _hover_mode: HoverMode = HoverMode.CELL
var _hovered_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _last_camera: Camera3D

# Drag state
var _is_dragging: bool = false
var _drag_cell: Vector2i = Vector2i(-1, -1)
var _drag_corner: int = -1
var _drag_mode: HoverMode = HoverMode.CELL
var _drag_original_corners: Array[int] = []
var _drag_current_delta: int = 0
var _drag_start_mouse_y: float = 0.0
var _drag_world_pos: Vector3 = Vector3.ZERO  # World position of drag point for scale calculation
var _drag_brush_cells: Array[Vector2i] = []  # All cells in brush area during drag
var _drag_brush_original_corners: Dictionary = {}  # Original corners for each cell in brush: "x,z" -> Array[int]
var _drag_sticky_corners: Array[int] = []  # Current heights for non-dragged corners (sticky per step)
var _drag_brush_min_height: int = 0  # Min corner height across all brush cells at drag start
var _drag_brush_max_height: int = 0  # Max corner height across all brush cells at drag start
var _drag_mountain_all_cells: Array[Vector2i] = []  # All cells affected by mountain tool (core + slopes)
var _drag_mountain_original_corners: Dictionary = {}  # Original corners for all mountain-affected cells
var _drag_mountain_corner_distances: Dictionary = {}  # Precomputed corner distances from core

# Flatten drag state
var _is_flatten_dragging: bool = false
var _flatten_target_height: int = 0
var _flatten_affected_cells: Dictionary = {}  # Vector2i -> original corners Array[int]

# Paint drag state
var _is_paint_dragging: bool = false
var _last_painted_cell: Vector2i = Vector2i(-1, -1)
var _last_painted_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _paint_preview_buffer: Dictionary = {}  # Preview buffer: "x,z,surface" -> packed_tile_value
var _paint_original_values: Dictionary = {}  # Original values for undo: "x,z,surface" -> packed_tile_value
var _paint_surface_locked: bool = false  # When true, only paint on the locked surface type
var _paint_locked_surface: TerrainData.Surface = TerrainData.Surface.TOP

# Right-click picker state
var _right_click_picking: bool = false


func set_terrain(terrain: LandscapeTerrain) -> void:
	_terrain = terrain
	_clear_hover()
	_cancel_drag()


func get_hovered_surface() -> TerrainData.Surface:
	return _hovered_surface


func clear_all_previews() -> void:
	# Clear hover state (which also clears paint preview)
	_clear_hover()


func _clear_hover() -> void:
	if _hovered_cell.x >= 0:
		_hovered_cell = Vector2i(-1, -1)
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
	# Clear buffer-based paint preview
	if _terrain:
		_terrain.clear_preview()
	_paint_preview_buffer.clear()


func get_current_height() -> float:
	if not _terrain or not _terrain.terrain_data:
		return NAN

	var cell := _drag_cell if _is_dragging else _hovered_cell
	var corner := _drag_corner if _is_dragging else _hovered_corner
	var mode := _drag_mode if _is_dragging else _hover_mode

	if cell.x < 0:
		return NAN

	var data := _terrain.terrain_data
	var corners := data.get_top_corners(cell.x, cell.y)

	if mode == HoverMode.CORNER and corner >= 0:
		return data.steps_to_world(corners[corner])
	else:
		var avg := 0.0
		for c in corners:
			avg += data.steps_to_world(c)
		return avg / 4.0


func handle_input(camera: Camera3D, event: InputEvent, terrain: LandscapeTerrain) -> bool:
	if not terrain:
		return false

	_terrain = terrain
	_last_camera = camera

	if current_tool == Tool.NONE:
		return false

	# Handle keyboard shortcuts for paint tool (Tiled-style)
	if current_tool == Tool.PAINT and event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_X:
					toggle_paint_flip_h()
					return true
				KEY_Y:
					toggle_paint_flip_v()
					return true
				KEY_Z:
					if key.shift_pressed:
						rotate_paint_ccw()
					else:
						rotate_paint_cw()
					return true

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_dragging:
			_update_drag(camera, motion.position)
			return true
		elif _is_flatten_dragging:
			_update_flatten_drag(camera, motion.position)
			return true
		elif _is_paint_dragging:
			_update_paint_drag(camera, motion.position)
			return true
		else:
			# Cancel right-click picker if mouse moves (user is moving camera)
			if _right_click_picking:
				_right_click_picking = false
			_update_hover(camera, motion.position, motion.shift_pressed)
			return false

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _start_drag(camera, mb.position, mb.shift_pressed)
			else:
				if _is_dragging:
					_finish_drag()
					return true
				elif _is_flatten_dragging:
					_finish_flatten_drag()
					return true
				elif _is_paint_dragging:
					_finish_paint_drag()
					return true
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if _is_dragging:
				_cancel_drag()
				return true
			elif _is_flatten_dragging:
				_cancel_flatten_drag()
				return true
			elif _is_paint_dragging:
				cancel_paint_preview()
				return true
			elif current_tool == Tool.PAINT:
				if mb.pressed:
					# Start right-click - might be picker or camera movement
					_right_click_picking = true
				else:
					# Right-click released - pick tile if we didn't move
					if _right_click_picking:
						_right_click_picking = false
						_pick_tile_at_hover()
				# Don't consume - allow camera movement
				return false

	return false


func _start_drag(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	# Handle paint tool
	if current_tool == Tool.PAINT:
		# Clear any existing preview and start fresh
		_paint_preview_buffer.clear()
		_paint_original_values.clear()
		# Lock surface when shift is held
		if shift_pressed:
			_paint_surface_locked = true
			_paint_locked_surface = _hovered_surface
		# Build preview for initial brush area (use locked surface if enabled)
		var paint_surface := _paint_locked_surface if _paint_surface_locked else _hovered_surface
		var previewed := _build_paint_preview(data, _hovered_cell, paint_surface)
		if previewed:
			_is_paint_dragging = true
			_last_painted_cell = _hovered_cell
			_last_painted_surface = paint_surface
			_terrain.set_tile_previews(_paint_preview_buffer)
		return previewed

	# Handle flip diagonal tool
	if current_tool == Tool.FLIP_DIAGONAL:
		_flip_diagonal_brush_area(data, _hovered_cell)
		return true

	# Handle flatten tool - start drag
	if current_tool == Tool.FLATTEN:
		# Get target height from the hovered corner
		var corners := data.get_top_corners(_hovered_cell.x, _hovered_cell.y)
		if _hover_mode == HoverMode.CORNER and _hovered_corner >= 0:
			_flatten_target_height = corners[_hovered_corner]
		else:
			# Use average height if clicking cell center
			_flatten_target_height = int(round(float(corners[0] + corners[1] + corners[2] + corners[3]) / 4.0))

		_is_flatten_dragging = true
		_flatten_affected_cells.clear()

		# Apply to initial brush area
		_apply_flatten_to_brush(data, _hovered_cell)
		return true

	if current_tool != Tool.SCULPT and current_tool != Tool.MOUNTAIN:
		return false

	_is_dragging = true
	_drag_cell = _hovered_cell
	_drag_corner = _hovered_corner
	_drag_current_delta = 0
	_drag_start_mouse_y = mouse_pos.y

	# For brush size > 1, force cell mode (corner mode doesn't make sense for multi-cell)
	if brush_size > 1:
		_drag_mode = HoverMode.CELL
	else:
		_drag_mode = _hover_mode

	# Store original heights for center cell
	_drag_original_corners = []
	var corners := data.get_top_corners(_drag_cell.x, _drag_cell.y)
	for c in corners:
		_drag_original_corners.append(c)
	_drag_sticky_corners = _drag_original_corners.duplicate()

	# Store original heights for all brush cells and find min/max
	_drag_brush_cells = get_brush_cells(_drag_cell, data, _brush_corner)
	_drag_brush_original_corners.clear()
	_drag_brush_min_height = 999999
	_drag_brush_max_height = -999999
	for cell in _drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		var cell_corners := data.get_top_corners(cell.x, cell.y)
		_drag_brush_original_corners[key] = cell_corners.duplicate()
		for c in cell_corners:
			_drag_brush_min_height = mini(_drag_brush_min_height, c)
			_drag_brush_max_height = maxi(_drag_brush_max_height, c)

	# For mountain tool, also store surrounding cells that may be affected by slopes
	if current_tool == Tool.MOUNTAIN:
		_drag_mountain_original_corners.clear()
		_drag_mountain_all_cells.clear()
		_drag_mountain_corner_distances.clear()

		# Corner offsets for precomputation
		var corner_offsets: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]

		# Store core brush cells (use Vector2i keys for performance)
		var brush_set: Dictionary = {}
		for cell in _drag_brush_cells:
			_drag_mountain_all_cells.append(cell)
			_drag_mountain_original_corners[cell] = _drag_brush_original_corners["%d,%d" % [cell.x, cell.y]].duplicate()
			brush_set[cell] = true
		# Expand outward to collect slope cells (up to 9 rings for max height change)
		var max_rings := 9
		var current_ring := _drag_brush_cells.duplicate()
		for _ring in max_rings:
			var next_ring: Array[Vector2i] = []
			for cell in current_ring:
				# Check all 8 neighbors
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dz == 0:
							continue
						var neighbor := Vector2i(cell.x + dx, cell.y + dz)
						if not brush_set.has(neighbor) and data.is_valid_cell(neighbor.x, neighbor.y):
							if not _drag_mountain_original_corners.has(neighbor):
								_drag_mountain_all_cells.append(neighbor)
								_drag_mountain_original_corners[neighbor] = data.get_top_corners(neighbor.x, neighbor.y).duplicate()
								next_ring.append(neighbor)
			current_ring = next_ring
			if current_ring.is_empty():
				break

		# Precompute corner distances using BFS
		var valid_corners: Dictionary = {}
		for cell in _drag_mountain_all_cells:
			for offset in corner_offsets:
				valid_corners[Vector2i(cell.x + offset.x, cell.y + offset.y)] = true

		var queue: Array[Vector2i] = []
		for cell in _drag_brush_cells:
			for offset in corner_offsets:
				var corner_pos := Vector2i(cell.x + offset.x, cell.y + offset.y)
				if not _drag_mountain_corner_distances.has(corner_pos):
					_drag_mountain_corner_distances[corner_pos] = 0
					queue.append(corner_pos)

		var directions: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
		var head := 0
		while head < queue.size():
			var pos := queue[head]
			head += 1
			var dist: int = _drag_mountain_corner_distances[pos]
			for dir in directions:
				var neighbor := Vector2i(pos.x + dir.x, pos.y + dir.y)
				if valid_corners.has(neighbor) and not _drag_mountain_corner_distances.has(neighbor):
					_drag_mountain_corner_distances[neighbor] = dist + 1
					queue.append(neighbor)

	# Calculate world position for scale reference
	var cell_size := data.cell_size
	var local_pos: Vector3
	if _drag_mode == HoverMode.CORNER:
		var corner_offsets := [
			Vector2(0.0, 0.0),  # NW
			Vector2(1.0, 0.0),  # NE
			Vector2(1.0, 1.0),  # SE
			Vector2(0.0, 1.0),  # SW
		]
		var offset: Vector2 = corner_offsets[_drag_corner]
		var height := data.steps_to_world(_drag_original_corners[_drag_corner])
		local_pos = Vector3(
			(_drag_cell.x + offset.x) * cell_size,
			height,
			(_drag_cell.y + offset.y) * cell_size
		)
	else:
		var avg_height := 0.0
		for c in _drag_original_corners:
			avg_height += data.steps_to_world(c)
		avg_height /= 4.0
		local_pos = Vector3(
			(_drag_cell.x + 0.5) * cell_size,
			avg_height,
			(_drag_cell.y + 0.5) * cell_size
		)
	_drag_world_pos = _terrain.to_global(local_pos)

	return true


func _update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _is_dragging or not _terrain:
		return

	var data := _terrain.terrain_data
	if not data:
		return

	# Calculate screen-space scale: how many pixels = 1 world unit at the drag point
	var point_above := _drag_world_pos + Vector3(0, 1, 0)
	var screen_drag_pos := camera.unproject_position(_drag_world_pos)
	var screen_above := camera.unproject_position(point_above)
	var pixels_per_unit := screen_drag_pos.y - screen_above.y  # Y is inverted in screen space

	if abs(pixels_per_unit) < 0.001:
		return

	# Calculate mouse delta in world units
	var mouse_delta_pixels := _drag_start_mouse_y - mouse_pos.y
	var mouse_delta_world := mouse_delta_pixels / pixels_per_unit

	# Convert to height steps
	var height_step := data.height_step
	var new_delta := int(round(mouse_delta_world / height_step))

	if new_delta == _drag_current_delta:
		return

	_drag_current_delta = new_delta

	# Apply the new heights directly (no undo yet)
	if current_tool == Tool.MOUNTAIN:
		# Mountain tool: raise/lower core with slopes radiating outward
		_apply_mountain_heights(data, _drag_current_delta)
		var world_height := data.steps_to_world(_drag_brush_min_height + _drag_current_delta)
		height_changed.emit(world_height, -1, _drag_mode)
	elif _drag_mode == HoverMode.CORNER:
		# Single corner mode (only for brush_size == 0)
		var corner_target := _drag_original_corners[_drag_corner] + _drag_current_delta
		var new_corners := _calculate_dragged_corners(_drag_corner, corner_target, data.max_slope_steps)
		data.set_top_corners(_drag_cell.x, _drag_cell.y, new_corners)
		var world_height := data.steps_to_world(new_corners[_drag_corner])
		height_changed.emit(world_height, _drag_corner, _drag_mode)
	elif brush_size == 1:
		# Single cell mode - uniform raise/lower of all corners
		data.begin_batch()
		for cell in _drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			var original: Array = _drag_brush_original_corners[key]
			var new_corners: Array[int] = []
			for i in 4:
				new_corners.append(original[i] + _drag_current_delta)
			data.set_top_corners(cell.x, cell.y, new_corners)
		data.end_batch()

		# Report height for center cell
		var avg_height := 0.0
		for c in _drag_original_corners:
			avg_height += data.steps_to_world(c + _drag_current_delta)
		avg_height /= 4.0
		height_changed.emit(avg_height, -1, _drag_mode)
	else:
		# Multi-cell brush - leveling sculpt
		# When raising: bring low corners up toward target (min + delta)
		# When lowering: bring high corners down toward target (max + delta)
		var target_height: int
		if _drag_current_delta >= 0:
			target_height = _drag_brush_min_height + _drag_current_delta
		else:
			target_height = _drag_brush_max_height + _drag_current_delta

		data.begin_batch()
		for cell in _drag_brush_cells:
			var current_corners := data.get_top_corners(cell.x, cell.y)
			var new_corners: Array[int] = []
			for i in 4:
				if _drag_current_delta >= 0:
					# Raising: corners move up toward target, never down
					new_corners.append(maxi(current_corners[i], target_height))
				else:
					# Lowering: corners move down toward target, never up
					new_corners.append(mini(current_corners[i], target_height))
			data.set_top_corners(cell.x, cell.y, new_corners)
		data.end_batch()

		# Report target height
		var world_height := data.steps_to_world(target_height)
		height_changed.emit(world_height, -1, _drag_mode)


func _calculate_dragged_corners(dragged_corner: int, target_height: int, max_slope: int) -> Array[int]:
	# Start with sticky corners (current heights) for non-dragged, target for dragged
	var corners: Array[int] = []
	for i in 4:
		if i == dragged_corner:
			corners.append(target_height)
		else:
			corners.append(_drag_sticky_corners[i])

	# Edge-adjacent corners (NW=0, NE=1, SE=2, SW=3)
	var adjacents := [
		[1, 3],  # NW -> NE, SW
		[0, 2],  # NE -> NW, SE
		[1, 3],  # SE -> NE, SW
		[0, 2],  # SW -> NW, SE
	]

	# Diagonal corner for each corner
	var diagonal: Array[int] = [2, 3, 0, 1]  # NW->SE, NE->SW, SE->NW, SW->NE

	# Process in order: dragged corner, then adjacent corners, then diagonal corner
	var adjacent_corners: Array = adjacents[dragged_corner]
	var diagonal_corner: int = diagonal[dragged_corner]

	# Constrain adjacent corners to dragged corner (only move if slope constraint requires it)
	for adj in adjacent_corners:
		var min_h := corners[dragged_corner] - max_slope
		var max_h := corners[dragged_corner] + max_slope
		corners[adj] = clampi(corners[adj], min_h, max_h)

	# Constrain diagonal corner to both adjacent corners
	var min_h := -999999
	var max_h := 999999
	for adj in adjacent_corners:
		min_h = maxi(min_h, corners[adj] - max_slope)
		max_h = mini(max_h, corners[adj] + max_slope)
	corners[diagonal_corner] = clampi(corners[diagonal_corner], min_h, max_h)

	# Update sticky corners for non-dragged corners
	for i in 4:
		if i != dragged_corner:
			_drag_sticky_corners[i] = corners[i]

	return corners


func _apply_mountain_heights(data: TerrainData, delta: int) -> void:
	var max_slope := data.max_slope_steps

	# Calculate reference height for the peak/valley
	var peak_height: int = _drag_brush_max_height + delta if delta >= 0 else _drag_brush_min_height + delta

	# Batch updates to avoid emitting data_changed for each cell
	data.begin_batch()

	# Apply heights to cells using precomputed corner distances
	for cell in _drag_mountain_all_cells:
		var original: Array = _drag_mountain_original_corners[cell]
		var cx := cell.x
		var cy := cell.y

		var d0: int = _drag_mountain_corner_distances.get(Vector2i(cx, cy), 0)
		var d1: int = _drag_mountain_corner_distances.get(Vector2i(cx + 1, cy), 0)
		var d2: int = _drag_mountain_corner_distances.get(Vector2i(cx + 1, cy + 1), 0)
		var d3: int = _drag_mountain_corner_distances.get(Vector2i(cx, cy + 1), 0)

		var o0: int = original[0]
		var o1: int = original[1]
		var o2: int = original[2]
		var o3: int = original[3]

		if delta >= 0:
			data.set_top_corners(cx, cy, [
				maxi(o0, peak_height - d0 * max_slope),
				maxi(o1, peak_height - d1 * max_slope),
				maxi(o2, peak_height - d2 * max_slope),
				maxi(o3, peak_height - d3 * max_slope),
			])
		else:
			data.set_top_corners(cx, cy, [
				mini(o0, peak_height + d0 * max_slope),
				mini(o1, peak_height + d1 * max_slope),
				mini(o2, peak_height + d2 * max_slope),
				mini(o3, peak_height + d3 * max_slope),
			])

	data.end_batch()


func _finish_drag() -> void:
	if not _is_dragging or not _terrain:
		_is_dragging = false
		return

	var data := _terrain.terrain_data
	if not data or _drag_current_delta == 0:
		_is_dragging = false
		return

	# Create undo/redo action for the final change
	var action_name := "Mountain Terrain" if current_tool == Tool.MOUNTAIN else "Sculpt Terrain"
	undo_redo.create_action(action_name)

	# Use mountain cells if mountain tool, otherwise brush cells
	var cells_to_undo: Array[Vector2i] = _drag_mountain_all_cells if current_tool == Tool.MOUNTAIN else _drag_brush_cells
	var use_vector_keys := current_tool == Tool.MOUNTAIN

	for cell in cells_to_undo:
		var original: Array
		if use_vector_keys:
			if not _drag_mountain_original_corners.has(cell):
				continue
			original = _drag_mountain_original_corners[cell]
		else:
			var key := "%d,%d" % [cell.x, cell.y]
			if not _drag_brush_original_corners.has(key):
				continue
			original = _drag_brush_original_corners[key]

		var final_corners := data.get_top_corners(cell.x, cell.y)
		var original_typed: Array[int] = []
		for c in original:
			original_typed.append(c)
		# Only add undo if there was a change
		if original_typed != final_corners:
			undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, final_corners)
			undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_typed)

	undo_redo.commit_action(false)  # Don't execute, already applied

	_is_dragging = false


func _cancel_drag() -> void:
	if not _is_dragging or not _terrain:
		_is_dragging = false
		return

	var data := _terrain.terrain_data
	if data:
		# Use mountain cells if mountain tool, otherwise brush cells
		var cells_to_restore: Array[Vector2i] = _drag_mountain_all_cells if current_tool == Tool.MOUNTAIN else _drag_brush_cells
		var use_vector_keys := current_tool == Tool.MOUNTAIN

		for cell in cells_to_restore:
			var original: Array
			if use_vector_keys:
				if not _drag_mountain_original_corners.has(cell):
					continue
				original = _drag_mountain_original_corners[cell]
			else:
				var key := "%d,%d" % [cell.x, cell.y]
				if not _drag_brush_original_corners.has(key):
					continue
				original = _drag_brush_original_corners[key]

			var original_typed: Array[int] = []
			for c in original:
				original_typed.append(c)
			data.set_top_corners(cell.x, cell.y, original_typed)

	_is_dragging = false


func _update_paint_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _is_paint_dragging or not _terrain:
		return

	var data := _terrain.terrain_data
	if not data:
		return

	# Update hover position (this also updates _hovered_surface)
	_update_hover(camera, mouse_pos)

	if _hovered_cell.x < 0:
		return

	# When surface is locked, only paint on matching surface type
	var paint_surface := _paint_locked_surface if _paint_surface_locked else _hovered_surface
	if _paint_surface_locked and _hovered_surface != _paint_locked_surface:
		return

	# Only update preview if cell or surface changed
	if _hovered_cell == _last_painted_cell and paint_surface == _last_painted_surface:
		return

	# Add new cells to preview (accumulate)
	_build_paint_preview(data, _hovered_cell, paint_surface)
	_terrain.set_tile_previews(_paint_preview_buffer)
	_last_painted_cell = _hovered_cell
	_last_painted_surface = paint_surface


func _finish_paint_drag() -> void:
	if not _terrain or _paint_preview_buffer.is_empty():
		_is_paint_dragging = false
		_paint_surface_locked = false
		_last_painted_cell = Vector2i(-1, -1)
		_paint_preview_buffer.clear()
		_paint_original_values.clear()
		return

	var data := _terrain.terrain_data
	if not data:
		_is_paint_dragging = false
		_paint_surface_locked = false
		return

	# Create undo/redo action from preview data
	undo_redo.create_action("Paint Terrain Tiles")
	for key: String in _paint_preview_buffer.keys():
		var parts: PackedStringArray = key.split(",")
		var x := int(parts[0])
		var z := int(parts[1])
		var surface := int(parts[2]) as TerrainData.Surface
		var new_packed: int = _paint_preview_buffer[key]
		var old_packed: int = _paint_original_values[key]
		undo_redo.add_do_method(data, "set_tile_packed", x, z, surface, new_packed)
		undo_redo.add_undo_method(data, "set_tile_packed", x, z, surface, old_packed)
	undo_redo.commit_action()

	# Clear preview
	_terrain.clear_preview()
	_paint_preview_buffer.clear()
	_paint_original_values.clear()
	_is_paint_dragging = false
	_paint_surface_locked = false
	_last_painted_cell = Vector2i(-1, -1)


func _update_hover(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> void:
	if _is_dragging:
		return

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	var hit := _raycast_terrain(ray_origin, ray_dir)
	if hit.is_empty():
		if _hovered_cell.x >= 0:
			_hovered_cell = Vector2i(-1, -1)
			_hovered_corner = -1
			_hover_mode = HoverMode.CELL
			_hovered_surface = TerrainData.Surface.TOP
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		# Clear paint preview when not hovering terrain (but not during paint drag)
		if current_tool == Tool.PAINT and _terrain and not _is_paint_dragging:
			_terrain.clear_preview()
		return

	var hit_pos: Vector3 = hit.position
	var hit_normal: Vector3 = hit.normal

	var old_cell := _hovered_cell
	var old_corner := _hovered_corner
	var old_mode := _hover_mode
	var old_surface := _hovered_surface

	_hovered_surface = _surface_from_normal(hit_normal)

	# For walls, adjust the cell based on which cell owns the wall
	# The hit position might be on the boundary, so we offset slightly into the correct cell
	var adjusted_pos := hit_pos
	if _hovered_surface == TerrainData.Surface.SOUTH:
		adjusted_pos.z -= 0.01
	elif _hovered_surface == TerrainData.Surface.EAST:
		adjusted_pos.x -= 0.01
	elif _hovered_surface == TerrainData.Surface.NORTH:
		adjusted_pos.z += 0.01
	elif _hovered_surface == TerrainData.Surface.WEST:
		adjusted_pos.x += 0.01

	_hovered_cell = _terrain.world_to_cell(adjusted_pos)

	# Calculate position within cell to determine nearest corner (for all tools)
	var local_pos := _terrain.to_local(hit_pos)
	var cell_size := _terrain.terrain_data.cell_size
	var cell_local_x := local_pos.x - _hovered_cell.x * cell_size
	var cell_local_z := local_pos.z - _hovered_cell.y * cell_size

	# Normalize to 0-1 range within cell
	var norm_x := cell_local_x / cell_size
	var norm_z := cell_local_z / cell_size

	# Check distance to each corner
	var corner_dists: Array[float] = [
		Vector2(norm_x, norm_z).length(),              # NW (0,0)
		Vector2(norm_x - 1.0, norm_z).length(),        # NE (1,0)
		Vector2(norm_x - 1.0, norm_z - 1.0).length(),  # SE (1,1)
		Vector2(norm_x, norm_z - 1.0).length(),        # SW (0,1)
	]

	# Find closest corner (used by even brush sizes to center on corner)
	var min_dist := corner_dists[0]
	var closest_corner := 0
	for i in range(1, 4):
		if corner_dists[i] < min_dist:
			min_dist = corner_dists[i]
			closest_corner = i

	# Store brush corner for even brush size centering
	_brush_corner = closest_corner

	# For paint, flip diagonal, and mountain tools, we don't need corner hover mode
	if current_tool == Tool.PAINT or current_tool == Tool.FLIP_DIAGONAL or current_tool == Tool.MOUNTAIN:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		if old_cell != _hovered_cell or old_surface != _hovered_surface:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		# Update buffer-based paint preview (hover preview, not during drag)
		if current_tool == Tool.PAINT and _terrain and not _is_paint_dragging:
			# Handle surface lock with shift key
			if shift_pressed:
				if not _paint_surface_locked:
					# Lock to current surface when shift first pressed
					_paint_surface_locked = true
					_paint_locked_surface = _hovered_surface
				if _hovered_surface == _paint_locked_surface:
					_update_hover_paint_preview()
				else:
					_terrain.clear_preview()
			else:
				# Release lock when shift released
				_paint_surface_locked = false
				_update_hover_paint_preview()
		return

	# For sculpt/flatten tools, also track corner hover mode
	_hovered_corner = closest_corner

	# Determine mode based on distance to corner
	if min_dist < CORNER_THRESHOLD:
		_hover_mode = HoverMode.CORNER
	else:
		_hover_mode = HoverMode.CELL

	if old_cell != _hovered_cell or old_corner != _hovered_corner or old_mode != _hover_mode:
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)


func _surface_from_normal(normal: Vector3) -> TerrainData.Surface:
	var up_dot := abs(normal.y)

	# Top surface detection (mostly horizontal)
	if up_dot > 0.7:
		return TerrainData.Surface.TOP

	# Wall surface - determine direction from normal
	var abs_normal := normal.abs()
	if abs_normal.z > abs_normal.x:
		# North or South wall
		return TerrainData.Surface.NORTH if normal.z < 0 else TerrainData.Surface.SOUTH
	else:
		# East or West wall
		return TerrainData.Surface.EAST if normal.x > 0 else TerrainData.Surface.WEST


func _raycast_terrain(origin: Vector3, direction: Vector3) -> Dictionary:
	if not _terrain or not _terrain.terrain_data:
		return {}

	var space_state := _terrain.get_world_3d().direct_space_state
	var end := origin + direction * 1000.0

	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return {}

	# Check if we hit the terrain
	var collider := result.get("collider")
	if collider and collider.get_parent() == _terrain:
		return {
			"position": result.get("position"),
			"normal": result.get("normal", Vector3.UP)
		}

	return {}


func _apply_flatten_to_brush(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := get_brush_cells(center, data, _brush_corner)

	if brush_cells.is_empty():
		return

	data.begin_batch()
	for cell in brush_cells:
		# Skip cells already flattened in this drag
		if _flatten_affected_cells.has(cell):
			continue

		var old_corners := data.get_top_corners(cell.x, cell.y)

		# Check if there's actually a change needed
		if old_corners[0] != _flatten_target_height or old_corners[1] != _flatten_target_height or \
		   old_corners[2] != _flatten_target_height or old_corners[3] != _flatten_target_height:
			# Store original for undo
			_flatten_affected_cells[cell] = old_corners.duplicate()
			# Apply flatten
			data.set_top_corners(cell.x, cell.y, [_flatten_target_height, _flatten_target_height, _flatten_target_height, _flatten_target_height])
	data.end_batch()


func _update_flatten_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _is_flatten_dragging or not _terrain:
		return

	var data := _terrain.terrain_data
	if not data:
		return

	# Raycast to find current cell
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var hit := _raycast_terrain(ray_origin, ray_dir)

	if hit.is_empty():
		return

	var hit_pos: Vector3 = hit.position
	var cell := _terrain.world_to_cell(hit_pos)

	if not data.is_valid_cell(cell.x, cell.y):
		return

	# Update brush corner for even-sized brushes
	var local_pos := _terrain.to_local(hit_pos)
	var cell_size := data.cell_size
	var norm_x := (local_pos.x - cell.x * cell_size) / cell_size
	var norm_z := (local_pos.z - cell.y * cell_size) / cell_size

	var corner_dists: Array[float] = [
		Vector2(norm_x, norm_z).length(),
		Vector2(norm_x - 1.0, norm_z).length(),
		Vector2(norm_x - 1.0, norm_z - 1.0).length(),
		Vector2(norm_x, norm_z - 1.0).length(),
	]

	var min_dist := corner_dists[0]
	_brush_corner = 0
	for i in range(1, 4):
		if corner_dists[i] < min_dist:
			min_dist = corner_dists[i]
			_brush_corner = i

	# Update hovered cell for overlay drawing
	_hovered_cell = cell

	# Apply flatten to cells under brush
	_apply_flatten_to_brush(data, cell)


func _finish_flatten_drag() -> void:
	if not _is_flatten_dragging or not _terrain:
		_is_flatten_dragging = false
		return

	var data := _terrain.terrain_data
	if not data or _flatten_affected_cells.is_empty():
		_is_flatten_dragging = false
		_flatten_affected_cells.clear()
		return

	# Create undo action for all affected cells
	undo_redo.create_action("Flatten Terrain")
	undo_redo.add_do_method(data, "begin_batch")
	undo_redo.add_undo_method(data, "begin_batch")
	for cell in _flatten_affected_cells:
		var original: Array = _flatten_affected_cells[cell]
		var original_typed: Array[int] = [original[0], original[1], original[2], original[3]]
		var new_corners: Array[int] = [_flatten_target_height, _flatten_target_height, _flatten_target_height, _flatten_target_height]
		undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, new_corners)
		undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_typed)
	undo_redo.add_do_method(data, "end_batch")
	undo_redo.add_undo_method(data, "end_batch")
	undo_redo.commit_action(false)  # Don't execute, already applied

	_is_flatten_dragging = false
	_flatten_affected_cells.clear()


func _cancel_flatten_drag() -> void:
	if not _is_flatten_dragging or not _terrain:
		_is_flatten_dragging = false
		return

	var data := _terrain.terrain_data
	if data:
		# Restore original heights
		data.begin_batch()
		for cell in _flatten_affected_cells:
			var original: Array = _flatten_affected_cells[cell]
			var original_typed: Array[int] = [original[0], original[1], original[2], original[3]]
			data.set_top_corners(cell.x, cell.y, original_typed)
		data.end_batch()

	_is_flatten_dragging = false
	_flatten_affected_cells.clear()


func _flip_diagonal_brush_area(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := get_brush_cells(center, data, _brush_corner)

	if brush_cells.is_empty():
		return

	# Create single undo action for all cells with batching
	undo_redo.create_action("Flip Diagonal")
	undo_redo.add_do_method(data, "begin_batch")
	undo_redo.add_undo_method(data, "begin_batch")
	for cell in brush_cells:
		var old_flip := data.get_diagonal_flip(cell.x, cell.y)
		var new_flip := not old_flip
		undo_redo.add_do_method(data, "set_diagonal_flip", cell.x, cell.y, new_flip)
		undo_redo.add_undo_method(data, "set_diagonal_flip", cell.x, cell.y, old_flip)
	undo_redo.add_do_method(data, "end_batch")
	undo_redo.add_undo_method(data, "end_batch")
	undo_redo.commit_action()


func _update_paint_preview() -> void:
	if current_tool != Tool.PAINT or not _terrain or _hovered_cell.x < 0:
		return
	_update_hover_paint_preview()


func _update_hover_paint_preview() -> void:
	if not _terrain or _hovered_cell.x < 0:
		return

	var data := _terrain.terrain_data
	if not data:
		return

	# Build hover preview for entire brush area
	var hover_preview: Dictionary = {}
	var brush_cells := get_brush_cells(_hovered_cell, data, _brush_corner)

	for cell in brush_cells:
		var key := "%d,%d,%d" % [cell.x, cell.y, _hovered_surface]
		hover_preview[key] = _get_paint_packed(cell, _hovered_surface)

	_terrain.set_tile_previews(hover_preview)


func _build_paint_preview(data: TerrainData, center: Vector2i, surface: TerrainData.Surface) -> bool:
	var brush_cells := get_brush_cells(center, data, _brush_corner)

	var any_added := false
	for cell in brush_cells:
		var key := "%d,%d,%d" % [cell.x, cell.y, surface]
		# Skip if already in preview buffer
		if _paint_preview_buffer.has(key):
			continue

		var old_packed := data.get_tile_packed(cell.x, cell.y, surface)
		# Store original value for undo
		_paint_original_values[key] = old_packed
		# Add to preview buffer with potentially random transform
		_paint_preview_buffer[key] = _get_paint_packed(cell, surface)
		any_added = true

	return any_added or brush_cells.size() > 0


func cancel_paint_preview() -> void:
	if _terrain:
		_terrain.clear_preview()
	_paint_preview_buffer.clear()
	_paint_original_values.clear()
	_is_paint_dragging = false
	_paint_surface_locked = false
	_last_painted_cell = Vector2i(-1, -1)


func _get_paint_packed(cell: Vector2i, surface: TerrainData.Surface) -> int:
	if current_paint_random:
		# Use cell position and surface as seed for deterministic randomness
		# This ensures the same cell shows the same random transform during hover
		var seed_value := cell.x * 73856093 ^ cell.y * 19349663 ^ surface * 83492791
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var rotation := rng.randi_range(0, 3) as TerrainData.Rotation
		var flip_h := rng.randi_range(0, 1) == 1
		var flip_v := rng.randi_range(0, 1) == 1
		return TerrainData.pack_tile(current_paint_tile, rotation, flip_h, flip_v, current_paint_wall_align)
	else:
		return TerrainData.pack_tile(current_paint_tile, current_paint_rotation, current_paint_flip_h, current_paint_flip_v, current_paint_wall_align)


func _pick_tile_at_hover() -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	# Get tile data from the hovered cell and surface
	var packed := data.get_tile_packed(_hovered_cell.x, _hovered_cell.y, _hovered_surface)
	var tile_info := TerrainData.unpack_tile(packed)

	# Set current paint state to match the picked tile
	current_paint_tile = tile_info.tile_index
	current_paint_rotation = tile_info.rotation as TerrainData.Rotation
	current_paint_flip_h = tile_info.flip_h
	current_paint_flip_v = tile_info.flip_v
	current_paint_wall_align = tile_info.wall_align as TerrainData.WallAlign

	return true


# Helper functions for paint tool rotation/flip
func rotate_paint_cw() -> void:
	current_paint_rotation = ((current_paint_rotation + 1) % 4) as TerrainData.Rotation


func rotate_paint_ccw() -> void:
	current_paint_rotation = ((current_paint_rotation + 3) % 4) as TerrainData.Rotation


func toggle_paint_flip_h() -> void:
	current_paint_flip_h = not current_paint_flip_h


func toggle_paint_flip_v() -> void:
	current_paint_flip_v = not current_paint_flip_v


# Get all cells within the brush area centered on the given cell
# For even brush sizes with corner specified, centers around the corner point
func get_brush_cells(center: Vector2i, data: TerrainData, corner: int = -1) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var half := brush_size / 2
	var is_even := brush_size % 2 == 0

	var start_x: int
	var end_x: int
	var start_z: int
	var end_z: int

	# For odd sizes OR no corner info: use cell-centered logic
	# For even sizes with corner: center around corner point
	if is_even and corner >= 0:
		# Corner-based offset for even brush sizes
		# Corner 0 (NW): brush extends toward negative x and z
		# Corner 1 (NE): brush extends toward positive x and negative z
		# Corner 2 (SE): brush extends toward positive x and z
		# Corner 3 (SW): brush extends toward negative x and positive z
		match corner:
			0:  # NW
				start_x = -half
				end_x = half - 1
				start_z = -half
				end_z = half - 1
			1:  # NE
				start_x = 1 - half
				end_x = half
				start_z = -half
				end_z = half - 1
			2:  # SE
				start_x = 1 - half
				end_x = half
				start_z = 1 - half
				end_z = half
			3:  # SW
				start_x = -half
				end_x = half - 1
				start_z = 1 - half
				end_z = half
			_:
				# Fallback to cell-centered
				start_x = -half
				end_x = brush_size - half - 1
				start_z = -half
				end_z = brush_size - half - 1
	else:
		# Cell-centered logic for odd sizes
		# Odd sizes (1,3,5,7,9): centered, e.g. size 3 = -1 to +1
		start_x = -half
		end_x = brush_size - half - 1
		start_z = -half
		end_z = brush_size - half - 1

	for dz in range(start_z, end_z + 1):
		for dx in range(start_x, end_x + 1):
			var cell := Vector2i(center.x + dx, center.y + dz)
			if data.is_valid_cell(cell.x, cell.y):
				cells.append(cell)
	return cells


func draw_overlay(overlay: Control, terrain: LandscapeTerrain) -> void:
	if _hovered_cell.x < 0 or not terrain or current_tool == Tool.NONE:
		return

	var camera := _last_camera
	if not camera:
		return

	var data := terrain.terrain_data
	if not data:
		return

	var display_cell := _drag_cell if _is_dragging else _hovered_cell
	if display_cell.x < 0:
		return

	# Get all cells in brush area for display
	var brush_cells := _drag_brush_cells if _is_dragging else get_brush_cells(display_cell, data, _brush_corner)

	# Paint tool: show outline only (tile preview is done via shader)
	if current_tool == Tool.PAINT:
		# Don't show outline when surface is locked and hovering a different surface
		if _paint_surface_locked and _hovered_surface != _paint_locked_surface:
			return
		for cell in brush_cells:
			_draw_surface_outline(overlay, camera, terrain, data, cell, _hovered_surface)
		return

	# Flip diagonal tool: highlight top surface and show current diagonal
	if current_tool == Tool.FLIP_DIAGONAL:
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, Color.ORANGE)
			_draw_diagonal_indicator(overlay, camera, terrain, data, cell)
		return

	# Flatten tool: highlight brush area
	if current_tool == Tool.FLATTEN:
		var color := Color.MAGENTA
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, color)
		return

	# Mountain tool: show core area and slope preview
	if current_tool == Tool.MOUNTAIN:
		var core_color := Color.ORANGE if not _is_dragging else Color.GREEN
		var slope_color := Color(0.6, 0.4, 0.2, 0.5)  # Brown for slopes

		# During drag, show all affected cells
		if _is_dragging:
			# Draw slope cells first (behind core)
			for cell in _drag_mountain_all_cells:
				var key := "%d,%d" % [cell.x, cell.y]
				var is_core := false
				for core_cell in _drag_brush_cells:
					if core_cell == cell:
						is_core = true
						break
				if not is_core:
					_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, slope_color)
			# Draw core cells on top
			for cell in _drag_brush_cells:
				_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, core_color)
		else:
			# Just show core brush area when hovering
			for cell in brush_cells:
				_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, core_color)
		return

	# Sculpt tool: draw cell/corner highlight
	var display_corner := _drag_corner if _is_dragging else _hovered_corner
	var display_mode := _drag_mode if _is_dragging else _hover_mode

	# For brush size > 1, force cell mode display
	if brush_size > 1:
		display_mode = HoverMode.CELL

	var color := Color.YELLOW if not _is_dragging else Color.GREEN

	if display_mode == HoverMode.CORNER and display_corner >= 0:
		# Corner mode: highlight the specific corner area (only for single cell)
		_draw_corner_highlight(overlay, camera, terrain, data, display_cell, display_corner, color)
	else:
		# Cell mode: highlight the entire top surface for all brush cells
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, color)


func _draw_surface_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, surface: TerrainData.Surface, color: Color = Color.CYAN) -> void:
	# Get surface corners in world space
	var surface_corners := data.get_surface_world_corners(cell.x, cell.y, surface)

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for corner in surface_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 3.0)

	# Draw filled quad as two triangles (more robust than draw_colored_polygon)
	var fill_color := color
	fill_color.a = 0.25
	var tri1 := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri2 := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	overlay.draw_colored_polygon(tri1, fill_color)
	overlay.draw_colored_polygon(tri2, fill_color)


func _draw_surface_outline(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, surface: TerrainData.Surface, color: Color = Color.CYAN) -> void:
	# Get surface corners in world space
	var surface_corners := data.get_surface_world_corners(cell.x, cell.y, surface)

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for corner in surface_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline only
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 2.0)


func _draw_tile_preview(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, surface: TerrainData.Surface) -> void:
	# Get tileset
	var tile_set := terrain.tile_set
	if not tile_set or not tile_set.atlas_texture:
		return

	if current_paint_tile < 0 or current_paint_tile >= tile_set.get_tile_count():
		return

	# Get surface corners in world space
	var surface_corners := data.get_surface_world_corners(cell.x, cell.y, surface)

	# Transform to screen space
	var screen_points: PackedVector2Array = []
	for corner in surface_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			return
		screen_points.append(camera.unproject_position(world_pos))

	if screen_points.size() != 4:
		return

	# Get tile UV rect (normalized 0-1)
	var uv_rect := tile_set.get_tile_uv_rect(current_paint_tile)

	# Base UVs for quad corners: NW, NE, SE, SW
	var base_uvs: Array[Vector2] = [
		uv_rect.position,                                          # NW (top-left)
		Vector2(uv_rect.end.x, uv_rect.position.y),               # NE (top-right)
		uv_rect.end,                                               # SE (bottom-right)
		Vector2(uv_rect.position.x, uv_rect.end.y),               # SW (bottom-left)
	]

	# Apply rotation (rotate UV indices)
	var rotation_offset := current_paint_rotation as int
	var rotated_uvs: Array[Vector2] = []
	for i in 4:
		rotated_uvs.append(base_uvs[(i + rotation_offset) % 4])

	# Apply flips
	if current_paint_flip_h:
		var temp := rotated_uvs[0]
		rotated_uvs[0] = rotated_uvs[1]
		rotated_uvs[1] = temp
		temp = rotated_uvs[3]
		rotated_uvs[3] = rotated_uvs[2]
		rotated_uvs[2] = temp

	if current_paint_flip_v:
		var temp := rotated_uvs[0]
		rotated_uvs[0] = rotated_uvs[3]
		rotated_uvs[3] = temp
		temp = rotated_uvs[1]
		rotated_uvs[1] = rotated_uvs[2]
		rotated_uvs[2] = temp

	# Convert to PackedVector2Array for draw_polygon
	var uvs := PackedVector2Array(rotated_uvs)

	# Draw textured quad as two triangles
	var colors := PackedColorArray([Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.7)])

	var tri1_points := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri1_uvs := PackedVector2Array([uvs[0], uvs[1], uvs[2]])
	overlay.draw_polygon(tri1_points, colors, tri1_uvs, tile_set.atlas_texture)

	var tri2_points := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	var tri2_uvs := PackedVector2Array([uvs[0], uvs[2], uvs[3]])
	overlay.draw_polygon(tri2_points, colors, tri2_uvs, tile_set.atlas_texture)


func _draw_diagonal_indicator(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i) -> void:
	# Get top corners in world space
	var top_corners := data.get_top_world_corners(cell.x, cell.y)
	var nw := top_corners[0]
	var ne := top_corners[1]
	var se := top_corners[2]
	var sw := top_corners[3]

	# Determine which diagonal is used (same logic as mesh builder)
	var diag1_diff := absf(nw.y - se.y)
	var diag2_diff := absf(ne.y - sw.y)
	var use_nw_se := diag1_diff <= diag2_diff

	# Apply flip flag
	if data.get_diagonal_flip(cell.x, cell.y):
		use_nw_se = not use_nw_se

	# Get the two corners of the current diagonal
	var corner1: Vector3
	var corner2: Vector3
	if use_nw_se:
		corner1 = nw
		corner2 = se
	else:
		corner1 = ne
		corner2 = sw

	# Transform to screen space
	var world1 := terrain.to_global(corner1)
	var world2 := terrain.to_global(corner2)

	if camera.is_position_behind(world1) or camera.is_position_behind(world2):
		return

	var screen1 := camera.unproject_position(world1)
	var screen2 := camera.unproject_position(world2)

	# Draw the diagonal line
	overlay.draw_line(screen1, screen2, Color.ORANGE, 3.0)


func _draw_corner_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, corner: int, color: Color) -> void:
	# Get top corners in world space
	var top_corners := data.get_top_world_corners(cell.x, cell.y)

	# Calculate corner area (quadrilateral from corner to midpoints of adjacent edges)
	var corner_pos := top_corners[corner]
	var prev_corner := top_corners[(corner + 3) % 4]
	var next_corner := top_corners[(corner + 1) % 4]
	var center := (top_corners[0] + top_corners[1] + top_corners[2] + top_corners[3]) / 4.0

	# Create a smaller quad around the corner
	var mid_to_prev := (corner_pos + prev_corner) / 2.0
	var mid_to_next := (corner_pos + next_corner) / 2.0
	var mid_to_center := (corner_pos + center) / 2.0

	var world_points: Array[Vector3] = [corner_pos, mid_to_next, mid_to_center, mid_to_prev]

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for point in world_points:
		var world_pos := terrain.to_global(point)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 3.0)

	# Draw filled quad as two triangles (more robust than draw_colored_polygon)
	var fill_color := color
	fill_color.a = 0.35
	var tri1 := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri2 := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	overlay.draw_colored_polygon(tri1, fill_color)
	overlay.draw_colored_polygon(tri2, fill_color)

	# Draw corner circle
	overlay.draw_circle(screen_points[0], 6.0, color)
