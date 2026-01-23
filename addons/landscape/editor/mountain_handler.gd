@tool
class_name MountainHandler
extends RefCounted

## Handles mountain tool operations for the terrain editor.
## Creates hills and valleys with smooth sloped edges using BFS propagation.

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_dragging = true
	_editor._drag_cell = _editor._hovered_cell
	_editor._drag_corner = _editor._hovered_corner
	_editor._drag_current_delta = 0
	_editor._drag_start_mouse_y = mouse_pos.y

	# Mountain tool always uses cell mode
	_editor._drag_editing_floor = false
	_editor._drag_mode = TerrainEditor.HoverMode.CELL

	# Store original heights for center cell
	_editor._drag_original_corners = []
	var corners := data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	for c in corners:
		_editor._drag_original_corners.append(c)

	# Store original heights for all brush cells and find min/max
	_editor._drag_brush_cells = _editor.get_brush_cells(_editor._drag_cell, data, _editor._brush_corner)
	_editor._drag_brush_original_corners.clear()
	_editor._drag_brush_min_height = 999999
	_editor._drag_brush_max_height = -999999
	for cell in _editor._drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		var cell_corners := data.get_top_corners(cell.x, cell.y)
		_editor._drag_brush_original_corners[key] = cell_corners.duplicate()
		for c in cell_corners:
			_editor._drag_brush_min_height = mini(_editor._drag_brush_min_height, c)
			_editor._drag_brush_max_height = maxi(_editor._drag_brush_max_height, c)

	# Store surrounding cells that may be affected by slopes
	_editor._drag_mountain_original_corners.clear()
	_editor._drag_mountain_all_cells.clear()
	_editor._drag_mountain_corner_distances.clear()

	# Corner offsets for precomputation
	var corner_offsets: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]

	# Store core brush cells (use Vector2i keys for performance)
	var brush_set: Dictionary = {}
	for cell in _editor._drag_brush_cells:
		_editor._drag_mountain_all_cells.append(cell)
		_editor._drag_mountain_original_corners[cell] = _editor._drag_brush_original_corners["%d,%d" % [cell.x, cell.y]].duplicate()
		brush_set[cell] = true

	# Expand outward to collect slope cells (up to 9 rings for max height change)
	var max_rings := 9
	var current_ring := _editor._drag_brush_cells.duplicate()
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
						if not _editor._drag_mountain_original_corners.has(neighbor):
							_editor._drag_mountain_all_cells.append(neighbor)
							_editor._drag_mountain_original_corners[neighbor] = data.get_top_corners(neighbor.x, neighbor.y).duplicate()
							next_ring.append(neighbor)
		current_ring = next_ring
		if current_ring.is_empty():
			break

	# Precompute corner distances using BFS
	var valid_corners: Dictionary = {}
	for cell in _editor._drag_mountain_all_cells:
		for offset in corner_offsets:
			valid_corners[Vector2i(cell.x + offset.x, cell.y + offset.y)] = true

	var queue: Array[Vector2i] = []
	for cell in _editor._drag_brush_cells:
		for offset in corner_offsets:
			var corner_pos := Vector2i(cell.x + offset.x, cell.y + offset.y)
			if not _editor._drag_mountain_corner_distances.has(corner_pos):
				_editor._drag_mountain_corner_distances[corner_pos] = 0
				queue.append(corner_pos)

	var directions: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var head := 0
	while head < queue.size():
		var pos := queue[head]
		head += 1
		var dist: int = _editor._drag_mountain_corner_distances[pos]
		for dir in directions:
			var neighbor := Vector2i(pos.x + dir.x, pos.y + dir.y)
			if valid_corners.has(neighbor) and not _editor._drag_mountain_corner_distances.has(neighbor):
				_editor._drag_mountain_corner_distances[neighbor] = dist + 1
				queue.append(neighbor)

	# Calculate world position for scale reference
	_calculate_drag_world_pos(data)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Calculate screen-space scale: how many pixels = 1 world unit at the drag point
	var point_above := _editor._drag_world_pos + Vector3(0, 1, 0)
	var screen_drag_pos := camera.unproject_position(_editor._drag_world_pos)
	var screen_above := camera.unproject_position(point_above)
	var pixels_per_unit := screen_drag_pos.y - screen_above.y  # Y is inverted in screen space

	if abs(pixels_per_unit) < 0.001:
		return

	# Calculate mouse delta in world units
	var mouse_delta_pixels := _editor._drag_start_mouse_y - mouse_pos.y
	var mouse_delta_world := mouse_delta_pixels / pixels_per_unit

	# Convert to height steps
	var height_step := data.height_step
	var new_delta := int(round(mouse_delta_world / height_step))

	if new_delta == _editor._drag_current_delta:
		return

	_editor._drag_current_delta = new_delta

	# Mountain tool: raise/lower core with slopes radiating outward
	_apply_mountain_heights(data, _editor._drag_current_delta)
	var world_height := data.steps_to_world(_editor._drag_brush_min_height + _editor._drag_current_delta)
	_editor.height_changed.emit(world_height, -1, _editor._drag_mode)


func finish_drag() -> void:
	if not _editor._is_dragging or not _editor._terrain:
		_editor._is_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if not data or _editor._drag_current_delta == 0:
		_editor._is_dragging = false
		return

	# Create undo/redo action for the final change
	_editor.undo_redo.create_action("Mountain Terrain")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")

	for cell in _editor._drag_mountain_all_cells:
		if not _editor._drag_mountain_original_corners.has(cell):
			continue
		var original: Array = _editor._drag_mountain_original_corners[cell]

		var final_corners := data.get_top_corners(cell.x, cell.y)
		var original_typed: Array[int] = []
		for c in original:
			original_typed.append(c)
		# Only add undo if there was a change
		if original_typed != final_corners:
			_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, final_corners)
			_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_typed)

	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action(false)  # Don't execute, already applied

	_editor._is_dragging = false


func cancel_drag() -> void:
	if not _editor._is_dragging or not _editor._terrain:
		_editor._is_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if data:
		data.begin_batch()
		for cell in _editor._drag_mountain_all_cells:
			if not _editor._drag_mountain_original_corners.has(cell):
				continue
			var original: Array = _editor._drag_mountain_original_corners[cell]

			var original_typed: Array[int] = []
			for c in original:
				original_typed.append(c)
			data.set_top_corners(cell.x, cell.y, original_typed)
		data.end_batch()

	_editor._is_dragging = false


func _calculate_drag_world_pos(data: TerrainData) -> void:
	var cell_size := data.cell_size
	var avg_height := 0.0
	for c in _editor._drag_original_corners:
		avg_height += data.steps_to_world(c)
	avg_height /= 4.0
	var local_pos := Vector3(
		(_editor._drag_cell.x + 0.5) * cell_size,
		avg_height,
		(_editor._drag_cell.y + 0.5) * cell_size
	)
	_editor._drag_world_pos = _editor._terrain.to_global(local_pos)


func _apply_mountain_heights(data: TerrainData, delta: int) -> void:
	var max_slope := data.max_slope_steps

	# Calculate reference height for the peak/valley
	var peak_height: int = _editor._drag_brush_max_height + delta if delta >= 0 else _editor._drag_brush_min_height + delta

	# Batch updates to avoid emitting data_changed for each cell
	data.begin_batch()

	# Apply heights to cells using precomputed corner distances
	for cell in _editor._drag_mountain_all_cells:
		var original: Array = _editor._drag_mountain_original_corners[cell]
		var cx := cell.x
		var cy := cell.y

		var d0: int = _editor._drag_mountain_corner_distances.get(Vector2i(cx, cy), 0)
		var d1: int = _editor._drag_mountain_corner_distances.get(Vector2i(cx + 1, cy), 0)
		var d2: int = _editor._drag_mountain_corner_distances.get(Vector2i(cx + 1, cy + 1), 0)
		var d3: int = _editor._drag_mountain_corner_distances.get(Vector2i(cx, cy + 1), 0)

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
				maxi(mini(o0, peak_height + d0 * max_slope), 0),
				maxi(mini(o1, peak_height + d1 * max_slope), 0),
				maxi(mini(o2, peak_height + d2 * max_slope), 0),
				maxi(mini(o3, peak_height + d3 * max_slope), 0),
			])

	data.end_batch()
