# Tracks app icon

One version, using the same optical-disc glyph as the app's idle Library LCD
(`opticaldisc.fill`): white disc on a black gradient macOS squircle.

## Files

- `app-icon.svg` — 1024 × 1024, transparent background
- `app-icon.png` — 1024 px export
- `preview.png` — 1024 px on a neutral backdrop
- `preview.html` — 512/128/64/32/16 px on light and dark surfaces

## Specs

- Canvas: 1024 × 1024, transparent background
- macOS squircle: 824 × 824 at (100, 100), corner radius 186
- Glyph: `opticaldisc.fill`, rendered at 1024 and embedded at 640 px (flat raster)
- Plate: black gradient (`#3E3E45 → #1A1A1E → #050506`), vector
- Glyph centre: (512, 512)
- Flat glyph; soft plate drop shadow

## Note

The glyph is Apple's SF Symbol shape. If the icon ships publicly, confirm the
SF Symbols licence for app-icon use (or redraw this silhouette as a custom
vector glyph). The plate and its shadow are vector; the glyph is an embedded 1024 px render.

## Re-render

```bash
rsvg-convert -w 1024 design/app-icon.svg -o /tmp/tracks-icon.png
```
