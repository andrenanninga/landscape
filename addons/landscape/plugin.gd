@tool
extends EditorPlugin

const LandscapeTerrainScript = preload("res://addons/landscape/nodes/landscape.gd")
const LandscapeTerrainIcon = preload("res://addons/landscape/icons/landscape_terrain.svg")
const TerrainOverlayUIScene = preload("res://addons/landscape/editor/terrain_overlay_ui.tscn")
const TerrainInspectorPluginScript = preload("res://addons/landscape/editor/terrain_inspector_plugin.gd")

var _overlay_ui: Control
var _terrain_editor: TerrainEditor
var _current_terrain: LandscapeTerrain
var _inspector_plugin: EditorInspectorPlugin
var _was_window_focused: bool = true
var _viewport_container: Control


func _enter_tree() -> void:
	# Register custom type
	add_custom_type(
		"LandscapeTerrain",
		"MeshInstance3D",
		LandscapeTerrainScript,
		LandscapeTerrainIcon
	)

	# Create terrain editor
	_terrain_editor = TerrainEditor.new()
	_terrain_editor.editor_interface = get_editor_interface()
	_terrain_editor.undo_redo = get_undo_redo()
	_terrain_editor.hover_changed.connect(_on_hover_changed)

	# Create inspector plugin for grid resize undo/redo
	_inspector_plugin = TerrainInspectorPluginScript.new()
	_inspector_plugin.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector_plugin)

	# Create viewport overlay UI
	if ResourceLoader.exists("res://addons/landscape/editor/terrain_overlay_ui.tscn"):
		_overlay_ui = TerrainOverlayUIScene.instantiate()
		_overlay_ui.set("terrain_editor", _terrain_editor)
		_overlay_ui.visible = false
		# Overlay will be attached to viewport in _forward_3d_draw_over_viewport


func _attach_overlay_to_viewport(draw_overlay: Control) -> void:
	if not _overlay_ui or _viewport_container:
		return

	# The draw_overlay is a child of the viewport control
	# Add our UI as a sibling to the draw overlay
	var parent := draw_overlay.get_parent()
	if parent:
		_viewport_container = parent
		parent.add_child(_overlay_ui)
		_overlay_ui.move_to_front()
		_update_overlay_visibility()


func _exit_tree() -> void:
	remove_custom_type("LandscapeTerrain")

	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

	if _overlay_ui:
		if _overlay_ui.get_parent():
			_overlay_ui.get_parent().remove_child(_overlay_ui)
		_overlay_ui.queue_free()
		_overlay_ui = null

	_viewport_container = null
	_terrain_editor = null


func _handles(object: Object) -> bool:
	return object is LandscapeTerrain


func _edit(object: Object) -> void:
	_current_terrain = object as LandscapeTerrain
	if _terrain_editor:
		_terrain_editor.set_terrain(_current_terrain)
	if _overlay_ui:
		_overlay_ui.set("terrain", _current_terrain)
	_update_overlay_visibility()


func _make_visible(visible: bool) -> void:
	_update_overlay_visibility()


func _update_overlay_visibility() -> void:
	if _overlay_ui:
		_overlay_ui.visible = _current_terrain != null


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not _current_terrain or not _terrain_editor:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var handled: bool = _terrain_editor.handle_input(viewport_camera, event, _current_terrain)

	# Update overlays on mouse motion or when input was handled (e.g., after clicking)
	if event is InputEventMouseMotion or handled:
		update_overlays()

	if handled:
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	# Attach our UI overlay to the viewport if not already done
	if _overlay_ui and not _viewport_container:
		_attach_overlay_to_viewport(overlay)

	if not _current_terrain or not _terrain_editor:
		return

	# Check if mouse is inside the 3D viewport
	var mouse_pos := overlay.get_local_mouse_position()
	var viewport_rect := Rect2(Vector2.ZERO, overlay.size)
	if not viewport_rect.has_point(mouse_pos):
		# Mouse is outside viewport - clear hover state and previews
		_terrain_editor.clear_all_previews()
		return

	_terrain_editor.draw_overlay(overlay, _current_terrain)


func _on_hover_changed(_cell: Vector2i, _corner: int, _mode: int) -> void:
	# Overlay-based highlighting is handled in draw_overlay
	pass


func _process(_delta: float) -> void:
	if not _terrain_editor:
		return

	# Check if the main window has focus
	var is_focused := DisplayServer.window_is_focused()
	if _was_window_focused and not is_focused:
		# Window lost focus - cancel any paint preview
		_terrain_editor.clear_all_previews()
	_was_window_focused = is_focused
