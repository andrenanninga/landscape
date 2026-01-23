@tool
class_name SculptHandler
extends RefCounted

## Handles sculpt tool operations for the terrain editor.
## Manages terrain sculpting including corner mode, cell mode, and floor editing.

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_dragging = true
	_editor._drag_cell = _editor._hovered_cell
	_editor._drag_corner = _editor._hovered_corner
	_editor._drag_current_delta = 0
	_editor._drag_start_mouse_y = mouse_pos.y

	# For brush size > 1, force cell mode (corner mode doesn't make sense for multi-cell)
	# But allow floor editing with larger brushes
	_editor._drag_editing_floor = _editor._hover_editing_floor
	if _editor.brush_size > 1:
		_editor._drag_mode = TerrainEditor.HoverMode.CELL
	else:
		_editor._drag_mode = _editor._hover_mode

	# Store original heights for center cell
	_editor._drag_original_corners = []
	var corners := data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	for c in corners:
		_editor._drag_original_corners.append(c)
	_editor._drag_sticky_corners = _editor._drag_original_corners.duplicate()

	# Store floor original heights if editing floor (for single corner mode)
	if _editor._drag_editing_floor:
		_editor._drag_floor_original_corners = []
		var floor_corners := data.get_floor_corners(_editor._drag_cell.x, _editor._drag_cell.y)
		for c in floor_corners:
			_editor._drag_floor_original_corners.append(c)
		_editor._drag_floor_sticky_corners = _editor._drag_floor_original_corners.duplicate()

	# Store original heights for all brush cells and find min/max
	_editor._drag_brush_cells = _editor.get_brush_cells(_editor._drag_cell, data, _editor._brush_corner)
	_editor._drag_brush_original_corners.clear()
	_editor._drag_brush_floor_original_corners.clear()
	_editor._drag_brush_min_height = 999999
	_editor._drag_brush_max_height = -999999
	_editor._drag_floor_brush_min_height = 999999
	_editor._drag_floor_brush_max_height = -999999
	for cell in _editor._drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		var cell_corners := data.get_top_corners(cell.x, cell.y)
		_editor._drag_brush_original_corners[key] = cell_corners.duplicate()
		for c in cell_corners:
			_editor._drag_brush_min_height = mini(_editor._drag_brush_min_height, c)
			_editor._drag_brush_max_height = maxi(_editor._drag_brush_max_height, c)
		# Always store floor corners for undo/redo (top editing may push floor down)
		var cell_floor_corners := data.get_floor_corners(cell.x, cell.y)
		_editor._drag_brush_floor_original_corners[key] = cell_floor_corners.duplicate()
		for c in cell_floor_corners:
			_editor._drag_floor_brush_min_height = mini(_editor._drag_floor_brush_min_height, c)
			_editor._drag_floor_brush_max_height = maxi(_editor._drag_floor_brush_max_height, c)

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

	# Apply the new heights directly (no undo yet)
	if _editor._drag_mode == TerrainEditor.HoverMode.FLOOR_CORNER:
		# Floor corner mode - edit floor corners
		var corner_target := _editor._drag_floor_original_corners[_editor._drag_corner] + _editor._drag_current_delta
		var new_corners := _calculate_floor_dragged_corners(_editor._drag_corner, corner_target, data)
		data.set_floor_corners(_editor._drag_cell.x, _editor._drag_cell.y, new_corners)
		var world_height := data.steps_to_world(new_corners[_editor._drag_corner])
		_editor.height_changed.emit(world_height, _editor._drag_corner, _editor._drag_mode)
	elif _editor._drag_mode == TerrainEditor.HoverMode.CORNER:
		# Single corner mode (only for brush_size == 0)
		var corner_target := _editor._drag_original_corners[_editor._drag_corner] + _editor._drag_current_delta
		var new_corners := _calculate_dragged_corners(_editor._drag_corner, corner_target, data.max_slope_steps)
		# Enforce minimum height >= 0
		for i in 4:
			new_corners[i] = maxi(new_corners[i], 0)
		data.set_top_corners(_editor._drag_cell.x, _editor._drag_cell.y, new_corners)
		# Push floor down if top goes below floor
		var floor_corners := data.get_floor_corners(_editor._drag_cell.x, _editor._drag_cell.y)
		var floor_changed := false
		var new_floor: Array[int] = []
		for i in 4:
			if floor_corners[i] > new_corners[i]:
				new_floor.append(new_corners[i])
				floor_changed = true
			else:
				new_floor.append(floor_corners[i])
		if floor_changed:
			data.set_floor_corners(_editor._drag_cell.x, _editor._drag_cell.y, new_floor)
		var world_height := data.steps_to_world(new_corners[_editor._drag_corner])
		_editor.height_changed.emit(world_height, _editor._drag_corner, _editor._drag_mode)
	elif _editor.brush_size == 1:
		# Single cell mode - uniform raise/lower of all corners
		data.begin_batch()
		for cell in _editor._drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			if _editor._drag_editing_floor:
				var original: Array = _editor._drag_brush_floor_original_corners[key]
				var top_corners := data.get_top_corners(cell.x, cell.y)
				var new_corners: Array[int] = []
				for i in 4:
					# Constraint: floor cannot exceed top and must be >= 0
					var target: int = int(original[i]) + _editor._drag_current_delta
					new_corners.append(mini(maxi(target, 0), top_corners[i]))
				data.set_floor_corners(cell.x, cell.y, new_corners)
			else:
				var original: Array = _editor._drag_brush_original_corners[key]
				var new_corners: Array[int] = []
				for i in 4:
					# Enforce minimum height >= 0
					new_corners.append(maxi(original[i] + _editor._drag_current_delta, 0))
				data.set_top_corners(cell.x, cell.y, new_corners)
				# Push floor down if top goes below floor
				var floor_corners := data.get_floor_corners(cell.x, cell.y)
				var floor_changed := false
				var new_floor: Array[int] = []
				for i in 4:
					if floor_corners[i] > new_corners[i]:
						new_floor.append(new_corners[i])
						floor_changed = true
					else:
						new_floor.append(floor_corners[i])
				if floor_changed:
					data.set_floor_corners(cell.x, cell.y, new_floor)
		data.end_batch()

		# Report height for center cell
		var avg_height := 0.0
		var original_corners: Array = _editor._drag_floor_original_corners if _editor._drag_editing_floor else _editor._drag_original_corners
		for c in original_corners:
			avg_height += data.steps_to_world(c + _editor._drag_current_delta)
		avg_height /= 4.0
		_editor.height_changed.emit(avg_height, -1, _editor._drag_mode)
	else:
		# Multi-cell brush - leveling sculpt
		# When raising: bring low corners up toward target (min + delta)
		# When lowering: bring high corners down toward target (max + delta)
		var target_height: int
		if _editor._drag_editing_floor:
			if _editor._drag_current_delta >= 0:
				target_height = _editor._drag_floor_brush_min_height + _editor._drag_current_delta
			else:
				target_height = _editor._drag_floor_brush_max_height + _editor._drag_current_delta
		else:
			if _editor._drag_current_delta >= 0:
				target_height = _editor._drag_brush_min_height + _editor._drag_current_delta
			else:
				target_height = _editor._drag_brush_max_height + _editor._drag_current_delta

		data.begin_batch()
		for cell in _editor._drag_brush_cells:
			if _editor._drag_editing_floor:
				var current_corners := data.get_floor_corners(cell.x, cell.y)
				var top_corners := data.get_top_corners(cell.x, cell.y)
				var new_corners: Array[int] = []
				for i in 4:
					var corner_target: int
					if _editor._drag_current_delta >= 0:
						corner_target = maxi(current_corners[i], target_height)
					else:
						corner_target = mini(current_corners[i], target_height)
					# Constraint: floor cannot exceed top and must be >= 0
					new_corners.append(mini(maxi(corner_target, 0), top_corners[i]))
				data.set_floor_corners(cell.x, cell.y, new_corners)
			else:
				var current_corners := data.get_top_corners(cell.x, cell.y)
				var new_corners: Array[int] = []
				for i in 4:
					if _editor._drag_current_delta >= 0:
						# Raising: corners move up toward target, never down
						new_corners.append(maxi(current_corners[i], target_height))
					else:
						# Lowering: corners move down toward target, never up (min 0)
						new_corners.append(maxi(mini(current_corners[i], target_height), 0))
				data.set_top_corners(cell.x, cell.y, new_corners)
				# Push floor down if top goes below floor
				var floor_corners := data.get_floor_corners(cell.x, cell.y)
				var floor_changed := false
				var new_floor: Array[int] = []
				for i in 4:
					if floor_corners[i] > new_corners[i]:
						new_floor.append(new_corners[i])
						floor_changed = true
					else:
						new_floor.append(floor_corners[i])
				if floor_changed:
					data.set_floor_corners(cell.x, cell.y, new_floor)
		data.end_batch()

		# Report target height
		var world_height := data.steps_to_world(target_height)
		_editor.height_changed.emit(world_height, -1, _editor._drag_mode)


func finish_drag() -> void:
	if not _editor._is_dragging or not _editor._terrain:
		_editor._is_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if not data or _editor._drag_current_delta == 0:
		_editor._is_dragging = false
		return

	# Handle floor editing
	if _editor._drag_editing_floor:
		_editor.undo_redo.create_action("Sculpt Floor")
		for cell in _editor._drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			if not _editor._drag_brush_floor_original_corners.has(key):
				continue
			var original: Array = _editor._drag_brush_floor_original_corners[key]
			var final_corners := data.get_floor_corners(cell.x, cell.y)
			var original_typed: Array[int] = []
			for c in original:
				original_typed.append(c)
			if original_typed != final_corners:
				_editor.undo_redo.add_do_method(data, "set_floor_corners", cell.x, cell.y, final_corners)
				_editor.undo_redo.add_undo_method(data, "set_floor_corners", cell.x, cell.y, original_typed)
		_editor.undo_redo.commit_action(false)
		_editor._is_dragging = false
		return

	# Create undo/redo action for the final change
	_editor.undo_redo.create_action("Sculpt Terrain")

	for cell in _editor._drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		if not _editor._drag_brush_original_corners.has(key):
			continue
		var original: Array = _editor._drag_brush_original_corners[key]

		var final_corners := data.get_top_corners(cell.x, cell.y)
		var original_typed: Array[int] = []
		for c in original:
			original_typed.append(c)
		# Only add undo if there was a change
		if original_typed != final_corners:
			_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, final_corners)
			_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_typed)

	# Also track floor corner changes (top editing may have pushed floor down)
	for cell in _editor._drag_brush_cells:
		var key := "%d,%d" % [cell.x, cell.y]
		if not _editor._drag_brush_floor_original_corners.has(key):
			continue
		var floor_original: Array = _editor._drag_brush_floor_original_corners[key]
		var floor_final := data.get_floor_corners(cell.x, cell.y)
		var floor_original_typed: Array[int] = []
		for c in floor_original:
			floor_original_typed.append(c)
		if floor_original_typed != floor_final:
			_editor.undo_redo.add_do_method(data, "set_floor_corners", cell.x, cell.y, floor_final)
			_editor.undo_redo.add_undo_method(data, "set_floor_corners", cell.x, cell.y, floor_original_typed)

	_editor.undo_redo.commit_action(false)  # Don't execute, already applied

	_editor._is_dragging = false


func cancel_drag() -> void:
	if not _editor._is_dragging or not _editor._terrain:
		_editor._is_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if data:
		# Handle floor editing - restore all brush cells
		if _editor._drag_editing_floor:
			data.begin_batch()
			for cell in _editor._drag_brush_cells:
				var key := "%d,%d" % [cell.x, cell.y]
				if not _editor._drag_brush_floor_original_corners.has(key):
					continue
				var original: Array = _editor._drag_brush_floor_original_corners[key]
				var original_typed: Array[int] = []
				for c in original:
					original_typed.append(c)
				data.set_floor_corners(cell.x, cell.y, original_typed)
			data.end_batch()
			_editor._is_dragging = false
			return

		data.begin_batch()
		for cell in _editor._drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			if not _editor._drag_brush_original_corners.has(key):
				continue
			var original: Array = _editor._drag_brush_original_corners[key]

			var original_typed: Array[int] = []
			for c in original:
				original_typed.append(c)
			data.set_top_corners(cell.x, cell.y, original_typed)

		# Also restore floor corners (top editing may have pushed floor down)
		for cell in _editor._drag_brush_cells:
			var key := "%d,%d" % [cell.x, cell.y]
			if not _editor._drag_brush_floor_original_corners.has(key):
				continue
			var floor_original: Array = _editor._drag_brush_floor_original_corners[key]
			var floor_original_typed: Array[int] = []
			for c in floor_original:
				floor_original_typed.append(c)
			data.set_floor_corners(cell.x, cell.y, floor_original_typed)
		data.end_batch()

	_editor._is_dragging = false


func _calculate_drag_world_pos(data: TerrainData) -> void:
	var cell_size := data.cell_size
	var local_pos: Vector3
	if _editor._drag_mode == TerrainEditor.HoverMode.CORNER:
		var corner_offsets := [
			Vector2(0.0, 0.0),  # NW
			Vector2(1.0, 0.0),  # NE
			Vector2(1.0, 1.0),  # SE
			Vector2(0.0, 1.0),  # SW
		]
		var offset: Vector2 = corner_offsets[_editor._drag_corner]
		var height := data.steps_to_world(_editor._drag_original_corners[_editor._drag_corner])
		local_pos = Vector3(
			(_editor._drag_cell.x + offset.x) * cell_size,
			height,
			(_editor._drag_cell.y + offset.y) * cell_size
		)
	else:
		var avg_height := 0.0
		for c in _editor._drag_original_corners:
			avg_height += data.steps_to_world(c)
		avg_height /= 4.0
		local_pos = Vector3(
			(_editor._drag_cell.x + 0.5) * cell_size,
			avg_height,
			(_editor._drag_cell.y + 0.5) * cell_size
		)
	_editor._drag_world_pos = _editor._terrain.to_global(local_pos)


func _calculate_dragged_corners(dragged_corner: int, target_height: int, max_slope: int) -> Array[int]:
	# Start with sticky corners (current heights) for non-dragged, target for dragged
	var corners: Array[int] = []
	for i in 4:
		if i == dragged_corner:
			corners.append(target_height)
		else:
			corners.append(_editor._drag_sticky_corners[i])

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

	# Enforce minimum height >= 0 for all corners
	for i in 4:
		corners[i] = maxi(corners[i], 0)

	# Update sticky corners for non-dragged corners
	for i in 4:
		if i != dragged_corner:
			_editor._drag_sticky_corners[i] = corners[i]

	return corners


func _calculate_floor_dragged_corners(dragged_corner: int, target_height: int, data: TerrainData) -> Array[int]:
	var top_corners := data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	var max_slope := data.max_slope_steps

	# Start with sticky corners for non-dragged, target for dragged
	var corners: Array[int] = []
	for i in 4:
		if i == dragged_corner:
			# Constraint: floor cannot exceed top and must be >= 0
			var max_floor := top_corners[i]
			corners.append(mini(maxi(target_height, 0), max_floor))
		else:
			corners.append(_editor._drag_floor_sticky_corners[i])

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
	# Also ensure each corner respects top limit and >= 0
	for adj in adjacent_corners:
		var min_h := corners[dragged_corner] - max_slope
		var max_h := corners[dragged_corner] + max_slope
		# Also constrain to top and minimum 0
		max_h = mini(max_h, top_corners[adj])
		min_h = maxi(min_h, 0)
		corners[adj] = clampi(corners[adj], min_h, max_h)

	# Constrain diagonal corner to both adjacent corners
	var min_h := -999999
	var max_h := 999999
	for adj in adjacent_corners:
		min_h = maxi(min_h, corners[adj] - max_slope)
		max_h = mini(max_h, corners[adj] + max_slope)
	# Also constrain to top and minimum 0
	max_h = mini(max_h, top_corners[diagonal_corner])
	min_h = maxi(min_h, 0)
	corners[diagonal_corner] = clampi(corners[diagonal_corner], min_h, max_h)

	# Update sticky corners for non-dragged corners
	for i in 4:
		if i != dragged_corner:
			_editor._drag_floor_sticky_corners[i] = corners[i]

	return corners
