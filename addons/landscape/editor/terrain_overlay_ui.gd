@tool
extends Control

const SculptIcon = preload("res://addons/landscape/icons/sculpt_tool.svg")
const PaintIcon = preload("res://addons/landscape/icons/paint_tool.svg")
const FlipIcon = preload("res://addons/landscape/icons/flip_tool.svg")
const FlattenIcon = preload("res://addons/landscape/icons/flatten_tool.svg")
const MountainIcon = preload("res://addons/landscape/icons/mountain_tool.svg")
const FenceIcon = preload("res://addons/landscape/icons/fence_tool.svg")

var terrain_editor = null:
	set(value):
		terrain_editor = value
		if terrain_editor:
			terrain_editor.tool_changed.connect(_on_tool_changed)
			terrain_editor.paint_state_changed.connect(_on_paint_state_changed)
			terrain_editor.brush_size_changed.connect(_on_brush_size_changed)

var terrain = null:
	set(value):
		terrain = value
		_update_tile_palette()

var _tool_buttons: Dictionary = {}
var _is_resizing: bool = false
var _resize_start_y: float = 0.0
var _resize_start_height: float = 0.0

const MIN_PALETTE_HEIGHT := 100.0
const MAX_PALETTE_HEIGHT := 800.0

@onready var _main_toolbar: PanelContainer = %MainToolbar
@onready var _paint_panel: PanelContainer = %PaintPanel
@onready var _brush_size_slider: HSlider = %BrushSizeSlider
@onready var _resize_handle: Panel = %ResizeHandle
@onready var _atlas_row: HBoxContainer = %AtlasRow
@onready var _atlas_selector: OptionButton = %AtlasSelector
@onready var _wall_align_button: Button = %WallAlignButton
@onready var _rotate_cw_button: Button = %RotateCWButton
@onready var _flip_h_button: Button = %FlipHButton
@onready var _flip_v_button: Button = %FlipVButton
@onready var _random_button: Button = %RandomButton
@onready var _tile_palette: TilePalette = %TilePalette

var _wall_align_icons: Array[Texture2D] = []
const WALL_ALIGN_TOOLTIPS: Array[String] = ["Wall alignment: World", "Wall alignment: Top", "Wall alignment: Bottom"]


func _ready() -> void:
	_setup_tool_buttons()
	_setup_brush_controls()
	_setup_paint_controls()
	_setup_resize_handle()
	_update_button_states()
	_update_paint_panel_visibility()

	if _tile_palette:
		_tile_palette.tile_selected.connect(_on_tile_selected)


func _setup_resize_handle() -> void:
	if _resize_handle:
		_resize_handle.gui_input.connect(_on_resize_handle_input)


func _on_resize_handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_resizing = true
				_resize_start_y = mb.global_position.y
				_resize_start_height = _tile_palette.custom_minimum_size.y if _tile_palette else 200.0
			else:
				_is_resizing = false
			_resize_handle.accept_event()

	elif event is InputEventMouseMotion and _is_resizing:
		var motion := event as InputEventMouseMotion
		var delta := _resize_start_y - motion.global_position.y
		var new_height := clampf(_resize_start_height + delta, MIN_PALETTE_HEIGHT, MAX_PALETTE_HEIGHT)
		if _tile_palette:
			_tile_palette.custom_minimum_size.y = new_height
		_resize_handle.accept_event()


func _setup_tool_buttons() -> void:
	_tool_buttons = {
		TerrainEditor.Tool.SCULPT: %SculptButton,
		TerrainEditor.Tool.PAINT: %PaintButton,
		TerrainEditor.Tool.FLIP_DIAGONAL: %FlipButton,
		TerrainEditor.Tool.FLATTEN: %FlattenButton,
		TerrainEditor.Tool.MOUNTAIN: %MountainButton,
		TerrainEditor.Tool.FENCE: %FenceButton,
	}

	var icons: Dictionary = {
		TerrainEditor.Tool.SCULPT: SculptIcon,
		TerrainEditor.Tool.PAINT: PaintIcon,
		TerrainEditor.Tool.FLIP_DIAGONAL: FlipIcon,
		TerrainEditor.Tool.FLATTEN: FlattenIcon,
		TerrainEditor.Tool.MOUNTAIN: MountainIcon,
		TerrainEditor.Tool.FENCE: FenceIcon,
	}

	var tooltips: Dictionary = {
		TerrainEditor.Tool.SCULPT: "Sculpt - Drag to raise/lower terrain",
		TerrainEditor.Tool.PAINT: "Paint - Click to paint tiles",
		TerrainEditor.Tool.FLIP_DIAGONAL: "Flip - Toggle cell diagonal",
		TerrainEditor.Tool.FLATTEN: "Flatten - Level terrain to height",
		TerrainEditor.Tool.MOUNTAIN: "Mountain - Create hills and valleys",
		TerrainEditor.Tool.FENCE: "Fence - Create fences on edges",
	}

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.icon = icons[tool_type]
			button.tooltip_text = tooltips[tool_type]
			button.expand_icon = true
			button.add_theme_constant_override("icon_max_width", 48)
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


func _setup_paint_controls() -> void:
	# Set editor icons using theme from this control
	# Cache wall align icons
	_wall_align_icons = [
		get_theme_icon("ControlAlignFullRect", "EditorIcons"),  # World
		get_theme_icon("ControlAlignTopWide", "EditorIcons"),     # Top
		get_theme_icon("ControlAlignBottomWide", "EditorIcons"), # Bottom
	]

	if _wall_align_button:
		_wall_align_button.icon = _wall_align_icons[0]
		_wall_align_button.pressed.connect(_on_wall_align_cycle)

	if _rotate_cw_button:
		_rotate_cw_button.icon = get_theme_icon("RotateRight", "EditorIcons")
		_rotate_cw_button.pressed.connect(_on_rotate_cw)

	if _flip_h_button:
		_flip_h_button.icon = get_theme_icon("MirrorX", "EditorIcons")
		_flip_h_button.toggled.connect(_on_flip_h_toggled)

	if _flip_v_button:
		_flip_v_button.icon = get_theme_icon("MirrorY", "EditorIcons")
		_flip_v_button.toggled.connect(_on_flip_v_toggled)

	if _random_button:
		_random_button.icon = get_theme_icon("RandomNumberGenerator", "EditorIcons")
		_random_button.toggled.connect(_on_random_toggled)

	if _atlas_selector:
		_atlas_selector.item_selected.connect(_on_atlas_selected)


func _on_tool_button_pressed(tool: TerrainEditor.Tool) -> void:
	if terrain_editor:
		if terrain_editor.current_tool == tool:
			terrain_editor.current_tool = TerrainEditor.Tool.NONE
		else:
			terrain_editor.current_tool = tool
	_update_button_states()


func _on_tool_changed(tool: TerrainEditor.Tool) -> void:
	_update_button_states()
	_update_paint_panel_visibility()


func _on_paint_state_changed() -> void:
	_update_paint_controls()
	_update_tile_selection()


func _on_atlas_selected(index: int) -> void:
	if _tile_palette:
		_tile_palette.selected_atlas = index


func _on_rotate_cw() -> void:
	if terrain_editor:
		terrain_editor.rotate_paint_cw()


func _on_flip_h_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_flip_h = pressed


func _on_flip_v_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_flip_v = pressed


func _on_random_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_random = pressed


func _on_wall_align_cycle() -> void:
	if terrain_editor:
		var current := terrain_editor.current_paint_wall_align as int
		var next := (current + 1) % 3
		terrain_editor.current_paint_wall_align = next as TerrainData.WallAlign
		_update_wall_align_button()


func _on_tile_selected(tile_index: int) -> void:
	if terrain_editor:
		terrain_editor.current_paint_tile = tile_index


func _update_paint_panel_visibility() -> void:
	var is_paint_mode: bool = terrain_editor != null and terrain_editor.current_tool == TerrainEditor.Tool.PAINT
	if _paint_panel:
		_paint_panel.visible = is_paint_mode


func _update_paint_controls() -> void:
	if not terrain_editor:
		return

	if _flip_h_button:
		_flip_h_button.button_pressed = terrain_editor.current_paint_flip_h

	if _flip_v_button:
		_flip_v_button.button_pressed = terrain_editor.current_paint_flip_v

	if _random_button:
		_random_button.button_pressed = terrain_editor.current_paint_random

	_update_wall_align_button()


func _update_wall_align_button() -> void:
	if not _wall_align_button or not terrain_editor:
		return

	var align_index := terrain_editor.current_paint_wall_align as int
	if align_index >= 0 and align_index < _wall_align_icons.size():
		_wall_align_button.icon = _wall_align_icons[align_index]
	if align_index >= 0 and align_index < WALL_ALIGN_TOOLTIPS.size():
		_wall_align_button.tooltip_text = WALL_ALIGN_TOOLTIPS[align_index]


func _update_tile_selection() -> void:
	if not terrain_editor or not _tile_palette:
		return
	_tile_palette.selected_tile = terrain_editor.current_paint_tile


func _update_tile_palette() -> void:
	if not _tile_palette:
		return

	var landscape := terrain as LandscapeTerrain
	if landscape and landscape.tile_set:
		_tile_palette.tile_set = landscape.tile_set
		_update_atlas_selector(landscape.tile_set)
	else:
		_tile_palette.tile_set = null
		_update_atlas_selector(null)


func _update_atlas_selector(tile_set: TerrainTileSet) -> void:
	if not _atlas_selector or not _atlas_row:
		return

	_atlas_selector.clear()

	if not tile_set:
		_atlas_row.visible = false
		return

	var atlas_count := tile_set.get_atlas_count()
	for i in atlas_count:
		var info := tile_set.get_atlas_info(i)
		var label := "Atlas %d" % i
		_atlas_selector.add_item(label, i)

	# Show atlas row (even with one atlas, so user knows which one is active)
	_atlas_row.visible = atlas_count > 0

	# Sync with tile palette selection
	if _tile_palette and _atlas_selector.item_count > 0:
		_atlas_selector.selected = _tile_palette.selected_atlas


func _update_button_states() -> void:
	if not terrain_editor:
		return

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.button_pressed = terrain_editor.current_tool == tool_type
