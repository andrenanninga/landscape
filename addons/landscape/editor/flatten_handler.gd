@tool
class_name FlattenHandler
extends RefCounted

## Handles flatten tool operations for the terrain editor.
## Manages flattening terrain to a target height with drag support.

var _editor: TerrainEditor

# Original corners of every cell touched during the drag, keyed by Vector2i cell
var _original_tops: Dictionary = {}
var _original_floors: Dictionary = {}


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(data: TerrainData) -> bool:
	var corners := data.get_top_corners(_editor._hovered_cell.x, _editor._hovered_cell.y)
	if _editor._hover_mode == TerrainEditor.HoverMode.CORNER and _editor._hovered_corner >= 0:
		_editor._flatten_target_height = corners[_editor._hovered_corner]
	else:
		_editor._flatten_target_height = int(round(float(corners[0] + corners[1] + corners[2] + corners[3]) / 4.0))

	_editor._is_flatten_dragging = true
	_original_tops.clear()
	_original_floors.clear()

	_apply_to_brush(data, _editor._hovered_cell)
	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_flatten_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	var hit := _editor._raycast_terrain(camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	if hit.is_empty():
		return

	var hit_pos: Vector3 = hit.position
	var cell := _editor._terrain.world_to_cell(hit_pos)

	_editor._brush_corner = _editor.nearest_corner(_editor._terrain.to_local(hit_pos), cell, data.cell_size)
	_editor._hovered_cell = cell

	_apply_to_brush(data, cell)


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not _editor._is_flatten_dragging or not data or _original_tops.is_empty():
		_reset()
		return

	_editor.undo_redo.create_action("Flatten Terrain")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")
	for cell: Vector2i in _original_tops:
		var original_top: Array[int] = _original_tops[cell]
		var original_floor: Array[int] = _original_floors[cell]
		_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, data.get_top_corners(cell.x, cell.y))
		_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_top)
		var final_floor := data.get_floor_corners(cell.x, cell.y)
		if final_floor != original_floor:
			_editor.undo_redo.add_do_method(data, "set_floor_corners", cell.x, cell.y, final_floor)
			_editor.undo_redo.add_undo_method(data, "set_floor_corners", cell.x, cell.y, original_floor)
	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action(false)  # Already applied

	_reset()


func cancel_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if _editor._is_flatten_dragging and data:
		data.begin_batch()
		for cell: Vector2i in _original_tops:
			data.set_top_corners(cell.x, cell.y, _original_tops[cell])
			data.set_floor_corners(cell.x, cell.y, _original_floors[cell])
		data.end_batch()

	_reset()


func _reset() -> void:
	_editor._is_flatten_dragging = false
	_original_tops.clear()
	_original_floors.clear()


func _apply_to_brush(data: TerrainData, center: Vector2i) -> void:
	var target := _editor._flatten_target_height
	var flat: Array[int] = [target, target, target, target]

	data.begin_batch()
	for cell in _editor.get_brush_cells(center, data, _editor._brush_corner):
		if _original_tops.has(cell):
			continue

		var old_corners := data.get_top_corners(cell.x, cell.y)
		if old_corners == flat:
			continue

		_original_tops[cell] = old_corners
		_original_floors[cell] = data.get_floor_corners(cell.x, cell.y)
		data.set_top_corners(cell.x, cell.y, flat)
		data.clamp_floor_to_top(cell.x, cell.y)
	data.end_batch()
