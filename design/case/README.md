# Tracks app icon

Jewel-case concept for Tracks: an unlabeled CD in a jewel case. The case itself
fills the macOS squircle, so the disc can be large; the hinged spine sits on the
left and the disc's centre hole is exactly on the icon's centre.

## Files

- `app-icon-light.svg` — light variant, case fills the squircle
- `app-icon-dark.svg` — dark variant, case fills the squircle
- `app-icon-light-inset.svg` / `app-icon-dark-inset.svg` — earlier floating-case
  alternative (smaller disc)
- `preview.html` — open in a browser: main variants, 16–128 px sizes, alternative
- `preview-compare.png` — floating case vs full-bleed case
- `preview-both.png`, `preview-light.png`, `preview-dark.png` — flat previews
- `preview-light-inset.png`, `preview-dark-inset.png` — inset previews

## Specs

- Canvas: 1024 × 1024, transparent background
- macOS squircle: 824 × 824 at (100, 100), corner radius 186
- Case = squircle; tray 684 × 684; disc 668 diameter
- Disc / hub hole centre: (512, 512)
- Hinge: 64 px recessed left channel + 12 px groove + two hinge pins
- Tray clips at the top and bottom
- Neumorphic lighting from the top-left; raised case, inset tray

## Re-render

```bash
rsvg-convert -w 1024 design/app-icon-light.svg -o /tmp/icon-light.png
rsvg-convert -w 1024 design/app-icon-dark.svg  -o /tmp/icon-dark.png
```
