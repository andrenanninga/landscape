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
- **Smart corner detection** - automatically detects cell vs corner mode based on cursor position
- **Paint tool** - paint tiles on any surface (top, north, south, east, west) with rotation/flip
- **Flip diagonal tool** - toggle triangle diagonal direction for saddle-shaped terrain
- **Flatten tool** - set all corners to a target height (click corner to use its height)
- **Adjustable brush size** - 1x1 to 9x9 brush for all terrain tools
- **Visual feedback** - overlay-based selection highlight and sidebar status display

## Architecture

### Data Model

Each cell stores **8 corner heights** (4 for top, 4 for floor) plus **5 surface tiles**:
- Corners: NW, NE, SE, SW (clockwise from top-left when viewed from above)
- Heights stored as integer steps, converted to world units via `height_step` multiplier
- Floor must always be at or below top
- Surfaces: TOP, NORTH, EAST, SOUTH, WEST - each with tile index, rotation (0-3), flip_h, flip_v

```
Cell[x,z]:
  top_corners   = [NW, NE, SE, SW]   # Top surface heights
  floor_corners = [NW, NE, SE, SW]   # Floor surface heights
  surfaces[5]:                        # Per-surface tile data
    tile_index  = int (0-255)        # Index into tile atlas
    rotation    = int (0-3)          # 0°, 90°, 180°, 270° clockwise
    flip_h      = bool               # Horizontal flip
    flip_v      = bool               # Vertical flip
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
│   ├── terrain_dock.gd             # UI panel script
│   └── terrain_dock.tscn           # UI panel scene
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
- Tools: SCULPT, PAINT, FLIP_DIAGONAL, FLATTEN
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
- **Surface detection** - Automatic top/wall detection from face normals
- **Selection highlight** - Visual feedback for hovered cell (top faces)

## Usage

1. Enable plugin: Project > Project Settings > Plugins > Enable "Landscape"
2. Add a `LandscapeTerrain` node to your scene
3. Select the node to see the editor dock
4. Use the **Sculpt** tool:
   - Click and drag **near center** to raise/lower entire cell
   - Click and drag **near a corner** to adjust individual corners (creates slopes)
   - Drag **up** to raise, drag **down** to lower
   - Height follows mouse position with camera perspective awareness
   - Adjacent corners are automatically pulled when slope limit is reached
   - Right-click to cancel drag and restore original heights
5. Use the **Paint** tool:
   - Click "Generate Placeholder Tiles" to create a test tileset
   - Select a tile from the palette
   - Click any surface (top, north, south, east, west) to paint
   - Use rotation buttons (↺ ↻) to rotate the tile
   - Use flip buttons (⇆ ⇅) to flip horizontally/vertically
   - Status bar shows which surface is being hovered
6. Use the **Flip** tool:
   - Click a cell to toggle its diagonal triangulation
   - Useful for saddle-shaped cells where opposite corners are at different heights
   - Orange line shows current diagonal direction
7. Use the **Flatten** tool:
   - Click **near a corner** to flatten cells to that corner's height
   - Click **at cell center** to flatten to the average height
   - Magenta highlight shows affected area, white dot shows selected corner
8. Adjust **Brush Size**:
   - Use the slider below the tool buttons (1-9)
   - Affects Sculpt, Paint, and Flip tools
   - Larger brushes edit multiple cells at once
9. View cell info in the sidebar dock (updates on hover and drag)

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
- [x] Tile rotation (0°/90°/180°/270°) and flip (H/V)
- [x] Overlay-based selection highlight (cell and corner modes)
- [x] Sidebar status display (cell, corner, height, surface)
- [x] Tile palette UI with large buttons for pixel art
- [x] Placeholder tile generator for testing
- [x] Undo/redo support
- [x] Collision generation
- [x] Terrain parameters exposed directly on LandscapeTerrain node
- [x] Brush size (1x1 to 9x9) for all tools
- [x] Flip diagonal tool for controlling cell triangulation
- [x] Flatten tool for setting cell heights to a target corner

### Not Yet Implemented
- [ ] Floor editing tools
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
