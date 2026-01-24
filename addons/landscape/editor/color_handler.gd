@tool
class_name ColorHandler
extends RefCounted

## Handles vertex color painting tool operations for the terrain editor.
## Manages corner vertex color painting with brush support.

var _editor: TerrainEditor

# Drag state for color painting
var _original_colors: Dictionary = {}  # "x,z,is_floor" -> Array[int] (4 packed colors)
var _painted_corners: Dictionary = {}  # "x,z,corner,is_floor" -> packed_color (for tracking what was painted)


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	_editor._is_color_dragging = true
	_original_colors.clear()
	_painted_corners.clear()

	# Paint the initial position
	_paint_at_hover(data)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_color_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Update hover position
	_editor._update_hover(camera, mouse_pos)

	if _editor._hovered_cell.x < 0:
		return

	# Paint at current position
	_paint_at_hover(data)


func finish_drag() -> void:
	if not _editor._terrain or _original_colors.is_empty():
		_editor._is_color_dragging = false
		_original_colors.clear()
		_painted_corners.clear()
		return

	var data := _editor._terrain.terrain_data
	if not data:
		_editor._is_color_dragging = false
		return

	# Create undo/redo action
	_editor.undo_redo.create_action("Paint Vertex Colors")
	_editor.undo_redo.add_do_method(data, "begin_batch")
	_editor.undo_redo.add_undo_method(data, "begin_batch")

	for key: String in _original_colors.keys():
		var parts: PackedStringArray = key.split(",")
		var x := int(parts[0])
		var z := int(parts[1])
		var is_floor := parts[2] == "1"

		var original_packed: Array = _original_colors[key]
		var original_typed: Array[int] = []
		for c in original_packed:
			original_typed.append(c)

		if is_floor:
			var final_colors := data.get_floor_vertex_colors(x, z)
			_editor.undo_redo.add_do_method(data, "set_floor_vertex_colors", x, z, final_colors)
			_editor.undo_redo.add_undo_method(data, "set_floor_vertex_colors", x, z, original_typed)
		else:
			var final_colors := data.get_top_vertex_colors(x, z)
			_editor.undo_redo.add_do_method(data, "set_top_vertex_colors", x, z, final_colors)
			_editor.undo_redo.add_undo_method(data, "set_top_vertex_colors", x, z, original_typed)

	_editor.undo_redo.add_do_method(data, "end_batch")
	_editor.undo_redo.add_undo_method(data, "end_batch")
	_editor.undo_redo.commit_action()

	_editor._is_color_dragging = false
	_original_colors.clear()
	_painted_corners.clear()


func cancel_drag() -> void:
	if not _editor._terrain:
		_editor._is_color_dragging = false
		_original_colors.clear()
		_painted_corners.clear()
		return

	var data := _editor._terrain.terrain_data
	if data:
		# Restore original colors
		data.begin_batch()
		for key: String in _original_colors.keys():
			var parts: PackedStringArray = key.split(",")
			var x := int(parts[0])
			var z := int(parts[1])
			var is_floor := parts[2] == "1"

			var original_packed: Array = _original_colors[key]
			var original_typed: Array[int] = []
			for c in original_packed:
				original_typed.append(c)

			if is_floor:
				data.set_floor_vertex_colors(x, z, original_typed)
			else:
				data.set_top_vertex_colors(x, z, original_typed)
		data.end_batch()

	_editor._is_color_dragging = false
	_original_colors.clear()
	_painted_corners.clear()


func _paint_at_hover(data: TerrainData) -> void:
	if _editor._hovered_cell.x < 0:
		return

	var is_floor := _editor._hover_editing_floor
	var brush_cells := _editor.get_brush_cells(_editor._hovered_cell, data, _editor._brush_corner)
	# Use white when erasing, otherwise use the selected color
	var paint_color := Color.WHITE if _editor.current_vertex_color_erase else _editor.current_vertex_color
	var color_packed := paint_color.to_rgba32()

	var cell_size := data.cell_size
	var brush_center := _get_brush_center(data)
	var brush_radius := _editor.brush_size * cell_size / 2.0

	data.begin_batch()
	for cell in brush_cells:
		var cell_key := "%d,%d,%d" % [cell.x, cell.y, 1 if is_floor else 0]

		# Store original colors if not already stored
		if not _original_colors.has(cell_key):
			if is_floor:
				_original_colors[cell_key] = data.get_floor_vertex_colors(cell.x, cell.y)
			else:
				_original_colors[cell_key] = data.get_top_vertex_colors(cell.x, cell.y)

		# Determine which corners to paint
		var corners_to_paint: Array[int] = []

		# For brush size > 1, always paint all corners
		# For brush size 1, use corner mode if close to a corner
		if _editor.brush_size > 1:
			corners_to_paint = [0, 1, 2, 3]
		elif _editor._hover_mode == TerrainEditor.HoverMode.CORNER or _editor._hover_mode == TerrainEditor.HoverMode.FLOOR_CORNER:
			# Only paint the hovered corner
			if _editor._hovered_corner >= 0:
				corners_to_paint = [_editor._hovered_corner]
		else:
			# Cell mode - paint all corners
			corners_to_paint = [0, 1, 2, 3]

		# Paint corners
		for corner in corners_to_paint:
			var corner_key := "%d,%d,%d,%d" % [cell.x, cell.y, corner, 1 if is_floor else 0]

			# In light mode, we allow repainting corners with accumulating blend
			# In normal mode, skip if already painted this corner
			if not _editor.current_vertex_color_light_mode:
				if _painted_corners.has(corner_key):
					continue
				_painted_corners[corner_key] = color_packed

			var final_color := paint_color

			if _editor.current_vertex_color_light_mode and not _editor.current_vertex_color_erase:
				# Calculate intensity based on distance from brush center
				var corner_world_pos := _get_corner_world_pos(cell, corner, cell_size)
				var intensity := _calculate_intensity(corner_world_pos, brush_center, brush_radius)

				if intensity <= 0.0:
					continue

				# Get current color (from original or already-painted state)
				var base_color: Color
				if is_floor:
					base_color = data.get_floor_vertex_color(cell.x, cell.y, corner)
				else:
					base_color = data.get_top_vertex_color(cell.x, cell.y, corner)

				# Blend using selected blend mode
				final_color = _blend_color(base_color, paint_color, intensity)

			if is_floor:
				data.set_floor_vertex_color(cell.x, cell.y, corner, final_color)
			else:
				data.set_top_vertex_color(cell.x, cell.y, corner, final_color)

	data.end_batch()


func _get_brush_center(data: TerrainData) -> Vector2:
	var cell_size := data.cell_size
	var center_cell := _editor._hovered_cell
	var brush_corner := _editor._brush_corner
	var is_even := _editor.brush_size % 2 == 0

	# For odd brush sizes, center on cell center
	# For even brush sizes with corner, center on the corner point
	if is_even and brush_corner >= 0:
		var base := Vector2(center_cell.x * cell_size, center_cell.y * cell_size)
		match brush_corner:
			0:  # NW
				return base
			1:  # NE
				return base + Vector2(cell_size, 0)
			2:  # SE
				return base + Vector2(cell_size, cell_size)
			3:  # SW
				return base + Vector2(0, cell_size)

	# Cell-centered
	return Vector2(
		center_cell.x * cell_size + cell_size / 2.0,
		center_cell.y * cell_size + cell_size / 2.0
	)


func _get_corner_world_pos(cell: Vector2i, corner: int, cell_size: float) -> Vector2:
	var base := Vector2(cell.x * cell_size, cell.y * cell_size)
	match corner:
		0:  # NW
			return base
		1:  # NE
			return base + Vector2(cell_size, 0)
		2:  # SE
			return base + Vector2(cell_size, cell_size)
		3:  # SW
			return base + Vector2(0, cell_size)
	return base


func _calculate_intensity(corner_world_pos: Vector2, brush_center: Vector2, radius: float) -> float:
	if radius <= 0.5:
		return 1.0  # Brush size 1 = full intensity
	var distance := corner_world_pos.distance_to(brush_center)
	var normalized := clampf(distance / radius, 0.0, 1.0)
	return (1.0 - normalized) * (1.0 - normalized)  # Quadratic falloff


func _blend_color(base: Color, blend: Color, intensity: float) -> Color:
	match _editor.current_vertex_color_blend_mode:
		TerrainEditor.BlendMode.SCREEN:
			return _screen_blend(base, blend, intensity)
		TerrainEditor.BlendMode.ADDITIVE:
			return _additive_blend(base, blend, intensity)
		TerrainEditor.BlendMode.OVERLAY:
			return _overlay_blend(base, blend, intensity)
		TerrainEditor.BlendMode.MULTIPLY:
			return _multiply_blend(base, blend, intensity)
	return _screen_blend(base, blend, intensity)


func _screen_blend(base: Color, blend: Color, intensity: float) -> Color:
	# Screen blend: 1 - (1 - base) * (1 - blend * intensity)
	var scaled_r := blend.r * intensity
	var scaled_g := blend.g * intensity
	var scaled_b := blend.b * intensity
	return Color(
		1.0 - (1.0 - base.r) * (1.0 - scaled_r),
		1.0 - (1.0 - base.g) * (1.0 - scaled_g),
		1.0 - (1.0 - base.b) * (1.0 - scaled_b)
	)


func _additive_blend(base: Color, blend: Color, intensity: float) -> Color:
	# Additive blend: base + blend * intensity (clamped to 1)
	return Color(
		minf(base.r + blend.r * intensity, 1.0),
		minf(base.g + blend.g * intensity, 1.0),
		minf(base.b + blend.b * intensity, 1.0)
	)


func _overlay_blend(base: Color, blend: Color, intensity: float) -> Color:
	# Overlay blend: brightens lights, darkens darks
	# Formula: if base < 0.5: 2 * base * blend, else: 1 - 2 * (1-base) * (1-blend)
	# Then lerp from base to result by intensity
	var result := Color()
	for i in 3:
		var b: float = base[i]
		var l: float = blend[i]
		var o: float
		if b < 0.5:
			o = 2.0 * b * l
		else:
			o = 1.0 - 2.0 * (1.0 - b) * (1.0 - l)
		result[i] = lerpf(b, o, intensity)
	result.a = 1.0
	return result


func _multiply_blend(base: Color, blend: Color, intensity: float) -> Color:
	# Multiply blend: base * blend, lerped by intensity
	# At full intensity: base * blend
	# At zero intensity: base
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

	var is_floor := _editor._hover_editing_floor
	var corner := _editor._hovered_corner if _editor._hovered_corner >= 0 else 0

	var picked_color: Color
	if is_floor:
		picked_color = data.get_floor_vertex_color(_editor._hovered_cell.x, _editor._hovered_cell.y, corner)
	else:
		picked_color = data.get_top_vertex_color(_editor._hovered_cell.x, _editor._hovered_cell.y, corner)

	# Set the current color
	_editor.current_vertex_color = picked_color

	return true
