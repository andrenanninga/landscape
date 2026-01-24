# Landscape Editor Plugin for Godot 4.5

A grid-based terrain editor plugin for Godot 4.5 with discrete height steps, similar to classic simulation games. Designed for pixel art aesthetics with flat shading.

## Features

- **Grid-based terrain** with configurable cell size
- **Discrete height steps** - terrain moves in fixed increments
- **Per-cell independent geometry** - cells don't share vertices, allowing walls between adjacent cells
- **Top + Floor surfaces** - each cell has both a top surface and a floor surface with independent corner heights
- **Slope support** - individual corners can be raised/lowered within slope constraints (edge-adjacent only)
- **Pixel art shader** - flat shading with tiled textures, supports atlas-based tile painting
- **Drag-based sculpting** - click and drag to raise/lower terrain with camera-aware height tracking
- **Floor sculpting** - edit floor surfaces by clicking below midpoint or viewing from below
- **Smart corner detection** - automatically detects cell vs corner mode based on cursor position
- **Paint tool** - paint tiles on any surface (top, north, south, east, west) with rotation/flip
- **Erase tool** - make faces invisible while keeping the mesh geometry
- **Vertex color tool** - paint vertex colors on terrain corners with optional light mode (distance-based falloff with blend modes)
- **Transparent tile support** - tiles with alpha transparency render correctly
- **Flip diagonal tool** - toggle triangle diagonal direction for saddle-shaped terrain
- **Flatten tool** - drag to flatten terrain to a target height
- **Mountain tool** - create hills and valleys with smooth sloped edges
- **Fence tool** - create vertical fences that extend upward from tile edges with independent corner heights
- **Adjustable brush size** - 1x1 to 9x9 brush for all terrain tools
- **Batched updates** - efficient mesh rebuilding for large brush operations
- **Visual feedback** - overlay-based selection highlight
- **Viewport overlay UI** - compact toolbar in 3D viewport with icon-based tool buttons, resizable paint panel

## Architecture

### Data Model

Each cell stores **8 corner heights** (4 for top, 4 for floor) plus **9 surface tiles** (5 walls + 4 fences):
- Corners: NW, NE, SE, SW (clockwise from top-left when viewed from above)
- Heights stored as integer steps, converted to world units via `height_step` multiplier
- Floor must always be at or below top (can be equal for flat surfaces without walls)
- Surfaces: TOP, NORTH, EAST, SOUTH, WEST - each with tile index, rotation (0-3), flip_h, flip_v
- Fences: Per-edge heights and tiles for FENCE_NORTH, FENCE_EAST, FENCE_SOUTH, FENCE_WEST

```
Cell[x,z]:
  top_corners   = [NW, NE, SE, SW]   # Top surface heights
  floor_corners = [NW, NE, SE, SW]   # Floor surface heights
  surfaces[5]:                        # Per-surface tile data (TOP, N, E, S, W)
    tile_index  = int (0-65535)      # Index into tile atlas
    rotation    = int (0-3)          # 0°, 90°, 180°, 270° clockwise
    flip_h      = bool               # Horizontal flip
    flip_v      = bool               # Vertical flip
    wall_align  = int (0-2)          # Wall alignment: 0=World, 1=Top, 2=Bottom
  fence_heights[4]:                   # Per-edge fence heights (N, E, S, W)
    left_height  = int (0-65535)     # Left corner height in steps
    right_height = int (0-65535)     # Right corner height in steps
  fence_tiles[4]:                     # Per-edge fence tile data (same format as surfaces)
```

### Mesh Generation

- **Top face**: 2 triangles with smart diagonal selection to avoid twisted quads on slopes
- **Floor face**: 2 triangles rendered from below (reversed winding)
- **Walls**: Generated where adjacent cells have different top heights
- **Outer walls**: Terrain edges have walls from top down to floor

### Wall Generation Logic

For each cell edge:
1. Check if neighbor exists at that edge
2. If neighbor exists: generate wall from our top down to `max(our_floor, neighbor_top)`
3. If no neighbor (outer edge): generate wall from top to floor

### Fence Generation Logic

- Fences extend **upward** from tile edges (unlike walls which extend downward)
- Each fence has 2 independent top corner heights that can be manipulated separately
- Fence base uses the **maximum** height of both neighboring cells at each corner
- Double-sided geometry (visible from both sides)
- Each physical edge can only have one fence (creating a fence clears any conflicting neighbor fence)
- Fences are editable from either side of the edge

## File Structure

```
addons/landscape/
├── plugin.cfg                      # Plugin metadata
├── plugin.gd                       # EditorPlugin entry point
├── README.md                       # This file
│
├── resources/
│   ├── terrain_data.gd             # TerrainData Resource - stores all cell data
│   ├── terrain_tile_set.gd         # TerrainTileSet Resource - tile atlas config
│   └── placeholder_tiles.gd        # Generates placeholder colored tiles
│
├── nodes/
│   └── landscape.gd                # LandscapeTerrain node (MeshInstance3D)
│
├── editor/
│   ├── terrain_editor.gd           # Tool coordination, raycasting, input handling
│   ├── terrain_inspector_plugin.gd # Inspector plugin for undo/redo
│   ├── terrain_overlay_ui.gd       # Viewport overlay UI script
│   ├── terrain_overlay_ui.tscn     # Viewport overlay UI scene
│   └── tile_palette.gd             # Tile palette canvas with pan/zoom
│
├── mesh/
│   └── terrain_mesh_builder.gd     # Procedural mesh generation with SurfaceTool
│
└── shaders/
    ├── terrain.gdshader            # Auto-texturing shader (checkerboard colors)
    └── terrain_tiled.gdshader      # Tiled texture shader with atlas support
```

## Key Classes

### TerrainData (Resource)
Stores all terrain state:
- `grid_width`, `grid_depth` - Grid dimensions
- `cell_size` - World units per cell (default: 1.0)
- `height_step` - World units per height step (default: 0.25)
- `max_slope_steps` - Maximum height difference between edge-adjacent corners (default: 1)
- `cells` - PackedInt32Array storing all cell data

Key methods:
- `get_top_corners(x, z)` / `set_top_corners(x, z, corners)`
- `get_floor_corners(x, z)` / `set_floor_corners(x, z, corners)`
- `get_top_world_corners(x, z)` - Returns Vector3 positions
- `get_surface_world_corners(x, z, surface)` - Returns 4 corners for any surface face
- `raise_cell(x, z, delta)` - Raise/lower all top corners
- `is_valid_slope(corners)` - Check slope constraints (edge-adjacent only, allows diagonal slopes)
- `get_surface_tile(x, z, surface)` / `set_surface_tile(x, z, surface, tile, rot, flip_h, flip_v)`
- `pack_tile_data()` - Returns tile data texture for shader

### LandscapeTerrain (Node)
Main terrain node extending MeshInstance3D:
- `terrain_data` - The TerrainData resource
- `tile_set` - Optional TerrainTileSet for tiled texturing
- `auto_rebuild` - Automatically rebuild mesh on data changes
- Exposes terrain parameters directly: `grid_width`, `grid_depth`, `cell_size`, `height_step`, `max_slope_steps`
- `rebuild_mesh()` - Regenerate the mesh
- `world_to_cell(pos)` - Convert world position to cell coordinates
- `world_to_corner(pos)` - Convert world position to nearest corner

### TerrainTileSet (Resource)
Defines tile atlas configuration:
- `atlas_texture` - The tile atlas image
- `atlas_columns` / `atlas_rows` - Grid dimensions of the atlas
- `get_tile_count()` - Total number of tiles
- `get_tile_uv_rect(index)` - UV coordinates for a tile

### TerrainMeshBuilder (RefCounted)
Generates ArrayMesh from TerrainData using SurfaceTool:
- `build_mesh(terrain_data)` - Returns complete ArrayMesh

### TerrainEditor (RefCounted)
Editor tool coordination:
- Tools: SCULPT, PAINT, FLIP_DIAGONAL, FLATTEN, MOUNTAIN, FENCE
- **Brush size**: Adjustable 1x1 to 9x9 (including even sizes), affects all tools
- **Drag-based sculpting**: Click and drag to raise/lower terrain
- **Smart corner detection**: Automatically switches between cell mode (center) and corner mode (near corners)
- **Camera-aware**: Height follows mouse position accounting for camera perspective
- **Constraint propagation**: Dragging a corner pulls adjacent corners when slope limit is reached
- **Surface painting**: Click any surface (top/north/south/east/west) to paint tiles
- **Surface detection**: Raycast normal determines which surface is being hovered
- Hover and overlay highlighting only active when a tool is selected
- Handles viewport raycasting and input
- Integrates with EditorUndoRedoManager for undo/redo

## Shaders

### terrain.gdshader (Checkerboard)
Basic shader with colored checkerboard pattern per face direction:
- **Unshaded rendering** - No lighting, pure flat colors
- **Nearest filtering** - Pixelated texture look
- **Checkerboard pattern** - Two-tone pattern per face direction
- **Face normals via derivatives** - True flat shading using `dFdx`/`dFdy`

Direction Colors:
- **Up**: Blue / **Down**: Yellow
- **North**: Red / **South**: Green
- **East**: Orange / **West**: Purple

### terrain_tiled.gdshader (Tiled Textures)
PBR shader with atlas-based tile texturing:
- **Per-surface tiles** - Each cell face can have different tile
- **Tile transformations** - Rotation (0°/90°/180°/270°) and flip (H/V)
- **Tile data texture** - GPU-side storage of per-cell tile info
- **Animated tiles** - Automatic animation using TileSet animation data (frame count, speed)
- **Surface detection** - Automatic top/wall detection from face normals
- **Paint preview** - Shader-based preview for accurate wall texture repeating
- **Selection highlight** - Visual feedback for hovered cell (top faces)

## Usage

1. Enable plugin: Project > Project Settings > Plugins > Enable "Landscape"
2. Add a `LandscapeTerrain` node to your scene
3. Select the node to see the toolbar overlay in the bottom-right of the 3D viewport
4. Use the **Sculpt** tool:
   - Click and drag **near center** to raise/lower entire cell
   - Click and drag **near a corner** to adjust individual corners (creates slopes)
   - Drag **up** to raise, drag **down** to lower
   - Height follows mouse position with camera perspective awareness
   - Adjacent corners are automatically pulled when slope limit is reached
   - Right-click to cancel drag and restore original heights
   - **Floor editing**: Click below the midpoint of a wall, or look from below to edit floor instead of top
   - Floor can be raised to match top (creates flat surface without walls)
   - Lowering top below floor will push floor down automatically
   - Heights cannot go below 0
5. Use the **Paint** tool:
   - Click "Generate Placeholder Tiles" to create a test tileset
   - Select a tile from the palette in the paint panel (appears when Paint tool is selected)
   - Click any surface (top, north, south, east, west) to paint
   - Use rotation button (↻) or keyboard shortcuts to transform tiles:
     - **Z**: Rotate clockwise
     - **X**: Flip horizontal
     - **Y**: Flip vertical
   - **Erase mode** (eraser icon): Toggle to make faces invisible instead of painting tiles
   - **Right-click** on a painted cell to pick its tile (eyedropper)
   - **Hold Shift** while painting to lock to one surface type (e.g., only paint north walls)
   - Enable **Random mode** (dice icon) to paint tiles with random rotation and flipping
   - Click **Wall alignment** button to cycle through modes:
     - **World** (full rect icon): Tiles align based on world Y position (seamless tiling)
     - **Top** (top align icon): Tiles anchored at wall top edge
     - **Bottom** (bottom align icon): Tiles anchored at wall bottom edge
   - Tile preview shows exactly how the painted result will look (including on walls)
   - Drag the triangle handle at top-left of the paint panel to resize in both directions
   - **Shift+click** the Paint tool button to reset panel size to default
6. Use the **Flip** tool:
   - Click a cell to toggle its diagonal triangulation
   - Useful for saddle-shaped cells where opposite corners are at different heights
   - Orange line shows current diagonal direction
7. Use the **Flatten** tool:
   - Click **near a corner** to set target height from that corner
   - Click **at cell center** to use the average height as target
   - Drag to flatten all cells under the brush path
   - Magenta highlight shows affected area
8. Use the **Mountain** tool:
   - Click and drag to create hills (drag up) or valleys (drag down)
   - Creates smooth sloped edges instead of sheer cliffs
   - Slopes respect the terrain's max_slope_steps setting
   - Ideal for creating natural-looking terrain features
9. Use the **Fence** tool:
   - Click on a tile **edge** to create a fence (default height: 1 step)
   - Drag fence **corners** to adjust that corner's height independently
   - Drag fence **middle** (between corners) to adjust both corners together
   - **Shift+click** to delete a fence
   - Fences extend upward from the edge, anchored at the highest neighboring cell
   - Fences can be edited from either side of the edge
   - Paint fences using the Paint tool (same as walls: rotation, flip, wall alignment)
10. Adjust **Brush Size**:
   - Use the slider below the tool icons (1-9)
   - Affects all terrain tools (Sculpt, Paint, Flip, Flatten, Mountain)
   - Larger brushes edit multiple cells at once

## Current Status

### Implemented
- [x] Core data structure with top + floor corners
- [x] Mesh generation (top, floor, walls)
- [x] Editor plugin with dock UI
- [x] Drag-based sculpting with smart corner detection
- [x] Camera-aware height tracking
- [x] Slope constraint propagation (edge-adjacent only)
- [x] Pixel art shader with flat shading and checkerboard pattern
- [x] Tiled texture shader with atlas support
- [x] Paint tool with per-surface tiles (top + 4 walls)
- [x] Tile rotation (0°/90°/180°/270°) and flip (H/V) with keyboard shortcuts (X, Y, Z)
- [x] Shader-based paint preview for accurate wall texture display
- [x] Overlay-based selection highlight (cell and corner modes)
- [x] Sidebar status display (cell, corner, height, surface)
- [x] Tile palette UI with pan/zoom canvas (like TileMapLayer editor)
- [x] Placeholder tile generator for testing
- [x] Undo/redo support
- [x] Collision generation
- [x] Terrain parameters exposed directly on LandscapeTerrain node
- [x] Brush size (1x1 to 9x9) for all tools
- [x] Flip diagonal tool for controlling cell triangulation
- [x] Flatten tool with drag support for setting cell heights
- [x] Mountain tool for creating hills/valleys with smooth slopes
- [x] Batched terrain updates for improved performance with large brushes
- [x] Animated tile support (uses TileSet animation properties)
- [x] Paint eyedropper (right-click to pick tile from painted cell)
- [x] Random paint mode (randomize rotation and flipping per tile)
- [x] Surface lock (hold Shift to paint only on one surface type)
- [x] Wall tile alignment modes (World/Top/Bottom) for controlling vertical tile positioning on walls
- [x] Fence tool - create vertical fences extending upward from tile edges with independent corner heights
- [x] Floor sculpting - edit floor surfaces with full constraint system (floor ≤ top, heights ≥ 0)
- [x] Viewport overlay UI - toolbar in 3D viewport with icon-based tools, resizable paint panel
- [x] Transparent tile support - tiles with alpha channel render correctly
- [x] Erase tool - make faces invisible while keeping mesh geometry
- [x] Vertex color tool - paint vertex colors on corners with brush support
- [x] Light mode for vertex colors - distance-based falloff with selectable blend modes (Screen, Additive, Overlay, Multiply)

### Not Yet Implemented
- [ ] Multi-cell selection
- [ ] Import/export terrain data
- [ ] LOD for large terrains
- [ ] Custom icons for node/tools

## Known Issues

- Raycasting requires collision to be generated (happens on mesh rebuild)

## Configuration

### LandscapeTerrain Properties (Inspector)
- **Grid Width/Depth**: Number of cells (default: 8x8)
- **Cell Size**: World units per cell (default: 1.0)
- **Height Step**: Height per step (default: 0.25)
- **Max Slope Steps**: Maximum edge-adjacent corner difference (default: 1)

### Shader Uniforms
- `color_up/down/north/south/east/west`: Primary direction colors
- `checker_color_*`: Secondary checkerboard colors
- `checker_scale`: Checkerboard pattern scale (default: 4.0)
- `slope_threshold`: Normal Y threshold for top vs wall (default: 0.7)
- `uv_scale`: Texture tiling scale
- `selection_color`: Highlight color for selected cells
- `selection_border_width`: Border thickness for selection
- `corner_highlight_size`: Size of corner highlight region
