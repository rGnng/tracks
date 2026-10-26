# Tracks

Tracks is a native macOS music player with an iTunes 12-style interface. It is
built with SwiftUI and AppKit, plays through AVPlayer, stores its library in
SQLite, and includes a built-in MPD server.

- **Product name:** Tracks
- **Internal module / executable:** Audia
- **Bundle identifier:** `com.audia.tracks`
- **UI:** 100% native SwiftUI + AppKit
- **Minimum macOS:** 15
- **App icon:** `Resources/AppIcon.icns` (source: `design/app-icon.svg` / `design/app-icon.png`)

## Highlights

- Library sections: Recently Added, Albums, Artists, Songs, and Genres.
- Album grid and list views with sortable album order.
- Stored playlists plus the virtual **Stared** playlist.
- Playlist tables expose **Add Seq** and **Add Time** columns. Add Seq is shown
  after Genre by default; Add Time is hidden by default. Add time is stored as a
  UNIX timestamp and rendered with the system date/time format.
- Double-click sidebar playlist entries, Albums, or Recently Added to play them
  in the current content-view sort order.
- Playback queue, current track, and playback position persist in SQLite. The
  queue is restored paused after relaunch; pressing Play resumes at the saved
  position.
- macOS Now Playing integration publishes title, artist, album, elapsed time,
  queue position, and album artwork. Hardware media keys and Control Center
  transport controls are handled through MediaPlayer. Control Center shows
  previous/next track, not skip-by-15-second buttons.
- Album detail keeps the underlying grid mounted, so returning restores the
  previous scroll position instead of recentering an already-visible album.
- The active sidebar view and the top visible item in Albums, Recently Added,
  Songs/playlists, Artists, and Genres are remembered across launches.
- Internal Library (writable) and External Libraries (read-only), with an
  organizer for imports and tag editing.
- Built-in MPD server for browsing and controlling the library over TCP.

## Build and run

```bash
# Fast development build
swift build

# Build a double-clickable app bundle
./scripts/build.sh
open build/Tracks.app
```

`scripts/build.sh [debug|release]` builds with SwiftPM, assembles
`build/Tracks.app`, copies the icon, writes `Info.plist`, and ad-hoc signs the
bundle. The complete signature is required by macOS MediaRemote/Now Playing;
a linker-only signature is not accepted.

Requires Xcode 16+ and Swift 6 on macOS 15+.

## App icon

The icon source files live in `design/`. Regenerate the `.icns` from the
1024px source image with:

```bash
./scripts/make-icon.sh
```

This writes `Resources/AppIcon.icns`, which the build script and app bundle use.

## Project layout

```text
Sources/Audia/
  AudiaApp.swift         App entry, AppDelegate, menus, Settings
  ContentView.swift      Root layout and sidebar/content composition
  PlayerToolbar.swift    Transport, volume, search, now-playing panel
  SidebarView.swift      Library and playlist sidebar
  ContentPane.swift      Content routing and album sorting
  ContentViews.swift     Album grid/list/detail and song tables
  BrowserViews.swift     Artists and Genres browsers
  Models.swift           Song, Album, Playlist, artwork, navigation models
  Library.swift          Library state, scanning, playlists, deletion
  LibraryDatabase.swift  SQLite schema, library sync, queue persistence
  PlayerState.swift      AVPlayer engine, queue, history, shuffle/repeat
  SystemNowPlaying.swift Now Playing metadata/artwork and media commands
  MPDServer.swift        Built-in MPD TCP server
  ArtworkCache.swift     500x500 artwork disk cache
  MediaImporter.swift    Import into the Internal Library
  TagWriter.swift        Tag/artwork writeback
  FLACLibrary.swift      Metadata readers and scanner
  Theme.swift            Light/dark palette and dynamic colors
  DragController.swift   Long-press drag and marquee support
  KeyboardShortcut.swift Shortcut recorder and global handler

Assets/AccentColors.xcassets  Static Graphite accent for native menus
Resources/AppIcon.icns        Built app icon
design/                       Icon source and previews
scripts/build.sh              App bundle build and signing
scripts/make-icon.sh          Icon regeneration
```

## Data

The primary database is:

```text
~/Music/Tracks/library.sqlite
```

The fallback location, when no Internal Library exists, is:

```text
~/Library/Application Support/Tracks/library.sqlite
```

Artwork is cached as 500×500 JPEG files under:

```text
~/Library/Caches/com.audia.tracks/Artwork
```

Stored playlists use `playlist_items.added_at` for per-item addition times.
The active playback queue is stored in the singleton `player_queue` table.

## Media keys and Control Center

Tracks registers the standard MediaPlayer remote commands:

- Play, pause, and toggle play/pause
- Previous and next track
- Absolute playback-position changes

Now Playing metadata includes artwork loaded from the artwork cache. The app
must be launched from the signed app bundle produced by `scripts/build.sh` for
macOS to treat it as the Now Playing application.

## Development notes

- `agent.md` is the detailed handoff document for the next coding agent.
- Keep UI work native; avoid web views.
- Use temporary playlists and sample files for destructive testing.
- Do not clear user playlists, stars, history, queue, or play counts.
- The MPD implementation covers the commands used by Tracks and common MPD
  clients; it is not a complete MPD 0.24 implementation.
