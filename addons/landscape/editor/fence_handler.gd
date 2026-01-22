@tool
class_name FenceHandler
extends RefCounted

## Handles fence tool operations for the terrain editor.
## Manages fence creation, modification, deletion, and hover detection.

const FENCE_EDGE_THRESHOLD := 0.25  # Distance from edge center to detect fence edge hover

var _editor: TerrainEditor


func _init(editor: TerrainEditor) -> void:
	_editor = editor


func start_drag(camera: Camera3D, mouse_pos: Vector2, data: TerrainData) -> bool:
	if _editor._hovered_cell.x < 0 or _editor._hovered_fence_edge < 0:
		return false

	_editor._is_fence_dragging = true
	_editor._fence_drag_cell = _editor._hovered_cell
	_editor._fence_drag_edge = _editor._hovered_fence_edge
	_editor._fence_current_delta = 0
	_editor._fence_drag_start_mouse_y = mouse_pos.y

	# Determine which corner(s) we're dragging
	match _editor._hovered_fence_hover:
		TerrainEditor.FenceHover.LEFT_CORNER:
			_editor._fence_drag_corner = 0
		TerrainEditor.FenceHover.RIGHT_CORNER:
			_editor._fence_drag_corner = 1
		_:  # MIDDLE or NONE
			_editor._fence_drag_corner = -1  # Both corners

	# Store original heights (before any modification, for undo)
	_editor._fence_original_heights = data.get_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge)

	# Store neighbor's fence heights (in case we clear it)
	var neighbor := get_neighbor_cell(_editor._fence_drag_cell, _editor._fence_drag_edge)
	var neighbor_edge := get_opposite_edge(_editor._fence_drag_edge)
	if data.is_valid_cell(neighbor.x, neighbor.y):
		_editor._fence_neighbor_original_heights = data.get_fence_heights(neighbor.x, neighbor.y, neighbor_edge)
	else:
		_editor._fence_neighbor_original_heights = [0, 0]

	# If no fence exists, create one with default height of 1 step
	# Note: _fence_original_heights stays [0, 0] for proper undo
	if _editor._fence_original_heights[0] == 0 and _editor._fence_original_heights[1] == 0:
		data.set_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, 1, 1)

	# Calculate world position for drag scaling
	var top_corners := data.get_top_world_corners(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y)

	# Get edge midpoint for world position reference
	var edge_start: Vector3
	var edge_end: Vector3
	match _editor._fence_drag_edge:
		0:  # NORTH
			edge_start = top_corners[0]  # NW
			edge_end = top_corners[1]    # NE
		1:  # EAST
			edge_start = top_corners[1]  # NE
			edge_end = top_corners[2]    # SE
		2:  # SOUTH
			edge_start = top_corners[2]  # SE
			edge_end = top_corners[3]    # SW
		3:  # WEST
			edge_start = top_corners[3]  # SW
			edge_end = top_corners[0]    # NW

	var edge_mid := (edge_start + edge_end) / 2.0
	# Use current fence heights (not original) for drag reference position
	var current_heights := data.get_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge)
	edge_mid.y += data.steps_to_world((current_heights[0] + current_heights[1]) / 2)
	_editor._fence_drag_world_pos = _editor._terrain.to_global(edge_mid)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_fence_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Calculate screen-space scale
	var point_above := _editor._fence_drag_world_pos + Vector3(0, 1, 0)
	var screen_drag_pos := camera.unproject_position(_editor._fence_drag_world_pos)
	var screen_above := camera.unproject_position(point_above)
	var pixels_per_unit := screen_drag_pos.y - screen_above.y

	if abs(pixels_per_unit) < 0.001:
		return

	# Calculate mouse delta in world units
	var mouse_delta_pixels := _editor._fence_drag_start_mouse_y - mouse_pos.y
	var mouse_delta_world := mouse_delta_pixels / pixels_per_unit

	# Convert to height steps
	var height_step := data.height_step
	var new_delta := int(round(mouse_delta_world / height_step))

	if new_delta == _editor._fence_current_delta:
		return

	_editor._fence_current_delta = new_delta

	# Apply the new heights
	var new_left := _editor._fence_original_heights[0]
	var new_right := _editor._fence_original_heights[1]

	if _editor._fence_drag_corner == 0:  # Left corner only
		new_left = maxi(0, _editor._fence_original_heights[0] + _editor._fence_current_delta)
	elif _editor._fence_drag_corner == 1:  # Right corner only
		new_right = maxi(0, _editor._fence_original_heights[1] + _editor._fence_current_delta)
	else:  # Both corners
		new_left = maxi(0, _editor._fence_original_heights[0] + _editor._fence_current_delta)
		new_right = maxi(0, _editor._fence_original_heights[1] + _editor._fence_current_delta)

	data.set_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, new_left, new_right)


func finish_drag() -> void:
	if not _editor._is_fence_dragging or not _editor._terrain:
		_editor._is_fence_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if not data:
		_editor._is_fence_dragging = false
		return

	var final_heights := data.get_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge)

	# Only create undo action if there was a change
	if final_heights[0] != _editor._fence_original_heights[0] or final_heights[1] != _editor._fence_original_heights[1]:
		_editor.undo_redo.create_action("Modify Fence")
		_editor.undo_redo.add_do_method(data, "set_fence_heights", _editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, final_heights[0], final_heights[1])
		_editor.undo_redo.add_undo_method(data, "set_fence_heights", _editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, _editor._fence_original_heights[0], _editor._fence_original_heights[1])

		# If we had a neighbor fence that was cleared, restore it on undo
		if _editor._fence_neighbor_original_heights[0] > 0 or _editor._fence_neighbor_original_heights[1] > 0:
			var neighbor := get_neighbor_cell(_editor._fence_drag_cell, _editor._fence_drag_edge)
			var neighbor_edge := get_opposite_edge(_editor._fence_drag_edge)
			_editor.undo_redo.add_undo_method(data, "set_fence_heights", neighbor.x, neighbor.y, neighbor_edge, _editor._fence_neighbor_original_heights[0], _editor._fence_neighbor_original_heights[1])

		_editor.undo_redo.commit_action(false)  # Don't execute, already applied

	_editor._is_fence_dragging = false


func cancel_drag() -> void:
	if not _editor._is_fence_dragging or not _editor._terrain:
		_editor._is_fence_dragging = false
		return

	var data := _editor._terrain.terrain_data
	if data:
		# Restore original heights (this may clear our fence if original was 0)
		data.set_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, _editor._fence_original_heights[0], _editor._fence_original_heights[1])

		# Restore neighbor fence if it was cleared
		if _editor._fence_neighbor_original_heights[0] > 0 or _editor._fence_neighbor_original_heights[1] > 0:
			var neighbor := get_neighbor_cell(_editor._fence_drag_cell, _editor._fence_drag_edge)
			var neighbor_edge := get_opposite_edge(_editor._fence_drag_edge)
			data.set_fence_heights(neighbor.x, neighbor.y, neighbor_edge, _editor._fence_neighbor_original_heights[0], _editor._fence_neighbor_original_heights[1])

	_editor._is_fence_dragging = false


func delete_fence(data: TerrainData, cell: Vector2i, edge: int) -> void:
	var old_heights := data.get_fence_heights(cell.x, cell.y, edge)
	if old_heights[0] == 0 and old_heights[1] == 0:
		return  # No fence to delete

	_editor.undo_redo.create_action("Delete Fence")
	_editor.undo_redo.add_do_method(data, "clear_fence", cell.x, cell.y, edge)
	_editor.undo_redo.add_undo_method(data, "set_fence_heights", cell.x, cell.y, edge, old_heights[0], old_heights[1])
	_editor.undo_redo.commit_action()


func update_hover(local_pos: Vector3, cell_size: float) -> void:
	# Reset fence hover state
	_editor._hovered_fence_edge = -1
	_editor._hovered_fence_hover = TerrainEditor.FenceHover.NONE

	if _editor._hovered_cell.x < 0 or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	# Calculate position within cell (0-1 range)
	var cell_local_x := local_pos.x - _editor._hovered_cell.x * cell_size
	var cell_local_z := local_pos.z - _editor._hovered_cell.y * cell_size
	var norm_x := cell_local_x / cell_size
	var norm_z := cell_local_z / cell_size

	# Check distance to each edge
	var dist_to_north := norm_z
	var dist_to_south := 1.0 - norm_z
	var dist_to_west := norm_x
	var dist_to_east := 1.0 - norm_x

	# Find closest edge
	var min_dist := dist_to_north
	var closest_edge := 0  # NORTH
	if dist_to_east < min_dist:
		min_dist = dist_to_east
		closest_edge = 1  # EAST
	if dist_to_south < min_dist:
		min_dist = dist_to_south
		closest_edge = 2  # SOUTH
	if dist_to_west < min_dist:
		min_dist = dist_to_west
		closest_edge = 3  # WEST

	# Only consider it a fence hover if close enough to edge
	if min_dist > FENCE_EDGE_THRESHOLD:
		return

	# Check if this cell has a fence on this edge
	var has_fence_here := data.has_fence(_editor._hovered_cell.x, _editor._hovered_cell.y, closest_edge)

	# Check if the neighbor has a fence on the shared edge
	var neighbor := get_neighbor_cell(_editor._hovered_cell, closest_edge)
	var neighbor_edge := get_opposite_edge(closest_edge)
	var has_fence_neighbor := data.is_valid_cell(neighbor.x, neighbor.y) and data.has_fence(neighbor.x, neighbor.y, neighbor_edge)

	# If neighbor has fence but we don't, redirect to neighbor's fence
	if has_fence_neighbor and not has_fence_here:
		_editor._hovered_cell = neighbor
		closest_edge = neighbor_edge
		# Recalculate normalized position relative to the new cell
		cell_local_x = local_pos.x - _editor._hovered_cell.x * cell_size
		cell_local_z = local_pos.z - _editor._hovered_cell.y * cell_size
		norm_x = cell_local_x / cell_size
		norm_z = cell_local_z / cell_size

	_editor._hovered_fence_edge = closest_edge

	# Determine if we're near a corner or in the middle of the edge
	var edge_pos: float  # 0-1 position along the edge (0 = left corner, 1 = right corner)
	match closest_edge:
		0:  # NORTH: left = NW (x=0), right = NE (x=1)
			edge_pos = norm_x
		1:  # EAST: left = NE (z=0), right = SE (z=1)
			edge_pos = norm_z
		2:  # SOUTH: left = SE (x=1), right = SW (x=0)
			edge_pos = 1.0 - norm_x
		3:  # WEST: left = SW (z=1), right = NW (z=0)
			edge_pos = 1.0 - norm_z

	# Corner threshold (closer than this to 0 or 1 = corner)
	const CORNER_THRESHOLD := 0.3
	if edge_pos < CORNER_THRESHOLD:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.LEFT_CORNER
	elif edge_pos > 1.0 - CORNER_THRESHOLD:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.RIGHT_CORNER
	else:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.MIDDLE


func get_neighbor_cell(cell: Vector2i, edge: int) -> Vector2i:
	match edge:
		0: return Vector2i(cell.x, cell.y - 1)  # NORTH
		1: return Vector2i(cell.x + 1, cell.y)  # EAST
		2: return Vector2i(cell.x, cell.y + 1)  # SOUTH
		3: return Vector2i(cell.x - 1, cell.y)  # WEST
	return cell


func get_opposite_edge(edge: int) -> int:
	match edge:
		0: return 2  # NORTH -> SOUTH
		1: return 3  # EAST -> WEST
		2: return 0  # SOUTH -> NORTH
		3: return 1  # WEST -> EAST
	return edge
