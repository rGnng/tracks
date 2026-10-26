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

## Features

- Native album grid/list, artist and genre browsers, and sortable song tables.
- Stored playlists and the virtual **Stared** playlist. Double-click sidebar
  entries to play them in the current table/view order.
- Playlist tables include **Add Seq** and **Add Time**. Add Seq is shown by
  default after Genre; Add Time is hidden by default. Both can be toggled from
  the table header menu. Add time is stored as a UNIX timestamp and displayed
  in the system date/time format.
- The playback queue, current track, and playback position persist in SQLite.
  On the next launch the queue is restored paused at the saved position; it is
  not played automatically.
- Now Playing integration publishes the current title, artist, album, elapsed
  time, queue position, and album artwork to macOS. Hardware media keys and
  Control Center transport controls are handled through MediaPlayer.
- Album details preserve the exact grid/list scroll position when returning,
  avoiding a forced recenter when the album is already visible.
- Custom long-press drag threshold is 100 ms for item drags.

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

`scripts/build.sh` also ad-hoc signs the app bundle. A fully sealed bundle is
required for macOS MediaRemote/Now Playing to recognize the app and deliver
media-key commands.

Requires Xcode 16+ / Swift 6 on macOS 15+.
