@tool
class_name PaintHandler
extends RefCounted

## Handles paint tool operations for the terrain editor.
## Manages tile painting, preview, eyedropper, and transform operations.
##
## Preview and undo buffers are keyed by Vector3i(x, z, surface).

const ALL_CELL_FACES: Array[TerrainData.Surface] = [
	TerrainData.Surface.TOP,
	TerrainData.Surface.NORTH,
	TerrainData.Surface.EAST,
	TerrainData.Surface.SOUTH,
	TerrainData.Surface.WEST,
]

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(data: TerrainData, shift_pressed: bool) -> bool:
	_editor._paint_preview_buffer.clear()
	_editor._paint_original_values.clear()

	if shift_pressed:
		_editor._paint_surface_locked = true
		_editor._paint_locked_surface = _editor._hovered_surface
	var paint_surface := _editor._paint_locked_surface if _editor._paint_surface_locked else _editor._hovered_surface

	if not _build_paint_preview(data, _editor._hovered_cell, paint_surface):
		return false

	_editor._is_paint_dragging = true
	_editor._last_painted_cell = _editor._hovered_cell
	_editor._last_painted_surface = paint_surface
	_editor._terrain.set_tile_previews(_editor._paint_preview_buffer)
	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_paint_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	_editor._update_hover(camera, mouse_pos)
	if _editor._hovered_cell.x < 0:
		return

	var paint_surface := _editor._paint_locked_surface if _editor._paint_surface_locked else _editor._hovered_surface
	if _editor._paint_surface_locked and _editor._hovered_surface != _editor._paint_locked_surface:
		return
	if _editor._hovered_cell == _editor._last_painted_cell and paint_surface == _editor._last_painted_surface:
		return

	_build_paint_preview(data, _editor._hovered_cell, paint_surface)
	_editor._terrain.set_tile_previews(_editor._paint_preview_buffer)
	_editor._last_painted_cell = _editor._hovered_cell
	_editor._last_painted_surface = paint_surface


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not data or _editor._paint_preview_buffer.is_empty():
		cancel_preview()
		return

	_editor.undo_redo.create_action("Paint Terrain Tiles")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")
	for key: Vector3i in _editor._paint_preview_buffer:
		var surface := key.z as TerrainData.Surface
		_editor.undo_redo.add_do_method(data, "set_tile_packed", key.x, key.y, surface, _editor._paint_preview_buffer[key])
		_editor.undo_redo.add_undo_method(data, "set_tile_packed", key.x, key.y, surface, _editor._paint_original_values[key])
	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action()

	cancel_preview()


func cancel_preview() -> void:
	if _editor._terrain:
		_editor._terrain.clear_preview()
	_editor._paint_preview_buffer.clear()
	_editor._paint_original_values.clear()
	_editor._is_paint_dragging = false
	_editor._paint_surface_locked = false
	_editor._last_painted_cell = Vector2i(-1, -1)


# Refreshes the hover preview after a paint setting changed
func update_preview() -> void:
	if _editor.current_tool != TerrainEditor.Tool.PAINT:
		return
	update_hover_preview()


func update_hover_preview() -> void:
	if not _editor._terrain or _editor._hovered_cell.x < 0:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	var hover_preview: Dictionary = {}
	for surface in _surfaces_to_paint(_editor._hovered_surface):
		for cell in _editor.get_brush_cells(_editor._hovered_cell, data, _editor._brush_corner):
			hover_preview[Vector3i(cell.x, cell.y, surface)] = _get_paint_packed(cell, surface)

	_editor._terrain.set_tile_previews(hover_preview)


# In all-faces mode a stroke on a cell face covers the top and all four walls
func _surfaces_to_paint(surface: TerrainData.Surface) -> Array[TerrainData.Surface]:
	if _editor.current_paint_all_faces and not TerrainData.is_fence_surface(surface):
		return ALL_CELL_FACES
	return [surface]


# Adds the brush area around center to the drag preview. Returns false if nothing is under the brush.
func _build_paint_preview(data: TerrainData, center: Vector2i, surface: TerrainData.Surface) -> bool:
	var brush_cells := _editor.get_brush_cells(center, data, _editor._brush_corner)

	for s in _surfaces_to_paint(surface):
		for cell in brush_cells:
			var key := Vector3i(cell.x, cell.y, s)
			if _editor._paint_preview_buffer.has(key):
				continue
			if TerrainData.is_fence_surface(s) and not data.has_fence(cell.x, cell.y, TerrainData.fence_edge_from_surface(s)):
				continue

			_editor._paint_original_values[key] = data.get_tile_packed(cell.x, cell.y, s)
			_editor._paint_preview_buffer[key] = _get_paint_packed(cell, s)

	return not brush_cells.is_empty()


func _get_paint_packed(cell: Vector2i, surface: TerrainData.Surface) -> int:
	if _editor.current_paint_erase:
		return TerrainData.ERASED_TILE_INDEX

	var tile_index := _editor.current_paint_tile
	if _editor.current_paint_all_faces:
		tile_index = _editor.current_paint_top_tile if surface == TerrainData.Surface.TOP else _editor.current_paint_side_tile

	if not _editor.current_paint_random:
		return TerrainData.pack_tile(tile_index, _editor.current_paint_rotation, _editor.current_paint_flip_h, _editor.current_paint_flip_v, _editor.current_paint_wall_align)

	# Seed from the cell and surface so the hover preview matches the painted result
	var rng := RandomNumberGenerator.new()
	rng.seed = cell.x * 73856093 ^ cell.y * 19349663 ^ surface * 83492791
	var rotation := rng.randi_range(0, 3) as TerrainData.Rotation
	var flip_h := rng.randi_range(0, 1) == 1
	var flip_v := rng.randi_range(0, 1) == 1
	return TerrainData.pack_tile(tile_index, rotation, flip_h, flip_v, _editor.current_paint_wall_align)


# Eyedropper: adopt the tile settings of the hovered surface
func pick_tile_at_hover() -> bool:
	if _editor._hovered_cell.x < 0 or not _editor._terrain:
		return false

	var data := _editor._terrain.terrain_data
	if not data:
		return false

	var surface := _editor._hovered_surface
	var tile_info := TerrainData.unpack_tile(data.get_tile_packed(_editor._hovered_cell.x, _editor._hovered_cell.y, surface))

	if _editor.current_paint_all_faces:
		if _editor.current_tile_slot == 0:
			_editor.current_paint_top_tile = tile_info.tile_index
		else:
			_editor.current_paint_side_tile = tile_info.tile_index
	else:
		_editor.current_paint_tile = tile_info.tile_index
	_editor.current_paint_rotation = tile_info.rotation as TerrainData.Rotation
	_editor.current_paint_flip_h = tile_info.flip_h
	_editor.current_paint_flip_v = tile_info.flip_v

	# Top faces carry no alignment, so keep the current setting when picking from one
	if surface != TerrainData.Surface.TOP:
		_editor.current_paint_wall_align = tile_info.wall_align as TerrainData.WallAlign

	return true


func rotate_cw() -> void:
	_editor.current_paint_rotation = ((_editor.current_paint_rotation + 1) % 4) as TerrainData.Rotation


func rotate_ccw() -> void:
	_editor.current_paint_rotation = ((_editor.current_paint_rotation + 3) % 4) as TerrainData.Rotation


func toggle_flip_h() -> void:
	_editor.current_paint_flip_h = not _editor.current_paint_flip_h


func toggle_flip_v() -> void:
	_editor.current_paint_flip_v = not _editor.current_paint_flip_v
