@tool
class_name FlattenHandler
extends RefCounted

## Handles flatten tool operations for the terrain editor.
## Manages flattening terrain to a target height with drag support.

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(data: TerrainData) -> bool:
	# Get target height from the hovered corner
	var corners := data.get_top_corners(_editor._hovered_cell.x, _editor._hovered_cell.y)
	if _editor._hover_mode == TerrainEditor.HoverMode.CORNER and _editor._hovered_corner >= 0:
		_editor._flatten_target_height = corners[_editor._hovered_corner]
	else:
		# Use average height if clicking cell center
		_editor._flatten_target_height = int(round(float(corners[0] + corners[1] + corners[2] + corners[3]) / 4.0))

	_editor._is_flatten_dragging = true
	_editor._flatten_affected_cells.clear()

	# Apply to initial brush area
	_apply_to_brush(data, _editor._hovered_cell)
	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_flatten_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Raycast to find current cell
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var hit := _editor._raycast_terrain(ray_origin, ray_dir)

	if hit.is_empty():
		return

	var hit_pos: Vector3 = hit.position
	var cell := _editor._terrain.world_to_cell(hit_pos)

	if not data.is_valid_cell(cell.x, cell.y):
		return

	# Update brush corner for even-sized brushes
	var local_pos := _editor._terrain.to_local(hit_pos)
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
	_editor._brush_corner = 0
	for i in range(1, 4):
		if corner_dists[i] < min_dist:
			min_dist = corner_dists[i]
			_editor._brush_corner = i

	# Update hovered cell for overlay drawing
	_editor._hovered_cell = cell

	# Apply flatten to cells under brush
	_apply_to_brush(data, cell)


func finish_drag() -> void:
	if not _editor._is_flatten_dragging or not _editor._terrain:
		_editor._is_flatten_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if not data or _editor._flatten_affected_cells.is_empty():
		_editor._is_flatten_dragging = false
		_editor._flatten_affected_cells.clear()
		return

	# Create undo action for all affected cells
	_editor.undo_redo.create_action("Flatten Terrain")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")
	for cell in _editor._flatten_affected_cells:
		var original: Array = _editor._flatten_affected_cells[cell]
		var original_typed: Array[int] = [original[0], original[1], original[2], original[3]]
		var new_corners: Array[int] = [_editor._flatten_target_height, _editor._flatten_target_height, _editor._flatten_target_height, _editor._flatten_target_height]
		_editor.undo_redo.add_do_method(data, "set_top_corners", cell.x, cell.y, new_corners)
		_editor.undo_redo.add_undo_method(data, "set_top_corners", cell.x, cell.y, original_typed)
	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action(false)  # Don't execute, already applied

	_editor._is_flatten_dragging = false
	_editor._flatten_affected_cells.clear()


func cancel_drag() -> void:
	if not _editor._is_flatten_dragging or not _editor._terrain:
		_editor._is_flatten_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if data:
		# Restore original heights
		data.begin_batch()
		for cell in _editor._flatten_affected_cells:
			var original: Array = _editor._flatten_affected_cells[cell]
			var original_typed: Array[int] = [original[0], original[1], original[2], original[3]]
			data.set_top_corners(cell.x, cell.y, original_typed)
		data.end_batch()

	_editor._is_flatten_dragging = false
	_editor._flatten_affected_cells.clear()


func _apply_to_brush(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := _editor.get_brush_cells(center, data, _editor._brush_corner)

	if brush_cells.is_empty():
		return

	data.begin_batch()
	for cell in brush_cells:
		# Skip cells already flattened in this drag
		if _editor._flatten_affected_cells.has(cell):
			continue

		var old_corners := data.get_top_corners(cell.x, cell.y)

		# Check if there's actually a change needed
		if old_corners[0] != _editor._flatten_target_height or old_corners[1] != _editor._flatten_target_height or \
		   old_corners[2] != _editor._flatten_target_height or old_corners[3] != _editor._flatten_target_height:
			# Store original for undo
			_editor._flatten_affected_cells[cell] = old_corners.duplicate()
			# Apply flatten
			data.set_top_corners(cell.x, cell.y, [_editor._flatten_target_height, _editor._flatten_target_height, _editor._flatten_target_height, _editor._flatten_target_height])
	data.end_batch()
