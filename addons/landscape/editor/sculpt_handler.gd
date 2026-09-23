@tool
class_name SculptHandler
extends RefCounted

## Handles sculpt tool operations for the terrain editor.
## Manages terrain sculpting including corner mode, cell mode, and floor editing.

# Edge-adjacent corners and the diagonal corner for each corner (NW=0, NE=1, SE=2, SW=3)
const ADJACENT_CORNERS := [[1, 3], [0, 2], [1, 3], [0, 2]]
const DIAGONAL_CORNER := [2, 3, 0, 1]

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_dragging = true
	_editor._drag_cell = _editor._hovered_cell
	_editor._drag_corner = _editor._hovered_corner
	_editor._drag_current_delta = 0
	_editor._drag_start_mouse_y = mouse_pos.y
	_editor._drag_editing_floor = _editor._hover_editing_floor

	# Corner mode only makes sense for a single cell
	_editor._drag_mode = _editor._hover_mode if _editor.brush_size == 1 else TerrainEditor.HoverMode.CELL

	_editor._drag_original_corners = data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	_editor._drag_sticky_corners = _editor._drag_original_corners.duplicate()
	_editor._drag_floor_original_corners = data.get_floor_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	_editor._drag_floor_sticky_corners = _editor._drag_floor_original_corners.duplicate()

	# Originals for every brush cell (floor included, since lowering the top pushes the floor)
	_editor._drag_brush_cells = _editor.get_brush_cells(_editor._drag_cell, data, _editor._brush_corner)
	_editor._drag_brush_original_corners.clear()
	_editor._drag_brush_floor_original_corners.clear()
	_editor._drag_brush_min_height = 999999
	_editor._drag_brush_max_height = -999999
	_editor._drag_floor_brush_min_height = 999999
	_editor._drag_floor_brush_max_height = -999999
	for cell in _editor._drag_brush_cells:
		var cell_corners := data.get_top_corners(cell.x, cell.y)
		_editor._drag_brush_original_corners[cell] = cell_corners
		for c in cell_corners:
			_editor._drag_brush_min_height = mini(_editor._drag_brush_min_height, c)
			_editor._drag_brush_max_height = maxi(_editor._drag_brush_max_height, c)

		var cell_floor_corners := data.get_floor_corners(cell.x, cell.y)
		_editor._drag_brush_floor_original_corners[cell] = cell_floor_corners
		for c in cell_floor_corners:
			_editor._drag_floor_brush_min_height = mini(_editor._drag_floor_brush_min_height, c)
			_editor._drag_floor_brush_max_height = maxi(_editor._drag_floor_brush_max_height, c)

	_calculate_drag_world_pos(data)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	var new_delta := _editor.mouse_delta_to_steps(camera, _editor._drag_world_pos, _editor._drag_start_mouse_y, mouse_pos.y, data, _editor._drag_current_delta)
	if new_delta == _editor._drag_current_delta:
		return
	_editor._drag_current_delta = new_delta

	data.begin_batch()
	match _editor._drag_mode:
		TerrainEditor.HoverMode.FLOOR_CORNER:
			_drag_floor_corner(data, new_delta)
		TerrainEditor.HoverMode.CORNER:
			_drag_top_corner(data, new_delta)
		_:
			if _editor.brush_size == 1:
				_drag_single_cell(data, new_delta)
			else:
				_drag_brush_leveling(data, new_delta)
	data.end_batch()


func _drag_floor_corner(data: TerrainData, delta: int) -> void:
	var corner := _editor._drag_corner
	var cell := _editor._drag_cell
	var new_corners := _calculate_floor_dragged_corners(corner, _editor._drag_floor_original_corners[corner] + delta, data)
	data.set_floor_corners(cell.x, cell.y, new_corners)

	_editor.height_changed.emit(data.steps_to_world(new_corners[corner]), corner, _editor._drag_mode)


func _drag_top_corner(data: TerrainData, delta: int) -> void:
	var corner := _editor._drag_corner
	var cell := _editor._drag_cell
	var new_corners := _calculate_dragged_corners(corner, _editor._drag_original_corners[corner] + delta, data.max_slope_steps)
	data.set_top_corners(cell.x, cell.y, new_corners)
	data.clamp_floor_to_top(cell.x, cell.y)

	_editor.height_changed.emit(data.steps_to_world(new_corners[corner]), corner, _editor._drag_mode)


# Single cell: move all four corners by the same amount
func _drag_single_cell(data: TerrainData, delta: int) -> void:
	for cell in _editor._drag_brush_cells:
		if _editor._drag_editing_floor:
			var original: Array[int] = _editor._drag_brush_floor_original_corners[cell]
			var top_corners := data.get_top_corners(cell.x, cell.y)
			var new_corners: Array[int] = []
			for i in 4:
				new_corners.append(clampi(original[i] + delta, 0, top_corners[i]))
			data.set_floor_corners(cell.x, cell.y, new_corners)
		else:
			var original: Array[int] = _editor._drag_brush_original_corners[cell]
			var new_corners: Array[int] = []
			for i in 4:
				new_corners.append(maxi(original[i] + delta, 0))
			data.set_top_corners(cell.x, cell.y, new_corners)
			data.clamp_floor_to_top(cell.x, cell.y)

	var original_corners: Array[int] = _editor._drag_floor_original_corners if _editor._drag_editing_floor else _editor._drag_original_corners
	var avg_height := 0.0
	for c in original_corners:
		avg_height += data.steps_to_world(c + delta)
	_editor.height_changed.emit(avg_height / 4.0, -1, _editor._drag_mode)


# Multi-cell brush levels toward a target: raising lifts low corners up to (min + delta),
# lowering brings high corners down to (max + delta); corners never move the other way.
func _drag_brush_leveling(data: TerrainData, delta: int) -> void:
	var raising := delta >= 0
	var target_height: int
	if _editor._drag_editing_floor:
		target_height = (_editor._drag_floor_brush_min_height if raising else _editor._drag_floor_brush_max_height) + delta
	else:
		target_height = (_editor._drag_brush_min_height if raising else _editor._drag_brush_max_height) + delta

	for cell in _editor._drag_brush_cells:
		if _editor._drag_editing_floor:
			var current := data.get_floor_corners(cell.x, cell.y)
			var top_corners := data.get_top_corners(cell.x, cell.y)
			var new_corners: Array[int] = []
			for i in 4:
				var corner_target := maxi(current[i], target_height) if raising else mini(current[i], target_height)
				new_corners.append(clampi(corner_target, 0, top_corners[i]))
			data.set_floor_corners(cell.x, cell.y, new_corners)
		else:
			var current := data.get_top_corners(cell.x, cell.y)
			var new_corners: Array[int] = []
			for i in 4:
				var corner_target := maxi(current[i], target_height) if raising else mini(current[i], target_height)
				new_corners.append(maxi(corner_target, 0))
			data.set_top_corners(cell.x, cell.y, new_corners)
			data.clamp_floor_to_top(cell.x, cell.y)

	_editor.height_changed.emit(data.steps_to_world(target_height), -1, _editor._drag_mode)


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not _editor._is_dragging or not data:
		_editor._is_dragging = false
		return

	var top_changes: Array[Vector2i] = []
	var floor_changes: Array[Vector2i] = []
	for cell in _editor._drag_brush_cells:
		if data.get_top_corners(cell.x, cell.y) != _editor._drag_brush_original_corners[cell]:
			top_changes.append(cell)
		if data.get_floor_corners(cell.x, cell.y) != _editor._drag_brush_floor_original_corners[cell]:
			floor_changes.append(cell)

	if not top_changes.is_empty() or not floor_changes.is_empty():
		_editor.undo_redo.create_action("Sculpt Floor" if _editor._drag_editing_floor else "Sculpt Terrain")
		_editor.undo_redo.add_do_method(data, "begin_batch")
		_editor.undo_redo.add_undo_method(data, "begin_batch")
		for cell in top_changes:
			_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, data.get_top_corners(cell.x, cell.y))
			_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, _editor._drag_brush_original_corners[cell])
		for cell in floor_changes:
			_editor.undo_redo.add_do_method(data, "set_floor_corners", cell.x, cell.y, data.get_floor_corners(cell.x, cell.y))
			_editor.undo_redo.add_undo_method(data, "set_floor_corners", cell.x, cell.y, _editor._drag_brush_floor_original_corners[cell])
		_editor.undo_redo.add_do_method(data, "end_batch")
		_editor.undo_redo.add_undo_method(data, "end_batch")
		_editor.undo_redo.commit_action(false)  # Already applied

	_editor._is_dragging = false


func cancel_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if _editor._is_dragging and data:
		data.begin_batch()
		for cell in _editor._drag_brush_cells:
			data.set_top_corners(cell.x, cell.y, _editor._drag_brush_original_corners[cell])
			data.set_floor_corners(cell.x, cell.y, _editor._drag_brush_floor_original_corners[cell])
		data.end_batch()

	_editor._is_dragging = false


func _calculate_drag_world_pos(data: TerrainData) -> void:
	if _editor._drag_mode == TerrainEditor.HoverMode.CORNER or _editor._drag_mode == TerrainEditor.HoverMode.FLOOR_CORNER:
		var heights := _editor._drag_floor_original_corners if _editor._drag_mode == TerrainEditor.HoverMode.FLOOR_CORNER else _editor._drag_original_corners
		var corners := data.get_world_corners(_editor._drag_cell.x, _editor._drag_cell.y, heights)
		_editor._drag_world_pos = _editor._terrain.to_global(corners[_editor._drag_corner])
	else:
		var heights := _editor._drag_floor_original_corners if _editor._drag_editing_floor else _editor._drag_original_corners
		_editor._drag_world_pos = _editor.cell_center_world_pos(_editor._drag_cell, heights, data)


# Moves one corner to target_height and pulls the others along only as far as the slope
# limit requires. Non-dragged corners are "sticky": they keep pulled positions between steps.
func _calculate_dragged_corners(dragged_corner: int, target_height: int, max_slope: int) -> Array[int]:
	var corners: Array[int] = _editor._drag_sticky_corners.duplicate()
	corners[dragged_corner] = target_height

	var adjacent_corners: Array = ADJACENT_CORNERS[dragged_corner]
	for adj: int in adjacent_corners:
		corners[adj] = clampi(corners[adj], corners[dragged_corner] - max_slope, corners[dragged_corner] + max_slope)

	var diagonal_corner: int = DIAGONAL_CORNER[dragged_corner]
	var min_h := -999999
	var max_h := 999999
	for adj: int in adjacent_corners:
		min_h = maxi(min_h, corners[adj] - max_slope)
		max_h = mini(max_h, corners[adj] + max_slope)
	corners[diagonal_corner] = clampi(corners[diagonal_corner], min_h, max_h)

	for i in 4:
		corners[i] = maxi(corners[i], 0)

	for i in 4:
		if i != dragged_corner:
			_editor._drag_sticky_corners[i] = corners[i]

	return corners


# Same as _calculate_dragged_corners for the floor, with each corner also limited to its top
func _calculate_floor_dragged_corners(dragged_corner: int, target_height: int, data: TerrainData) -> Array[int]:
	var top_corners := data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)
	var max_slope := data.max_slope_steps

	var corners: Array[int] = _editor._drag_floor_sticky_corners.duplicate()
	corners[dragged_corner] = clampi(target_height, 0, top_corners[dragged_corner])

	var adjacent_corners: Array = ADJACENT_CORNERS[dragged_corner]
	for adj: int in adjacent_corners:
		var min_h := maxi(corners[dragged_corner] - max_slope, 0)
		var max_h := mini(corners[dragged_corner] + max_slope, top_corners[adj])
		corners[adj] = clampi(corners[adj], min_h, max_h)

	var diagonal_corner: int = DIAGONAL_CORNER[dragged_corner]
	var min_h := 0
	var max_h := top_corners[diagonal_corner]
	for adj: int in adjacent_corners:
		min_h = maxi(min_h, corners[adj] - max_slope)
		max_h = mini(max_h, corners[adj] + max_slope)
	corners[diagonal_corner] = clampi(corners[diagonal_corner], min_h, max_h)

	for i in 4:
		if i != dragged_corner:
			_editor._drag_floor_sticky_corners[i] = corners[i]

	return corners
