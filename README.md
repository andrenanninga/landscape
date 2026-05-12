# Landscape — Godot Terrain Editor Plugin

A tile-based terrain editor for Godot 4 that lets you sculpt, paint, and detail grid-based 3D terrain directly inside the Godot editor.

---

## Overview

Landscape adds a `LandscapeTerrain` node to Godot that represents a grid of cells. Each cell has a top surface, optional floor surface, up to four wall surfaces (where adjacent cells differ in height), and optional fence structures. The entire terrain is a single mesh, with trimesh collision generated automatically.

When a `LandscapeTerrain` node is selected, an overlay toolbar appears in the bottom-right corner of the 3D viewport with all editing tools.

---

## Installation

1. Copy the `addons/landscape/` folder into your project.
2. Enable the plugin in **Project → Project Settings → Plugins → Landscape**.
3. Add a `LandscapeTerrain` node to your scene. The editor toolbar activates automatically when this node is selected.

---

## Node Properties

Configure the terrain in the Inspector after selecting a `LandscapeTerrain` node.

| Property | Description |
|---|---|
| `grid_width` | Number of cells along the X axis (1–256) |
| `grid_depth` | Number of cells along the Z axis (1–256) |
| `cell_size` | World units per cell (min 0.1) |
| `height_step` | World units per height increment (min 0.1) |
| `max_slope_steps` | Maximum height difference allowed between two adjacent corners |
| `terrain_data` | The `TerrainData` resource that stores all cell data |
| `tile_set` | Optional `TerrainTileSet` resource for PBR atlas texturing |
| `auto_rebuild` | Automatically rebuild the mesh whenever data changes |

### Resizing the Grid

Below the `grid_depth` property in the Inspector, four directional controls appear — **W**, **N**, **S**, **E** — each with a **−** (shrink) and **+** (grow) button. Resizing preserves all existing cell data and automatically repositions the terrain node so the existing terrain stays in place. All resize operations are undoable.

---

## Editing Tools

The overlay toolbar contains seven tools. Select a tool by clicking its icon button.

### Sculpt

Raise and lower terrain corners and cells by clicking and dragging in the viewport.

- **Cell mode** — click near the center of a cell to move all four of its corners together.
- **Corner mode** — click near a corner to adjust only that corner. Adjacent corners are pulled along if the slope limit would otherwise be exceeded.
- Drag **up** to raise, drag **down** to lower.
- Heights cannot go below zero.
- Right-click during a drag to cancel and revert all changes.

**Editing the floor surface**

Each cell has an independent floor. Click below the midpoint of a wall face, or view the terrain from beneath, to edit the floor instead of the top. The floor cannot exceed the top surface height, and lowering the top automatically pushes the floor down to match.

---

### Flatten

Level an area of terrain to a single target height.

1. Click a cell or corner to set the target height. Clicking near a corner uses that corner's height; clicking near the center uses the average of all four corners.
2. Drag across the terrain to flatten all cells under the brush path to the target height.
3. The affected area is highlighted in magenta during the drag.
4. Right-click to cancel.

The entire drag is recorded as a single undo action.

---

### Mountain

Create smooth hills and valleys by dragging.

- Drag **up** to raise a hill; drag **down** to carve a valley.
- The cells directly under the brush are moved by the full amount.
- Surrounding cells slope outward automatically, respecting `max_slope_steps`, to create a natural transition without abrupt cliffs.
- The core cells are highlighted in orange and the sloped transition area in brown during the drag.

---

### Paint

Paint tiles onto any surface of the terrain using a tile palette.

#### Tile Palette

The palette panel opens alongside the viewport. It is resizable — drag the handle in the top-left corner to adjust. Shift-click the Paint tool button to reset the panel to its default size.

- **Navigate** — two-finger scroll, right-click drag, or mouse scroll to pan; pinch or Ctrl/Cmd+scroll to zoom.
- **Select** — click any tile to make it active.
- **Eyedropper** — right-click any painted surface in the viewport to pick its tile, rotation, flip, and wall alignment settings.

#### Tile Transformations

| Control | Action |
|---|---|
| **Z** | Rotate 90° clockwise |
| **Shift+Z** | Rotate 90° counter-clockwise |
| **X** | Flip horizontally |
| **Y** | Flip vertically |
| Rotation label | Shows the current angle: 0°, 90°, 180°, or 270° |

#### Paint Modes

- **Normal** — paint the selected tile onto surfaces.
- **Erase** — make surfaces invisible rather than painting a tile.
- **Random** — apply deterministic random rotation and flipping per cell for natural variation.
- **All Faces** — paint the top and all four walls in a single stroke. Two slot buttons appear to let you assign different tiles to the top face (Top Slot) and the side walls (Side Slot).

#### Wall Alignment

Controls how tiles are anchored on wall surfaces when the wall height varies.

| Mode | Behaviour |
|---|---|
| **World** | Tiles align by world Y position; walls tile seamlessly regardless of height |
| **Top** | Tile anchored at the top edge of the wall |
| **Bottom** | Tile anchored at the bottom edge of the wall |
| **Stretch** | Tile stretched to fill the full wall height |

#### Surface Lock

Hold **Shift** and hover over a surface to lock painting to that surface type only (for example, top-only or north-wall-only). Release Shift to unlock.

#### Hover Preview

A real-time shader preview shows exactly how the tile will look before you click, including rotation, flip, and wall alignment. The preview updates instantly as you change any paint setting.

---

### Color

Paint vertex colors onto terrain corners for lighting effects, shadows, and decoration.

- **Color picker** — click the color swatch to choose a color with full alpha support.
- **Erase** — remove color, resetting corners to white.
- **Light mode** — paint with a radial falloff so the center of the brush receives full intensity and the edges fade off smoothly. Available blend modes:
  - **Screen** — soft lighting
  - **Additive** — bright glowing light
  - **Overlay** — contrast-preserving tint
  - **Multiply** — shadows and darkening

---

### Flip Diagonal

Toggle the triangulation direction of individual cell quads. Useful for saddle-shaped terrain where the default diagonal produces an undesirable shape. The current diagonal is shown as an orange line on the cell in the viewport overlay.

---

### Fence

Create thin vertical structures along cell edges.

- **Create** — click any cell edge to place a fence. The fence base height matches the taller of the two adjacent cell tops so it follows sloped terrain.
- **Edit height** — drag a fence corner handle to adjust that corner's height independently; drag the middle of the fence to move both corners together.
- **Delete** — Shift-click a fence edge to remove it.
- **Paint** — the Paint tool recognises fence surfaces (north, east, south, west fence faces), so tiles, rotation, flip, and wall alignment all apply to fences as well.

---

## Brush Size

A slider below the tool icons controls the brush size from **1×1** to **9×9** cells. Odd sizes center on the hovered cell; even sizes offset toward the nearest corner. Brush size applies to all tools except Flip Diagonal.

---

## Tile System

### TerrainTileSet Resource

Assign a `TerrainTileSet` to the `tile_set` property to enable atlas-based PBR texturing. The resource wraps one or more Godot `TileSet` sources and supports:

- Multiple atlases, each with independent tile dimensions.
- **Animated tiles** — frame count, column layout, and playback speed taken from the underlying `TileSet`.
- **PBR material settings** — `roughness` (default 0.8) and `metallic` (default 0.0).
- Transparent tiles with correct alpha blending.
- Nearest-neighbour filtering for a pixel-art look.

### Default Shader (no tile set)

Without a tile set, the terrain renders with a flat unshaded shader that uses direction-based colors and a checkerboard pattern:

- **Top** — dark soil brown
- **Walls** — shaded dirt tones that vary by facing direction (north, south, east, west)
- Vertex colors are applied as tinting on top of the base colors.

---

## Surfaces

Each cell exposes the following paintable and sculptable surfaces:

| Surface | Description |
|---|---|
| Top | The upper face of the cell |
| North / East / South / West wall | Side faces where adjacent cells differ in height |
| Floor | The underside face of the cell |
| Fence North / East / South / West | The faces of a fence structure on that edge |

---

## Undo / Redo

All editing operations — sculpting, painting, vertex colors, flipping diagonals, placing fences, and grid resizing — integrate with Godot's built-in undo/redo system. Multi-cell drag operations are recorded as a single undo step.

---

## Viewport Feedback

The 3D viewport overlay provides real-time visual feedback for every tool:

| Tool | Highlight colour |
|---|---|
| Sculpt (top) | Yellow / green |
| Sculpt (floor) | Cyan |
| Paint | Surface outline |
| Color | Brush area outline |
| Flip | Orange fill + diagonal line |
| Flatten | Magenta fill |
| Mountain (core) | Orange fill |
| Mountain (slope) | Brown fill |
| Fence | Edge and corner handles |

A status bar in the panel shows the current cell coordinates, active corner or surface name, and height in world units while editing.
