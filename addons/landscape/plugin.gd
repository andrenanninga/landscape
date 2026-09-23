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
var _overlay_attached: bool = false


func _enter_tree() -> void:
	add_custom_type("LandscapeTerrain", "MeshInstance3D", LandscapeTerrainScript, LandscapeTerrainIcon)

	_terrain_editor = TerrainEditor.new()
	_terrain_editor.editor_interface = get_editor_interface()
	_terrain_editor.undo_redo = get_undo_redo()

	_inspector_plugin = TerrainInspectorPluginScript.new()
	_inspector_plugin.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector_plugin)

	# Attached to the 3D viewport lazily, once _forward_3d_draw_over_viewport hands us the viewport overlay
	_overlay_ui = TerrainOverlayUIScene.instantiate()
	_overlay_ui.set("terrain_editor", _terrain_editor)
	_overlay_ui.visible = false


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

	_overlay_attached = false
	_current_terrain = null
	if _terrain_editor:
		_terrain_editor.dispose()
		_terrain_editor = null


func _notification(what: int) -> void:
	# A paint preview left behind while alt-tabbing would linger until the mouse returns
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _terrain_editor:
		_terrain_editor.clear_all_previews()


func _handles(object: Object) -> bool:
	return object is LandscapeTerrain


func _edit(object: Object) -> void:
	_current_terrain = object as LandscapeTerrain
	_terrain_editor.set_terrain(_current_terrain)
	_overlay_ui.set("terrain", _current_terrain)
	_update_overlay_visibility()


func _make_visible(visible: bool) -> void:
	if not visible:
		_current_terrain = null
		_terrain_editor.set_terrain(null)
	_update_overlay_visibility()


func _update_overlay_visibility() -> void:
	if _overlay_ui:
		_overlay_ui.visible = _current_terrain != null


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not _current_terrain or not _terrain_editor:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var handled: bool = _terrain_editor.handle_input(viewport_camera, event, _current_terrain)

	if event is InputEventMouseMotion or handled:
		update_overlays()

	return EditorPlugin.AFTER_GUI_INPUT_STOP if handled else EditorPlugin.AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _overlay_attached:
		_attach_overlay_to_viewport(overlay)

	if not _current_terrain or not _terrain_editor:
		return

	# Outside the viewport there is nothing to hover; drop stale previews
	if not Rect2(Vector2.ZERO, overlay.size).has_point(overlay.get_local_mouse_position()):
		_terrain_editor.clear_all_previews()
		return

	_terrain_editor.draw_overlay(overlay, _current_terrain)


# The draw overlay is a child of the viewport control; our UI becomes its sibling
func _attach_overlay_to_viewport(draw_overlay: Control) -> void:
	var parent := draw_overlay.get_parent()
	if not _overlay_ui or not parent:
		return

	parent.add_child(_overlay_ui)
	_overlay_ui.move_to_front()
	_overlay_attached = true
	_update_overlay_visibility()
