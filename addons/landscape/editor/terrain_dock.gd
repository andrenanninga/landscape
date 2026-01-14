@tool
extends Control

var terrain_editor: TerrainEditor:
	set(value):
		terrain_editor = value
		if terrain_editor:
			terrain_editor.tool_changed.connect(_on_tool_changed)
			terrain_editor.hover_changed.connect(_on_hover_changed)
			terrain_editor.height_changed.connect(_on_height_changed)

var _current_cell: Vector2i = Vector2i(-1, -1)
var _current_corner: int = -1
var _current_mode: int = 0

@onready var _tool_buttons: Dictionary = {}
@onready var _status_label: Label = %StatusLabel


func _ready() -> void:
	_setup_tool_buttons()
	_update_button_states()


func _setup_tool_buttons() -> void:
	_tool_buttons = {
		TerrainEditor.Tool.SCULPT: %SculptButton,
	}

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.pressed.connect(_on_tool_button_pressed.bind(tool_type))


func _on_tool_button_pressed(tool: TerrainEditor.Tool) -> void:
	if terrain_editor:
		if terrain_editor.current_tool == tool:
			terrain_editor.current_tool = TerrainEditor.Tool.NONE
		else:
			terrain_editor.current_tool = tool
	_update_button_states()


func _on_tool_changed(tool: TerrainEditor.Tool) -> void:
	_update_button_states()


func _on_hover_changed(cell: Vector2i, corner: int, mode: int) -> void:
	_current_cell = cell
	_current_corner = corner
	_current_mode = mode
	var height := terrain_editor.get_current_height() if terrain_editor else NAN
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

	# Line 2: Corner
	if _current_mode == TerrainEditor.HoverMode.CORNER:
		var corner_name := _get_corner_name(_current_corner)
		lines.append("Corner: %s" % corner_name)
	else:
		lines.append("Corner: All")

	# Line 3: Height
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


func _update_button_states() -> void:
	if not terrain_editor:
		return

	for tool_type in _tool_buttons:
		var button: Button = _tool_buttons[tool_type]
		if button:
			button.button_pressed = terrain_editor.current_tool == tool_type
