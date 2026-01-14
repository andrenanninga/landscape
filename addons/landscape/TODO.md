# Landscape Editor - TODO

## Next Steps (Priority Order)

### High Priority
1. **Paint tool** - Apply texture index per cell, shader needs to support multiple textures
2. **Floor editing** - Tools to raise/lower floor surfaces
3. **Brush size** - Allow affecting multiple cells at once

### Medium Priority
4. **Keyboard shortcuts** - Quick tool switching (1-6 keys)
5. **Grid overlay** - Show grid lines in editor for better visualization
6. **Multi-cell selection** - Select and edit multiple cells at once

### Low Priority
7. **Custom node icon** - Create SVG icon for LandscapeTerrain in scene tree
8. **Import/export** - Save/load terrain data to file
9. **Copy/paste regions** - Select and duplicate terrain sections
10. **Smoothing tool** - Average heights between cells
11. **Flatten tool** - Set region to specific height

## Recently Completed
- [x] **Pixel art shader** - Flat shading, nearest filtering, checkerboard with 6 direction colors
- [x] **Drag-based sculpting** - Click and drag to raise/lower (replaced click tools)
- [x] **Smart corner detection** - Auto-detect cell vs corner mode based on cursor position
- [x] **Camera-aware height** - Height follows mouse with perspective correction
- [x] **Slope constraint propagation** - Adjacent corners pulled when slope limit reached
- [x] **Edge-only slope validation** - Diagonal slopes now allowed (max 2 with slope=1)
- [x] **Selection highlight** - Shader-based cell and corner highlighting
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
