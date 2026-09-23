@tool
class_name FenceHandler
extends RefCounted

## Handles fence tool operations for the terrain editor.
## Manages fence creation, modification, deletion, and hover detection.

const FENCE_EDGE_THRESHOLD := 0.25  # Distance from edge (fraction of cell) to detect fence edge hover
const CORNER_THRESHOLD := 0.3  # Distance along the edge (fraction) that counts as a corner grab

var _editor: TerrainEditor

# Fence the neighbour had on the shared edge before this drag replaced it
var _neighbor_original_heights: Array[int] = [0, 0]
var _neighbor_original_tile: int = 0


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

	match _editor._hovered_fence_hover:
		TerrainEditor.FenceHover.LEFT_CORNER:
			_editor._fence_drag_corner = 0
		TerrainEditor.FenceHover.RIGHT_CORNER:
			_editor._fence_drag_corner = 1
		_:
			_editor._fence_drag_corner = -1  # Both corners

	var cell := _editor._fence_drag_cell
	var edge := _editor._fence_drag_edge
	_editor._fence_original_heights = data.get_fence_heights(cell.x, cell.y, edge)

	var neighbor := TerrainData.fence_neighbor(cell.x, cell.y, edge)
	var neighbor_edge := TerrainData.opposite_edge(edge)
	_neighbor_original_heights = data.get_fence_heights(neighbor.x, neighbor.y, neighbor_edge)
	_neighbor_original_tile = data.get_fence_tile_packed(neighbor.x, neighbor.y, neighbor_edge)

	# Clicking an empty edge creates a fence of one step; the original stays [0, 0] for undo
	if _editor._fence_original_heights[0] == 0 and _editor._fence_original_heights[1] == 0:
		data.set_fence_heights(cell.x, cell.y, edge, 1, 1)

	# Drag scale reference: midpoint of the fence's top edge
	var fence_corners := data.get_fence_world_corners(cell.x, cell.y, TerrainData.fence_surface_from_edge(edge))
	_editor._fence_drag_world_pos = _editor._terrain.to_global((fence_corners[0] + fence_corners[1]) / 2.0)

	return true


func update_drag(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not _editor._is_fence_dragging or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	var new_delta := _editor.mouse_delta_to_steps(camera, _editor._fence_drag_world_pos, _editor._fence_drag_start_mouse_y, mouse_pos.y, data, _editor._fence_current_delta)
	if new_delta == _editor._fence_current_delta:
		return
	_editor._fence_current_delta = new_delta

	var new_left: int = _editor._fence_original_heights[0]
	var new_right: int = _editor._fence_original_heights[1]
	if _editor._fence_drag_corner != 1:
		new_left = maxi(0, new_left + new_delta)
	if _editor._fence_drag_corner != 0:
		new_right = maxi(0, new_right + new_delta)

	data.set_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, new_left, new_right)


func finish_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not _editor._is_fence_dragging or not data:
		_editor._is_fence_dragging = false
		return

	var cell := _editor._fence_drag_cell
	var edge := _editor._fence_drag_edge
	var final_heights := data.get_fence_heights(cell.x, cell.y, edge)

	if final_heights != _editor._fence_original_heights:
		_editor.undo_redo.create_action("Modify Fence")
		_editor.undo_redo.add_do_method(data, "set_fence_heights", cell.x, cell.y, edge, final_heights[0], final_heights[1])
		_editor.undo_redo.add_undo_method(data, "set_fence_heights", cell.x, cell.y, edge, _editor._fence_original_heights[0], _editor._fence_original_heights[1])
		_add_neighbor_restore(data)
		_editor.undo_redo.commit_action(false)  # Already applied

	_editor._is_fence_dragging = false


func cancel_drag() -> void:
	var data := _editor._terrain.terrain_data if _editor._terrain else null
	if not _editor._is_fence_dragging or not data:
		_editor._is_fence_dragging = false
		return

	data.begin_batch()
	data.set_fence_heights(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge, _editor._fence_original_heights[0], _editor._fence_original_heights[1])
	_restore_neighbor(data)
	data.end_batch()

	_editor._is_fence_dragging = false


func delete_fence(data: TerrainData, cell: Vector2i, edge: int) -> void:
	var old_heights := data.get_fence_heights(cell.x, cell.y, edge)
	if old_heights[0] == 0 and old_heights[1] == 0:
		return

	_editor.undo_redo.create_action("Delete Fence")
	_editor.undo_redo.add_do_method(data, "clear_fence", cell.x, cell.y, edge)
	_editor.undo_redo.add_undo_method(data, "set_fence_heights", cell.x, cell.y, edge, old_heights[0], old_heights[1])
	_editor.undo_redo.commit_action()


func _had_neighbor_fence() -> bool:
	return _neighbor_original_heights[0] > 0 or _neighbor_original_heights[1] > 0


func _add_neighbor_restore(data: TerrainData) -> void:
	if not _had_neighbor_fence():
		return
	var neighbor := TerrainData.fence_neighbor(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge)
	var neighbor_edge := TerrainData.opposite_edge(_editor._fence_drag_edge)
	_editor.undo_redo.add_undo_method(data, "set_fence_heights", neighbor.x, neighbor.y, neighbor_edge, _neighbor_original_heights[0], _neighbor_original_heights[1])
	_editor.undo_redo.add_undo_method(data, "set_fence_tile_packed", neighbor.x, neighbor.y, neighbor_edge, _neighbor_original_tile)


func _restore_neighbor(data: TerrainData) -> void:
	if not _had_neighbor_fence():
		return
	var neighbor := TerrainData.fence_neighbor(_editor._fence_drag_cell.x, _editor._fence_drag_cell.y, _editor._fence_drag_edge)
	var neighbor_edge := TerrainData.opposite_edge(_editor._fence_drag_edge)
	data.set_fence_heights(neighbor.x, neighbor.y, neighbor_edge, _neighbor_original_heights[0], _neighbor_original_heights[1])
	data.set_fence_tile_packed(neighbor.x, neighbor.y, neighbor_edge, _neighbor_original_tile)


# Determines which edge (and which part of it) is hovered within the current cell
func update_hover(local_pos: Vector3, cell_size: float) -> void:
	_editor._hovered_fence_edge = -1
	_editor._hovered_fence_hover = TerrainEditor.FenceHover.NONE

	if _editor._hovered_cell.x < 0 or not _editor._terrain:
		return

	var data := _editor._terrain.terrain_data
	if not data:
		return

	var norm := _normalized_cell_position(local_pos, _editor._hovered_cell, cell_size)

	# Distances to N, E, S, W edges
	var edge_distances: Array[float] = [norm.y, 1.0 - norm.x, 1.0 - norm.y, norm.x]
	var closest_edge := 0
	for edge in range(1, 4):
		if edge_distances[edge] < edge_distances[closest_edge]:
			closest_edge = edge
	if edge_distances[closest_edge] > FENCE_EDGE_THRESHOLD:
		return

	# A fence owned by the neighbour on the shared edge is edited from this side too
	var neighbor := TerrainData.fence_neighbor(_editor._hovered_cell.x, _editor._hovered_cell.y, closest_edge)
	var neighbor_edge := TerrainData.opposite_edge(closest_edge)
	if not data.has_fence(_editor._hovered_cell.x, _editor._hovered_cell.y, closest_edge) and data.has_fence(neighbor.x, neighbor.y, neighbor_edge):
		_editor._hovered_cell = neighbor
		closest_edge = neighbor_edge
		norm = _normalized_cell_position(local_pos, neighbor, cell_size)

	_editor._hovered_fence_edge = closest_edge

	# Position along the edge from its left corner (0) to its right corner (1)
	var edge_pos: float
	match closest_edge:
		TerrainData.Edge.NORTH:
			edge_pos = norm.x
		TerrainData.Edge.EAST:
			edge_pos = norm.y
		TerrainData.Edge.SOUTH:
			edge_pos = 1.0 - norm.x
		TerrainData.Edge.WEST:
			edge_pos = 1.0 - norm.y

	if edge_pos < CORNER_THRESHOLD:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.LEFT_CORNER
	elif edge_pos > 1.0 - CORNER_THRESHOLD:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.RIGHT_CORNER
	else:
		_editor._hovered_fence_hover = TerrainEditor.FenceHover.MIDDLE


static func _normalized_cell_position(local_pos: Vector3, cell: Vector2i, cell_size: float) -> Vector2:
	return Vector2(local_pos.x / cell_size - cell.x, local_pos.z / cell_size - cell.y)
