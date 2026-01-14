@tool
extends EditorPlugin

const LandscapeTerrainScript = preload("res://addons/landscape/nodes/landscape.gd")
const TerrainEditorScript = preload("res://addons/landscape/editor/terrain_editor.gd")
const TerrainDockScene = preload("res://addons/landscape/editor/terrain_dock.tscn")
const TerrainInspectorPluginScript = preload("res://addons/landscape/editor/terrain_inspector_plugin.gd")

var _dock: Control
var _terrain_editor: RefCounted  # TerrainEditor
var _current_terrain: LandscapeTerrain
var _inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
	# Register custom type
	add_custom_type(
		"LandscapeTerrain",
		"MeshInstance3D",
		LandscapeTerrainScript,
		null
	)

	# Create terrain editor
	_terrain_editor = TerrainEditorScript.new()
	_terrain_editor.editor_interface = get_editor_interface()
	_terrain_editor.undo_redo = get_undo_redo()
	_terrain_editor.hover_changed.connect(_on_hover_changed)

	# Create inspector plugin for grid resize undo/redo
	_inspector_plugin = TerrainInspectorPluginScript.new()
	_inspector_plugin.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector_plugin)

	# Create dock
	if ResourceLoader.exists("res://addons/landscape/editor/terrain_dock.tscn"):
		_dock = TerrainDockScene.instantiate()
		_dock.terrain_editor = _terrain_editor
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
		_dock.visible = false


func _exit_tree() -> void:
	remove_custom_type("LandscapeTerrain")

	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

	_terrain_editor = null


func _handles(object: Object) -> bool:
	return object is LandscapeTerrain


func _edit(object: Object) -> void:
	_current_terrain = object as LandscapeTerrain
	if _terrain_editor:
		_terrain_editor.set_terrain(_current_terrain)
	_update_dock_visibility()


func _make_visible(visible: bool) -> void:
	_update_dock_visibility()


func _update_dock_visibility() -> void:
	if _dock:
		_dock.visible = _current_terrain != null


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not _current_terrain or not _terrain_editor:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var handled: bool = _terrain_editor.handle_input(viewport_camera, event, _current_terrain)

	if handled:
		update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _current_terrain or not _terrain_editor:
		return
	_terrain_editor.draw_overlay(overlay, _current_terrain)


func _on_hover_changed(cell: Vector2i, corner: int, mode: int) -> void:
	if not _current_terrain:
		return
	if cell.x >= 0:
		var corner_mode := mode == 1  # HoverMode.CORNER = 1
		_current_terrain.set_selected_cell(cell, corner, corner_mode)
	else:
		_current_terrain.clear_selection()
