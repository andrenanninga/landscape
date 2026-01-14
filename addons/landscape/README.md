# Landscape Editor Plugin for Godot 4.5

A grid-based terrain editor plugin for Godot 4.5 with discrete height steps, similar to classic simulation games. Designed for pixel art aesthetics with flat shading.

## Features

- **Grid-based terrain** with configurable cell size
- **Discrete height steps** - terrain moves in fixed increments
- **Per-cell independent geometry** - cells don't share vertices, allowing walls between adjacent cells
- **Top + Floor surfaces** - each cell has both a top surface and a floor surface with independent corner heights
- **Slope support** - individual corners can be raised/lowered within slope constraints (edge-adjacent only)
- **Pixel art shader** - flat shading with checkerboard pattern, 6 distinct direction colors
- **Drag-based sculpting** - click and drag to raise/lower terrain with camera-aware height tracking
- **Smart corner detection** - automatically detects cell vs corner mode based on cursor position
- **Visual feedback** - shader-based selection highlight and sidebar status display

## Architecture

### Data Model

Each cell stores **8 corner heights** (4 for top, 4 for floor) plus a texture index:
- Corners: NW, NE, SE, SW (clockwise from top-left when viewed from above)
- Heights stored as integer steps, converted to world units via `height_step` multiplier
- Floor must always be at or below top

```
Cell[x,z]:
  top_corners   = [NW, NE, SE, SW]   # Top surface heights
  floor_corners = [NW, NE, SE, SW]   # Floor surface heights
  texture_index = int                 # For painting (future)
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
│   └── terrain_texture_set.gd      # TerrainTextureSet Resource - texture config
│
├── nodes/
│   └── landscape.gd                # LandscapeTerrain node (MeshInstance3D)
│
├── editor/
│   ├── terrain_editor.gd           # Tool coordination, raycasting, input handling
│   ├── terrain_dock.gd             # UI panel script
│   └── terrain_dock.tscn           # UI panel scene
│
├── mesh/
│   └── terrain_mesh_builder.gd     # Procedural mesh generation with SurfaceTool
│
└── shaders/
    └── terrain.gdshader            # Auto-texturing shader (top/wall/floor colors)
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
- `raise_cell(x, z, delta)` - Raise/lower all top corners
- `is_valid_slope(corners)` - Check slope constraints (edge-adjacent only, allows diagonal slopes)

### LandscapeTerrain (Node)
Main terrain node extending MeshInstance3D:
- `terrain_data` - The TerrainData resource
- `texture_set` - Optional TerrainTextureSet for texturing
- `auto_rebuild` - Automatically rebuild mesh on data changes
- Exposes terrain parameters directly: `grid_width`, `grid_depth`, `cell_size`, `height_step`, `max_slope_steps`
- `rebuild_mesh()` - Regenerate the mesh
- `world_to_cell(pos)` - Convert world position to cell coordinates
- `world_to_corner(pos)` - Convert world position to nearest corner
- `set_selected_cell(cell, corner, corner_mode)` - Update shader selection highlight
- `clear_selection()` - Remove selection highlight

### TerrainMeshBuilder (RefCounted)
Generates ArrayMesh from TerrainData using SurfaceTool:
- `build_mesh(terrain_data)` - Returns complete ArrayMesh

### TerrainEditor (RefCounted)
Editor tool coordination:
- Tools: SCULPT, PAINT
- **Drag-based sculpting**: Click and drag to raise/lower terrain
- **Smart corner detection**: Automatically switches between cell mode (center) and corner mode (near corners)
- **Camera-aware**: Height follows mouse position accounting for camera perspective
- **Constraint propagation**: Dragging a corner pulls adjacent corners when slope limit is reached
- Hover and outline only active when a tool is selected
- Handles viewport raycasting and input
- Integrates with EditorUndoRedoManager for undo/redo

## Shader

The terrain shader (`terrain.gdshader`) provides pixel art aesthetics with flat shading:

### Visual Style
- **Unshaded rendering** - No lighting, pure flat colors
- **Nearest filtering** - Pixelated texture look
- **Checkerboard pattern** - Two-tone pattern per face direction
- **Face normals via derivatives** - True flat shading using `dFdx`/`dFdy`

### Direction Colors (Checkerboard)
- **Up (top faces)**: Blue (`0.2, 0.6, 0.9`) / Dark blue (`0.1, 0.4, 0.7`)
- **Down (floor)**: Yellow (`0.9, 0.8, 0.2`) / Dark yellow (`0.7, 0.6, 0.1`)
- **North (-Z)**: Red (`0.9, 0.2, 0.2`) / Dark red (`0.7, 0.1, 0.1`)
- **South (+Z)**: Green (`0.2, 0.8, 0.3`) / Dark green (`0.1, 0.6, 0.2`)
- **East (+X)**: Orange (`0.95, 0.5, 0.1`) / Dark orange (`0.75, 0.35, 0.05`)
- **West (-X)**: Purple (`0.6, 0.3, 0.8`) / Dark purple (`0.45, 0.2, 0.6`)

### Selection Highlight
- Shader-based cell and corner highlighting on top faces only
- Cell mode: Border highlight around entire cell
- Corner mode: Chevron highlight pointing to selected corner

Supports optional texture assignment for top and side surfaces with triplanar mapping.

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
5. View cell info and height in the sidebar dock (updates on hover and drag)

## Current Status

### Implemented
- [x] Core data structure with top + floor corners
- [x] Mesh generation (top, floor, walls)
- [x] Editor plugin with dock UI
- [x] Drag-based sculpting with smart corner detection
- [x] Camera-aware height tracking
- [x] Slope constraint propagation (edge-adjacent only)
- [x] Pixel art shader with flat shading and checkerboard pattern
- [x] 6 distinct direction colors
- [x] Shader-based selection highlight (cell and corner modes)
- [x] Sidebar status display (cell, corner, height)
- [x] Undo/redo support
- [x] Collision generation
- [x] Terrain parameters exposed directly on LandscapeTerrain node

### Not Yet Implemented
- [ ] Paint tool (texture per cell)
- [ ] Floor editing tools
- [ ] Brush size options
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
