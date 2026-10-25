# Tracks

A native macOS music player whose interface closely follows iTunes 12.7–12.13.

- **Product name:** Tracks
- **Internal / module / executable name:** Audia
- **UI:** 100% native (SwiftUI + AppKit), light appearance, no web views.

## Layout

- **Top bar:** transport controls + volume + AirPlay device picker (left), now-playing status with seek bar (center), search field (right).
- **Sidebar:** `LIBRARY` (Recently Added, Albums, Artists, Songs, Genres) and `PLAYLISTS`.
- **Content pane:** album grid, artist grid, genre list, or song table depending on the sidebar selection.
- **Status bar:** track/album count summary.

## Run

Quick iteration (runs the bare executable, app name shows as “Audia”):

```bash
swift run
```

Build a double-clickable `Tracks.app`:

```bash
./scripts/build.sh
open build/Tracks.app
```

Requires Xcode 16+ / Swift 6 on macOS 15+.
