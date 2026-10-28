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
- The top-bar album cover is bilinear-downsampled to its backing-pixel size
  before display for a crisper 45pt thumbnail.
- Optional menu-bar **disc** icon with compact track-change and Stared-playlist
  popups. The icon is off by default; star popups default on, track-change
  popups default off, and popups can be limited to when the Library window is
  not focused. Popup duration is configurable and defaults to 1500 ms.
- Shortcuts are split into In-App and System-wide tables. Add an action with
  **+**, remove it with **−**, and click its Key field to record a combination.
  Defaults: in-app mute `m`, volume down `-`, volume up `=`, play/pause Space,
  and go to current album `j`; system-wide show/hide Tracks `F17` and
  add/remove the current song from Stared playlist `F18`. Command-1/2 reopen the
  main window when every window is closed.
- Library and MiniPlayer are separate windows and are never shown together.
  Opening MiniPlayer hides Library; closing MiniPlayer restores Library. The
  MiniPlayer has no separate return-to-Library button.
- Album detail keeps the underlying grid mounted, so returning restores the
  previous scroll position instead of recentering an already-visible album.
  Opening an album from another view via **Go to Album** instead brings that
  album row to the top when the detail closes.
- The active sidebar view, focused item, and viewport anchor in Albums, Recently
  Added, Songs/playlists, Artists, and Genres are remembered across launches.
  Returning to a view therefore keeps an already-visible focus item in place
  instead of pulling it to the top.
- Internal Library (writable) and External Libraries (read-only), with an
  organizer for imports and tag editing. Quick Scan adds new files; Full Scan
  refreshes changed metadata and presents missing tracks for per-song review
  instead of silently deleting them. External libraries can be disabled and
  later restored; deleting their Tracks index creates a timestamped database
  backup and never removes their audio files.
- Output menu offers plain System Default, System Default with Volume Control,
  and all real Core Audio devices. The volume-control option locks player
  attenuation and routes volume to the macOS output.
- Window movement is native AppKit dragging. There is no custom collision
  barrier, manual position tracking, or magnetic snapping layer.
- Built-in MPD server for browsing and controlling the library over TCP.

## Build and run

```bash
# Build and launch the app bundle
./scripts/build.sh
open build/Tracks.app
```

`scripts/build.sh [debug|release]` builds with SwiftPM, passes the current macOS
SDK version to the linker (needed for the current AppKit window design),
assembles `build/Tracks.app`, copies the icon, writes `Info.plist`, and ad-hoc
signs the bundle. The complete signature is required by macOS
MediaRemote/Now Playing; a linker-only signature is not accepted. A bare
`swift build` is useful for compiler checks but does not produce the properly
configured app bundle.

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
  KeyboardShortcut.swift Shortcut recorder and persistence
  SystemWideShortcuts.swift Carbon system-wide hot keys
  TrayController.swift   Menu-bar disc icon and popups
  LibraryFocusSink.swift Keeps search from auto-focusing on window show

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
