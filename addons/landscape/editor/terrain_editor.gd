@tool
class_name TerrainEditor
extends RefCounted

enum Tool { NONE, SCULPT, PAINT, COLOR, FLIP_DIAGONAL, FLATTEN, MOUNTAIN, FENCE }
enum HoverMode { CELL, CORNER, FLOOR_CORNER }
enum FenceHover { NONE, LEFT_CORNER, RIGHT_CORNER, MIDDLE }

signal tool_changed(new_tool: Tool)
signal hover_changed(cell: Vector2i, corner: int, mode: int)
signal height_changed(height: float, corner: int, mode: int)
signal paint_state_changed()
signal brush_size_changed(new_size: int)
signal vertex_color_changed()

var editor_interface: EditorInterface
var undo_redo: EditorUndoRedoManager

var current_tool: Tool = Tool.NONE:
	set(value):
		var old_tool := current_tool
		current_tool = value
		tool_changed.emit(value)
		if value == Tool.NONE:
			_clear_hover()
		elif old_tool == Tool.PAINT and value != Tool.PAINT:
			# Clear paint preview when switching away from paint tool
			if _terrain:
				_terrain.clear_preview()
			_paint_preview_buffer.clear()

# Paint tool state
var current_paint_tile: int = 0:
	set(value):
		current_paint_tile = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_surface: TerrainData.Surface = TerrainData.Surface.TOP:
	set(value):
		current_paint_surface = value
		paint_state_changed.emit()

var current_paint_rotation: TerrainData.Rotation = TerrainData.Rotation.ROT_0:
	set(value):
		current_paint_rotation = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_flip_h: bool = false:
	set(value):
		current_paint_flip_h = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_flip_v: bool = false:
	set(value):
		current_paint_flip_v = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_random: bool = false:
	set(value):
		current_paint_random = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_erase: bool = false:
	set(value):
		current_paint_erase = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

var current_paint_wall_align: TerrainData.WallAlign = TerrainData.WallAlign.WORLD:
	set(value):
		current_paint_wall_align = value
		paint_state_changed.emit()
		if _paint_handler:
			_paint_handler.update_preview()

# Brush size (1 = 1x1, 2 = 2x2, 3 = 3x3, etc.)
var brush_size: int = 1:
	set(value):
		brush_size = clampi(value, 1, 9)
		brush_size_changed.emit(brush_size)

# Vertex color painting state
var current_vertex_color: Color = Color.WHITE:
	set(value):
		current_vertex_color = value
		vertex_color_changed.emit()

var current_vertex_color_erase: bool = false:
	set(value):
		current_vertex_color_erase = value
		vertex_color_changed.emit()

var current_vertex_color_light_mode: bool = false:
	set(value):
		current_vertex_color_light_mode = value
		vertex_color_changed.emit()

enum BlendMode { SCREEN, ADDITIVE, OVERLAY, MULTIPLY }

var current_vertex_color_blend_mode: BlendMode = BlendMode.SCREEN:
	set(value):
		current_vertex_color_blend_mode = value
		vertex_color_changed.emit()

# Corner detection threshold - distance from corner as fraction of cell size
const CORNER_THRESHOLD := 0.45

var _terrain: LandscapeTerrain
var _hovered_cell: Vector2i = Vector2i(-1, -1)
var _hovered_corner: int = -1
var _brush_corner: int = -1  # Nearest corner for even brush sizes (0=NW, 1=NE, 2=SE, 3=SW)
var _hover_mode: HoverMode = HoverMode.CELL
var _hovered_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _last_camera: Camera3D

# Drag state
var _is_dragging: bool = false
var _drag_cell: Vector2i = Vector2i(-1, -1)
var _drag_corner: int = -1
var _drag_mode: HoverMode = HoverMode.CELL
var _drag_original_corners: Array[int] = []
var _drag_current_delta: int = 0
var _drag_start_mouse_y: float = 0.0
var _drag_world_pos: Vector3 = Vector3.ZERO  # World position of drag point for scale calculation
var _drag_brush_cells: Array[Vector2i] = []  # All cells in brush area during drag
var _drag_brush_original_corners: Dictionary = {}  # Original corners for each cell in brush: "x,z" -> Array[int]
var _drag_sticky_corners: Array[int] = []  # Current heights for non-dragged corners (sticky per step)
var _drag_brush_min_height: int = 0  # Min corner height across all brush cells at drag start
var _drag_brush_max_height: int = 0  # Max corner height across all brush cells at drag start

# Floor editing state
var _hover_editing_floor: bool = false
var _drag_editing_floor: bool = false
var _drag_floor_original_corners: Array[int] = []
var _drag_floor_sticky_corners: Array[int] = []
var _drag_brush_floor_original_corners: Dictionary = {}  # Floor corners for each cell in brush: "x,z" -> Array[int]
var _drag_floor_brush_min_height: int = 0  # Min floor corner height across all brush cells
var _drag_floor_brush_max_height: int = 0  # Max floor corner height across all brush cells
var _drag_mountain_all_cells: Array[Vector2i] = []  # All cells affected by mountain tool (core + slopes)
var _drag_mountain_original_corners: Dictionary = {}  # Original corners for all mountain-affected cells
var _drag_mountain_corner_distances: Dictionary = {}  # Precomputed corner distances from core

# Flatten drag state
var _is_flatten_dragging: bool = false
var _flatten_target_height: int = 0
var _flatten_affected_cells: Dictionary = {}  # Vector2i -> original corners Array[int]

# Paint drag state
var _is_paint_dragging: bool = false
var _last_painted_cell: Vector2i = Vector2i(-1, -1)
var _last_painted_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _paint_preview_buffer: Dictionary = {}  # Preview buffer: "x,z,surface" -> packed_tile_value
var _paint_original_values: Dictionary = {}  # Original values for undo: "x,z,surface" -> packed_tile_value
var _paint_surface_locked: bool = false  # When true, only paint on the locked surface type
var _paint_locked_surface: TerrainData.Surface = TerrainData.Surface.TOP

# Right-click picker state
var _right_click_picking: bool = false

# Vertex color drag state
var _is_color_dragging: bool = false

# Fence tool state
var _hovered_fence_edge: int = -1  # 0=N, 1=E, 2=S, 3=W, -1=none
var _hovered_fence_hover: FenceHover = FenceHover.NONE

# Fence drag state
var _is_fence_dragging: bool = false
var _fence_drag_cell: Vector2i = Vector2i(-1, -1)
var _fence_drag_edge: int = -1
var _fence_drag_corner: int = -1  # 0=left, 1=right, -1=both (middle)
var _fence_original_heights: Array[int] = [0, 0]  # [left, right]
var _fence_neighbor_original_heights: Array[int] = [0, 0]  # Neighbor fence that may be cleared
var _fence_drag_start_mouse_y: float = 0.0
var _fence_drag_world_pos: Vector3 = Vector3.ZERO
var _fence_current_delta: int = 0

# Handlers for modular tool logic
var _overlay_handler: TerrainOverlay
var _fence_handler: FenceHandler
var _paint_handler: PaintHandler
var _flatten_handler: FlattenHandler
var _sculpt_handler: SculptHandler
var _mountain_handler: MountainHandler
var _color_handler: ColorHandler


func _init() -> void:
	_overlay_handler = TerrainOverlay.new(self)
	_fence_handler = FenceHandler.new(self)
	_paint_handler = PaintHandler.new(self)
	_color_handler = ColorHandler.new(self)
	_flatten_handler = FlattenHandler.new(self)
	_sculpt_handler = SculptHandler.new(self)
	_mountain_handler = MountainHandler.new(self)


func set_terrain(terrain: LandscapeTerrain) -> void:
	_terrain = terrain
	_clear_hover()
	_cancel_all_drags()


func _cancel_all_drags() -> void:
	if _is_dragging:
		if current_tool == Tool.MOUNTAIN:
			_mountain_handler.cancel_drag()
		else:
			_sculpt_handler.cancel_drag()
	if _is_flatten_dragging:
		_flatten_handler.cancel_drag()
	if _is_paint_dragging:
		_paint_handler.cancel_preview()
	if _is_color_dragging:
		_color_handler.cancel_drag()
	if _is_fence_dragging:
		_fence_handler.cancel_drag()


func get_hovered_surface() -> TerrainData.Surface:
	return _hovered_surface


func clear_all_previews() -> void:
	# Clear hover state (which also clears paint preview)
	_clear_hover()


func _clear_hover() -> void:
	if _hovered_cell.x >= 0:
		_hovered_cell = Vector2i(-1, -1)
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		_hover_editing_floor = false
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
	# Clear buffer-based paint preview
	if _terrain:
		_terrain.clear_preview()
	_paint_preview_buffer.clear()


func get_current_height() -> float:
	if not _terrain or not _terrain.terrain_data:
		return NAN

	var cell := _drag_cell if _is_dragging else _hovered_cell
	var corner := _drag_corner if _is_dragging else _hovered_corner
	var mode := _drag_mode if _is_dragging else _hover_mode

	if cell.x < 0:
		return NAN

	var data := _terrain.terrain_data
	var corners := data.get_top_corners(cell.x, cell.y)

	if mode == HoverMode.CORNER and corner >= 0:
		return data.steps_to_world(corners[corner])
	elif mode == HoverMode.FLOOR_CORNER and corner >= 0:
		var floor_corners := data.get_floor_corners(cell.x, cell.y)
		return data.steps_to_world(floor_corners[corner])
	else:
		var avg := 0.0
		for c in corners:
			avg += data.steps_to_world(c)
		return avg / 4.0


func _should_edit_floor(hit_pos: Vector3, cell: Vector2i, surface: TerrainData.Surface, data: TerrainData) -> bool:
	# Get top and floor corners
	var top_corners := data.get_top_corners(cell.x, cell.y)
	var floor_corners := data.get_floor_corners(cell.x, cell.y)

	var local_hit := _terrain.to_local(hit_pos)

	# For TOP surface, check if we're hitting the floor (bottom) rather than the top
	# This happens when the hit Y is closer to floor height than top height
	if surface == TerrainData.Surface.TOP:
		var avg_top := (data.steps_to_world(top_corners[0]) + data.steps_to_world(top_corners[1]) +
					   data.steps_to_world(top_corners[2]) + data.steps_to_world(top_corners[3])) / 4.0
		var avg_floor := (data.steps_to_world(floor_corners[0]) + data.steps_to_world(floor_corners[1]) +
						 data.steps_to_world(floor_corners[2]) + data.steps_to_world(floor_corners[3])) / 4.0

		# If looking from below (camera below surface), edit floor for the full cell
		if _last_camera:
			var local_camera := _terrain.to_local(_last_camera.global_position)
			if local_camera.y < avg_floor:
				return true

		var mid_height := (avg_top + avg_floor) / 2.0
		return local_hit.y < mid_height

	# For wall surfaces, check if below midpoint
	if surface >= TerrainData.Surface.NORTH and surface <= TerrainData.Surface.WEST:
		# Determine which corners are relevant for this wall edge
		var left_corner: int
		var right_corner: int
		match surface:
			TerrainData.Surface.NORTH:
				left_corner = TerrainData.Corner.NW
				right_corner = TerrainData.Corner.NE
			TerrainData.Surface.EAST:
				left_corner = TerrainData.Corner.NE
				right_corner = TerrainData.Corner.SE
			TerrainData.Surface.SOUTH:
				left_corner = TerrainData.Corner.SE
				right_corner = TerrainData.Corner.SW
			TerrainData.Surface.WEST:
				left_corner = TerrainData.Corner.SW
				right_corner = TerrainData.Corner.NW
			_:
				return false

		# Calculate midpoint height between top and floor
		var top_height := (data.steps_to_world(top_corners[left_corner]) + data.steps_to_world(top_corners[right_corner])) / 2.0
		var floor_height := (data.steps_to_world(floor_corners[left_corner]) + data.steps_to_world(floor_corners[right_corner])) / 2.0
		var mid_height := (top_height + floor_height) / 2.0
		return local_hit.y < mid_height

	return false


func handle_input(camera: Camera3D, event: InputEvent, terrain: LandscapeTerrain) -> bool:
	if not terrain:
		return false

	_terrain = terrain
	_last_camera = camera

	if current_tool == Tool.NONE:
		return false

	# Handle keyboard shortcuts for paint tool (Tiled-style)
	if current_tool == Tool.PAINT and event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_X:
					_paint_handler.toggle_flip_h()
					return true
				KEY_Y:
					_paint_handler.toggle_flip_v()
					return true
				KEY_Z:
					if key.shift_pressed:
						_paint_handler.rotate_ccw()
					else:
						_paint_handler.rotate_cw()
					return true

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_dragging:
			if current_tool == Tool.MOUNTAIN:
				_mountain_handler.update_drag(camera, motion.position)
			else:
				_sculpt_handler.update_drag(camera, motion.position)
			return true
		elif _is_flatten_dragging:
			_flatten_handler.update_drag(camera, motion.position)
			return true
		elif _is_paint_dragging:
			_paint_handler.update_drag(camera, motion.position)
			return true
		elif _is_color_dragging:
			_color_handler.update_drag(camera, motion.position)
			return true
		elif _is_fence_dragging:
			_fence_handler.update_drag(camera, motion.position)
			return true
		else:
			# Cancel right-click picker if mouse moves (user is moving camera)
			if _right_click_picking:
				_right_click_picking = false
			_update_hover(camera, motion.position, motion.shift_pressed)
			return false

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _start_drag(camera, mb.position, mb.shift_pressed)
			else:
				if _is_dragging:
					if current_tool == Tool.MOUNTAIN:
						_mountain_handler.finish_drag()
					else:
						_sculpt_handler.finish_drag()
					return true
				elif _is_flatten_dragging:
					_flatten_handler.finish_drag()
					return true
				elif _is_paint_dragging:
					_paint_handler.finish_drag()
					return true
				elif _is_color_dragging:
					_color_handler.finish_drag()
					return true
				elif _is_fence_dragging:
					_fence_handler.finish_drag()
					return true
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if _is_dragging:
				if current_tool == Tool.MOUNTAIN:
					_mountain_handler.cancel_drag()
				else:
					_sculpt_handler.cancel_drag()
				return true
			elif _is_flatten_dragging:
				_flatten_handler.cancel_drag()
				return true
			elif _is_paint_dragging:
				_paint_handler.cancel_preview()
				return true
			elif _is_color_dragging:
				_color_handler.cancel_drag()
				return true
			elif _is_fence_dragging:
				_fence_handler.cancel_drag()
				return true
			elif current_tool == Tool.PAINT or current_tool == Tool.COLOR:
				if mb.pressed:
					# Start right-click - might be picker or camera movement
					_right_click_picking = true
				else:
					# Right-click released - pick tile/color if we didn't move
					if _right_click_picking:
						_right_click_picking = false
						if current_tool == Tool.PAINT:
							_paint_handler.pick_tile_at_hover()
						elif current_tool == Tool.COLOR:
							_color_handler.pick_color_at_hover()
				# Don't consume - allow camera movement
				return false

	return false


func _start_drag(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	# Handle paint tool
	if current_tool == Tool.PAINT:
		# Clear any existing preview and start fresh
		_paint_preview_buffer.clear()
		_paint_original_values.clear()
		# Lock surface when shift is held
		if shift_pressed:
			_paint_surface_locked = true
			_paint_locked_surface = _hovered_surface
		# Build preview for initial brush area (use locked surface if enabled)
		var paint_surface := _paint_locked_surface if _paint_surface_locked else _hovered_surface
		var previewed := _paint_handler._build_paint_preview(data, _hovered_cell, paint_surface)
		if previewed:
			_is_paint_dragging = true
			_last_painted_cell = _hovered_cell
			_last_painted_surface = paint_surface
			_terrain.set_tile_previews(_paint_preview_buffer)
		return previewed

	# Handle vertex color tool
	if current_tool == Tool.COLOR:
		return _color_handler.start_drag(camera, mouse_pos, data)

	# Handle flip diagonal tool
	if current_tool == Tool.FLIP_DIAGONAL:
		_flip_diagonal_brush_area(data, _hovered_cell)
		return true

	# Handle flatten tool - start drag
	if current_tool == Tool.FLATTEN:
		return _flatten_handler.start_drag(data)

	# Handle fence tool
	if current_tool == Tool.FENCE:
		if _hovered_fence_edge < 0:
			return false

		# Shift+click = delete fence
		if shift_pressed:
			_fence_handler.delete_fence(data, _hovered_cell, _hovered_fence_edge)
			return true

		return _fence_handler.start_drag(camera, mouse_pos, data)

	if current_tool == Tool.SCULPT:
		return _sculpt_handler.start_drag(camera, mouse_pos, data)
	elif current_tool == Tool.MOUNTAIN:
		return _mountain_handler.start_drag(camera, mouse_pos, data)

	return false


func _update_hover(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> void:
	if _is_dragging:
		return

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	var hit := _raycast_terrain(ray_origin, ray_dir)
	if hit.is_empty():
		if _hovered_cell.x >= 0:
			_hovered_cell = Vector2i(-1, -1)
			_hovered_corner = -1
			_hover_mode = HoverMode.CELL
			_hovered_surface = TerrainData.Surface.TOP
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		# Clear paint preview when not hovering terrain (but not during paint drag)
		if current_tool == Tool.PAINT and _terrain and not _is_paint_dragging:
			_terrain.clear_preview()
		return

	var hit_pos: Vector3 = hit.position
	var hit_normal: Vector3 = hit.normal

	var old_cell := _hovered_cell
	var old_corner := _hovered_corner
	var old_mode := _hover_mode
	var old_surface := _hovered_surface

	_hovered_surface = _surface_from_normal(hit_normal)

	# For walls/fences, adjust the cell based on which cell owns the surface
	# The hit position might be on the boundary, so we offset slightly into the correct cell
	var adjusted_pos := hit_pos
	if _hovered_surface == TerrainData.Surface.SOUTH or _hovered_surface == TerrainData.Surface.FENCE_SOUTH:
		adjusted_pos.z -= 0.01
	elif _hovered_surface == TerrainData.Surface.EAST or _hovered_surface == TerrainData.Surface.FENCE_EAST:
		adjusted_pos.x -= 0.01
	elif _hovered_surface == TerrainData.Surface.NORTH or _hovered_surface == TerrainData.Surface.FENCE_NORTH:
		adjusted_pos.z += 0.01
	elif _hovered_surface == TerrainData.Surface.WEST or _hovered_surface == TerrainData.Surface.FENCE_WEST:
		adjusted_pos.x += 0.01

	_hovered_cell = _terrain.world_to_cell(adjusted_pos)

	# Check if we hit a fence surface instead of a wall
	# Fences extend upward from terrain top, walls extend downward
	if _hovered_surface >= TerrainData.Surface.NORTH and _hovered_surface <= TerrainData.Surface.WEST:
		var local_hit := _terrain.to_local(hit_pos)
		var data := _terrain.terrain_data
		var edge := _hovered_surface - 1  # NORTH=1 -> edge 0, etc.
		if data.has_fence(_hovered_cell.x, _hovered_cell.y, edge):
			# Get terrain top height at this edge
			var top_corners := data.get_top_corners(_hovered_cell.x, _hovered_cell.y)
			var left_corner: int
			var right_corner: int
			match edge:
				0:  # NORTH
					left_corner = TerrainData.Corner.NW
					right_corner = TerrainData.Corner.NE
				1:  # EAST
					left_corner = TerrainData.Corner.NE
					right_corner = TerrainData.Corner.SE
				2:  # SOUTH
					left_corner = TerrainData.Corner.SE
					right_corner = TerrainData.Corner.SW
				3:  # WEST
					left_corner = TerrainData.Corner.SW
					right_corner = TerrainData.Corner.NW

			var top_height := (data.steps_to_world(top_corners[left_corner]) + data.steps_to_world(top_corners[right_corner])) / 2.0
			# If hit is above the terrain top, it's a fence
			if local_hit.y > top_height - 0.01:
				_hovered_surface = [TerrainData.Surface.FENCE_NORTH, TerrainData.Surface.FENCE_EAST, TerrainData.Surface.FENCE_SOUTH, TerrainData.Surface.FENCE_WEST][edge]

	# Calculate position within cell to determine nearest corner (for all tools)
	var local_pos := _terrain.to_local(hit_pos)
	var cell_size := _terrain.terrain_data.cell_size
	var cell_local_x := local_pos.x - _hovered_cell.x * cell_size
	var cell_local_z := local_pos.z - _hovered_cell.y * cell_size

	# Normalize to 0-1 range within cell
	var norm_x := cell_local_x / cell_size
	var norm_z := cell_local_z / cell_size

	# Check distance to each corner
	var corner_dists: Array[float] = [
		Vector2(norm_x, norm_z).length(),              # NW (0,0)
		Vector2(norm_x - 1.0, norm_z).length(),        # NE (1,0)
		Vector2(norm_x - 1.0, norm_z - 1.0).length(),  # SE (1,1)
		Vector2(norm_x, norm_z - 1.0).length(),        # SW (0,1)
	]

	# Find closest corner (used by even brush sizes to center on corner)
	var min_dist := corner_dists[0]
	var closest_corner := 0
	for i in range(1, 4):
		if corner_dists[i] < min_dist:
			min_dist = corner_dists[i]
			closest_corner = i

	# Store brush corner for even brush size centering
	_brush_corner = closest_corner

	# For fence tool, we track edge hover mode instead of corner
	if current_tool == Tool.FENCE:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		_fence_handler.update_hover(local_pos, cell_size)
		if old_cell != _hovered_cell:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		return

	# For paint, flip diagonal, and mountain tools, we don't need corner hover mode
	if current_tool == Tool.PAINT or current_tool == Tool.FLIP_DIAGONAL or current_tool == Tool.MOUNTAIN:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		if old_cell != _hovered_cell or old_surface != _hovered_surface:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		# Update buffer-based paint preview (hover preview, not during drag)
		if current_tool == Tool.PAINT and _terrain and not _is_paint_dragging:
			# Handle surface lock with shift key
			if shift_pressed:
				if not _paint_surface_locked:
					# Lock to current surface when shift first pressed
					_paint_surface_locked = true
					_paint_locked_surface = _hovered_surface
				if _hovered_surface == _paint_locked_surface:
					_paint_handler.update_hover_preview()
				else:
					_terrain.clear_preview()
			else:
				# Release lock when shift released
				_paint_surface_locked = false
				_paint_handler.update_hover_preview()
		return

	# For sculpt/flatten tools, also track corner hover mode
	_hovered_corner = closest_corner

	# Determine floor editing based on hit position (wall or bottom surface)
	_hover_editing_floor = _should_edit_floor(hit_pos, _hovered_cell, _hovered_surface, _terrain.terrain_data)

	# Determine mode based on distance to corner
	if min_dist < CORNER_THRESHOLD:
		_hover_mode = HoverMode.FLOOR_CORNER if _hover_editing_floor else HoverMode.CORNER
	else:
		_hover_mode = HoverMode.CELL
		# Allow cell mode floor editing when looking from below
		if _hover_editing_floor and _last_camera:
			var floor_corners := _terrain.terrain_data.get_floor_corners(_hovered_cell.x, _hovered_cell.y)
			var avg_floor := (_terrain.terrain_data.steps_to_world(floor_corners[0]) +
							  _terrain.terrain_data.steps_to_world(floor_corners[1]) +
							  _terrain.terrain_data.steps_to_world(floor_corners[2]) +
							  _terrain.terrain_data.steps_to_world(floor_corners[3])) / 4.0
			var local_camera := _terrain.to_local(_last_camera.global_position)
			if local_camera.y >= avg_floor:
				_hover_editing_floor = false  # Only disable if not looking from below

	if old_cell != _hovered_cell or old_corner != _hovered_corner or old_mode != _hover_mode:
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)


func _surface_from_normal(normal: Vector3) -> TerrainData.Surface:
	var up_dot := abs(normal.y)

	# Top surface detection (mostly horizontal)
	if up_dot > 0.7:
		return TerrainData.Surface.TOP

	# Wall surface - determine direction from normal
	var abs_normal := normal.abs()
	if abs_normal.z > abs_normal.x:
		# North or South wall
		return TerrainData.Surface.NORTH if normal.z < 0 else TerrainData.Surface.SOUTH
	else:
		# East or West wall
		return TerrainData.Surface.EAST if normal.x > 0 else TerrainData.Surface.WEST


func _raycast_terrain(origin: Vector3, direction: Vector3) -> Dictionary:
	if not _terrain or not _terrain.terrain_data:
		return {}

	var space_state := _terrain.get_world_3d().direct_space_state
	var end := origin + direction * 1000.0

	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return {}

	# Check if we hit the terrain
	var collider := result.get("collider")
	if collider and collider.get_parent() == _terrain:
		return {
			"position": result.get("position"),
			"normal": result.get("normal", Vector3.UP)
		}

	return {}


func _flip_diagonal_brush_area(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := get_brush_cells(center, data, _brush_corner)

	if brush_cells.is_empty():
		return

	# Create single undo action for all cells with batching
	undo_redo.create_action("Flip Diagonal")
	undo_redo.add_do_method(data, "begin_batch")
	undo_redo.add_undo_method(data, "begin_batch")
	for cell in brush_cells:
		var old_flip := data.get_diagonal_flip(cell.x, cell.y)
		var new_flip := not old_flip
		undo_redo.add_do_method(data, "set_diagonal_flip", cell.x, cell.y, new_flip)
		undo_redo.add_undo_method(data, "set_diagonal_flip", cell.x, cell.y, old_flip)
	undo_redo.add_do_method(data, "end_batch")
	undo_redo.add_undo_method(data, "end_batch")
	undo_redo.commit_action()


# Get all cells within the brush area centered on the given cell
# For even brush sizes with corner specified, centers around the corner point
func get_brush_cells(center: Vector2i, data: TerrainData, corner: int = -1) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var half := brush_size / 2
	var is_even := brush_size % 2 == 0

	var start_x: int
	var end_x: int
	var start_z: int
	var end_z: int

	# For odd sizes OR no corner info: use cell-centered logic
	# For even sizes with corner: center around corner point
	if is_even and corner >= 0:
		# Corner-based offset for even brush sizes
		# Corner 0 (NW): brush extends toward negative x and z
		# Corner 1 (NE): brush extends toward positive x and negative z
		# Corner 2 (SE): brush extends toward positive x and z
		# Corner 3 (SW): brush extends toward negative x and positive z
		match corner:
			0:  # NW
				start_x = -half
				end_x = half - 1
				start_z = -half
				end_z = half - 1
			1:  # NE
				start_x = 1 - half
				end_x = half
				start_z = -half
				end_z = half - 1
			2:  # SE
				start_x = 1 - half
				end_x = half
				start_z = 1 - half
				end_z = half
			3:  # SW
				start_x = -half
				end_x = half - 1
				start_z = 1 - half
				end_z = half
			_:
				# Fallback to cell-centered
				start_x = -half
				end_x = brush_size - half - 1
				start_z = -half
				end_z = brush_size - half - 1
	else:
		# Cell-centered logic for odd sizes
		# Odd sizes (1,3,5,7,9): centered, e.g. size 3 = -1 to +1
		start_x = -half
		end_x = brush_size - half - 1
		start_z = -half
		end_z = brush_size - half - 1

	for dz in range(start_z, end_z + 1):
		for dx in range(start_x, end_x + 1):
			var cell := Vector2i(center.x + dx, center.y + dz)
			if data.is_valid_cell(cell.x, cell.y):
				cells.append(cell)
	return cells


func draw_overlay(overlay: Control, terrain: LandscapeTerrain) -> void:
	_overlay_handler.draw(overlay, terrain)


func rotate_paint_cw() -> void:
	if _paint_handler:
		_paint_handler.rotate_cw()
