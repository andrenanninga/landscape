@tool
class_name TerrainEditor
extends RefCounted

## Coordinates the terrain tools: tracks the hovered cell, dispatches viewport input to the
## tool handlers and owns the shared drag state they operate on.

enum Tool { NONE, SCULPT, PAINT, COLOR, FLIP_DIAGONAL, FLATTEN, MOUNTAIN, FENCE }
enum HoverMode { CELL, CORNER, FLOOR_CORNER }
enum FenceHover { NONE, LEFT_CORNER, RIGHT_CORNER, MIDDLE }
enum BlendMode { SCREEN, ADDITIVE, OVERLAY, MULTIPLY }

signal tool_changed(new_tool: Tool)
signal hover_changed(cell: Vector2i, corner: int, mode: int)
signal height_changed(height: float, corner: int, mode: int)
signal paint_state_changed()
signal brush_size_changed(new_size: int)
signal vertex_color_changed()

# Distance from a corner (fraction of cell size) within which sculpting targets that corner
const CORNER_THRESHOLD := 0.45

# Walls sit exactly on cell boundaries; hits are nudged this far into the owning cell
const WALL_HIT_NUDGE := 0.01

const RAYCAST_LENGTH := 1000.0

# Collision layer the hovered terrain is moved to while raycasting so overlapping
# terrains and other bodies are ignored
const RAYCAST_LAYER := 20

var editor_interface: EditorInterface
var undo_redo: EditorUndoRedoManager

var current_tool: Tool = Tool.NONE:
	set(value):
		var old_tool := current_tool
		current_tool = value
		tool_changed.emit(value)
		if value == Tool.NONE:
			_clear_hover()
		elif old_tool == Tool.PAINT:
			if _terrain:
				_terrain.clear_preview()
			_paint_preview_buffer.clear()

# Paint tool state
var current_paint_tile: int = 0:
	set(value):
		current_paint_tile = value
		_paint_setting_changed()

var current_paint_rotation: TerrainData.Rotation = TerrainData.Rotation.ROT_0:
	set(value):
		current_paint_rotation = value
		_paint_setting_changed()

var current_paint_flip_h: bool = false:
	set(value):
		current_paint_flip_h = value
		_paint_setting_changed()

var current_paint_flip_v: bool = false:
	set(value):
		current_paint_flip_v = value
		_paint_setting_changed()

var current_paint_random: bool = false:
	set(value):
		current_paint_random = value
		_paint_setting_changed()

var current_paint_erase: bool = false:
	set(value):
		current_paint_erase = value
		_paint_setting_changed()

var current_paint_wall_align: TerrainData.WallAlign = TerrainData.WallAlign.WORLD:
	set(value):
		current_paint_wall_align = value
		_paint_setting_changed()

# All-faces mode paints the top with current_paint_top_tile and the walls with current_paint_side_tile
var current_paint_all_faces: bool = false:
	set(value):
		current_paint_all_faces = value
		_paint_setting_changed()

# Which all-faces slot the palette edits: 0 = top, 1 = sides
var current_tile_slot: int = 0:
	set(value):
		current_tile_slot = value
		paint_state_changed.emit()

var current_paint_top_tile: int = 0:
	set(value):
		current_paint_top_tile = value
		_paint_setting_changed()

var current_paint_side_tile: int = 0:
	set(value):
		current_paint_side_tile = value
		_paint_setting_changed()

# Brush size in cells per side (1 = 1x1, 2 = 2x2, ...)
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

var current_vertex_color_blend_mode: BlendMode = BlendMode.SCREEN:
	set(value):
		current_vertex_color_blend_mode = value
		vertex_color_changed.emit()

var _terrain: LandscapeTerrain
var _last_camera: Camera3D

# Hover state
var _hovered_cell: Vector2i = Vector2i(-1, -1)
var _hovered_corner: int = -1
var _brush_corner: int = -1  # Nearest corner, anchors even-sized brushes (0=NW, 1=NE, 2=SE, 3=SW)
var _hover_mode: HoverMode = HoverMode.CELL
var _hovered_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _hover_editing_floor: bool = false

# Sculpt / mountain drag state
var _is_dragging: bool = false
var _drag_cell: Vector2i = Vector2i(-1, -1)
var _drag_corner: int = -1
var _drag_mode: HoverMode = HoverMode.CELL
var _drag_editing_floor: bool = false
var _drag_original_corners: Array[int] = []
var _drag_sticky_corners: Array[int] = []  # Non-dragged corners keep positions they were pulled to
var _drag_floor_original_corners: Array[int] = []
var _drag_floor_sticky_corners: Array[int] = []
var _drag_current_delta: int = 0
var _drag_start_mouse_y: float = 0.0
var _drag_world_pos: Vector3 = Vector3.ZERO  # Reference point for converting mouse motion to height
var _drag_brush_cells: Array[Vector2i] = []
var _drag_brush_original_corners: Dictionary = {}  # Vector2i cell -> Array[int]
var _drag_brush_floor_original_corners: Dictionary = {}  # Vector2i cell -> Array[int]
var _drag_brush_min_height: int = 0
var _drag_brush_max_height: int = 0
var _drag_floor_brush_min_height: int = 0
var _drag_floor_brush_max_height: int = 0
var _drag_mountain_all_cells: Array[Vector2i] = []  # Core + slope cells
var _drag_mountain_original_corners: Dictionary = {}  # Vector2i cell -> Array[int]
var _drag_mountain_corner_distances: Dictionary = {}  # Vector2i corner point -> distance from core

# Flatten drag state
var _is_flatten_dragging: bool = false
var _flatten_target_height: int = 0

# Paint drag state; buffers are keyed by Vector3i(x, z, surface)
var _is_paint_dragging: bool = false
var _last_painted_cell: Vector2i = Vector2i(-1, -1)
var _last_painted_surface: TerrainData.Surface = TerrainData.Surface.TOP
var _paint_preview_buffer: Dictionary = {}
var _paint_original_values: Dictionary = {}
var _paint_surface_locked: bool = false
var _paint_locked_surface: TerrainData.Surface = TerrainData.Surface.TOP

# Right-click picks a tile/color only if the mouse did not move (otherwise it is camera orbit)
var _right_click_picking: bool = false

var _is_color_dragging: bool = false

# Fence tool state
var _hovered_fence_edge: int = -1  # 0=N, 1=E, 2=S, 3=W, -1=none
var _hovered_fence_hover: FenceHover = FenceHover.NONE
var _is_fence_dragging: bool = false
var _fence_drag_cell: Vector2i = Vector2i(-1, -1)
var _fence_drag_edge: int = -1
var _fence_drag_corner: int = -1  # 0=left, 1=right, -1=both
var _fence_original_heights: Array[int] = [0, 0]
var _fence_drag_start_mouse_y: float = 0.0
var _fence_drag_world_pos: Vector3 = Vector3.ZERO
var _fence_current_delta: int = 0

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
	_cancel_all_drags()
	_clear_hover()
	_terrain = terrain


# The handlers hold a reference back to this editor; break the cycle when the plugin unloads
func dispose() -> void:
	_cancel_all_drags()
	_terrain = null
	_overlay_handler = null
	_fence_handler = null
	_paint_handler = null
	_color_handler = null
	_flatten_handler = null
	_sculpt_handler = null
	_mountain_handler = null


func _paint_setting_changed() -> void:
	paint_state_changed.emit()
	_paint_handler.update_preview()


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
	_clear_hover()


func _clear_hover() -> void:
	if _hovered_cell.x >= 0:
		_hovered_cell = Vector2i(-1, -1)
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		_hover_editing_floor = false
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
	if _terrain:
		_terrain.clear_preview()
	_paint_preview_buffer.clear()


# Height (world units) of the hovered/dragged corner, or the cell average in cell mode
func get_current_height() -> float:
	if not _terrain or not _terrain.terrain_data:
		return NAN

	var cell := _drag_cell if _is_dragging else _hovered_cell
	var corner := _drag_corner if _is_dragging else _hovered_corner
	var mode := _drag_mode if _is_dragging else _hover_mode
	if cell.x < 0:
		return NAN

	var data := _terrain.terrain_data
	if mode == HoverMode.CORNER and corner >= 0:
		return data.steps_to_world(data.get_top_corners(cell.x, cell.y)[corner])
	if mode == HoverMode.FLOOR_CORNER and corner >= 0:
		return data.steps_to_world(data.get_floor_corners(cell.x, cell.y)[corner])
	return _average_height(data.get_top_corners(cell.x, cell.y), data)


static func _average_height(corners: Array[int], data: TerrainData) -> float:
	var total := 0.0
	for c in corners:
		total += data.steps_to_world(c)
	return total / 4.0


# ============================================================================
# SHARED DRAG HELPERS
# ============================================================================

# Converts vertical mouse movement since the drag started into whole height steps, scaled
# so one world unit at world_pos corresponds to its on-screen size. Returns fallback when
# the camera looks straight along the vertical axis and the scale is degenerate.
func mouse_delta_to_steps(camera: Camera3D, world_pos: Vector3, start_mouse_y: float, mouse_y: float, data: TerrainData, fallback: int) -> int:
	var screen_pos := camera.unproject_position(world_pos)
	var screen_above := camera.unproject_position(world_pos + Vector3.UP)
	var pixels_per_unit := screen_pos.y - screen_above.y  # Screen Y grows downward
	if absf(pixels_per_unit) < 0.001:
		return fallback

	var mouse_delta_world := (start_mouse_y - mouse_y) / pixels_per_unit
	return int(round(mouse_delta_world / data.height_step))


# World position of the centre of a cell at the average of the given corner heights
func cell_center_world_pos(cell: Vector2i, heights: Array[int], data: TerrainData) -> Vector3:
	var local_pos := Vector3(
		(cell.x + 0.5) * data.cell_size,
		_average_height(heights, data),
		(cell.y + 0.5) * data.cell_size
	)
	return _terrain.to_global(local_pos)


# Corner of the cell nearest to a terrain-local position (0=NW, 1=NE, 2=SE, 3=SW)
func nearest_corner(local_pos: Vector3, cell: Vector2i, cell_size: float) -> int:
	var norm := Vector2(local_pos.x / cell_size - cell.x, local_pos.z / cell_size - cell.y)
	var corner_points := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]

	var closest := 0
	for i in range(1, 4):
		if norm.distance_to(corner_points[i]) < norm.distance_to(corner_points[closest]):
			closest = i
	return closest


func _corner_distance(local_pos: Vector3, cell: Vector2i, cell_size: float, corner: int) -> float:
	var norm := Vector2(local_pos.x / cell_size - cell.x, local_pos.z / cell_size - cell.y)
	var corner_points := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	return norm.distance_to(corner_points[corner])


# ============================================================================
# INPUT
# ============================================================================

func handle_input(camera: Camera3D, event: InputEvent, terrain: LandscapeTerrain) -> bool:
	if not terrain:
		return false

	_terrain = terrain
	_last_camera = camera

	if current_tool == Tool.NONE:
		return false

	if current_tool == Tool.PAINT and event is InputEventKey:
		if _handle_paint_shortcut(event as InputEventKey):
			return true

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_dragging or _is_flatten_dragging or _is_paint_dragging or _is_color_dragging or _is_fence_dragging:
			_update_active_drag(camera, motion.position)
			return true

		# Moving with the right button held is camera orbit, not a pick
		_right_click_picking = false
		_update_hover(camera, motion.position, motion.shift_pressed)
		return false

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _start_drag(camera, mb.position, mb.shift_pressed)
			return _finish_active_drag()

		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if _cancel_active_drag():
				return true
			if current_tool == Tool.PAINT or current_tool == Tool.COLOR:
				if mb.pressed:
					_right_click_picking = true
				elif _right_click_picking:
					_right_click_picking = false
					if current_tool == Tool.PAINT:
						_paint_handler.pick_tile_at_hover()
					else:
						_color_handler.pick_color_at_hover()
			return false

	return false


# Tiled-style shortcuts: X flip horizontal, Y flip vertical, Z rotate (Shift+Z counter-clockwise)
func _handle_paint_shortcut(key: InputEventKey) -> bool:
	if not key.pressed or key.echo:
		return false

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
	return false


func _update_active_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if _is_dragging:
		if current_tool == Tool.MOUNTAIN:
			_mountain_handler.update_drag(camera, mouse_pos)
		else:
			_sculpt_handler.update_drag(camera, mouse_pos)
	elif _is_flatten_dragging:
		_flatten_handler.update_drag(camera, mouse_pos)
	elif _is_paint_dragging:
		_paint_handler.update_drag(camera, mouse_pos)
	elif _is_color_dragging:
		_color_handler.update_drag(camera, mouse_pos)
	elif _is_fence_dragging:
		_fence_handler.update_drag(camera, mouse_pos)


func _finish_active_drag() -> bool:
	if _is_dragging:
		if current_tool == Tool.MOUNTAIN:
			_mountain_handler.finish_drag()
		else:
			_sculpt_handler.finish_drag()
	elif _is_flatten_dragging:
		_flatten_handler.finish_drag()
	elif _is_paint_dragging:
		_paint_handler.finish_drag()
	elif _is_color_dragging:
		_color_handler.finish_drag()
	elif _is_fence_dragging:
		_fence_handler.finish_drag()
	else:
		return false
	return true


func _cancel_active_drag() -> bool:
	if not (_is_dragging or _is_flatten_dragging or _is_paint_dragging or _is_color_dragging or _is_fence_dragging):
		return false
	_cancel_all_drags()
	return true


func _start_drag(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> bool:
	if _hovered_cell.x < 0 or not _terrain:
		return false

	var data := _terrain.terrain_data
	if not data:
		return false

	match current_tool:
		Tool.PAINT:
			return _paint_handler.start_drag(data, shift_pressed)
		Tool.COLOR:
			return _color_handler.start_drag(camera, mouse_pos, data)
		Tool.FLIP_DIAGONAL:
			_flip_diagonal_brush_area(data, _hovered_cell)
			return true
		Tool.FLATTEN:
			return _flatten_handler.start_drag(data)
		Tool.FENCE:
			if _hovered_fence_edge < 0:
				return false
			if shift_pressed:
				_fence_handler.delete_fence(data, _hovered_cell, _hovered_fence_edge)
				return true
			return _fence_handler.start_drag(camera, mouse_pos, data)
		Tool.SCULPT:
			return _sculpt_handler.start_drag(camera, mouse_pos, data)
		Tool.MOUNTAIN:
			return _mountain_handler.start_drag(camera, mouse_pos, data)

	return false


# ============================================================================
# HOVER
# ============================================================================

func _update_hover(camera: Camera3D, mouse_pos: Vector2, shift_pressed: bool = false) -> void:
	if _is_dragging:
		return

	var hit := _raycast_terrain(camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	if hit.is_empty():
		if _hovered_cell.x >= 0:
			_hovered_cell = Vector2i(-1, -1)
			_hovered_corner = -1
			_hover_mode = HoverMode.CELL
			_hovered_surface = TerrainData.Surface.TOP
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		if current_tool == Tool.PAINT and _terrain and not _is_paint_dragging:
			_terrain.clear_preview()
		return

	var hit_pos: Vector3 = hit.position
	var data := _terrain.terrain_data
	var cell_size := data.cell_size

	var old_cell := _hovered_cell
	var old_corner := _hovered_corner
	var old_mode := _hover_mode
	var old_surface := _hovered_surface

	_hovered_surface = _surface_from_normal(hit.normal)
	_hovered_cell = _terrain.world_to_cell(_nudge_into_owner(hit_pos, _hovered_surface))
	_detect_fence_hit(hit_pos, data)

	var local_pos := _terrain.to_local(hit_pos)
	_brush_corner = nearest_corner(local_pos, _hovered_cell, cell_size)

	if current_tool == Tool.FENCE:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		_fence_handler.update_hover(local_pos, cell_size)
		if old_cell != _hovered_cell:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		return

	if current_tool == Tool.PAINT or current_tool == Tool.FLIP_DIAGONAL or current_tool == Tool.MOUNTAIN:
		_hovered_corner = -1
		_hover_mode = HoverMode.CELL
		if old_cell != _hovered_cell or old_surface != _hovered_surface:
			hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)
		if current_tool == Tool.PAINT and not _is_paint_dragging:
			_update_paint_hover(shift_pressed)
		return

	# Sculpt, flatten and color: corner vs cell mode, top vs floor
	_hovered_corner = _brush_corner
	_hover_editing_floor = _should_edit_floor(local_pos, _hovered_cell, _hovered_surface, data)

	if _corner_distance(local_pos, _hovered_cell, cell_size, _brush_corner) < CORNER_THRESHOLD:
		_hover_mode = HoverMode.FLOOR_CORNER if _hover_editing_floor else HoverMode.CORNER
	else:
		_hover_mode = HoverMode.CELL
		# Whole-cell floor editing is only offered when looking at the underside
		if _hover_editing_floor and not _camera_below_floor(_hovered_cell, data):
			_hover_editing_floor = false

	if old_cell != _hovered_cell or old_corner != _hovered_corner or old_mode != _hover_mode:
		hover_changed.emit(_hovered_cell, _hovered_corner, _hover_mode)


# Shift locks painting to the surface type first hovered while it is held
func _update_paint_hover(shift_pressed: bool) -> void:
	if not shift_pressed:
		_paint_surface_locked = false
		_paint_handler.update_hover_preview()
		return

	if not _paint_surface_locked:
		_paint_surface_locked = true
		_paint_locked_surface = _hovered_surface

	if _hovered_surface == _paint_locked_surface:
		_paint_handler.update_hover_preview()
	else:
		_terrain.clear_preview()


# Walls and fences lie on the boundary between two cells; step slightly into the cell that owns them
static func _nudge_into_owner(hit_pos: Vector3, surface: TerrainData.Surface) -> Vector3:
	match surface:
		TerrainData.Surface.NORTH, TerrainData.Surface.FENCE_NORTH:
			hit_pos.z += WALL_HIT_NUDGE
		TerrainData.Surface.SOUTH, TerrainData.Surface.FENCE_SOUTH:
			hit_pos.z -= WALL_HIT_NUDGE
		TerrainData.Surface.EAST, TerrainData.Surface.FENCE_EAST:
			hit_pos.x -= WALL_HIT_NUDGE
		TerrainData.Surface.WEST, TerrainData.Surface.FENCE_WEST:
			hit_pos.x += WALL_HIT_NUDGE
	return hit_pos


# A wall hit above the terrain top is really a fence. Fences are double-sided, so the hit
# may come from the back: then the fence belongs to the opposite edge, possibly of the cell
# the nudge moved us out of.
func _detect_fence_hit(hit_pos: Vector3, data: TerrainData) -> void:
	if _hovered_surface < TerrainData.Surface.NORTH or _hovered_surface > TerrainData.Surface.WEST:
		return

	var edge: int = _hovered_surface - TerrainData.Surface.NORTH
	var opposite := TerrainData.opposite_edge(edge)
	var original_cell := _terrain.world_to_cell(hit_pos)

	var fence_cell := _hovered_cell
	var fence_edge := -1
	if data.has_fence(_hovered_cell.x, _hovered_cell.y, edge):
		fence_edge = edge
	elif data.has_fence(_hovered_cell.x, _hovered_cell.y, opposite):
		fence_edge = opposite
	elif original_cell != _hovered_cell and data.has_fence(original_cell.x, original_cell.y, opposite):
		fence_edge = opposite
		fence_cell = original_cell
	if fence_edge < 0:
		return

	var top := data.get_top_corners(fence_cell.x, fence_cell.y)
	var left: int = TerrainData.EDGE_CORNERS[fence_edge][0]
	var right: int = TerrainData.EDGE_CORNERS[fence_edge][1]
	var top_height := (data.steps_to_world(top[left]) + data.steps_to_world(top[right])) / 2.0

	if _terrain.to_local(hit_pos).y > top_height - WALL_HIT_NUDGE:
		_hovered_surface = TerrainData.fence_surface_from_edge(fence_edge)
		_hovered_cell = fence_cell


func _camera_below_floor(cell: Vector2i, data: TerrainData) -> bool:
	if not _last_camera:
		return false
	var avg_floor := _average_height(data.get_floor_corners(cell.x, cell.y), data)
	return _terrain.to_local(_last_camera.global_position).y < avg_floor


# Floor editing is chosen when the hit is on the lower half of a wall, on the lower half of
# a cell's height range, or when the camera is looking up from below the floor.
func _should_edit_floor(local_hit: Vector3, cell: Vector2i, surface: TerrainData.Surface, data: TerrainData) -> bool:
	var top_corners := data.get_top_corners(cell.x, cell.y)
	var floor_corners := data.get_floor_corners(cell.x, cell.y)

	if surface == TerrainData.Surface.TOP:
		if _camera_below_floor(cell, data):
			return true
		var mid_height := (_average_height(top_corners, data) + _average_height(floor_corners, data)) / 2.0
		return local_hit.y < mid_height

	if surface >= TerrainData.Surface.NORTH and surface <= TerrainData.Surface.WEST:
		var edge: int = surface - TerrainData.Surface.NORTH
		var left: int = TerrainData.EDGE_CORNERS[edge][0]
		var right: int = TerrainData.EDGE_CORNERS[edge][1]
		var top_height := (data.steps_to_world(top_corners[left]) + data.steps_to_world(top_corners[right])) / 2.0
		var floor_height := (data.steps_to_world(floor_corners[left]) + data.steps_to_world(floor_corners[right])) / 2.0
		return local_hit.y < (top_height + floor_height) / 2.0

	return false


func _surface_from_normal(normal: Vector3) -> TerrainData.Surface:
	if absf(normal.y) > 0.7:
		return TerrainData.Surface.TOP

	if absf(normal.z) > absf(normal.x):
		return TerrainData.Surface.NORTH if normal.z < 0 else TerrainData.Surface.SOUTH
	return TerrainData.Surface.EAST if normal.x > 0 else TerrainData.Surface.WEST


# Raycasts against the edited terrain only. Its collision body is temporarily moved to a
# dedicated layer so overlapping terrains and other scene bodies never intercept the ray.
func _raycast_terrain(origin: Vector3, direction: Vector3) -> Dictionary:
	if not _terrain or not _terrain.terrain_data:
		return {}

	var body := _terrain.get_collision_body()
	if not body:
		return {}

	var original_layer := body.collision_layer
	body.collision_layer = 1 << RAYCAST_LAYER

	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * RAYCAST_LENGTH)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.collision_mask = 1 << RAYCAST_LAYER
	var result := _terrain.get_world_3d().direct_space_state.intersect_ray(query)

	body.collision_layer = original_layer

	if result.is_empty():
		return {}
	return {
		"position": result.position,
		"normal": result.get("normal", Vector3.UP),
	}


# ============================================================================
# TOOLS WITHOUT A HANDLER
# ============================================================================

func _flip_diagonal_brush_area(data: TerrainData, center: Vector2i) -> void:
	var brush_cells := get_brush_cells(center, data, _brush_corner)
	if brush_cells.is_empty():
		return

	undo_redo.create_action("Flip Diagonal")
	undo_redo.add_do_method(data, "begin_batch")
	undo_redo.add_undo_method(data, "begin_batch")
	for cell in brush_cells:
		var old_flip := data.get_diagonal_flip(cell.x, cell.y)
		undo_redo.add_do_method(data, "set_diagonal_flip", cell.x, cell.y, not old_flip)
		undo_redo.add_undo_method(data, "set_diagonal_flip", cell.x, cell.y, old_flip)
	undo_redo.add_do_method(data, "end_batch")
	undo_redo.add_undo_method(data, "end_batch")
	undo_redo.commit_action()


# Cells covered by the brush. Odd sizes centre on the cell; even sizes centre on the
# given corner of the cell so the brush can be anchored to any grid point.
func get_brush_cells(center: Vector2i, data: TerrainData, corner: int = -1) -> Array[Vector2i]:
	var half := brush_size / 2
	var start := Vector2i(-half, -half)
	var end := Vector2i(brush_size - half - 1, brush_size - half - 1)

	if brush_size % 2 == 0 and corner >= 0:
		# Corner 0 (NW) keeps the default extent toward negative x/z; the others shift by one
		if corner == TerrainData.Corner.NE or corner == TerrainData.Corner.SE:
			start.x += 1
			end.x += 1
		if corner == TerrainData.Corner.SE or corner == TerrainData.Corner.SW:
			start.y += 1
			end.y += 1

	var cells: Array[Vector2i] = []
	for dz in range(start.y, end.y + 1):
		for dx in range(start.x, end.x + 1):
			var cell := center + Vector2i(dx, dz)
			if data.is_valid_cell(cell.x, cell.y):
				cells.append(cell)
	return cells


func draw_overlay(overlay: Control, terrain: LandscapeTerrain) -> void:
	_overlay_handler.draw(overlay, terrain)


func rotate_paint_cw() -> void:
	_paint_handler.rotate_cw()


func rotate_paint_ccw() -> void:
	_paint_handler.rotate_ccw()
