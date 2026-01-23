@tool
class_name TilePacking
extends RefCounted

## Static utility class for packing/unpacking tile data into integers.
## Provides bit manipulation for tile index, rotation, flip, and wall alignment.

# Bit packing constants for tile values
const TILE_INDEX_MASK := 0xFFFF      # Bits 0-15: tile index (0-65535)
const TILE_ROTATION_MASK := 0x30000  # Bits 16-17: rotation (0-3)
const TILE_ROTATION_SHIFT := 16
const TILE_FLIP_H_BIT := 0x40000     # Bit 18: flip horizontal
const TILE_FLIP_V_BIT := 0x80000     # Bit 19: flip vertical
const DIAGONAL_FLIP_BIT := 0x100000  # Bit 20: flip diagonal (stored in top tile only)
const TILE_WALL_ALIGN_MASK := 0x300000   # Bits 20-21: wall alignment mode (for wall tiles)
const TILE_WALL_ALIGN_SHIFT := 20


static func pack(tile_index: int, rotation: int = 0, flip_h: bool = false, flip_v: bool = false, wall_align: int = 0) -> int:
	var packed := tile_index & TILE_INDEX_MASK
	packed |= (rotation << TILE_ROTATION_SHIFT)
	if flip_h:
		packed |= TILE_FLIP_H_BIT
	if flip_v:
		packed |= TILE_FLIP_V_BIT
	packed |= (wall_align << TILE_WALL_ALIGN_SHIFT)
	return packed


static func unpack(packed: int) -> Dictionary:
	return {
		"tile_index": packed & TILE_INDEX_MASK,
		"rotation": (packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT,
		"flip_h": (packed & TILE_FLIP_H_BIT) != 0,
		"flip_v": (packed & TILE_FLIP_V_BIT) != 0,
		"wall_align": (packed & TILE_WALL_ALIGN_MASK) >> TILE_WALL_ALIGN_SHIFT,
	}


static func get_tile_index(packed: int) -> int:
	return packed & TILE_INDEX_MASK


static func get_rotation(packed: int) -> int:
	return (packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT


static func get_flip_h(packed: int) -> bool:
	return (packed & TILE_FLIP_H_BIT) != 0


static func get_flip_v(packed: int) -> bool:
	return (packed & TILE_FLIP_V_BIT) != 0


static func get_wall_align(packed: int) -> int:
	return (packed & TILE_WALL_ALIGN_MASK) >> TILE_WALL_ALIGN_SHIFT


static func has_diagonal_flip(packed: int) -> bool:
	return (packed & DIAGONAL_FLIP_BIT) != 0


static func set_diagonal_flip(packed: int, flip: bool) -> int:
	if flip:
		return packed | DIAGONAL_FLIP_BIT
	else:
		return packed & ~DIAGONAL_FLIP_BIT
