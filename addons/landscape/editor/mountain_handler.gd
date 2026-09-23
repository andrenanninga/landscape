@tool
class_name MountainHandler
extends RefCounted

## Handles mountain tool operations for the terrain editor.
## Creates hills and valleys with smooth sloped edges using BFS propagation.

# Slope cells are collected this many cells out from the brush; with max_slope_steps of 1
# that allows a height change of MAX_RINGS steps before the slope is cut off.
const MAX_RINGS := 9

const CORNER_OFFSETS: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]

var _editor: TerrainEditor

# Original floor corners for every affected cell, keyed by Vector2i cell
var _original_floors: Dictionary = {}


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_dragging = true
	_editor._drag_cell = _editor._hovered_cell
	_editor._drag_corner = -1
	_editor._drag_current_delta = 0
	_editor._drag_start_mouse_y = mouse_pos.y
	_editor._drag_editing_floor = false
	_editor._drag_mode = TerrainEditor.HoverMode.CELL
	_editor._drag_original_corners = data.get_top_corners(_editor._drag_cell.x, _editor._drag_cell.y)

	# Core brush cells and their height range
	_editor._drag_brush_cells = _editor.get_brush_cells(_editor._drag_cell, data, _editor._brush_corner)
	_editor._drag_brush_min_height = 999999
	_editor._drag_brush_max_height = -999999
	_editor._drag_mountain_original_corners.clear()
	_editor._drag_mountain_all_cells.clear()
	_editor._drag_mountain_corner_distances.clear()
	_original_floors.clear()

	var brush_set: Dictionary = {}
	for cell in _editor._drag_brush_cells:
		_remember_cell(cell, data)
		brush_set[cell] = true
		for c in _editor._drag_mountain_original_corners[cell]:
			_editor._drag_brush_min_height = mini(_editor._drag_brush_min_height, c)
			_editor._drag_brush_max_height = maxi(_editor._drag_brush_max_height, c)

	# Expand outward ring by ring to collect the cells the slopes may reach
	var current_ring := _editor._drag_brush_cells.duplicate()
	for _ring in MAX_RINGS:
		var next_ring: Array[Vector2i] = []
		for cell in current_ring:
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var neighbor := Vector2i(cell.x + dx, cell.y + dz)
					if brush_set.has(neighbor) or _editor._drag_mountain_original_corners.has(neighbor):
						continue
					if not data.is_valid_cell(neighbor.x, neighbor.y):
						continue
					_remember_cell(neighbor, data)
					next_ring.append(neighbor)
		current_ring = next_ring
		if current_ring.is_empty():
			break

	# BFS over corner points: distance (in edges) from the nearest core corner
	var valid_corners: Dictionary = {}
	for cell in _editor._drag_mountain_all_cells:
		for offset in CORNER_OFFSETS:
			valid_corners[cell + offset] = true

	var queue: Array[Vector2i] = []
	for cell in _editor._drag_brush_cells:
		for offset in CORNER_OFFSETS:
			var corner_pos := cell + offset
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
			var neighbor := pos + dir
			if valid_corners.has(neighbor) and not _editor._drag_mountain_corner_distances.has(neighbor):
				_editor._drag_mountain_corner_distances[neighbor] = dist + 1
				queue.append(neighbor)

	_editor._drag_world_pos = _editor.cell_center_world_pos(_editor._drag_cell, _editor._drag_original_corners, data)

	return true


func _remember_cell(cell: Vector2i, data: TerrainData) -> void:
	_editor._drag_mountain_all_cells.append(cell)
	_editor._drag_mountain_original_corners[cell] = data.get_top_corners(cell.x, cell.y)
	_original_floors[cell] = data.get_floor_corners(cell.x, cell.y)


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

	_apply_mountain_heights(data, new_delta)

	var world_height := data.steps_to_world(_editor._drag_brush_min_height + new_delta)
	_editor.height_changed.emit(world_height, -1, _editor._drag_mode)


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not _editor._is_dragging or not data:
		_editor._is_dragging = false
		return

	var changed_cells: Array[Vector2i] = []
	for cell in _editor._drag_mountain_all_cells:
		if data.get_top_corners(cell.x, cell.y) != _editor._drag_mountain_original_corners[cell] \
				or data.get_floor_corners(cell.x, cell.y) != _original_floors[cell]:
			changed_cells.append(cell)

	if not changed_cells.is_empty():
		_editor.undo_redo.create_action("Mountain Terrain")
		_editor.undo_redo.add_do_method(data, "begin_batch")
		_editor.undo_redo.add_undo_method(data, "begin_batch")
		for cell in changed_cells:
			_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, data.get_top_corners(cell.x, cell.y))
			_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, _editor._drag_mountain_original_corners[cell])
			_editor.undo_redo.add_do_method(data, "set_floor_corners", cell.x, cell.y, data.get_floor_corners(cell.x, cell.y))
			_editor.undo_redo.add_undo_method(data, "set_floor_corners", cell.x, cell.y, _original_floors[cell])
		_editor.undo_redo.add_do_method(data, "end_batch")
		_editor.undo_redo.add_undo_method(data, "end_batch")
		_editor.undo_redo.commit_action(false)  # Already applied

	_editor._is_dragging = false


func cancel_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if _editor._is_dragging and data:
		data.begin_batch()
		for cell in _editor._drag_mountain_all_cells:
			data.set_top_corners(cell.x, cell.y, _editor._drag_mountain_original_corners[cell])
			data.set_floor_corners(cell.x, cell.y, _original_floors[cell])
		data.end_batch()

	_editor._is_dragging = false


# Core cells move by the full delta; every other corner is limited by how far it is
# from the core so the slope never exceeds max_slope_steps per cell.
func _apply_mountain_heights(data: TerrainData, delta: int) -> void:
	var max_slope := data.max_slope_steps
	var peak_height: int = _editor._drag_brush_max_height + delta if delta >= 0 else _editor._drag_brush_min_height + delta

	data.begin_batch()
	for cell in _editor._drag_mountain_all_cells:
		var original: Array[int] = _editor._drag_mountain_original_corners[cell]
		var new_corners: Array[int] = []
		for i in 4:
			var dist: int = _editor._drag_mountain_corner_distances.get(cell + CORNER_OFFSETS[i], 0)
			if delta >= 0:
				new_corners.append(maxi(original[i], peak_height - dist * max_slope))
			else:
				new_corners.append(maxi(mini(original[i], peak_height + dist * max_slope), 0))

		data.set_top_corners(cell.x, cell.y, new_corners)
		data.clamp_floor_to_top(cell.x, cell.y)
	data.end_batch()
