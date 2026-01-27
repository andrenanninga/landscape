@tool
class_name TerrainInspectorPlugin
extends EditorInspectorPlugin

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is TerrainData


func _parse_property(object: Object, type: Variant.Type, name: String, hint_type: PropertyHint, hint_string: String, usage_flags: int, wide: bool) -> bool:
	if not object is TerrainData:
		return false

	if name == "grid_width":
		var editor := GridSizePropertyForData.new()
		editor.undo_redo = undo_redo
		add_property_editor(name, editor)
		return true

	if name == "grid_depth":
		var editor := GridSizePropertyForData.new()
		editor.undo_redo = undo_redo
		add_property_editor(name, editor)
		# Add directional resize controls after grid_depth
		var resize_control := GridResizeControl.new()
		resize_control.terrain_data = object
		resize_control.undo_redo = undo_redo
		add_custom_control(resize_control)
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


class GridResizeControl extends VBoxContainer:
	var terrain_data: TerrainData
	var undo_redo: EditorUndoRedoManager

	func _init() -> void:
		# Create collapsible section
		var hbox := HBoxContainer.new()
		hbox.alignment = BoxContainer.ALIGNMENT_CENTER

		# Direction buttons in a grid layout: W [-][+]  N [-][+]  S [-][+]  E [-][+]
		_add_direction_buttons(hbox, "W", _shrink_west, _grow_west)
		_add_direction_buttons(hbox, "N", _shrink_north, _grow_north)
		_add_direction_buttons(hbox, "S", _shrink_south, _grow_south)
		_add_direction_buttons(hbox, "E", _shrink_east, _grow_east)

		add_child(hbox)

	func _add_direction_buttons(parent: HBoxContainer, label_text: String, shrink_callback: Callable, grow_callback: Callable) -> void:
		var label := Label.new()
		label.text = label_text
		label.custom_minimum_size.x = 16
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		parent.add_child(label)

		var shrink_btn := Button.new()
		shrink_btn.text = "-"
		shrink_btn.custom_minimum_size = Vector2(24, 24)
		shrink_btn.tooltip_text = "Shrink from %s" % _direction_name(label_text)
		shrink_btn.pressed.connect(shrink_callback)
		parent.add_child(shrink_btn)

		var grow_btn := Button.new()
		grow_btn.text = "+"
		grow_btn.custom_minimum_size = Vector2(24, 24)
		grow_btn.tooltip_text = "Grow toward %s" % _direction_name(label_text)
		grow_btn.pressed.connect(grow_callback)
		parent.add_child(grow_btn)

		# Add separator except for last
		if label_text != "E":
			var sep := VSeparator.new()
			parent.add_child(sep)

	func _direction_name(short: String) -> String:
		match short:
			"N": return "North"
			"S": return "South"
			"E": return "East"
			"W": return "West"
		return short

	func _find_terrain_node() -> Node3D:
		# First try to get the currently selected node
		var selection := EditorInterface.get_selection()
		if selection:
			var selected_nodes := selection.get_selected_nodes()
			for node in selected_nodes:
				if node is LandscapeTerrain and node.terrain_data == terrain_data:
					return node

		# Fallback: search scene tree
		var scene_root := EditorInterface.get_edited_scene_root()
		if not scene_root:
			return null
		return _find_terrain_recursive(scene_root)

	func _find_terrain_recursive(node: Node) -> Node3D:
		if node is LandscapeTerrain and node.terrain_data == terrain_data:
			return node
		for child in node.get_children():
			var result := _find_terrain_recursive(child)
			if result:
				return result
		return null

	func _do_resize(delta_width: int, delta_depth: int, offset_x: int, offset_z: int) -> void:
		if not terrain_data:
			return

		var old_width := terrain_data.grid_width
		var old_depth := terrain_data.grid_depth
		var new_width := maxi(1, old_width + delta_width)
		var new_depth := maxi(1, old_depth + delta_depth)

		if new_width == old_width and new_depth == old_depth:
			return

		var old_cells := terrain_data.cells.duplicate()

		# Find terrain node to adjust position for West/North operations
		var terrain_node := _find_terrain_node()
		var position_offset := Vector3.ZERO
		if offset_x != 0 or offset_z != 0:
			position_offset.x = -offset_x * terrain_data.cell_size
			position_offset.z = -offset_z * terrain_data.cell_size

		if undo_redo:
			undo_redo.create_action("Resize Grid")
			undo_redo.add_do_method(terrain_data, "resize_with_offset", new_width, new_depth, offset_x, offset_z)
			undo_redo.add_undo_method(terrain_data, "restore_grid_state", old_width, old_depth, old_cells)
			if terrain_node and position_offset != Vector3.ZERO:
				var old_position := terrain_node.position
				undo_redo.add_do_property(terrain_node, "position", old_position + position_offset)
				undo_redo.add_undo_property(terrain_node, "position", old_position)
			undo_redo.commit_action()
		else:
			terrain_data.resize_with_offset(new_width, new_depth, offset_x, offset_z)
			if terrain_node and position_offset != Vector3.ZERO:
				terrain_node.position += position_offset

	func _grow_north() -> void:
		_do_resize(0, 1, 0, 1)

	func _shrink_north() -> void:
		_do_resize(0, -1, 0, -1)

	func _grow_south() -> void:
		_do_resize(0, 1, 0, 0)

	func _shrink_south() -> void:
		_do_resize(0, -1, 0, 0)

	func _grow_east() -> void:
		_do_resize(1, 0, 0, 0)

	func _shrink_east() -> void:
		_do_resize(-1, 0, 0, 0)

	func _grow_west() -> void:
		_do_resize(1, 0, 1, 0)

	func _shrink_west() -> void:
		_do_resize(-1, 0, -1, 0)
