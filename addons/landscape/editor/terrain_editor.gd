@tool
class_name TerrainEditor
extends RefCounted

enum Tool { NONE, SCULPT, PAINT }
enum HoverMode { CELL, CORNER }

signal tool_changed(new_tool: Tool)
signal hover_changed(cell: Vector2i, corner: int, mode: int)
signal height_changed(height: float, corner: int, mode: int)

var editor_interface: EditorInterface
var undo_redo: EditorUndoRedoManager

var current_tool: Tool = Tool.NONE:
	set(value):
		current_tool = value
		tool_changed.emit(value)
		if value == Tool.NONE:
			_clear_hover()

var current_texture: int = 0

# Corner detection threshold - distance from corner as fraction of cell size
const CORNER_THRESHOLD := 0.45

var _terrain: LandscapeTerrain
var _hovered_cell: Vector2i = Vector2i(-1, -1)
var _hovered_corner: int = -1
var _hover_mode: HoverMode = HoverMode.CELL

# Drag state
var _is_dragging: bool = false
var _drag_cell: Vector2i = Vector2i(-1, -1)
var _drag_corner: int = -1
var _drag_mode: HoverMode = HoverMode.CELL
var _drag_original_corners: Array[int] = []
var _drag_current_delta: int = 0
var _drag_start_mouse_y: float = 0.0
var _drag_world_pos: Vector3 = Vector3.ZERO  # World position of drag point for scale calculation


func set_terrain(terrain: LandscapeTerrain) -> void:
	_terrain = terrain
	_clear_hover()
	_cancel_drag()


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

	if current_tool == Tool.NONE:
		return false

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_dragging:
			_update_drag(camera, motion.position)
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
		elif mb.button_index == MOUSE_BUTTON_RIGHT and _is_dragging:
			_cancel_drag()
			return true

	return false


func _start_drag(camera: Camera3D, mouse_pos: Vector2) -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	if current_tool != Tool.SCULPT:
		return false

	_is_dragging = true
	_drag_cell = _hovered_cell
	_drag_corner = _hovered_corner
	_drag_mode = _hover_mode
	_drag_current_delta = 0
	_drag_start_mouse_y = mouse_pos.y

	# Store original heights
	_drag_original_corners = []
	var corners := data.get_top_corners(_drag_cell.x, _drag_cell.y)
	for c in corners:
		_drag_original_corners.append(c)

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
		var corner_target := _drag_original_corners[_drag_corner] + _drag_current_delta
		var new_corners := _calculate_dragged_corners(_drag_corner, corner_target, data.max_slope_steps)
		data.set_top_corners(_drag_cell.x, _drag_cell.y, new_corners)
		var world_height := data.steps_to_world(new_corners[_drag_corner])
		height_changed.emit(world_height, _drag_corner, _drag_mode)
	else:
		# Raise/lower all corners
		var new_corners: Array[int] = []
		for i in 4:
			new_corners.append(_drag_original_corners[i] + _drag_current_delta)
		data.set_top_corners(_drag_cell.x, _drag_cell.y, new_corners)
		var avg_height := 0.0
		for c in new_corners:
			avg_height += data.steps_to_world(c)
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
	var final_corners := data.get_top_corners(_drag_cell.x, _drag_cell.y)

	undo_redo.create_action("Sculpt Terrain")
	undo_redo.add_do_method(data, "set_top_corners", _drag_cell.x, _drag_cell.y, final_corners)
	undo_redo.add_undo_method(data, "set_top_corners", _drag_cell.x, _drag_cell.y, _drag_original_corners)
	undo_redo.commit_action(false)  # Don't execute, already applied

	_is_dragging = false


func _cancel_drag() -> void:
	if not _is_dragging or not _terrain:
		_is_dragging = false
		return

	var data := _terrain.terrain_data
	if data and _drag_cell.x >= 0:
		# Restore original heights
		data.set_top_corners(_drag_cell.x, _drag_cell.y, _drag_original_corners)

	_is_dragging = false


func _update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
	if _is_dragging:
		return

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	var hit := _raycast_terrain(ray_origin, ray_dir)
	if hit:
		var old_cell := _hovered_cell
		var old_corner := _hovered_corner
		var old_mode := _hover_mode

		_hovered_cell = _terrain.world_to_cell(hit)

		# Calculate position within cell to determine corner vs center
		var local_pos := _terrain.to_local(hit)
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
	else:
		if _hovered_cell.x >= 0:
			_hovered_cell = Vector2i(-1, -1)
			_hovered_corner = -1
			_hover_mode = HoverMode.CELL
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)


func _raycast_terrain(origin: Vector3, direction: Vector3) -> Variant:
	if not _terrain or not _terrain.terrain_data:
		return null

	var space_state := _terrain.get_world_3d().direct_space_state
	var end := origin + direction * 1000.0

	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return null

	# Check if we hit the terrain
	var collider := result.get("collider")
	if collider and collider.get_parent() == _terrain:
		return result.get("position")

	return null


func _paint_cell(data: TerrainData, x: int, z: int) -> bool:
	var old_texture := data.get_texture_index(x, z)
	if old_texture == current_texture:
		return false

	undo_redo.create_action("Paint Terrain")
	undo_redo.add_do_method(data, "set_texture_index", x, z, current_texture)
	undo_redo.add_undo_method(data, "set_texture_index", x, z, old_texture)
	undo_redo.commit_action()

	return true


func draw_overlay(overlay: Control, terrain: LandscapeTerrain) -> void:
	if _hovered_cell.x < 0 or not terrain or current_tool == Tool.NONE:
		return

	# Get the viewport camera
	var viewport := overlay.get_viewport()
	if not viewport:
		return

	var camera := viewport.get_camera_3d()
	if not camera:
		return

	var data := terrain.terrain_data
	if not data:
		return

	# Use drag cell if dragging, otherwise hovered cell
	var display_cell := _drag_cell if _is_dragging else _hovered_cell
	var display_corner := _drag_corner if _is_dragging else _hovered_corner
	var display_mode := _drag_mode if _is_dragging else _hover_mode

	if display_cell.x < 0:
		return

	# Get cell corners in world space
	var top_corners := data.get_top_world_corners(display_cell.x, display_cell.y)

	# Transform to screen space and draw
	var screen_points: Array[Vector2] = []
	for corner in top_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			return
		screen_points.append(camera.unproject_position(world_pos))

	# Draw cell outline
	var color := Color.YELLOW if not _is_dragging else Color.GREEN
	color.a = 0.8

	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], color, 2.0)

	# Highlight hovered corner when in corner mode
	if display_mode == HoverMode.CORNER and display_corner >= 0:
		var corner_pos := screen_points[display_corner]
		overlay.draw_circle(corner_pos, 8.0, Color.RED if not _is_dragging else Color.GREEN)
