@tool
class_name TerrainPreview
extends RefCounted

## Manages tile preview state for terrain editing.
## Stores preview buffer and notifies terrain when updates are needed.

signal preview_changed

var _buffer: Dictionary = {}  # "x,z,surface" -> packed_tile_value


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


func has(key: String) -> bool:
	return _buffer.has(key)


func get_value(key: String) -> int:
	return _buffer.get(key, 0)
