@tool
class_name TerrainOverlay
extends RefCounted

## Draws the viewport overlay for the terrain editor: brush and surface highlights,
## corner handles, diagonal indicators and fence handles.

const OUTLINE_ALPHA := 0.9
const FILL_ALPHA := 0.25
const CORNER_FILL_ALPHA := 0.35
const SLOPE_COLOR := Color(0.6, 0.4, 0.2, 0.5)

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func draw(overlay: Control, terrain: LandscapeTerrain) -> void:
	if _editor._hovered_cell.x < 0 or not terrain or _editor.current_tool == TerrainEditor.Tool.NONE:
		return

	var camera := _editor._last_camera
	var data := terrain.terrain_data if terrain else null
	if not camera or not data:
		return

	var display_cell := _editor._drag_cell if _editor._is_dragging else _editor._hovered_cell
	if display_cell.x < 0:
		return

	var brush_cells := _editor._drag_brush_cells if _editor._is_dragging else _editor.get_brush_cells(display_cell, data, _editor._brush_corner)

	match _editor.current_tool:
		TerrainEditor.Tool.PAINT:
			# The tile itself is previewed through the shader; only outline the brush
			if _editor._paint_surface_locked and _editor._hovered_surface != _editor._paint_locked_surface:
				return
			for cell in brush_cells:
				_draw_quad(overlay, camera, terrain, data.get_surface_world_corners(cell.x, cell.y, _editor._hovered_surface), Color.CYAN, 0.0, 2.0)

		TerrainEditor.Tool.FLIP_DIAGONAL:
			for cell in brush_cells:
				_draw_quad(overlay, camera, terrain, data.get_top_world_corners(cell.x, cell.y), Color.ORANGE, FILL_ALPHA)
				_draw_diagonal_indicator(overlay, camera, terrain, data, cell)

		TerrainEditor.Tool.FLATTEN:
			for cell in brush_cells:
				_draw_quad(overlay, camera, terrain, data.get_top_world_corners(cell.x, cell.y), Color.MAGENTA, FILL_ALPHA)

		TerrainEditor.Tool.MOUNTAIN:
			_draw_mountain(overlay, camera, terrain, data, brush_cells)

		TerrainEditor.Tool.FENCE:
			_draw_fence_overlay(overlay, camera, terrain, data)

		_:
			_draw_sculpt(overlay, camera, terrain, data, display_cell, brush_cells)


func _draw_mountain(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, brush_cells: Array[Vector2i]) -> void:
	var core_color := Color.GREEN if _editor._is_dragging else Color.ORANGE

	if _editor._is_dragging:
		# Slope cells first so the core draws on top
		for cell in _editor._drag_mountain_all_cells:
			if not _editor._drag_brush_cells.has(cell):
				_draw_quad(overlay, camera, terrain, data.get_top_world_corners(cell.x, cell.y), SLOPE_COLOR, FILL_ALPHA)
		for cell in _editor._drag_brush_cells:
			_draw_quad(overlay, camera, terrain, data.get_top_world_corners(cell.x, cell.y), core_color, FILL_ALPHA)
	else:
		for cell in brush_cells:
			_draw_quad(overlay, camera, terrain, data.get_top_world_corners(cell.x, cell.y), core_color, FILL_ALPHA)


# Sculpt and color tools: yellow/cyan for top/floor while hovering, green while dragging
func _draw_sculpt(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, display_cell: Vector2i, brush_cells: Array[Vector2i]) -> void:
	var display_corner := _editor._drag_corner if _editor._is_dragging else _editor._hovered_corner
	var display_mode := _editor._drag_mode if _editor._is_dragging else _editor._hover_mode
	var is_floor := _editor._drag_editing_floor if _editor._is_dragging else _editor._hover_editing_floor

	if _editor.brush_size > 1:
		display_mode = TerrainEditor.HoverMode.CELL

	var color: Color
	if _editor._is_dragging:
		color = Color.GREEN
	else:
		color = Color.CYAN if is_floor else Color.YELLOW

	if display_mode != TerrainEditor.HoverMode.CELL and display_corner >= 0:
		var is_floor_corner := display_mode == TerrainEditor.HoverMode.FLOOR_CORNER
		_draw_corner_highlight(overlay, camera, terrain, data, display_cell, display_corner, color, is_floor_corner)
		return

	for cell in brush_cells:
		var corners := data.get_floor_world_corners(cell.x, cell.y) if is_floor else data.get_top_world_corners(cell.x, cell.y)
		_draw_quad(overlay, camera, terrain, corners, color, FILL_ALPHA)


# Projects terrain-local points to the viewport; empty if any point is behind the camera
func _project(camera: Camera3D, terrain: LandscapeTerrain, points: Array[Vector3]) -> Array[Vector2]:
	var screen_points: Array[Vector2] = []
	for point in points:
		var world_pos := terrain.to_global(point)
		if camera.is_position_behind(world_pos):
			return []
		screen_points.append(camera.unproject_position(world_pos))
	return screen_points


# Outlined quad with optional fill; drawn as two triangles, which stays robust at extreme angles
func _draw_quad(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, corners: Array[Vector3], color: Color, fill_alpha: float, line_width: float = 3.0) -> void:
	var points := _project(camera, terrain, corners)
	if points.size() != 4:
		return

	var outline_color := color
	outline_color.a = OUTLINE_ALPHA
	for i in 4:
		overlay.draw_line(points[i], points[(i + 1) % 4], outline_color, line_width)

	if fill_alpha > 0.0:
		var fill_color := color
		fill_color.a = fill_alpha
		overlay.draw_colored_polygon(PackedVector2Array([points[0], points[1], points[2]]), fill_color)
		overlay.draw_colored_polygon(PackedVector2Array([points[0], points[2], points[3]]), fill_color)


func _draw_diagonal_indicator(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i) -> void:
	var top := data.get_top_world_corners(cell.x, cell.y)

	# Same choice as TerrainMeshBuilder: the flatter diagonal, unless flipped
	var use_nw_se := absf(top[0].y - top[2].y) <= absf(top[1].y - top[3].y)
	if data.get_diagonal_flip(cell.x, cell.y):
		use_nw_se = not use_nw_se

	var ends: Array[Vector3] = [top[0], top[2]] if use_nw_se else [top[1], top[3]]
	var points := _project(camera, terrain, ends)
	if points.size() == 2:
		overlay.draw_line(points[0], points[1], Color.ORANGE, 3.0)


# Highlights the quarter of the cell around one corner
func _draw_corner_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, corner: int, color: Color, is_floor: bool) -> void:
	var corners := data.get_floor_world_corners(cell.x, cell.y) if is_floor else data.get_top_world_corners(cell.x, cell.y)

	var corner_pos := corners[corner]
	var prev_corner := corners[(corner + 3) % 4]
	var next_corner := corners[(corner + 1) % 4]
	var center := (corners[0] + corners[1] + corners[2] + corners[3]) / 4.0
	var quad: Array[Vector3] = [
		corner_pos,
		(corner_pos + next_corner) / 2.0,
		(corner_pos + center) / 2.0,
		(corner_pos + prev_corner) / 2.0,
	]

	_draw_quad(overlay, camera, terrain, quad, color, CORNER_FILL_ALPHA)

	var points := _project(camera, terrain, [corner_pos])
	if points.size() == 1:
		overlay.draw_circle(points[0], 6.0, color)


func _draw_fence_overlay(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData) -> void:
	var cell := _editor._fence_drag_cell if _editor._is_fence_dragging else _editor._hovered_cell
	var edge := _editor._fence_drag_edge if _editor._is_fence_dragging else _editor._hovered_fence_edge
	if cell.x < 0 or edge < 0:
		return

	var color := Color.GREEN if _editor._is_fence_dragging else Color.CYAN

	if not data.has_fence(cell.x, cell.y, edge):
		# No fence yet: mark the edge where one would be created
		var top := data.get_top_world_corners(cell.x, cell.y)
		var ends: Array[Vector3] = [top[TerrainData.EDGE_CORNERS[edge][0]], top[TerrainData.EDGE_CORNERS[edge][1]]]
		var points := _project(camera, terrain, ends)
		if points.size() == 2:
			overlay.draw_line(points[0], points[1], color, 4.0)
			overlay.draw_circle(points[0], 5.0, color)
			overlay.draw_circle(points[1], 5.0, color)
		return

	var fence_corners := data.get_fence_world_corners(cell.x, cell.y, TerrainData.fence_surface_from_edge(edge))
	_draw_quad(overlay, camera, terrain, fence_corners, color, FILL_ALPHA)

	# Handle on the hovered fence corner (top-left = 0, top-right = 1)
	var hover := _editor._hovered_fence_hover
	if _editor._is_fence_dragging or hover == TerrainEditor.FenceHover.MIDDLE or hover == TerrainEditor.FenceHover.NONE:
		return

	var corner_idx := 0 if hover == TerrainEditor.FenceHover.LEFT_CORNER else 1
	var points := _project(camera, terrain, [fence_corners[corner_idx]])
	if points.size() == 1:
		overlay.draw_circle(points[0], 8.0, Color.WHITE)
		overlay.draw_circle(points[0], 6.0, color)
