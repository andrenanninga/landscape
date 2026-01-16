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
			terrain_editor.brush_size_changed.connect(_on_brush_size_changed)

var terrain = null:
	set(value):
		terrain = value
		_update_tile_palette()

var _current_cell: Vector2i = Vector2i(-1, -1)
var _current_corner: int = -1
var _current_mode: int = 0

@onready var _tool_buttons: Dictionary = {}
@onready var _status_label: Label = %StatusLabel
@onready var _brush_size_slider: HSlider = %BrushSizeSlider
@onready var _brush_size_label: Label = %BrushSizeLabel
@onready var _paint_section: VBoxContainer = %PaintSection
@onready var _surface_selector: OptionButton = %SurfaceSelector
@onready var _rotate_ccw_button: Button = %RotateCCWButton
@onready var _rotate_cw_button: Button = %RotateCWButton
@onready var _flip_h_button: Button = %FlipHButton
@onready var _flip_v_button: Button = %FlipVButton
@onready var _rotation_label: Label = %RotationLabel
@onready var _tile_palette: TilePalette = %TilePalette
@onready var _generate_placeholders_button: Button = %GeneratePlaceholdersButton
@onready var _zoom_in_button: Button = %ZoomInButton
@onready var _zoom_out_button: Button = %ZoomOutButton
@onready var _spacer: Control = %Spacer


func _ready() -> void:
	_setup_tool_buttons()
	_setup_brush_controls()
	_setup_paint_controls()
	_update_button_states()

	if _tile_palette:
		_tile_palette.tile_selected.connect(_on_tile_selected)


func _setup_tool_buttons() -> void:
	_tool_buttons = {
		TerrainEditor.Tool.SCULPT: %SculptButton,
		TerrainEditor.Tool.PAINT: %PaintButton,
		TerrainEditor.Tool.FLIP_DIAGONAL: %FlipDiagonalButton,
		TerrainEditor.Tool.FLATTEN: %FlattenButton,
	}

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.pressed.connect(_on_tool_button_pressed.bind(tool_type))


func _setup_brush_controls() -> void:
	if _brush_size_slider:
		_brush_size_slider.value_changed.connect(_on_brush_size_slider_changed)


func _on_brush_size_slider_changed(value: float) -> void:
	if terrain_editor:
		terrain_editor.brush_size = int(value)


func _on_brush_size_changed(new_size: int) -> void:
	_update_brush_size_display()


func _update_brush_size_display() -> void:
	if not terrain_editor:
		return

	if _brush_size_slider:
		_brush_size_slider.set_value_no_signal(terrain_editor.brush_size)

	if _brush_size_label:
		_brush_size_label.text = str(terrain_editor.brush_size)


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

	if _zoom_in_button:
		_zoom_in_button.pressed.connect(_on_zoom_in)

	if _zoom_out_button:
		_zoom_out_button.pressed.connect(_on_zoom_out)


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

	# Update the tile palette
	_update_tile_palette()


func _update_paint_section_visibility() -> void:
	var is_paint_mode: bool = terrain_editor != null and terrain_editor.current_tool == TerrainEditor.Tool.PAINT
	if _paint_section:
		_paint_section.visible = is_paint_mode
	if _spacer:
		# Hide spacer when paint section is visible to give it more space
		_spacer.visible = not is_paint_mode


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
	if not terrain_editor or not _tile_palette:
		return
	_tile_palette.selected_tile = terrain_editor.current_paint_tile


func _on_zoom_in() -> void:
	if _tile_palette:
		_tile_palette.zoom_in()


func _on_zoom_out() -> void:
	if _tile_palette:
		_tile_palette.zoom_out()


func _update_tile_palette() -> void:
	if not _tile_palette:
		return

	var landscape := terrain as LandscapeTerrain
	if landscape and landscape.tile_set:
		_tile_palette.tile_set = landscape.tile_set
	else:
		_tile_palette.tile_set = null


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
