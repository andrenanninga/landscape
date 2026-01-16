@tool
class_name TilePalette
extends Control

signal tile_selected(tile_index: int)

var tile_set: TerrainTileSet:
	set(value):
		tile_set = value
		queue_redraw()

var selected_tile: int = 0:
	set(value):
		if selected_tile != value:
			selected_tile = value
			queue_redraw()

var zoom: float = 1.0:
	set(value):
		zoom = clampf(value, MIN_ZOOM, MAX_ZOOM)
		queue_redraw()

var pan_offset: Vector2 = Vector2.ZERO

var _is_panning: bool = false

const MIN_ZOOM = 0.25
const MAX_ZOOM = 4.0
const ZOOM_STEP = 0.25
const BASE_TILE_SIZE = 64.0


func _ready() -> void:
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _draw() -> void:
	# Draw background
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.15, 0.15, 0.15))

	if not tile_set or not tile_set.atlas_texture:
		var font := ThemeDB.fallback_font
		var font_size := ThemeDB.fallback_font_size
		draw_string(font, Vector2(10, 20), "No tileset", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.5, 0.5, 0.5))
		return

	var atlas := tile_set.atlas_texture
	var tile_count := tile_set.get_tile_count()
	var columns := tile_set.atlas_columns

	if tile_count == 0 or columns == 0:
		return

	var tile_size := BASE_TILE_SIZE * zoom
	var visible_rect := Rect2(Vector2.ZERO, size)

	# Draw tiles
	for i in tile_count:
		var screen_rect := _get_tile_screen_rect(i)

		# Cull tiles outside visible area
		if not visible_rect.intersects(screen_rect):
			continue

		# Get UV rect for this tile
		var uv_rect := tile_set.get_tile_uv_rect(i)
		var tex_size := atlas.get_size()
		var source_rect := Rect2(uv_rect.position * tex_size, uv_rect.size * tex_size)

		draw_texture_rect_region(atlas, screen_rect, source_rect)

	# Draw selection highlight
	if selected_tile >= 0 and selected_tile < tile_count:
		var sel_rect := _get_tile_screen_rect(selected_tile)
		if visible_rect.intersects(sel_rect):
			draw_rect(sel_rect, Color(0.4, 0.6, 1.0, 0.3))
			draw_rect(sel_rect, Color(0.4, 0.6, 1.0), false, 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		# Ctrl/Cmd + scroll = zoom
		if mb.ctrl_pressed or mb.meta_pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
				_zoom_at_point(mb.position, 1)
				accept_event()
				return
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
				_zoom_at_point(mb.position, -1)
				accept_event()
				return

		# Regular scroll = pan
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			pan_offset.y += 30
			_clamp_pan()
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			pan_offset.y -= 30
			_clamp_pan()
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_LEFT and mb.pressed:
			pan_offset.x += 30
			_clamp_pan()
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT and mb.pressed:
			pan_offset.x -= 30
			_clamp_pan()
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_is_panning = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var tile := _get_tile_at_position(mb.position)
			if tile >= 0:
				selected_tile = tile
				tile_selected.emit(tile)
			accept_event()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _is_panning:
			pan_offset += motion.relative
			_clamp_pan()
			queue_redraw()
			accept_event()

	# Trackpad pinch-to-zoom
	elif event is InputEventMagnifyGesture:
		var magnify := event as InputEventMagnifyGesture
		var zoom_delta := (magnify.factor - 1.0) * 2.0
		_zoom_at_point(magnify.position, zoom_delta)
		accept_event()

	# Trackpad two-finger pan
	elif event is InputEventPanGesture:
		var pan := event as InputEventPanGesture
		pan_offset -= pan.delta * 10
		_clamp_pan()
		queue_redraw()
		accept_event()


func _get_tile_screen_rect(index: int) -> Rect2:
	if not tile_set or tile_set.atlas_columns == 0:
		return Rect2()

	var columns := tile_set.atlas_columns
	var col := index % columns
	var row := index / columns
	var tile_size := BASE_TILE_SIZE * zoom

	var pos := Vector2(col * tile_size, row * tile_size) + pan_offset
	return Rect2(pos, Vector2(tile_size, tile_size))


func _get_tile_at_position(screen_pos: Vector2) -> int:
	if not tile_set or tile_set.atlas_columns == 0:
		return -1

	var tile_size := BASE_TILE_SIZE * zoom
	var local_pos := screen_pos - pan_offset

	if local_pos.x < 0 or local_pos.y < 0:
		return -1

	var col := int(local_pos.x / tile_size)
	var row := int(local_pos.y / tile_size)
	var columns := tile_set.atlas_columns

	if col >= columns:
		return -1

	var index := row * columns + col
	if index >= tile_set.get_tile_count():
		return -1

	return index


func _zoom_at_point(point: Vector2, direction: float) -> void:
	var old_zoom := zoom
	var new_zoom := clampf(zoom + direction * ZOOM_STEP, MIN_ZOOM, MAX_ZOOM)

	if old_zoom == new_zoom:
		return

	# Adjust pan to keep the point under the cursor stationary
	var local_point := point - pan_offset
	var scale_factor := new_zoom / old_zoom
	var new_local_point := local_point * scale_factor
	pan_offset = point - new_local_point

	zoom = new_zoom
	_clamp_pan()


func _clamp_pan() -> void:
	if not tile_set or tile_set.atlas_columns == 0:
		return

	var tile_size := BASE_TILE_SIZE * zoom
	var columns := tile_set.atlas_columns
	var rows := ceili(float(tile_set.get_tile_count()) / columns)
	var content_size := Vector2(columns * tile_size, rows * tile_size)

	# Clamp so content stays within view
	# max_pan = 0 means top-left of content aligns with top-left of viewport
	# min_pan ensures we can scroll to see bottom-right of content
	var max_pan := Vector2(0, 0)
	var min_pan := Vector2(
		minf(0, size.x - content_size.x),
		minf(0, size.y - content_size.y)
	)

	pan_offset.x = clampf(pan_offset.x, min_pan.x, max_pan.x)
	pan_offset.y = clampf(pan_offset.y, min_pan.y, max_pan.y)


func zoom_in() -> void:
	_zoom_at_point(size / 2, 1)


func zoom_out() -> void:
	_zoom_at_point(size / 2, -1)


func reset_view() -> void:
	zoom = 1.0
	pan_offset = Vector2.ZERO
	queue_redraw()
