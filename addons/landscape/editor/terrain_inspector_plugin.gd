@tool
class_name TerrainInspectorPlugin
extends EditorInspectorPlugin

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is TerrainData or object is LandscapeTerrain


func _parse_property(object: Object, type: Variant.Type, name: String, hint_type: PropertyHint, hint_string: String, usage_flags: int, wide: bool) -> bool:
	if name == "grid_width" or name == "grid_depth":
		if object is TerrainData:
			var editor := GridSizePropertyForData.new()
			editor.undo_redo = undo_redo
			add_property_editor(name, editor)
			return true
		elif object is LandscapeTerrain:
			var editor := GridSizePropertyForTerrain.new()
			editor.undo_redo = undo_redo
			add_property_editor(name, editor)
			return true
	return false


class GridSizePropertyForData extends EditorProperty:
	var undo_redo: EditorUndoRedoManager
	var _spin_box: SpinBox
	var _updating: bool = false

	func _init() -> void:
		_spin_box = SpinBox.new()
		_spin_box.min_value = 1
		_spin_box.max_value = 256
		_spin_box.step = 1
		_spin_box.value_changed.connect(_on_value_changed)
		add_child(_spin_box)

	func _update_property() -> void:
		var value = get_edited_object()[get_edited_property()]
		_updating = true
		_spin_box.value = value
		_updating = false

	func _on_value_changed(new_value: float) -> void:
		if _updating:
			return

		var data: TerrainData = get_edited_object()
		var prop_name: String = get_edited_property()
		var old_value: int = data[prop_name]
		var new_int_value := int(new_value)

		if old_value == new_int_value:
			return

		# Store all the data needed to restore state
		var old_width := data.grid_width
		var old_depth := data.grid_depth
		var old_cells := data.cells.duplicate()

		# Create undo/redo action
		undo_redo.create_action("Resize Terrain Grid")

		# Do: set the new value (this triggers _resize_grid internally)
		undo_redo.add_do_property(data, prop_name, new_int_value)

		# Undo: restore full state atomically
		undo_redo.add_undo_method(data, "restore_grid_state", old_width, old_depth, old_cells)

		undo_redo.commit_action()


class GridSizePropertyForTerrain extends EditorProperty:
	var undo_redo: EditorUndoRedoManager
	var _spin_box: SpinBox
	var _updating: bool = false

	func _init() -> void:
		_spin_box = SpinBox.new()
		_spin_box.min_value = 1
		_spin_box.max_value = 256
		_spin_box.step = 1
		_spin_box.value_changed.connect(_on_value_changed)
		add_child(_spin_box)

	func _update_property() -> void:
		var value = get_edited_object()[get_edited_property()]
		_updating = true
		_spin_box.value = value
		_updating = false

	func _on_value_changed(new_value: float) -> void:
		if _updating:
			return

		var terrain: LandscapeTerrain = get_edited_object()
		var data: TerrainData = terrain.terrain_data
		if not data:
			return

		var prop_name: String = get_edited_property()
		var old_value: int = data[prop_name]
		var new_int_value := int(new_value)

		if old_value == new_int_value:
			return

		# Store all the data needed to restore state
		var old_width := data.grid_width
		var old_depth := data.grid_depth
		var old_cells := data.cells.duplicate()

		# Create undo/redo action
		undo_redo.create_action("Resize Terrain Grid")

		# Do: set the new value on TerrainData (this triggers _resize_grid internally)
		undo_redo.add_do_property(data, prop_name, new_int_value)

		# Undo: restore full state atomically
		undo_redo.add_undo_method(data, "restore_grid_state", old_width, old_depth, old_cells)

		undo_redo.commit_action()
