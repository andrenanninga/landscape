# Landscape Editor Plugin

Technical reference for the `addons/landscape` plugin (Godot 4.5+). For a user-facing feature guide see the repository `README.md`.

## Overview

`LandscapeTerrain` is a `MeshInstance3D` that renders a grid of cells described by a `TerrainData` resource. Every cell has four top corner heights, four floor corner heights, a tile per face, optional fences on its edges and per-corner vertex colors. Heights are stored as integer steps and multiplied by `height_step` at build time.

The whole terrain is one `ArrayMesh`, rebuilt from scratch whenever `TerrainData` emits `data_changed`. Trimesh collision is kept in sync on an unowned child body. The mesh, material and collision body are derived data: they are rebuilt on load and excluded from the saved scene.

## File Structure

```
addons/landscape/
├── plugin.cfg
├── plugin.gd                       # EditorPlugin: registers the node, routes viewport input, hosts the overlay UI
├── resources/
│   ├── terrain_data.gd             # TerrainData resource: all cell data + geometry helpers
│   ├── terrain_tile_set.gd         # TerrainTileSet resource: wraps a Godot TileSet for atlas texturing
│   └── tile_packing.gd             # Bit layout of a packed tile
├── nodes/
│   ├── landscape.gd                # LandscapeTerrain node: mesh, collision, material, tile data texture
│   └── terrain_preview.gd          # Tile overrides shown while painting
├── mesh/
│   └── terrain_mesh_builder.gd     # SurfaceTool mesh generation
├── editor/
│   ├── terrain_editor.gd           # Tool coordination, hover/raycast, shared drag state
│   ├── sculpt_handler.gd           # Sculpt tool
│   ├── flatten_handler.gd          # Flatten tool
│   ├── mountain_handler.gd         # Mountain tool
│   ├── paint_handler.gd            # Paint tool (tiles, preview, eyedropper)
│   ├── color_handler.gd            # Vertex color tool
│   ├── fence_handler.gd            # Fence tool
│   ├── terrain_overlay.gd          # Viewport overlay drawing
│   ├── terrain_overlay_ui.gd/.tscn # Toolbar, paint panel and color panel in the 3D viewport
│   ├── tile_palette.gd             # Pan/zoom tile palette control
│   └── terrain_inspector_plugin.gd # Grid size properties with undo and directional resize buttons
├── shaders/
│   ├── terrain.gdshader            # Fallback: flat two-tone checkerboard per face type
│   └── terrain_tiled.gdshader      # Atlas tile rendering driven by the tile data texture
└── icons/
```

## Data Model

### Cell layout

`TerrainData.cells` is a `PackedInt32Array` with `CELL_DATA_SIZE` (29) ints per cell, row-major (`(z * grid_width + x) * 29`):

| Offset | Content |
|---|---|
| 0-3 | Top corner heights in steps: NW, NE, SE, SW |
| 4-7 | Floor corner heights in steps |
| 8-12 | Packed tiles for TOP, NORTH, EAST, SOUTH, WEST |
| 13-16 | Packed fence heights per edge N, E, S, W (bits 0-15 left corner, 16-31 right corner) |
| 17-20 | Packed fence tiles per edge |
| 21-24 | Top vertex colors (RGBA32) |
| 25-28 | Floor vertex colors (RGBA32) |

Invariants maintained by the tools: heights are never negative, the floor never exceeds the top, and edge-adjacent top corners differ by at most `max_slope_steps`.

### Packed tile (`TilePacking`)

| Bits | Content |
|---|---|
| 0-15 | Tile index; `0xFFFF` marks an erased (invisible) face |
| 16-17 | Rotation, clockwise quarter turns |
| 18 | Flip horizontal |
| 19 | Flip vertical |
| 20-21 | Wall alignment (`WallAlign`: WORLD, TOP, BOTTOM, STRETCH) on wall and fence tiles |

Bit 20 of the TOP tile stores the cell's diagonal flip instead; top faces have no wall alignment. `TerrainData.set_tile_packed` strips alignment bits from top tiles and preserves the diagonal flag, and `get_tile_packed` never reports alignment for a top tile.

### Edges and corners

Edges are indexed N=0, E=1, S=2, W=3. Each edge has a left and right corner as seen from outside the cell (`TerrainData.EDGE_CORNERS`), with the neighbouring cell's coinciding corners in `NEIGHBOR_EDGE_CORNERS`. `fence_neighbor()` and `opposite_edge()` map an edge to the cell and edge on the other side.

### Fences

A fence stands on the higher of the two cells that share its edge (`get_fence_base_heights`) and extends upward by its left and right heights. A physical edge holds one fence: setting a fence clears any fence the neighbour had on the shared edge, including its tile.

## Change Notification

Every setter compares before writing and emits `data_changed` only on a real change. `begin_batch()` / `end_batch()` collapse many edits into a single emission; all tools use it for multi-cell operations.

## Mesh Generation (`TerrainMeshBuilder`)

- Top face: two triangles, split along the diagonal with the smaller height difference unless the cell's diagonal flip is set.
- Floor face: drawn only when any floor corner differs from its top corner, with reversed winding.
- Walls: per edge, from this cell's top down to `max(own floor, neighbour top)`; outer edges go down to the floor. Degenerate walls are skipped.
- Fences: double-sided quads.

Each vertex carries the surface type in `COLOR.a` (0 top, 1-4 walls N/E/S/W, 5 floor, 6-9 fences, divided by 9) and the vertex tint in `COLOR.rgb`. Wall and fence vertices carry the wall's top and bottom Y in `UV2` so the shader can align tiles per vertex on sloped walls.

## Rendering

### Tile data texture

`LandscapeTerrain` encodes tile info into an RGBA8 texture with 9 pixels per cell (TOP, N, E, S, W, fence N, E, S, W) and one row per grid row:

| Channel | Content |
|---|---|
| R, G | Atlas tile coordinates |
| B | Flags: bits 0-1 rotation, 2 flip_h, 3 flip_v, 4-5 wall alignment |
| A | Atlas index; `(255, 255, *, 255)` marks an erased face |

Paint previews are written over this texture without touching `TerrainData`. The texture is refreshed on every data change; the material and the `Texture2DArray` of atlas images are only rebuilt when the tile set changes.

### terrain_tiled.gdshader

Samples the atlas array layer for the surface's tile. UVs come from the local position: XZ for top and floor, the edge axis and Y for walls. Wall alignment selects the vertical origin (world Y, wall top, wall bottom, or stretched over the wall height). Erased faces are discarded; alpha uses a 0.5 scissor threshold. The floor always shows tile (0, 0) of atlas 0.

Limits: at most 8 atlases (`LandscapeTerrain.MAX_ATLASES`), atlas coordinates up to 254. Atlas layers must share one size, so smaller atlases are upscaled with nearest filtering.

### terrain.gdshader

Used when no tile set is assigned. Unshaded two-tone checkerboard whose colors depend on the surface type; fences use the colors of the wall facing the same way.

## Editor

`plugin.gd` registers the node type, forwards 3D viewport input to `TerrainEditor`, draws the overlay and attaches the toolbar UI to the viewport. `TerrainEditor` raycasts against the terrain's own collision body (moved to a dedicated collision layer for the query so overlapping terrains never interfere), tracks the hovered cell, corner and surface, and dispatches to the tool handlers. Each handler applies edits directly to `TerrainData` during a drag and records one `EditorUndoRedoManager` action on release, committed without re-executing.

Tools: Sculpt, Paint, Color, Flip Diagonal, Flatten, Mountain, Fence. Brush size (1-9) applies to all of them; even sizes anchor on the nearest corner.

`TerrainTileSet` cannot listen to its own `TileSet.changed` (a `RefCounted` script has no usable `self` during teardown, and `TileSet` emits `changed` from its destructor), so `LandscapeTerrain` watches the inner `TileSet` and calls `TerrainTileSet.refresh()`.

## Key API

### TerrainData
- `grid_width`, `grid_depth`, `cell_size`, `height_step`, `max_slope_steps`, `cells`
- `get_top_corners` / `set_top_corners`, `get_floor_corners` / `set_floor_corners`, `clamp_floor_to_top`
- `get_tile_packed` / `set_tile_packed` (any `Surface`, including fences), `pack_tile` / `unpack_tile`
- `get_diagonal_flip` / `set_diagonal_flip`
- `get_fence_heights` / `set_fence_heights`, `has_fence`, `clear_fence`, `get_fence_tile_packed` / `set_fence_tile_packed`
- `get_top_vertex_color` / `set_top_vertex_color` and floor equivalents
- `get_top_world_corners`, `get_floor_world_corners`, `get_surface_world_corners`, `get_fence_world_corners`
- `resize_with_offset`, `restore_grid_state`, `begin_batch` / `end_batch`

### LandscapeTerrain
- `terrain_data`, `tile_set`, `auto_rebuild`
- `rebuild_mesh()`, `get_collision_body()`
- `world_to_cell()`, `world_to_corner()`
- `set_tile_previews()`, `clear_preview()`
- `terrain_changed` signal

### TerrainTileSet
- `tileset`, `roughness`, `metallic`
- `get_tile_count()`, `get_tile_uv_rect()`, `get_tile_location()`
- `get_atlas_count()`, `get_atlas_info()`, `get_atlas_for_tile()`, `get_local_tile_index()`, `get_global_tile_index()`
- `refresh()`
