@tool
extends Control

const PlaceholderTiles = preload("res://addons/landscape/resources/placeholder_tiles.gd")

var terrain_editor = null:
	set(value):
		terrain_editor = value
		if terrain_editor:
			terrain_editor.tool_changed.connect(_on_tool_changed)
			terrain_editor.hover_changed.connect(_on_hover_changed)
			terrain_editor.height_changed.connect(_on_height_changed)
			terrain_editor.paint_state_changed.connect(_on_paint_state_changed)

var terrain = null:
	set(value):
		terrain = value
		_rebuild_tile_palette()

var _current_cell: Vector2i = Vector2i(-1, -1)
var _current_corner: int = -1
var _current_mode: int = 0
var _tile_buttons: Array[Button] = []

@onready var _tool_buttons: Dictionary = {}
@onready var _status_label: Label = %StatusLabel
@onready var _paint_section: VBoxContainer = %PaintSection
@onready var _surface_selector: OptionButton = %SurfaceSelector
@onready var _rotate_ccw_button: Button = %RotateCCWButton
@onready var _rotate_cw_button: Button = %RotateCWButton
@onready var _flip_h_button: Button = %FlipHButton
@onready var _flip_v_button: Button = %FlipVButton
@onready var _rotation_label: Label = %RotationLabel
@onready var _tile_palette_grid: GridContainer = %TilePaletteGrid
@onready var _generate_placeholders_button: Button = %GeneratePlaceholdersButton


func _ready() -> void:
	_setup_tool_buttons()
	_setup_paint_controls()
	_update_button_states()


func _setup_tool_buttons() -> void:
	_tool_buttons = {
		TerrainEditor.Tool.SCULPT: %SculptButton,
		TerrainEditor.Tool.PAINT: %PaintButton,
	}

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.pressed.connect(_on_tool_button_pressed.bind(tool_type))


func _setup_paint_controls() -> void:
	if _surface_selector:
		_surface_selector.item_selected.connect(_on_surface_selected)

	if _rotate_ccw_button:
		_rotate_ccw_button.pressed.connect(_on_rotate_ccw)

	if _rotate_cw_button:
		_rotate_cw_button.pressed.connect(_on_rotate_cw)

	if _flip_h_button:
		_flip_h_button.toggled.connect(_on_flip_h_toggled)

	if _flip_v_button:
		_flip_v_button.toggled.connect(_on_flip_v_toggled)

	if _generate_placeholders_button:
		_generate_placeholders_button.pressed.connect(_on_generate_placeholders)


func _on_tool_button_pressed(tool: TerrainEditor.Tool) -> void:
	if terrain_editor:
		if terrain_editor.current_tool == tool:
			terrain_editor.current_tool = TerrainEditor.Tool.NONE
		else:
			terrain_editor.current_tool = tool
	_update_button_states()


func _on_tool_changed(tool: TerrainEditor.Tool) -> void:
	_update_button_states()
	_update_paint_section_visibility()


func _on_paint_state_changed() -> void:
	_update_paint_controls()
	_update_tile_selection()


func _on_surface_selected(index: int) -> void:
	if terrain_editor:
		terrain_editor.current_paint_surface = index as TerrainData.Surface


func _on_rotate_ccw() -> void:
	if terrain_editor:
		terrain_editor.rotate_paint_ccw()


func _on_rotate_cw() -> void:
	if terrain_editor:
		terrain_editor.rotate_paint_cw()


func _on_flip_h_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_flip_h = pressed


func _on_flip_v_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_flip_v = pressed


func _on_tile_selected(tile_index: int) -> void:
	if terrain_editor:
		terrain_editor.current_paint_tile = tile_index


func _on_generate_placeholders() -> void:
	var landscape := terrain as LandscapeTerrain
	if not landscape:
		return

	# Generate placeholder tileset
	var tile_set := PlaceholderTiles.create_terrain_tileset()
	landscape.tile_set = tile_set

	# Rebuild the tile palette
	_rebuild_tile_palette()


func _update_paint_section_visibility() -> void:
	if _paint_section:
		_paint_section.visible = terrain_editor and terrain_editor.current_tool == TerrainEditor.Tool.PAINT


func _update_paint_controls() -> void:
	if not terrain_editor:
		return

	if _surface_selector:
		_surface_selector.selected = terrain_editor.current_paint_surface

	if _flip_h_button:
		_flip_h_button.button_pressed = terrain_editor.current_paint_flip_h

	if _flip_v_button:
		_flip_v_button.button_pressed = terrain_editor.current_paint_flip_v

	if _rotation_label:
		var rotation_degrees: int = terrain_editor.current_paint_rotation * 90
		_rotation_label.text = "%d°" % rotation_degrees


func _update_tile_selection() -> void:
	if not terrain_editor:
		return

	var selected_tile: int = terrain_editor.current_paint_tile
	for i in _tile_buttons.size():
		var button := _tile_buttons[i]
		# Visual feedback for selected tile
		if i == selected_tile:
			button.modulate = Color(1.2, 1.2, 1.2)
		else:
			button.modulate = Color.WHITE


func _rebuild_tile_palette() -> void:
	if not _tile_palette_grid:
		return

	# Clear existing buttons
	for button in _tile_buttons:
		button.queue_free()
	_tile_buttons.clear()

	# Get tile set from terrain
	var landscape := terrain as LandscapeTerrain
	if not landscape or not landscape.tile_set or not landscape.tile_set.atlas_texture:
		return

	var tile_set := landscape.tile_set
	var tile_count := tile_set.get_tile_count()

	if tile_count == 0:
		return

	_tile_palette_grid.columns = tile_set.atlas_columns

	for i in tile_count:
		var button := Button.new()
		button.custom_minimum_size = Vector2(96, 96)
		button.tooltip_text = "Tile %d" % i

		# Create atlas texture for button icon
		var atlas_tex := AtlasTexture.new()
		atlas_tex.atlas = tile_set.atlas_texture
		var uv_rect := tile_set.get_tile_uv_rect(i)
		var tex_size := tile_set.atlas_texture.get_size()
		atlas_tex.region = Rect2(
			uv_rect.position * tex_size,
			uv_rect.size * tex_size
		)

		button.icon = atlas_tex
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.expand_icon = true

		# Use nearest-neighbor filtering for pixel art
		button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

		button.pressed.connect(_on_tile_selected.bind(i))
		_tile_palette_grid.add_child(button)
		_tile_buttons.append(button)

	_update_tile_selection()


func _on_hover_changed(cell: Vector2i, corner: int, mode: int) -> void:
	_current_cell = cell
	_current_corner = corner
	_current_mode = mode
	var height: float = terrain_editor.get_current_height() if terrain_editor else NAN
	_update_status_label(height)


func _on_height_changed(height: float, corner: int, mode: int) -> void:
	_update_status_label(height)


func _update_status_label(height: float = NAN) -> void:
	if not _status_label:
		return

	if _current_cell.x < 0:
		_status_label.text = "No cell selected"
		return

	var lines: Array[String] = []

	# Line 1: Cell coordinates
	lines.append("Cell: (%d, %d)" % [_current_cell.x, _current_cell.y])

	# Show different info based on tool
	if terrain_editor and terrain_editor.current_tool == TerrainEditor.Tool.PAINT:
		# Paint mode: show surface
		var surface: int = terrain_editor.get_hovered_surface()
		var surface_name := _get_surface_name(surface)
		lines.append("Surface: %s" % surface_name)
	else:
		# Sculpt mode: show corner
		if _current_mode == TerrainEditor.HoverMode.CORNER:
			var corner_name := _get_corner_name(_current_corner)
			lines.append("Corner: %s" % corner_name)
		else:
			lines.append("Corner: All")

		# Height (only relevant for sculpt)
		if not is_nan(height):
			lines.append("Height: %.2f" % height)

	_status_label.text = "\n".join(lines)


func _get_corner_name(corner: int) -> String:
	match corner:
		TerrainData.Corner.NW: return "NW"
		TerrainData.Corner.NE: return "NE"
		TerrainData.Corner.SE: return "SE"
		TerrainData.Corner.SW: return "SW"
	return "?"


func _get_surface_name(surface: int) -> String:
	match surface:
		0: return "Top"
		1: return "North"
		2: return "East"
		3: return "South"
		4: return "West"
	return "?"


func _update_button_states() -> void:
	if not terrain_editor:
		return

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.button_pressed = terrain_editor.current_tool == tool_type
