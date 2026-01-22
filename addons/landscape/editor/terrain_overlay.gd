@tool
class_name TerrainOverlay
extends RefCounted

## Handles all overlay drawing for the terrain editor.
## Draws selection highlights, corner indicators, and tool-specific visualizations.

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func draw(overlay: Control, terrain: LandscapeTerrain) -> void:
	if _editor._hovered_cell.x < 0 or not terrain or _editor.current_tool == TerrainEditor.Tool.NONE:
		return

	var camera := _editor._last_camera
	if not camera:
		return

	var data := terrain.terrain_data
	if not data:
		return

	var display_cell := _editor._drag_cell if _editor._is_dragging else _editor._hovered_cell
	if display_cell.x < 0:
		return

	# Get all cells in brush area for display
	var brush_cells := _editor._drag_brush_cells if _editor._is_dragging else _editor.get_brush_cells(display_cell, data, _editor._brush_corner)

	# Paint tool: show outline only (tile preview is done via shader)
	if _editor.current_tool == TerrainEditor.Tool.PAINT:
		# Don't show outline when surface is locked and hovering a different surface
		if _editor._paint_surface_locked and _editor._hovered_surface != _editor._paint_locked_surface:
			return
		for cell in brush_cells:
			_draw_surface_outline(overlay, camera, terrain, data, cell, _editor._hovered_surface)
		return

	# Flip diagonal tool: highlight top surface and show current diagonal
	if _editor.current_tool == TerrainEditor.Tool.FLIP_DIAGONAL:
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, Color.ORANGE)
			_draw_diagonal_indicator(overlay, camera, terrain, data, cell)
		return

	# Flatten tool: highlight brush area
	if _editor.current_tool == TerrainEditor.Tool.FLATTEN:
		var color := Color.MAGENTA
		for cell in brush_cells:
			_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, color)
		return

	# Mountain tool: show core area and slope preview
	if _editor.current_tool == TerrainEditor.Tool.MOUNTAIN:
		var core_color := Color.ORANGE if not _editor._is_dragging else Color.GREEN
		var slope_color := Color(0.6, 0.4, 0.2, 0.5)  # Brown for slopes

		# During drag, show all affected cells
		if _editor._is_dragging:
			# Draw slope cells first (behind core)
			for cell in _editor._drag_mountain_all_cells:
				var is_core := false
				for core_cell in _editor._drag_brush_cells:
					if core_cell == cell:
						is_core = true
						break
				if not is_core:
					_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, slope_color)
			# Draw core cells on top
			for cell in _editor._drag_brush_cells:
				_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, core_color)
		else:
			# Just show core brush area when hovering
			for cell in brush_cells:
				_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, core_color)
		return

	# Fence tool: show fence edge highlight
	if _editor.current_tool == TerrainEditor.Tool.FENCE:
		_draw_fence_overlay(overlay, camera, terrain, data)
		return

	# Sculpt tool: draw cell/corner highlight
	var display_corner := _editor._drag_corner if _editor._is_dragging else _editor._hovered_corner
	var display_mode := _editor._drag_mode if _editor._is_dragging else _editor._hover_mode
	var is_floor_editing := _editor._drag_editing_floor if _editor._is_dragging else _editor._hover_editing_floor

	# For brush size > 1, force cell mode display
	if _editor.brush_size > 1:
		display_mode = TerrainEditor.HoverMode.CELL

	# Use cyan for floor editing, yellow/green for top editing
	var color: Color
	if is_floor_editing:
		color = Color.CYAN if not _editor._is_dragging else Color.GREEN
	else:
		color = Color.YELLOW if not _editor._is_dragging else Color.GREEN

	if display_mode == TerrainEditor.HoverMode.CORNER and display_corner >= 0:
		# Corner mode: highlight the specific corner area (only for single cell)
		_draw_corner_highlight(overlay, camera, terrain, data, display_cell, display_corner, color)
	elif display_mode == TerrainEditor.HoverMode.FLOOR_CORNER and display_corner >= 0:
		# Floor corner mode: highlight the specific floor corner area
		_draw_corner_highlight(overlay, camera, terrain, data, display_cell, display_corner, color, true)
	else:
		# Cell mode: highlight the entire surface for all brush cells
		for cell in brush_cells:
			if is_floor_editing:
				_draw_floor_surface_highlight(overlay, camera, terrain, data, cell, color)
			else:
				_draw_surface_highlight(overlay, camera, terrain, data, cell, TerrainData.Surface.TOP, color)


func _draw_surface_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, surface: TerrainData.Surface, color: Color = Color.CYAN) -> void:
	# Get surface corners in world space
	var surface_corners := data.get_surface_world_corners(cell.x, cell.y, surface)

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for corner in surface_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 3.0)

	# Draw filled quad as two triangles (more robust than draw_colored_polygon)
	var fill_color := color
	fill_color.a = 0.25
	var tri1 := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri2 := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	overlay.draw_colored_polygon(tri1, fill_color)
	overlay.draw_colored_polygon(tri2, fill_color)


func _draw_surface_outline(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, surface: TerrainData.Surface, color: Color = Color.CYAN) -> void:
	# Get surface corners in world space
	var surface_corners := data.get_surface_world_corners(cell.x, cell.y, surface)

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for corner in surface_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline only
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 2.0)


func _draw_floor_surface_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, color: Color = Color.CYAN) -> void:
	# Get floor corners in world space
	var floor_corners := data.get_floor_world_corners(cell.x, cell.y)

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for corner in floor_corners:
		var world_pos := terrain.to_global(corner)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 3.0)

	# Draw filled quad as two triangles
	var fill_color := color
	fill_color.a = 0.25
	var tri1 := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri2 := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	overlay.draw_colored_polygon(tri1, fill_color)
	overlay.draw_colored_polygon(tri2, fill_color)


func _draw_diagonal_indicator(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i) -> void:
	# Get top corners in world space
	var top_corners := data.get_top_world_corners(cell.x, cell.y)
	var nw := top_corners[0]
	var ne := top_corners[1]
	var se := top_corners[2]
	var sw := top_corners[3]

	# Determine which diagonal is used (same logic as mesh builder)
	var diag1_diff := absf(nw.y - se.y)
	var diag2_diff := absf(ne.y - sw.y)
	var use_nw_se := diag1_diff <= diag2_diff

	# Apply flip flag
	if data.get_diagonal_flip(cell.x, cell.y):
		use_nw_se = not use_nw_se

	# Get the two corners of the current diagonal
	var corner1: Vector3
	var corner2: Vector3
	if use_nw_se:
		corner1 = nw
		corner2 = se
	else:
		corner1 = ne
		corner2 = sw

	# Transform to screen space
	var world1 := terrain.to_global(corner1)
	var world2 := terrain.to_global(corner2)

	if camera.is_position_behind(world1) or camera.is_position_behind(world2):
		return

	var screen1 := camera.unproject_position(world1)
	var screen2 := camera.unproject_position(world2)

	# Draw the diagonal line
	overlay.draw_line(screen1, screen2, Color.ORANGE, 3.0)


func _draw_corner_highlight(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData, cell: Vector2i, corner: int, color: Color, is_floor: bool = false) -> void:
	# Get corners in world space (top or floor depending on mode)
	var top_corners := data.get_floor_world_corners(cell.x, cell.y) if is_floor else data.get_top_world_corners(cell.x, cell.y)

	# Calculate corner area (quadrilateral from corner to midpoints of adjacent edges)
	var corner_pos := top_corners[corner]
	var prev_corner := top_corners[(corner + 3) % 4]
	var next_corner := top_corners[(corner + 1) % 4]
	var center := (top_corners[0] + top_corners[1] + top_corners[2] + top_corners[3]) / 4.0

	# Create a smaller quad around the corner
	var mid_to_prev := (corner_pos + prev_corner) / 2.0
	var mid_to_next := (corner_pos + next_corner) / 2.0
	var mid_to_center := (corner_pos + center) / 2.0

	var world_points: Array[Vector3] = [corner_pos, mid_to_next, mid_to_center, mid_to_prev]

	# Transform to screen space
	var screen_points: Array[Vector2] = []
	var any_behind := false
	for point in world_points:
		var world_pos := terrain.to_global(point)
		if camera.is_position_behind(world_pos):
			any_behind = true
			break
		screen_points.append(camera.unproject_position(world_pos))

	if any_behind or screen_points.size() != 4:
		return

	# Draw outline
	var outline_color := color
	outline_color.a = 0.9
	for i in 4:
		var next := (i + 1) % 4
		overlay.draw_line(screen_points[i], screen_points[next], outline_color, 3.0)

	# Draw filled quad as two triangles (more robust than draw_colored_polygon)
	var fill_color := color
	fill_color.a = 0.35
	var tri1 := PackedVector2Array([screen_points[0], screen_points[1], screen_points[2]])
	var tri2 := PackedVector2Array([screen_points[0], screen_points[2], screen_points[3]])
	overlay.draw_colored_polygon(tri1, fill_color)
	overlay.draw_colored_polygon(tri2, fill_color)

	# Draw corner circle
	overlay.draw_circle(screen_points[0], 6.0, color)


func _draw_fence_overlay(overlay: Control, camera: Camera3D, terrain: LandscapeTerrain, data: TerrainData) -> void:
	var cell := _editor._fence_drag_cell if _editor._is_fence_dragging else _editor._hovered_cell
	var edge := _editor._fence_drag_edge if _editor._is_fence_dragging else _editor._hovered_fence_edge

	if cell.x < 0 or edge < 0:
		return

	var color := Color.CYAN if not _editor._is_fence_dragging else Color.GREEN

	# Get fence surface
	var fence_surface: TerrainData.Surface
	match edge:
		0: fence_surface = TerrainData.Surface.FENCE_NORTH
		1: fence_surface = TerrainData.Surface.FENCE_EAST
		2: fence_surface = TerrainData.Surface.FENCE_SOUTH
		3: fence_surface = TerrainData.Surface.FENCE_WEST

	# Check if fence exists
	var has_fence := data.has_fence(cell.x, cell.y, edge)

	if has_fence:
		# Draw the fence surface highlight
		_draw_surface_highlight(overlay, camera, terrain, data, cell, fence_surface, color)

		# If hovering a corner, highlight that corner
		if not _editor._is_fence_dragging and _editor._hovered_fence_hover != TerrainEditor.FenceHover.MIDDLE and _editor._hovered_fence_hover != TerrainEditor.FenceHover.NONE:
			var fence_corners := data.get_fence_world_corners(cell.x, cell.y, fence_surface)
			var corner_idx: int
			if _editor._hovered_fence_hover == TerrainEditor.FenceHover.LEFT_CORNER:
				corner_idx = 0  # top-left
			else:
				corner_idx = 1  # top-right

			var corner_world := terrain.to_global(fence_corners[corner_idx])
			if not camera.is_position_behind(corner_world):
				var corner_screen := camera.unproject_position(corner_world)
				overlay.draw_circle(corner_screen, 8.0, Color.WHITE)
				overlay.draw_circle(corner_screen, 6.0, color)
	else:
		# No fence - draw edge highlight to show where fence will be created
		var top_corners := data.get_top_world_corners(cell.x, cell.y)
		var edge_start: Vector3
		var edge_end: Vector3
		match edge:
			0:  # NORTH
				edge_start = top_corners[0]  # NW
				edge_end = top_corners[1]    # NE
			1:  # EAST
				edge_start = top_corners[1]  # NE
				edge_end = top_corners[2]    # SE
			2:  # SOUTH
				edge_start = top_corners[2]  # SE
				edge_end = top_corners[3]    # SW
			3:  # WEST
				edge_start = top_corners[3]  # SW
				edge_end = top_corners[0]    # NW

		var world_start := terrain.to_global(edge_start)
		var world_end := terrain.to_global(edge_end)

		if camera.is_position_behind(world_start) or camera.is_position_behind(world_end):
			return

		var screen_start := camera.unproject_position(world_start)
		var screen_end := camera.unproject_position(world_end)

		# Draw edge line with preview of fence height
		overlay.draw_line(screen_start, screen_end, color, 4.0)

		# Draw small circles at edge endpoints
		overlay.draw_circle(screen_start, 5.0, color)
		overlay.draw_circle(screen_end, 5.0, color)
