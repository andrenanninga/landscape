@tool
class_name PaintHandler
extends RefCounted

## Handles paint tool operations for the terrain editor.
## Manages tile painting, preview, eyedropper, and transform operations.

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_paint_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Update hover position (this also updates _hovered_surface)
	_editor._update_hover(camera, mouse_pos)

	if _editor._hovered_cell.x < 0:
		return

	# When surface is locked, only paint on matching surface type
	var paint_surface := _editor._paint_locked_surface if _editor._paint_surface_locked else _editor._hovered_surface
	if _editor._paint_surface_locked and _editor._hovered_surface != _editor._paint_locked_surface:
		return

	# Only update preview if cell or surface changed
	if _editor._hovered_cell == _editor._last_painted_cell and paint_surface == _editor._last_painted_surface:
		return

	# Add new cells to preview (accumulate)
	_build_paint_preview(data, _editor._hovered_cell, paint_surface)
	_editor._terrain.set_tile_previews(_editor._paint_preview_buffer)
	_editor._last_painted_cell = _editor._hovered_cell
	_editor._last_painted_surface = paint_surface


func finish_drag() -> void:
	if not _editor._terrain or _editor._paint_preview_buffer.is_empty():
		_editor._is_paint_dragging = false
		_editor._paint_surface_locked = false
		_editor._last_painted_cell = Vector2i(-1, -1)
		_editor._paint_preview_buffer.clear()
		_editor._paint_original_values.clear()
		return

	var data := _editor._terrain.terrain_data
	if not data:
		_editor._is_paint_dragging = false
		_editor._paint_surface_locked = false
		return

	# Create undo/redo action from preview data
	# Wrap in batch mode to avoid emitting data_changed for each tile
	_editor.undo_redo.create_action("Paint Terrain Tiles")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")
	for key: String in _editor._paint_preview_buffer.keys():
		var parts: PackedStringArray = key.split(",")
		var x := int(parts[0])
		var z := int(parts[1])
		var surface := int(parts[2]) as TerrainData.Surface
		var new_packed: int = _editor._paint_preview_buffer[key]
		var old_packed: int = _editor._paint_original_values[key]

		# Handle fence surfaces differently
		if surface >= TerrainData.Surface.FENCE_NORTH:
			var edge := surface - TerrainData.Surface.FENCE_NORTH
			_editor.undo_redo.add_do_method(data, "set_fence_tile_packed", x, z, edge, new_packed)
			_editor.undo_redo.add_undo_method(data, "set_fence_tile_packed", x, z, edge, old_packed)
		else:
			_editor.undo_redo.add_do_method(data, "set_tile_packed", x, z, surface, new_packed)
			_editor.undo_redo.add_undo_method(data, "set_tile_packed", x, z, surface, old_packed)
	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action()

	# Clear preview
	_editor._terrain.clear_preview()
	_editor._paint_preview_buffer.clear()
	_editor._paint_original_values.clear()
	_editor._is_paint_dragging = false
	_editor._paint_surface_locked = false
	_editor._last_painted_cell = Vector2i(-1, -1)


func cancel_preview() -> void:
	if _editor._terrain:
		_editor._terrain.clear_preview()
	_editor._paint_preview_buffer.clear()
	_editor._paint_original_values.clear()
	_editor._is_paint_dragging = false
	_editor._paint_surface_locked = false
	_editor._last_painted_cell = Vector2i(-1, -1)


func update_preview() -> void:
	if _editor.current_tool != TerrainEditor.Tool.PAINT or not _editor._terrain or _editor._hovered_cell.x < 0:
		return
	update_hover_preview()


func update_hover_preview() -> void:
	if not _editor._terrain or _editor._hovered_cell.x < 0:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Build hover preview for entire brush area
	var hover_preview: Dictionary = {}
	var brush_cells := _editor.get_brush_cells(_editor._hovered_cell, data, _editor._brush_corner)

	for cell in brush_cells:
		var key := "%d,%d,%d" % [cell.x, cell.y, _editor._hovered_surface]
		hover_preview[key] = _get_paint_packed(cell, _editor._hovered_surface)

	_editor._terrain.set_tile_previews(hover_preview)


func _build_paint_preview(data: TerrainData, center: Vector2i, surface: TerrainData.Surface) -> bool:
	var brush_cells := _editor.get_brush_cells(center, data, _editor._brush_corner)

	var any_added := false
	for cell in brush_cells:
		var key := "%d,%d,%d" % [cell.x, cell.y, surface]
		# Skip if already in preview buffer
		if _editor._paint_preview_buffer.has(key):
			continue

		# Handle fence surfaces differently
		var old_packed: int
		if surface >= TerrainData.Surface.FENCE_NORTH:
			var edge := surface - TerrainData.Surface.FENCE_NORTH
			# Skip if no fence exists at this edge
			if not data.has_fence(cell.x, cell.y, edge):
				continue
			old_packed = data.get_fence_tile_packed(cell.x, cell.y, edge)
		else:
			old_packed = data.get_tile_packed(cell.x, cell.y, surface)

		# Store original value for undo
		_editor._paint_original_values[key] = old_packed
		# Add to preview buffer with potentially random transform
		_editor._paint_preview_buffer[key] = _get_paint_packed(cell, surface)
		any_added = true

	return any_added or brush_cells.size() > 0


func _get_paint_packed(cell: Vector2i, surface: TerrainData.Surface) -> int:
	if _editor.current_paint_random:
		# Use cell position and surface as seed for deterministic randomness
		# This ensures the same cell shows the same random transform during hover
		var seed_value := cell.x * 73856093 ^ cell.y * 19349663 ^ surface * 83492791
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var rotation := rng.randi_range(0, 3) as TerrainData.Rotation
		var flip_h := rng.randi_range(0, 1) == 1
		var flip_v := rng.randi_range(0, 1) == 1
		return TerrainData.pack_tile(_editor.current_paint_tile, rotation, flip_h, flip_v, _editor.current_paint_wall_align)
	else:
		return TerrainData.pack_tile(_editor.current_paint_tile, _editor.current_paint_rotation, _editor.current_paint_flip_h, _editor.current_paint_flip_v, _editor.current_paint_wall_align)


func pick_tile_at_hover() -> bool:
	if _editor._hovered_cell.x < 0 or not _editor._terrain:
		return false

	var data := _editor._terrain.terrain_data
	if not data:
		return false

	# Get tile data from the hovered cell and surface
	var packed: int
	if _editor._hovered_surface >= TerrainData.Surface.FENCE_NORTH:
		var edge := _editor._hovered_surface - TerrainData.Surface.FENCE_NORTH
		packed = data.get_fence_tile_packed(_editor._hovered_cell.x, _editor._hovered_cell.y, edge)
	else:
		packed = data.get_tile_packed(_editor._hovered_cell.x, _editor._hovered_cell.y, _editor._hovered_surface)

	var tile_info := TerrainData.unpack_tile(packed)

	# Set current paint state to match the picked tile
	_editor.current_paint_tile = tile_info.tile_index
	_editor.current_paint_rotation = tile_info.rotation as TerrainData.Rotation
	_editor.current_paint_flip_h = tile_info.flip_h
	_editor.current_paint_flip_v = tile_info.flip_v
	_editor.current_paint_wall_align = tile_info.wall_align as TerrainData.WallAlign

	return true


# Helper functions for paint tool rotation/flip
func rotate_cw() -> void:
	_editor.current_paint_rotation = ((_editor.current_paint_rotation + 1) % 4) as TerrainData.Rotation


func rotate_ccw() -> void:
	_editor.current_paint_rotation = ((_editor.current_paint_rotation + 3) % 4) as TerrainData.Rotation


func toggle_flip_h() -> void:
	_editor.current_paint_flip_h = not _editor.current_paint_flip_h


func toggle_flip_v() -> void:
	_editor.current_paint_flip_v = not _editor.current_paint_flip_v
