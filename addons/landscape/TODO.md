# Landscape Editor - TODO

## Next Steps (Priority Order)

### High Priority
1. **Custom tile atlas import** - Load user-provided tile atlases

### Medium Priority
4. **Keyboard shortcuts** - Quick tool switching (1-6 keys)
5. **Grid overlay** - Show grid lines in editor for better visualization
6. **Multi-cell selection** - Select and edit multiple cells at once
7. **Paint fill tool** - Fill connected surfaces with same tile

### Low Priority
8. **Custom node icon** - Create SVG icon for LandscapeTerrain in scene tree
9. **Import/export** - Save/load terrain data to file
10. **Copy/paste regions** - Select and duplicate terrain sections
11. **Smoothing tool** - Average heights between cells

## Recently Completed
- [x] **Viewport overlay UI** - Moved editor controls from dock to 3D viewport overlay in bottom-right corner. Icon-based tool buttons, resizable paint panel with drag handle, native Godot editor icons for transform controls.
- [x] **Floor sculpting** - Edit floor surfaces with improved constraints: floor can match top (flat surfaces), lowering top pushes floor down, minimum height of 0. Cell mode floor editing when viewing from below.
- [x] **Fence tool** - Create vertical fences extending upward from tile edges with independent corner heights, double-sided geometry, editable from either side
- [x] **Wall tile alignment modes** - Per-tile setting controlling vertical positioning on walls (World/Top/Bottom), follows sloped edges
- [x] **Paint eyedropper** - Right-click on a painted cell to pick its tile, rotation, and flip settings
- [x] **Random paint mode** - Toggle "Rnd" button to paint tiles with random rotation and flipping (deterministic per cell)
- [x] **Surface lock** - Hold Shift while painting to lock to one surface type (only paints matching surfaces)
- [x] **Animated tile support** - Tiles with animation data (frame count, columns, speed) animate automatically using TIME uniform
- [x] **Mountain tool** - Create hills/valleys with smooth sloped edges that respect max_slope_steps
- [x] **Flatten tool drag support** - Click and drag to flatten terrain along brush path
- [x] **Batched terrain updates** - TerrainData.begin_batch/end_batch for efficient large brush operations
- [x] **Performance optimization** - All tools now batch updates to emit data_changed only once per operation
- [x] **Shader-based paint preview** - Tile preview renders through shader for correct wall texture repeating (replaces stretched overlay preview)
- [x] **Paint tool keyboard shortcuts** - Tiled-style shortcuts: X (flip H), Y (flip V), Z (rotate CW), Shift+Z (rotate CCW)
- [x] **TileMapLayer-style tile palette** - Pan/zoom canvas with fixed tile positions, trackpad support (two-finger pan, pinch zoom, Ctrl+scroll zoom)
- [x] **Flatten tool** - Set cells to a target height (click near corner for its height, center for average)
- [x] **Flip diagonal tool** - Toggle the diagonal triangulation of cells (useful for saddle-shaped terrain)
- [x] **Brush size** - Slider to adjust brush size (1x1 to 9x9, including even sizes), affects sculpt and paint tools
- [x] **Paint tool** - Click any surface to paint tiles (top, north, south, east, west)
- [x] **Tile atlas system** - TerrainTileSet resource with atlas texture support
- [x] **Tile transformations** - Rotation (0°/90°/180°/270°) and flip (H/V)
- [x] **Tiled shader** - PBR shader with per-surface tile data texture
- [x] **Surface detection** - Raycast normal determines hovered surface
- [x] **Overlay highlighting** - Replaced shader-based selection with overlay polygons
- [x] **Tile palette UI** - Pan/zoom canvas like TileMapLayer editor
- [x] **Placeholder tiles** - Generate colored test tileset
- [x] **Status bar surface display** - Shows hovered surface name in paint mode
- [x] **Pixel art shader** - Flat shading, nearest filtering, checkerboard with 6 direction colors
- [x] **Drag-based sculpting** - Click and drag to raise/lower (replaced click tools)
- [x] **Smart corner detection** - Auto-detect cell vs corner mode based on cursor position
- [x] **Camera-aware height** - Height follows mouse with perspective correction
- [x] **Slope constraint propagation** - Adjacent corners pulled when slope limit reached
- [x] **Edge-only slope validation** - Diagonal slopes now allowed (max 2 with slope=1)
- [x] **Sidebar status** - Show cell, corner, and height in dock (replaces overlay toast)
- [x] **Tool-gated hover** - Outline and hover only active when tool selected
- [x] **Exposed parameters** - Terrain settings directly on LandscapeTerrain node

## Future Considerations

### Performance (for large terrains)
- Chunked mesh generation (only rebuild affected chunks)
- LOD system for distant cells
- Deferred/batched rebuilding

### Advanced Features
- Water plane integration
- Texture blending between cells
- Vertex colors for additional variation
- Path/road tool that follows terrain

## Session Notes

### 2024-XX-XX - Initial Implementation
- Created core plugin structure
- Implemented TerrainData with top + floor corners per cell
- Built mesh generator with walls between cells
- Added editor dock with raise/lower/slope/floor tools
- Created auto-texturing shader (green top, brown walls, gray floor)
- Fixed wall winding order (were inside-out)

### 2025-01-XX - Pixel Art Shader & Drag Sculpting
- Rewrote shader for pixel art aesthetics:
  - Added `render_mode unshaded` for flat shading
  - Added `filter_nearest` for pixelated textures
  - Implemented checkerboard pattern with 6 direction colors (blue, yellow, red, green, orange, purple)
  - Fixed color bleeding by computing face normals from screen-space derivatives (`dFdx`/`dFdy`)
  - Added shader-based selection highlight for cells and corners (top faces only)
- Replaced raise/lower tools with unified Sculpt tool:
  - Smart corner detection: cursor near corner = corner mode, cursor at center = cell mode
  - Drag-based UX: click and drag to adjust height
  - Camera-aware height calculation using screen-space scaling
  - Constraint propagation: dragging a corner pulls adjacent corners when slope limit is reached
  - Fixed slope validation to only check edge-adjacent corners (allows diagonal slopes of 2 with max_slope=1)
  - Moved height display from overlay toast to sidebar dock
  - Sidebar shows: cell coordinates, corner (NW/NE/SE/SW/All), height
  - Height shown on hover and during drag
  - Disabled outline and hover when no tool is active
- Exposed terrain parameters directly on LandscapeTerrain node
- Reduced default height_step from 0.5 to 0.25
- Reduced default max_slope_steps from 2 to 1

### 2025-01-14 - Paint Tool & Tile System
- Implemented complete paint tool for all surfaces:
  - Surface detection from raycast hit normal
  - Position adjustment for wall boundaries (walls sit on cell edges)
  - Per-surface tile data: tile index, rotation (0-3), flip_h, flip_v
  - Undo/redo support for paint operations
- Created TerrainTileSet resource:
  - Atlas texture with configurable columns/rows
  - UV rect calculation for tile lookup
  - Placeholder tile generator (4x4 colored tiles)
- Created terrain_tiled.gdshader:
  - Per-surface tile sampling from data texture
  - Tile transformations (rotation, flip)
  - Surface detection from face normals (using dFdx/dFdy cross product)
  - Fixed inverted normals (cross product gives camera-facing normal)
  - PBR rendering with roughness/metallic
- Replaced shader-based selection with overlay highlighting:
  - draw_colored_polygon for surface faces
  - draw_line for cell/corner borders
  - Works for all surfaces (top + walls)
- Updated dock UI:
  - Tile palette with zoomable seamless tiles
  - Rotation/flip controls
  - Surface selector dropdown
  - Status bar moved to bottom showing surface name

### 2025-01-14 - Brush Size & Flip Diagonal Tool
- Implemented adjustable brush size (1-9):
  - Slider in dock UI below tool buttons
  - Supports both odd (centered) and even (offset) sizes
  - Affects Sculpt, Paint, and Flip Diagonal tools
  - Single undo action for multi-cell operations
  - Overlay highlights all cells in brush area
- Implemented Flip Diagonal tool:
  - New "Flip" button in toolbar
  - Toggles triangle diagonal direction per cell
  - Stored as bit flag in tile data (bit 12 of top tile)
  - Mesh builder respects flip flag when triangulating
  - Orange overlay shows current diagonal direction
  - Useful for saddle-shaped terrain where auto-selection isn't ideal
- Fixed overlay polygon drawing:
  - Draw quads as two triangles to avoid triangulation errors at extreme camera angles
- Implemented Flatten tool:
  - New "Flatten" button in toolbar
  - Click near corner to use that corner's height as target
  - Click at cell center to use average height of all corners
  - Magenta highlight shows affected area
  - White dot indicates which corner is being used for target height
  - Respects brush size for multi-cell operations

### 2025-01-16 - TileMapLayer-style Tile Palette
- Redesigned tile palette to match Godot's TileMapLayer editor:
  - New TilePalette custom Control with _draw() rendering
  - Tiles at fixed grid positions (no reflow)
  - Pan: two-finger scroll, right-click drag, scroll wheel
  - Zoom: pinch gesture, Ctrl/Cmd+scroll, +/- buttons
  - Zoom centered on cursor position
  - Selection highlight with fill and outline
  - Efficient tile culling for large tilesets

### 2025-01-16 - Paint Tool Improvements
- Added Tiled-style keyboard shortcuts for paint tool:
  - X: Flip horizontal
  - Y: Flip vertical
  - Z: Rotate clockwise
  - Shift+Z: Rotate counter-clockwise
- Implemented shader-based paint preview:
  - Added preview uniforms to terrain_tiled.gdshader
  - Preview renders through same shader as final result
  - Correctly shows repeating texture on tall walls (was stretching with overlay)
  - Preview updates when changing tile, rotation, or flip settings

### 2025-01-18 - Mountain Tool & Performance
- Implemented Mountain tool:
  - Creates hills (drag up) or valleys (drag down) with smooth slopes
  - Uses BFS to propagate slope heights outward from brush core
  - Respects max_slope_steps for natural-looking terrain
  - Precomputes corner distances at drag start for performance
- Added flatten tool drag support:
  - Click sets target height, drag to flatten all cells under brush path
  - Single undo action for entire drag operation
  - Right-click to cancel and revert changes
- Performance optimization with batched updates:
  - Added TerrainData.begin_batch() / end_batch() methods
  - data_changed signal only emits once at end of batch
  - All tools (sculpt, flatten, mountain, flip diagonal) now use batching
  - Dramatic performance improvement for large brush sizes (8x8, 9x9)

### 2025-01-20 - Wall Tile Alignment Modes
- Implemented per-tile wall alignment setting:
  - Three modes: World (seamless tiling), Top (anchored at top edge), Bottom (anchored at bottom edge)
  - Stored in packed tile data (bits 20-21)
  - Alignment follows sloped wall edges using per-vertex UV2 interpolation
  - Eyedropper picks alignment mode along with other tile properties
  - UI dropdown in paint section for selecting alignment mode

### 2025-01-20 - Paint Tool Enhancements
- Implemented paint eyedropper:
  - Right-click on a painted cell to pick its tile
  - Picks tile index, rotation, and flip settings
  - Click-only detection (moving mouse cancels pick to allow camera movement)
- Implemented random paint mode:
  - "Rnd" toggle button in transform controls
  - Each cell gets deterministic random rotation (0-3) and flip (H/V)
  - Uses cell position as seed for consistent preview
- Implemented surface lock:
  - Hold Shift to lock painting to one surface type
  - First surface hovered while holding Shift becomes the locked surface
  - Preview and outline hidden when hovering non-matching surfaces
  - Works for both hover preview and drag painting

### 2025-01-21 - Fence Tool
- Implemented complete fence feature:
  - New FENCE tool in terrain editor
  - Fences extend **upward** from tile edges (unlike walls which go downward)
  - Each fence has 2 independent corner heights (left and right)
  - Click on edge to create fence with default height (1 step)
  - Drag corners to adjust height independently, drag middle for both together
  - Shift+click to delete fence
  - Double-sided geometry (visible from both sides)
- Data structure changes:
  - Extended CELL_DATA_SIZE from 13 to 21 integers per cell
  - Added fence height packing (bits 0-15 left, bits 16-31 right)
  - Added fence tile data (same format as wall tiles)
  - Surface enum extended with FENCE_NORTH, FENCE_EAST, FENCE_SOUTH, FENCE_WEST
- Mesh generation:
  - New _add_fences() and _add_fence_quad() methods
  - Surface color encoding expanded from 5 to 9 types
  - Fence base uses MAX height of both neighboring cells
- Shader updates:
  - Handle 10 surface types (0-9 instead of 0-5)
  - Fence surfaces mapped to tile data indices 5-8
- Editor improvements:
  - Fences editable from either side of the edge
  - Each physical edge can only have one fence (auto-clears conflicting neighbor fence)
  - Paint tool extended to support fence surfaces
  - Full undo/redo support for fence create, modify, and delete

### 2025-01-23 - Viewport Overlay UI
- Moved editor controls from right dock to 3D viewport overlay:
  - Toolbar anchored to bottom-right of viewport
  - Icon-based tool buttons (56x56 with large icons)
  - Brush size slider below tool icons
  - Semi-transparent dark background with rounded corners
- Paint panel improvements:
  - Flyout panel appears above toolbar when Paint tool selected
  - Resizable via drag handle at top (100-800px height)
  - Transform controls with native Godot editor icons (RotateRight, MirrorX, MirrorY, RandomNumberGenerator)
  - Wall alignment as cycling button with icons (ControlAlignFullRect, ControlAlignTopWide, ControlAlignBottomWide)
  - Removed status labels and redundant controls for cleaner UI
- Plugin changes:
  - Uses `_forward_3d_draw_over_viewport` callback to attach overlay to viewport
  - Overlay visibility controlled by terrain selection state

### 2025-01-22 - Floor Sculpting
- Improved floor editing constraints:
  - Floor can now match top height (creates flat surface without walls)
  - Changed constraint from `floor < top` to `floor <= top`
  - Minimum height of 0 for both top and floor corners
  - Lowering top below floor automatically pushes floor down
- Floor detection improvements:
  - Removed minimum height requirement check in `_should_edit_floor`
  - Cell mode floor editing enabled when viewing from below (camera below floor height)
  - Full cell editing (not just corners) when looking from underneath
- Undo/redo updates:
  - Always store original floor corners at drag start (for top editing that may push floor)
  - Track floor corner changes when editing top corners
  - Proper restoration of both top and floor on cancel
