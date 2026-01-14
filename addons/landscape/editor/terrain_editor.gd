@tool
class_name TerrainEditor
extends RefCounted

enum Tool { NONE, SCULPT, PAINT, FLIP_DIAGONAL, FLATTEN }
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
		current_tool = value
		tool_changed.emit(value)
		if value == Tool.NONE:
			_clear_hover()

# Paint tool state
var current_paint_tile: int = 0:
	set(value):
		current_paint_tile = value
		paint_state_changed.emit()

var current_paint_surface: TerrainData.Surface = TerrainData.Surface.TOP:
	set(value):
		current_paint_surface = value
		paint_state_changed.emit()

var current_paint_rotation: TerrainData.Rotation = TerrainData.Rotation.ROT_0:
	set(value):
		current_paint_rotation = value
		paint_state_changed.emit()

var current_paint_flip_h: bool = false:
	set(value):
		current_paint_flip_h = value
		paint_state_changed.emit()

var current_paint_flip_v: bool = false:
	set(value):
		current_paint_flip_v = value
		paint_state_changed.emit()

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

# Paint drag state
var _is_paint_dragging: bool = false
var _last_painted_cell: Vector2i = Vector2i(-1, -1)
var _last_painted_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _painted_cells_this_drag: Dictionary = {}  # Tracks cells painted during current drag


func set_terrain(terrain: LandscapeTerrain) -> void:
	_terrain = terrain
	_clear_hover()
	_cancel_drag()


func get_hovered_surface() -> TerrainData.Surface:
	return _hovered_surface


func _clear_hover() -> void:
	if _hovered_cell.x >= 0:
		_hovered_cell = Vector2i(-1, -1)
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)


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

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_dragging:
			_update_drag(camera, motion.position)
			return true
		elif _is_paint_dragging:
			_update_paint_drag(camera, motion.position)
			return true
		else:
			_update_hover(camera, motion.position)
			return false

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _start_drag(camera, mb.position)
			else:
				if _is_dragging:
					_finish_drag()
					return true
				elif _is_paint_dragging:
					_finish_paint_drag()
					return true
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if _is_dragging:
				_cancel_drag()
				return true
			elif _is_paint_dragging:
				_finish_paint_drag()
				return true

	return false


func _start_drag(camera: Camera3D, mouse_pos: Vector2) -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	# Handle paint tool
	if current_tool == Tool.PAINT:
		_painted_cells_this_drag.clear()
		var painted := _paint_brush_area(data, _hovered_cell, _hovered_surface)
		if painted:
			_is_paint_dragging = true
			_last_painted_cell = _hovered_cell
			_last_painted_surface = _hovered_surface
		return painted

	# Handle flip diagonal tool
	if current_tool == Tool.FLIP_DIAGONAL:
		_flip_diagonal_brush_area(data, _hovered_cell)
		return true

	# Handle flatten tool
	if current_tool == Tool.FLATTEN:
		# Get target height from the hovered corner
		var target_height: int
		var corners := data.get_top_corners(_hovered_cell.x, _hovered_cell.y)
		if _hover_mode == HoverMode.CORNER and _hovered_corner >= 0:
			target_height = corners[_hovered_corner]
		else:
			# Use average height if clicking cell center
			target_height = int(round(float(corners[0] + corners[1] + corners[2] + corners[3]) / 4.0))
		_flatten_brush_area(data, _hovered_cell, target_height)
		return true

	if current_tool != Tool.SCULPT:
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

	# Store original heights for all brush cells
	_drag_brush_cells = get_brush_cells(_drag_cell, data)
	_drag_brush_original_corners.clear()
	for cell in _drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		var cell_corners := data.get_top_corners(cell.x, cell.y)
		_drag_brush_original_corners[key] = cell_corners.duplicate()

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
	if _drag_mode == HoverMode.CORNER:
		# Single corner mode (only for brush_size == 0)
		var corner_target := _drag_original_corners[_drag_corner] + _drag_current_delta
		var new_corners := _calculate_dragged_corners(_drag_corner, corner_target, data.max_slope_steps)
		data.set_top_corners(_drag_cell.x, _drag_cell.y, new_corners)
		var world_height := data.steps_to_world(new_corners[_drag_corner])
		height_changed.emit(world_height, _drag_corner, _drag_mode)
	else:
		# Cell mode - raise/lower all corners of all brush cells
		for cell in _drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			var original: Array = _drag_brush_original_corners[key]
			var new_corners: Array[int] = []
			for i in 4:
				new_corners.append(original[i] + _drag_current_delta)
			data.set_top_corners(cell.x, cell.y, new_corners)

		# Report height for center cell
		var avg_height := 0.0
		for c in _drag_original_corners:
			avg_height += data.steps_to_world(c + _drag_current_delta)
		avg_height /= 4.0
		height_changed.emit(avg_height, -1, _drag_mode)


func _calculate_dragged_corners(dragged_corner: int, target_height: int, max_slope: int) -> Array[int]:
	# Start with original corners
	var corners: Array[int] = []
	for c in _drag_original_corners:
		corners.append(c)

	# Set the dragged corner to target
	corners[dragged_corner] = target_height

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

	# Constrain adjacent corners to dragged corner
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

	return corners


func _finish_drag() -> void:
	if not _is_dragging or not _terrain:
		_is_dragging = false
		return

	var data := _terrain.terrain_data
	if not data or _drag_current_delta == 0:
		_is_dragging = false
		return

	# Create undo/redo action for the final change
	undo_redo.create_action("Sculpt Terrain")

	for cell in _drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		var original: Array = _drag_brush_original_corners[key]
		var final_corners := data.get_top_corners(cell.x, cell.y)
		var original_typed: Array[int] = []
		for c in original:
			original_typed.append(c)
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
		# Restore original heights for all brush cells
		for cell in _drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			if _drag_brush_original_corners.has(key):
				var original: Array = _drag_brush_original_corners[key]
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

	# Only paint if cell or surface changed
	if _hovered_cell == _last_painted_cell and _hovered_surface == _last_painted_surface:
		return

	_paint_brush_area(data, _hovered_cell, _hovered_surface)
	_last_painted_cell = _hovered_cell
	_last_painted_surface = _hovered_surface


func _finish_paint_drag() -> void:
	_is_paint_dragging = false
	_last_painted_cell = Vector2i(-1, -1)


func _update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
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

	# For paint and flip diagonal tools, we don't need corner detection
	if current_tool == Tool.PAINT or current_tool == Tool.FLIP_DIAGONAL:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		if old_cell != _hovered_cell or old_surface != _hovered_surface:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		return

	# Calculate position within cell to determine corner vs center (sculpt tool)
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

	# Find closest corner
	var min_dist := corner_dists[0]
	var closest_corner := 0
	for i in range(1, 4):
		if corner_dists[i] < min_dist:
			min_dist = corner_dists[i]
			closest_corner = i

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


func _flatten_brush_area(data: TerrainData, center: Vector2i, target_height: int) -> void:
	var brush_cells := get_brush_cells(center, data)

	if brush_cells.is_empty():
		return

	# Collect cells that need to be changed
	var changes: Array[Dictionary] = []
	for cell in brush_cells:
		var old_corners := data.get_top_corners(cell.x, cell.y)
		var new_corners: Array[int] = [target_height, target_height, target_height, target_height]

		# Check if there's actually a change
		if old_corners[0] != target_height or old_corners[1] != target_height or \
		   old_corners[2] != target_height or old_corners[3] != target_height:
			changes.append({
				"x": cell.x,
				"z": cell.y,
				"old": old_corners,
				"new": new_corners
			})

	if changes.is_empty():
		return

	# Create single undo action for all cells
	undo_redo.create_action("Flatten Terrain")
	for change in changes:
		undo_redo.add_do_method(data, "set_top_corners", change.x, change.z, change.new)
		undo_redo.add_undo_method(data, "set_top_corners", change.x, change.z, change.old)
	undo_redo.commit_action()


func _flip_diagonal_brush_area(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := get_brush_cells(center, data)

	if brush_cells.is_empty():
		return

	# Create single undo action for all cells
	undo_redo.create_action("Flip Diagonal")
	for cell in brush_cells:
		var old_flip := data.get_diagonal_flip(cell.x, cell.y)
		var new_flip := not old_flip
		undo_redo.add_do_method(data, "set_diagonal_flip", cell.x, cell.y, new_flip)
		undo_redo.add_undo_method(data, "set_diagonal_flip", cell.x, cell.y, old_flip)
	undo_redo.commit_action()


func _paint_brush_area(data: TerrainData, center: Vector2i, surface: TerrainData.Surface) -> bool:
	var brush_cells := get_brush_cells(center, data)
	var new_packed := TerrainData.pack_tile(current_paint_tile, current_paint_rotation, current_paint_flip_h, current_paint_flip_v)

	# Collect cells that need to be painted (not already painted this drag, and different value)
	var cells_to_paint: Array[Dictionary] = []
	for cell in brush_cells:
		var key := "%d,%d,%d" % [cell.x, cell.y, surface]
		if _painted_cells_this_drag.has(key):
			continue

		var old_packed := data.get_tile_packed(cell.x, cell.y, surface)
		if old_packed != new_packed:
			cells_to_paint.append({
				"x": cell.x,
				"z": cell.y,
				"old": old_packed,
				"new": new_packed
			})
		_painted_cells_this_drag[key] = true

	if cells_to_paint.is_empty():
		return brush_cells.size() > 0  # Return true if we have valid brush area

	# Create single undo action for all cells
	undo_redo.create_action("Paint Terrain Tiles")
	for cell_data in cells_to_paint:
		undo_redo.add_do_method(data, "set_tile_packed", cell_data.x, cell_data.z, surface, cell_data.new)
		undo_redo.add_undo_method(data, "set_tile_packed", cell_data.x, cell_data.z, surface, cell_data.old)
	undo_redo.commit_action()

	return true


func _paint_cell(data: TerrainData, x: int, z: int, surface: TerrainData.Surface) -> bool:
	var old_packed := data.get_tile_packed(x, z, surface)
	var new_packed := TerrainData.pack_tile(current_paint_tile, current_paint_rotation, current_paint_flip_h, current_paint_flip_v)

	if old_packed == new_packed:
		return false

	undo_redo.create_action("Paint Terrain Tile")
	undo_redo.add_do_method(data, "set_tile_packed", x, z, surface, new_packed)
	undo_redo.add_undo_method(data, "set_tile_packed", x, z, surface, old_packed)
	undo_redo.commit_action()

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
func get_brush_cells(center: Vector2i, data: TerrainData) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	# Calculate offset range based on brush size
	# Odd sizes (1,3,5,7,9): centered, e.g. size 3 = -1 to +1
	# Even sizes (2,4,6,8): offset toward negative, e.g. size 2 = -1 to 0, size 4 = -2 to +1
	var half := brush_size / 2
	var start := -half
	var end := brush_size - half - 1

	for dz in range(start, end + 1):
		for dx in range(start, end + 1):
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
	var brush_cells := _drag_brush_cells if _is_dragging else get_brush_cells(display_cell, data)

	# Paint tool: highlight the specific surface face for all brush cells
	if current_tool == Tool.PAINT:
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, _hovered_surface)
		return

	# Flip diagonal tool: highlight top surface and show current diagonal
	if current_tool == Tool.FLIP_DIAGONAL:
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, Color.ORANGE)
			_draw_diagonal_indicator(overlay, camera, terrain, data, cell)
		return

	# Flatten tool: highlight brush area with corner indicator
	if current_tool == Tool.FLATTEN:
		var color := Color.MAGENTA
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, color)
		# Show corner indicator on hovered cell if near a corner
		if _hover_mode == HoverMode.CORNER and _hovered_corner >= 0:
			_draw_corner_highlight(overlay, camera, terrain, data, display_cell, _hovered_corner, Color.WHITE)
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
