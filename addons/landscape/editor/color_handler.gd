@tool
class_name ColorHandler
extends RefCounted

## Handles vertex color painting tool operations for the terrain editor.
## Paints the corners of top and floor faces and the vertices of walls, with brush support.

# Which colour set a cell key addresses: the top face, the floor face, or the wall on
# edge (kind - KIND_WALL)
const KIND_TOP := 0
const KIND_FLOOR := 1
const KIND_WALL := 2

var _editor: TerrainEditor

# Colors of every surface touched during the drag: Vector3i(x, z, kind) -> Array[int] of 4 packed colors
var _original_colors: Dictionary = {}

# Vertices already painted this drag: Vector4i(x, z, vertex, kind) -> true
var _painted_corners: Dictionary = {}


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_color_dragging = true
	_original_colors.clear()
	_painted_corners.clear()

	_paint_at_hover(data)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_color_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	_editor._update_hover(camera, mouse_pos)
	if _editor._hovered_cell.x < 0:
		return

	_paint_at_hover(data)


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not data or _original_colors.is_empty():
		_reset()
		return

	_editor.undo_redo.create_action("Paint Vertex Colors")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")
	for key: Vector3i in _original_colors:
		var original: Array[int] = _original_colors[key]
		var current := _get_colors(data, key)
		if key.z >= KIND_WALL:
			var edge := key.z - KIND_WALL
			_editor.undo_redo.add_do_method(data, "set_wall_vertex_colors", key.x, key.y, edge, current)
			_editor.undo_redo.add_undo_method(data, "set_wall_vertex_colors", key.x, key.y, edge, original)
		elif key.z == KIND_FLOOR:
			_editor.undo_redo.add_do_method(data, "set_floor_vertex_colors", key.x, key.y, current)
			_editor.undo_redo.add_undo_method(data, "set_floor_vertex_colors", key.x, key.y, original)
		else:
			_editor.undo_redo.add_do_method(data, "set_top_vertex_colors", key.x, key.y, current)
			_editor.undo_redo.add_undo_method(data, "set_top_vertex_colors", key.x, key.y, original)
	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action(false)  # Already applied

	_reset()


func cancel_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if data:
		data.begin_batch()
		for key: Vector3i in _original_colors:
			_set_colors(data, key, _original_colors[key])
		data.end_batch()

	_reset()


func _reset() -> void:
	_editor._is_color_dragging = false
	_original_colors.clear()
	_painted_corners.clear()


func _get_colors(data: TerrainData, key: Vector3i) -> Array[int]:
	if key.z >= KIND_WALL:
		return data.get_wall_vertex_colors(key.x, key.y, key.z - KIND_WALL)
	if key.z == KIND_FLOOR:
		return data.get_floor_vertex_colors(key.x, key.y)
	return data.get_top_vertex_colors(key.x, key.y)


func _set_colors(data: TerrainData, key: Vector3i, colors: Array[int]) -> void:
	if key.z >= KIND_WALL:
		data.set_wall_vertex_colors(key.x, key.y, key.z - KIND_WALL, colors)
	elif key.z == KIND_FLOOR:
		data.set_floor_vertex_colors(key.x, key.y, colors)
	else:
		data.set_top_vertex_colors(key.x, key.y, colors)


static func _is_wall_surface(surface: TerrainData.Surface) -> bool:
	return surface >= TerrainData.Surface.NORTH and surface <= TerrainData.Surface.WEST


# The wall vertex under the cursor: left or right by nearest corner, top or bottom by
# which half of the wall was hit
func hovered_wall_vertex(edge: int) -> int:
	var on_left: bool = _editor._hovered_corner == TerrainData.EDGE_CORNERS[edge][0]
	if _editor._hover_editing_floor:
		return TerrainData.WallVertex.BOTTOM_LEFT if on_left else TerrainData.WallVertex.BOTTOM_RIGHT
	return TerrainData.WallVertex.TOP_LEFT if on_left else TerrainData.WallVertex.TOP_RIGHT


func _paint_at_hover(data: TerrainData) -> void:
	if _editor._hovered_cell.x < 0:
		return

	if _is_wall_surface(_editor._hovered_surface):
		_paint_wall_at_hover(data, _editor._hovered_surface - TerrainData.Surface.NORTH)
	else:
		_paint_face_at_hover(data)


# Walls of every brush cell on the hovered edge. A single-cell brush near a wall corner
# paints just that vertex; otherwise the whole wall. Erasing returns vertices to the
# corner colours they inherit by default.
func _paint_wall_at_hover(data: TerrainData, edge: int) -> void:
	var kind := KIND_WALL + edge
	var erase := _editor.current_vertex_color_erase
	var light_mode := _editor.current_vertex_color_light_mode and not erase

	var cell_size := data.cell_size
	var brush_center := _get_brush_center(data)
	var brush_radius := _editor.brush_size * cell_size / 2.0

	var vertices_to_paint: Array[int] = [0, 1, 2, 3]
	if _editor.brush_size == 1 and _editor._hover_mode != TerrainEditor.HoverMode.CELL and _editor._hovered_corner >= 0:
		vertices_to_paint = [hovered_wall_vertex(edge)]

	data.begin_batch()
	for cell in _editor.get_brush_cells(_editor._hovered_cell, data, _editor._brush_corner):
		var cell_key := Vector3i(cell.x, cell.y, kind)
		if not _original_colors.has(cell_key):
			_original_colors[cell_key] = data.get_wall_vertex_colors(cell.x, cell.y, edge)

		for vertex in vertices_to_paint:
			if not light_mode:
				var vertex_key := Vector4i(cell.x, cell.y, vertex, kind)
				if _painted_corners.has(vertex_key):
					continue
				_painted_corners[vertex_key] = true

			if erase:
				data.clear_wall_vertex_color(cell.x, cell.y, edge, vertex)
				continue

			var final_color := _editor.current_vertex_color
			if light_mode:
				var corner := TerrainData.wall_vertex_corner(edge, vertex)
				var intensity := _calculate_intensity(_get_corner_world_pos(cell, corner, cell_size), brush_center, brush_radius)
				if intensity <= 0.0:
					continue
				final_color = _blend_color(data.get_wall_vertex_color(cell.x, cell.y, edge, vertex), final_color, intensity)

			data.set_wall_vertex_color(cell.x, cell.y, edge, vertex, final_color)
	data.end_batch()


func _paint_face_at_hover(data: TerrainData) -> void:
	var is_floor := _editor._hover_editing_floor
	var floor_flag := KIND_FLOOR if is_floor else KIND_TOP
	var paint_color := Color.WHITE if _editor.current_vertex_color_erase else _editor.current_vertex_color
	var light_mode := _editor.current_vertex_color_light_mode and not _editor.current_vertex_color_erase

	var cell_size := data.cell_size
	var brush_center := _get_brush_center(data)
	var brush_radius := _editor.brush_size * cell_size / 2.0

	# A single-cell brush near a corner paints that corner only; otherwise all four
	var corners_to_paint: Array[int] = [0, 1, 2, 3]
	if _editor.brush_size == 1 and _editor._hover_mode != TerrainEditor.HoverMode.CELL and _editor._hovered_corner >= 0:
		corners_to_paint = [_editor._hovered_corner]

	data.begin_batch()
	for cell in _editor.get_brush_cells(_editor._hovered_cell, data, _editor._brush_corner):
		var cell_key := Vector3i(cell.x, cell.y, floor_flag)
		if not _original_colors.has(cell_key):
			_original_colors[cell_key] = data.get_floor_vertex_colors(cell.x, cell.y) if is_floor else data.get_top_vertex_colors(cell.x, cell.y)

		for corner in corners_to_paint:
			# Light mode accumulates on repeated passes; plain painting sets each corner once
			if not light_mode:
				var corner_key := Vector4i(cell.x, cell.y, corner, floor_flag)
				if _painted_corners.has(corner_key):
					continue
				_painted_corners[corner_key] = true

			var final_color := paint_color
			if light_mode:
				var intensity := _calculate_intensity(_get_corner_world_pos(cell, corner, cell_size), brush_center, brush_radius)
				if intensity <= 0.0:
					continue
				var base_color := data.get_floor_vertex_color(cell.x, cell.y, corner) if is_floor else data.get_top_vertex_color(cell.x, cell.y, corner)
				final_color = _blend_color(base_color, paint_color, intensity)

			if is_floor:
				data.set_floor_vertex_color(cell.x, cell.y, corner, final_color)
			else:
				data.set_top_vertex_color(cell.x, cell.y, corner, final_color)
	data.end_batch()


# Brush centre on the XZ plane: cell centre for odd sizes, the anchor corner for even sizes
func _get_brush_center(data: TerrainData) -> Vector2:
	var cell_size := data.cell_size
	var center_cell := _editor._hovered_cell

	if _editor.brush_size % 2 == 0 and _editor._brush_corner >= 0:
		return _get_corner_world_pos(center_cell, _editor._brush_corner, cell_size)

	return Vector2(center_cell.x + 0.5, center_cell.y + 0.5) * cell_size


func _get_corner_world_pos(cell: Vector2i, corner: int, cell_size: float) -> Vector2:
	var offsets := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	return (Vector2(cell) + offsets[corner]) * cell_size


# Quadratic falloff from full intensity at the brush centre to zero at its edge
func _calculate_intensity(corner_world_pos: Vector2, brush_center: Vector2, radius: float) -> float:
	if radius <= 0.5:
		return 1.0
	var normalized := clampf(corner_world_pos.distance_to(brush_center) / radius, 0.0, 1.0)
	return (1.0 - normalized) * (1.0 - normalized)


func _blend_color(base: Color, blend: Color, intensity: float) -> Color:
	match _editor.current_vertex_color_blend_mode:
		TerrainEditor.BlendMode.ADDITIVE:
			return _additive_blend(base, blend, intensity)
		TerrainEditor.BlendMode.OVERLAY:
			return _overlay_blend(base, blend, intensity)
		TerrainEditor.BlendMode.MULTIPLY:
			return _multiply_blend(base, blend, intensity)
	return _screen_blend(base, blend, intensity)


func _screen_blend(base: Color, blend: Color, intensity: float) -> Color:
	return Color(
		1.0 - (1.0 - base.r) * (1.0 - blend.r * intensity),
		1.0 - (1.0 - base.g) * (1.0 - blend.g * intensity),
		1.0 - (1.0 - base.b) * (1.0 - blend.b * intensity)
	)


func _additive_blend(base: Color, blend: Color, intensity: float) -> Color:
	return Color(
		minf(base.r + blend.r * intensity, 1.0),
		minf(base.g + blend.g * intensity, 1.0),
		minf(base.b + blend.b * intensity, 1.0)
	)


# Brightens light channels and darkens dark ones, then fades toward the base by intensity
func _overlay_blend(base: Color, blend: Color, intensity: float) -> Color:
	var result := Color(0.0, 0.0, 0.0, 1.0)
	for i in 3:
		var b: float = base[i]
		var l: float = blend[i]
		var overlay := 2.0 * b * l if b < 0.5 else 1.0 - 2.0 * (1.0 - b) * (1.0 - l)
		result[i] = lerpf(b, overlay, intensity)
	return result


func _multiply_blend(base: Color, blend: Color, intensity: float) -> Color:
	return Color(
		lerpf(base.r, base.r * blend.r, intensity),
		lerpf(base.g, base.g * blend.g, intensity),
		lerpf(base.b, base.b * blend.b, intensity)
	)


func pick_color_at_hover() -> bool:
	if _editor._hovered_cell.x < 0 or not _editor._terrain:
		return false

	var data := _editor._terrain.terrain_data
	if not data:
		return false

	var cell := _editor._hovered_cell
	var corner := maxi(_editor._hovered_corner, 0)
	if _is_wall_surface(_editor._hovered_surface):
		var edge: int = _editor._hovered_surface - TerrainData.Surface.NORTH
		_editor.current_vertex_color = data.get_wall_vertex_color(cell.x, cell.y, edge, hovered_wall_vertex(edge))
	elif _editor._hover_editing_floor:
		_editor.current_vertex_color = data.get_floor_vertex_color(cell.x, cell.y, corner)
	else:
		_editor.current_vertex_color = data.get_top_vertex_color(cell.x, cell.y, corner)

	return true
