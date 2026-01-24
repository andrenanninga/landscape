@tool
extends Control

const SculptIcon = preload("res://addons/landscape/icons/sculpt_tool.svg")
const PaintIcon = preload("res://addons/landscape/icons/paint_tool.svg")
const ColorIcon = preload("res://addons/landscape/icons/color_tool.svg")
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
			terrain_editor.vertex_color_changed.connect(_on_vertex_color_changed)

var terrain = null:
	set(value):
		terrain = value
		_update_tile_palette()

var _tool_buttons: Dictionary = {}
var _panel_size := Vector2(800.0, 700.0)
var _is_dragging_resize := false
var _resize_drag_start := Vector2.ZERO
var _resize_size_start := Vector2.ZERO

const MIN_PANEL_WIDTH := 250.0
const MIN_PANEL_HEIGHT := 150.0
const DEFAULT_PANEL_SIZE := Vector2(800.0, 700.0)

@onready var _main_toolbar: PanelContainer = %MainToolbar
@onready var _paint_panel: PanelContainer = %PaintPanel
@onready var _color_panel: PanelContainer = %ColorPanel
@onready var _brush_size_slider: HSlider = %BrushSizeSlider
@onready var _resize_handle: Control = %ResizeHandle
@onready var _atlas_selector: OptionButton = %AtlasSelector
@onready var _erase_button: Button = %EraseButton
@onready var _wall_align_button: Button = %WallAlignButton
@onready var _rotate_cw_button: Button = %RotateCWButton
@onready var _flip_h_button: Button = %FlipHButton
@onready var _flip_v_button: Button = %FlipVButton
@onready var _random_button: Button = %RandomButton
@onready var _tile_palette: TilePalette = %TilePalette
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_erase_button: Button = %ColorEraseButton
@onready var _color_light_mode_button: Button = %ColorLightModeButton
@onready var _color_blend_mode_selector: OptionButton = %ColorBlendModeSelector

var _wall_align_icons: Array[Texture2D] = []
const WALL_ALIGN_TOOLTIPS: Array[String] = ["Wall alignment: World", "Wall alignment: Top", "Wall alignment: Bottom"]


func _ready() -> void:
	_setup_tool_buttons()
	_setup_brush_controls()
	_setup_paint_controls()
	_setup_color_controls()
	_setup_resize_handle()
	_update_button_states()
	_update_paint_panel_visibility()
	_update_color_panel_visibility()

	if _tile_palette:
		_tile_palette.tile_selected.connect(_on_tile_selected)


func _process(_delta: float) -> void:
	_update_paint_panel()
	_update_color_panel()


func _setup_resize_handle() -> void:
	if _resize_handle:
		_resize_handle.draw.connect(_on_resize_handle_draw)
		_resize_handle.gui_input.connect(_on_resize_handle_input)
		_resize_handle.queue_redraw()


func _on_resize_handle_draw() -> void:
	if not _resize_handle:
		return
	var s := _resize_handle.size
	var points := PackedVector2Array([Vector2(0, 0), Vector2(s.x, 0), Vector2(0, s.y)])
	_resize_handle.draw_polygon(points, [Color(0.5, 0.5, 0.5, 0.8)])


func _on_resize_handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_is_dragging_resize = true
			_resize_drag_start = mb.global_position
			_resize_size_start = _panel_size
			_resize_handle.accept_event()


func _input(event: InputEvent) -> void:
	if not _is_dragging_resize:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var delta := _resize_drag_start - motion.global_position
		_panel_size.x = maxf(_resize_size_start.x + delta.x, MIN_PANEL_WIDTH)
		_panel_size.y = maxf(_resize_size_start.y + delta.y, MIN_PANEL_HEIGHT)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_is_dragging_resize = false


func _setup_tool_buttons() -> void:
	_tool_buttons = {
		TerrainEditor.Tool.SCULPT: %SculptButton,
		TerrainEditor.Tool.PAINT: %PaintButton,
		TerrainEditor.Tool.COLOR: %ColorButton,
		TerrainEditor.Tool.FLIP_DIAGONAL: %FlipButton,
		TerrainEditor.Tool.FLATTEN: %FlattenButton,
		TerrainEditor.Tool.MOUNTAIN: %MountainButton,
		TerrainEditor.Tool.FENCE: %FenceButton,
	}

	var icons: Dictionary = {
		TerrainEditor.Tool.SCULPT: SculptIcon,
		TerrainEditor.Tool.PAINT: PaintIcon,
		TerrainEditor.Tool.COLOR: ColorIcon,
		TerrainEditor.Tool.FLIP_DIAGONAL: FlipIcon,
		TerrainEditor.Tool.FLATTEN: FlattenIcon,
		TerrainEditor.Tool.MOUNTAIN: MountainIcon,
		TerrainEditor.Tool.FENCE: FenceIcon,
	}

	var tooltips: Dictionary = {
		TerrainEditor.Tool.SCULPT: "Sculpt - Drag to raise/lower terrain",
		TerrainEditor.Tool.PAINT: "Paint - Click to paint tiles",
		TerrainEditor.Tool.COLOR: "Color - Paint vertex colors on corners",
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
			# Add shift+click to reset paint panel size
			if tool_type == TerrainEditor.Tool.PAINT:
				button.gui_input.connect(_on_paint_button_input)


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
	if _erase_button:
		_erase_button.icon = get_theme_icon("Eraser", "EditorIcons")
		_erase_button.toggled.connect(_on_erase_toggled)

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


func _setup_color_controls() -> void:
	if _color_picker:
		_color_picker.color = Color.WHITE
		_color_picker.color_changed.connect(_on_color_picker_changed)

	if _color_erase_button:
		_color_erase_button.icon = get_theme_icon("Eraser", "EditorIcons")
		_color_erase_button.toggled.connect(_on_color_erase_toggled)

	if _color_light_mode_button:
		var icon := get_theme_icon("GizmoLight", "EditorIcons")
		var img := icon.get_image()
		img.resize(32, 32)
		_color_light_mode_button.icon = ImageTexture.create_from_image(img)
		_color_light_mode_button.toggled.connect(_on_color_light_mode_toggled)

	if _color_blend_mode_selector:
		_color_blend_mode_selector.clear()
		_color_blend_mode_selector.add_item("Screen", TerrainEditor.BlendMode.SCREEN)
		_color_blend_mode_selector.add_item("Additive", TerrainEditor.BlendMode.ADDITIVE)
		_color_blend_mode_selector.add_item("Overlay", TerrainEditor.BlendMode.OVERLAY)
		_color_blend_mode_selector.add_item("Multiply", TerrainEditor.BlendMode.MULTIPLY)
		_color_blend_mode_selector.item_selected.connect(_on_color_blend_mode_selected)
		_update_blend_mode_visibility()


func _on_tool_button_pressed(tool: TerrainEditor.Tool) -> void:
	if terrain_editor:
		if terrain_editor.current_tool == tool:
			terrain_editor.current_tool = TerrainEditor.Tool.NONE
		else:
			terrain_editor.current_tool = tool
	_update_button_states()


func _on_paint_button_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.shift_pressed:
			_panel_size = DEFAULT_PANEL_SIZE


func _on_tool_changed(tool: TerrainEditor.Tool) -> void:
	_update_button_states()
	_update_paint_panel_visibility()
	_update_color_panel_visibility()


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


func _on_erase_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_paint_erase = pressed


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
	if _resize_handle:
		_resize_handle.visible = is_paint_mode


func _update_color_panel_visibility() -> void:
	var is_color_mode: bool = terrain_editor != null and terrain_editor.current_tool == TerrainEditor.Tool.COLOR
	if _color_panel:
		_color_panel.visible = is_color_mode


func _on_color_picker_changed(color: Color) -> void:
	if terrain_editor:
		terrain_editor.current_vertex_color = color
		# Disable erase mode when a new color is selected
		terrain_editor.current_vertex_color_erase = false


func _on_color_erase_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_vertex_color_erase = pressed


func _on_color_light_mode_toggled(pressed: bool) -> void:
	if terrain_editor:
		terrain_editor.current_vertex_color_light_mode = pressed
		if pressed:
			terrain_editor.current_vertex_color_erase = false
	_update_blend_mode_visibility()


func _on_color_blend_mode_selected(index: int) -> void:
	if terrain_editor and _color_blend_mode_selector:
		var blend_mode := _color_blend_mode_selector.get_item_id(index) as TerrainEditor.BlendMode
		terrain_editor.current_vertex_color_blend_mode = blend_mode


func _update_blend_mode_visibility() -> void:
	if _color_blend_mode_selector and terrain_editor:
		_color_blend_mode_selector.disabled = not terrain_editor.current_vertex_color_light_mode


func _on_vertex_color_changed() -> void:
	_update_color_controls()


func _update_color_controls() -> void:
	if not terrain_editor:
		return

	if _color_picker:
		_color_picker.color = terrain_editor.current_vertex_color

	if _color_erase_button:
		_color_erase_button.button_pressed = terrain_editor.current_vertex_color_erase

	if _color_light_mode_button:
		_color_light_mode_button.button_pressed = terrain_editor.current_vertex_color_light_mode

	if _color_blend_mode_selector:
		_color_blend_mode_selector.selected = terrain_editor.current_vertex_color_blend_mode as int

	_update_blend_mode_visibility()


func _update_paint_panel() -> void:
	if not _paint_panel or not _main_toolbar or not _paint_panel.visible:
		return

	# Set panel size and position directly
	var toolbar_rect := _main_toolbar.get_rect()
	_paint_panel.position = Vector2(
		toolbar_rect.end.x - _panel_size.x,
		toolbar_rect.position.y - _panel_size.y - 12
	)
	_paint_panel.size = _panel_size

	# Position resize handle at top-left of panel
	if _resize_handle:
		_resize_handle.position = _paint_panel.position


func _update_color_panel() -> void:
	if not _color_panel or not _main_toolbar or not _color_panel.visible:
		return

	# Position color panel above the toolbar, aligned to right edge
	var toolbar_rect := _main_toolbar.get_rect()
	var panel_size := _color_panel.size
	_color_panel.position = Vector2(
		toolbar_rect.end.x - panel_size.x,
		toolbar_rect.position.y - panel_size.y - 12
	)


func _update_paint_controls() -> void:
	if not terrain_editor:
		return

	if _erase_button:
		_erase_button.button_pressed = terrain_editor.current_paint_erase

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
	if not _atlas_selector:
		return

	_atlas_selector.clear()

	if not tile_set:
		_atlas_selector.visible = false
		return

	var atlas_count := tile_set.get_atlas_count()
	for i in atlas_count:
		var info := tile_set.get_atlas_info(i)
		var label := "Atlas %d" % i
		_atlas_selector.add_item(label, i)

	# Show selector if there are atlases
	_atlas_selector.visible = atlas_count > 0

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
