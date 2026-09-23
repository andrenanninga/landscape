@tool
class_name TerrainPreview
extends RefCounted

## Holds tile overrides shown while painting, before they are committed to TerrainData.
## Keys are Vector3i(x, z, surface); values are packed tiles (see TilePacking).

signal preview_changed

var _buffer: Dictionary = {}


func set_previews(previews: Dictionary) -> void:
	_buffer = previews
	preview_changed.emit()


func get_buffer() -> Dictionary:
	return _buffer


func clear() -> void:
	if _buffer.is_empty():
		return
	_buffer.clear()
	preview_changed.emit()


func is_empty() -> bool:
	return _buffer.is_empty()
