# Tracks (internal target: Audia) - Agent Handoff

Last updated: 2026-10-26

This file is the handoff snapshot for a future coding agent. Read it before changing
the project, then verify the current code and running state.

## 1. Product and scope

- Native macOS music player with an iTunes 12-style interface.
- Product name: **Tracks**. Internal module, executable, and bundle identity: **Audia**
  (`com.audia.tracks`).
- SwiftUI plus targeted AppKit. No WebView. Light and dark appearance are supported.
- Real playback through `AVPlayer`, not a mock transport. The queue, history, play
  counts, stars, playlists, and library are backed by SQLite.
- Separate Library and MiniPlayer windows, with only one visible at a time.
- No cloud service, no account system, and no multiple-window document model.

## 2. Environment and build

- Project root: `/Users/n/Documents/ws/tracks`
- Git repository: branch `main`, remote `github-rgnng:rGnng/tracks.git`.
  Recent feature commits include sidebar playback order, playlist add-time
  columns, queue persistence, and native media integration.
- `Package.swift`: Swift tools 6.0, minimum platform macOS 15, links system SQLite3.
- Current machine snapshot: macOS 27.0.1, Apple Silicon, Xcode 27.0, Swift 6.4.

Build and run:

```bash
cd /Users/n/Documents/ws/tracks
swift build
bash scripts/build.sh          # release build into build/Tracks.app
open build/Tracks.app
```

`scripts/build.sh [debug|release]` builds with SPM, copies the executable to
`build/Tracks.app/Contents/MacOS/Audia`, copies `Resources/AppIcon.icns`, writes
`Info.plist` with `CFBundleName=Tracks` and `CFBundleIconFile=AppIcon`, and ad-hoc
signs the complete bundle. The code signature is required: MediaRemote/Now
Playing rejects a linker-only signature for remote media commands.

Regenerate the icon after changing `design/app-icon.png`:

```bash
./scripts/make-icon.sh
```

Primary database:

```bash
sqlite3 ~/Music/Tracks/library.sqlite \
  "select count(*) from songs; select count(*) from albums; select * from libraries;"
```

If no Internal Library exists, the fallback database path is
`~/Library/Application Support/Tracks/library.sqlite`.

## 3. Current runtime snapshot

- App is running from `/Users/n/Documents/ws/tracks/build/Tracks.app`.
- Main window frame at the time of this snapshot: about `1098 x 823`.
- Appearance: system/automatic; highlight color: Red; sidebar: playlist `337845818`;
  Add Time column hidden; playback queue empty. Output: plain `System Default`.
- MPD is enabled, listening on all interfaces, port `6600`, empty password.
- Current database: `~/Music/Tracks/library.sqlite` (WAL while the app is running).
- Database counts:
  - 20,669 songs
  - 2,143 albums
  - 5,481 artists
  - 2 stored playlists, 37 stored playlist items
  - 10 starred songs
  - 0 persisted queue rows (the test queue was cleared)
- Libraries table:
  - Internal: `/Users/n/Music/Tracks` (`Tracks`)
  - External: `/Volumes/New Volume/MusicLocal/Media.localized` (`Media.localized`)
- All 20,669 current songs are from the External Library. The Internal Library
  `Music/` folder is currently empty at the database level.
- The previous Internal Library audio files appear in the macOS Trash. This is
  consistent with the Delete feature having been used. Do **not** restore or rescan
  those files unless the user explicitly asks.
- Stored playlists:
  - `337845818`: 10 songs
  - `McStone`: 27 songs
- Artwork cache:
  - `~/Library/Caches/com.audia.tracks/Artwork`
  - 2,141 files, about 206 MB
- `artworkCacheJPEGQuality` is currently `0.75`. The default is `0.8`; the cache
  is only regenerated when the user clicks **Rebuild Cache**.
- `playlists.date_modified` exists and is used by MPD.
- `playlist_items.added_at` stores the per-playlist addition time as a UNIX
  timestamp (REAL seconds); Add Seq is derived from it. Existing rows were
  backfilled from `playlists.date_created + position`.
- `player_queue` is a singleton table (`id = 1`). `queue_entries` and
  `base_queue_entries` store JSON arrays of `{id, songID}` queue-entry records;
  `next_queue_id` persists the monotonic MPD-ID allocator. Older queue columns
  are not read or written.
- `PRAGMA user_version = 1` remains as an inert legacy value; no code reads it.
- Do not clear playback history, play counts, stars, playlists, or user window
  preferences while testing.

## 4. Source map

```text
Package.swift
README.md
agent.md
Assets/AccentColors.xcassets
Resources/AppIcon.icns
design/app-icon.svg
design/app-icon.png
design/README.md
scripts/build.sh
scripts/make-icon.sh
scripts/generate_library.swift
Sources/Audia/
  AudiaApp.swift             App entry, AppDelegate, menus, Settings window, setup window
  Theme.swift                Light/dark colors and layout constants
  Models.swift               Artwork, Song, Album, Playlist, MusicLibrary, sidebar models
  Library.swift              Library singleton, scanning, playlists, read-only rules, delete API
  LibraryDatabase.swift      SQLite schema, sync/prune, playlists, queue, song deletion
  LibraryOrganizer.swift     Canonical file names and tag-driven file relocation
  LibraryDeletion.swift      Delete confirmation UI and partial-failure alert
  FLACLibrary.swift          FLAC/AVFoundation metadata readers and LibraryScanner
  MediaImporter.swift        Import into Internal Library with organizer naming
  TagWriter.swift            Tag/artwork writeback for supported formats
  ArtworkCache.swift         500x500 JPEG disk cache, quality, size, rebuild
  MPDServer.swift            Custom MPD TCP server, queue/playlists/album art
  PlayerState.swift          AVPlayer engine, queue, history, shuffle/repeat
  SystemNowPlaying.swift     Now Playing metadata/artwork and media-key commands
  AudioDevices.swift         Core Audio output device enumeration and selection
  SystemVolume.swift         macOS output-volume get/set for system-volume outputs
  WindowMode.swift           Separate Library/MiniPlayer windows and metrics
  MiniPlayerView.swift       Compact player UI and Liquid Glass mini traffic lights
  Components.swift           WindowConfigurator, titlebar layout, native drag, shared controls
  ContentView.swift          Root layout, sidebar/player/content composition
  PlayerToolbar.swift        Top transport bar, seek, volume, output, search
  SidebarView.swift          Library and playlist sidebar
  ContentPane.swift          Content routing and album sort/view settings
  ContentViews.swift         Album grid/list, album detail, song table, Add Seq/Add Time, selection
  BrowserViews.swift         Artists/Genres master-detail browsers
  ContextMenus.swift         Shared album/song context menus
  KeyboardShortcut.swift     Standard AppKit shortcut recorder, matching, persistence
  SystemWideShortcuts.swift  Carbon system-wide hot keys for show/hide and current-song star
  TrayController.swift       Menu-bar icon/cover flip, inline track and star strip
  LibraryFocusSink.swift     Initial first responder for the Library window
  SettingsFocusSink.swift    Invisible initial first responder for Settings
  GetInfo.swift              Details/Artwork/File inspector and tag editing
  StatusBarView.swift        Bottom status bar and status context
  DragController.swift       Long-press drag, marquee, native file drag
  MarqueeSelection.swift     Reusable marquee selection modifier
  PlaylistActions.swift      Add-to-playlist submenu and New Playlist naming
  KeyboardNavigator.swift    Keyboard selection navigation
  NavigationCenter.swift     Cross-view navigation state
```

## 5. Library model and database

### Internal and External Libraries

- There is at most one Internal Library. It is writable and owns both:
  - `<root>/library.sqlite`
  - `<root>/Music/`
- External Libraries are read-only indexes of folders managed by other apps.
  Tracks never writes their audio files.
- External Libraries have a persisted enabled state. Disabling one hides its
  songs from all content views, stops playback, and clears the global queue and
  History. Song and playlist rows remain in SQLite for re-enable.
- Deleting an External Library is available only while disabled, requires a
  second destructive confirmation, creates a millisecond-timestamped SQLite
  Online Backup first, and deletes only Tracks index data.
- Read-only rules:
  - `Library.isReadOnly(song:)`: true unless the file is under the Internal
    Library's `Music/` directory.
  - `Library.isReadOnly(album:)`: true if any track in the album is read-only.
  - UI disables editing, and the update methods also guard against writes.
- Paths are canonicalized with `resolvingSymlinksInPath()` on both sides.
- Albums and artists are not isolated per library. If the same artist/album exists
  in Internal and External libraries, rows merge and album-level editing is
  read-only.

### Stable IDs

- Song ID: `stableUUID(path)` with no prefix. This preserves old playlist history.
- Artist ID: `stableUUID("artist|" + lowercased(name))`.
- Album ID: `stableUUID("album|" + artistID + "|" + lowercased(title))`.
- Library ID: `stableUUID("library|" + path)`.
- Playlist ID: random UUID.

Never recompute song IDs during normal open/move/rebase operations.

### Core schema

```sql
artists(id TEXT PK, name TEXT UNIQUE)
albums(id TEXT PK, title, artist_id, genre, year TEXT, artwork BLOB,
       UNIQUE(title, artist_id))
songs(id TEXT PK, path TEXT UNIQUE, library_id, title, artist_id, album_id,
      genre, year TEXT, track, track_total, disc, disc_total, comments,
      duration, date_added, play_count, rating, loved, last_played,
      skip_count, mtime, file_size)
libraries(id TEXT PK, path TEXT UNIQUE, kind TEXT, name TEXT, date_added,
          enabled INTEGER NOT NULL DEFAULT 1)
playlists(id TEXT PK, name TEXT, date_created REAL, date_modified REAL)
playlist_items(playlist_id, song_id, position,
               PRIMARY KEY(playlist_id, song_id))
```

Important schema decisions:

- Artwork BLOBs were removed from the database. Album rows keep metadata and the
  artwork cache key; the 500x500 JPEG lives on disk.
- `songs.loved` is the star flag and backs the built-in Stared playlist.
- `songs.library_id` identifies the owning source; `libraries.enabled` controls
  whether its songs appear in the normal library and playlists. Disabling does
  not delete or rewrite songs or playlist items.
- `createSchema()` defines the only supported schema. Old library databases
  missing current columns are not migrated.
- `playlists.date_modified` is maintained for MPD `Last-Modified`.
- `playlist_items` has a primary key on `(playlist_id, song_id)`, so a stored
  playlist cannot contain duplicate copies of the same song.
- `date_added` is first-discovery time:
  - Internal imports: import time.
  - External tracks: file modification time.
  - Existing rows preserve it across rescans and tag edits.
- Year/date values are stored as raw text in `songs.year` and `albums.year`
  (`TEXT NOT NULL DEFAULT ''`). Empty means unknown. Tags such as `2015` and
  `2015-05-01` are preserved. UI displays the text without thousands separators
  and omits it when empty. Sorting uses the first four digits only. Get Info
  shows an empty year field for unknown years; clearing a known year removes it
  from the database and the managed tag fields.
- `Album.addedAt` is `max(song.dateAdded)` and drives the Recently Added order.
  The order is computed by caching `addedAt` once per album before sorting;
  recomputing it inside the comparator made every playback-driven view update
  re-walk all songs.
- `LibraryCatalog` rebuilds when `Library.albums` changes and caches the
  flattened `allSongs` array plus song→album and ID lookups. Now Playing,
  MiniPlayer, Control Center, and the menu-bar card resolve artwork by song ID,
  not album title; duplicate album titles must never select the first matching
  album's cover.
- WAL is used while running. On normal termination, `closeForTermination()`
  checkpoints and switches the journal back to DELETE so `library.sqlite` is
  self-contained.

### Scanning and import

- Supported files: FLAC, MP3, M4A, WAV, AIFF, OGG/Opus.
- Startup Quick Scan and Settings Quick Scan share one policy: discover and import
  new paths only; do not reparse known paths or remove missing rows.
- Full Scan refreshes files when `mtime` or `file_size` changes. File contents are
  never hashed. Missing rows are reviewed per track in a searchable table; only
  explicitly selected rows are removed from the Tracks index. No review sheet is
  shown when there are no missing rows.
- Scan deletion candidates are available only if the root exists, is readable,
  and enumeration completed. A readable empty root still produces a missing-file
  report; no volume UUID/label is checked or stored.
- Relocate matches the full relative path beneath the old and new library roots,
  preserving song IDs and playlist/play-count/star metadata. Unmatched tracks use
  the same searchable missing-file review as Full Scan. If none are unmatched,
  relocation completes without a review sheet. During relocation, every
  unselected song path is rewritten under the new root even when that file is
  currently absent; explicitly selected unmatched rows and their playlist items
  are deleted. The review's left action is Cancel, and it offers Select All and
  Deselect All.
- `LibraryScanner` resolves symlinks and reads metadata concurrently.
- Internal imports use `LibraryOrganizer`:
  - Canonical path: `<Album Artist>/<Album>/[disc-]track.title-artist.ext`
  - Track digits: at least 2, expand automatically for 3+ digit track numbers.
  - Disc prefix only when present.
- Internal tag edits write tags back to the file, then relocate/rename it to the
  canonical path while preserving the song ID, stars, play counts, playlists,
  and `date_added`.
- Get Info supports Mixed values with italic placeholders; submitting empty mixed
  fields preserves the underlying value.
- Get Info Details fields use square AppKit-backed boxes. They remain selectable
  and copyable when read-only (for example for External Library tracks); the
  read-only state only disables editing, not text selection.

## 6. Playback, queue, and UI behavior

- `PlayerState` uses `AVPlayer`/`AVPlayerItem`, with real Core Audio output devices.
- Queue operations: append, insert, remove, move, shuffle, clear, play by position/
  song, history, auto-next on end.
- Up Next rows support drag-to-reorder; the currently playing track and the
  already-played queue prefix are not moved.
- Queue rows show the title, artist, album, duration, and a gray filled star for
  starred songs. The trailing star toggle is intentionally absent from the queue.
- Queue row context menus provide Play Next (move the song directly after the
  current track), Go to Album, Go to Artist (album artist, falling back to the
  track artist), and Delete from Queue.
- The main queue popover has no visible width/height resize handle. Invisible
  left/right edge drags adjust its width; a 10pt vertical splitter below the
  Clear row adjusts only list height. Width and list height persist under
  `queue.popoverWidth` and `queue.listHeight`.
- `baseQueueEntries` preserves normal order and entry IDs when shuffle is
  toggled off.
- The active queue, queue-entry IDs, `nextQueueID`, and playback position are
  persisted in `player_queue`. Structural queue changes save the full queue;
  position is checkpointed every five seconds and on pause/termination. On launch
  the queue and saved elapsed position are restored paused. Pressing Play resumes
  from that position instead of restarting the track. Empty/finished/cleared
  queues delete the row.
- Runtime missing-file markers are held in memory only. Confirmed missing tracks
  show a warning icon and are skipped; permission/decoder errors are not marked
  missing. One hundred consecutive missing tracks pauses playback with a warning.
- Playback History lives in UserDefaults (`player.historyIDs`), currently capped
  at 50. Disabling any External Library stops playback and clears the global queue
  and History; the UI uses the existing “History” label.
- `SystemNowPlaying` publishes title, artist, album, duration, elapsed time,
  queue count/index, and cached album artwork to `MPNowPlayingInfoCenter`, and
  registers play/pause/toggle, next/previous, and position handlers on
  `MPRemoteCommandCenter`. Control Center shows previous/next track controls
  (not 15-second skip buttons). Hardware media keys and Control Center
  transport controls use that path. macOS MediaRemote only accepts a fully
  sealed code-signed bundle; `scripts/build.sh` ad-hoc signs the app.
- Shuffle/random covers the unplayed queue: enabling it while stopped shuffles
  the whole queue, enabling it while playing keeps the current track and shuffles
  the remainder, and tracks appended while shuffle is active are randomized too.
- Repeat modes: Off, All, One; persisted in UserDefaults.
- Volume level is persisted in UserDefaults (`player.volume`) and restored at
  launch, including when playback starts later. Output selection is persisted
  under `audioOutputSelection` (`system-default`,
  `system-default-volume-control`, or a real device UID). Plain **System
  Default** uses app-controlled AVPlayer volume. **System Default with Volume
  Control** and every real output device lock the player at 100% and route the
  app volume controls to that macOS output. The prior player volume is saved in
  `player.volumeBeforeSystemControl` for restoration when returning to plain
  System Default.
- History is most-recent-first, persisted by song ID.
- Window modes:
  - Library: SwiftUI main window, minimum about `1040 x 640`.
  - MiniPlayer: a separate AppKit `NSWindow` hosting `MiniPlayerView`, resizable
    width `320...560`; the cover is a square at the top and grows with the
    window; middle `42`; bottom `30`. The queue panel has its own adjustable
    height (`140...500`, screen permitting). Height is `width + 72`
    (`+ queueHeight` while the queue is open). Window shortcuts are Command-1 /
    Command-2. Both call `WindowModeCenter.setMode()`, which also shows the
    target window; the windows are mutually exclusive: opening one orders the
    other out. Closing MiniPlayer (red light or Command-W via `performClose`)
    restores Library. The main window is retained strongly; `showWindow()`
    deminiaturizes, orders it front, activates the app, and gives it focus.
    MiniPlayer uses `.managed, .fullScreenNone` and never joins a full-screen
    Space. Switching to MiniPlayer from a full-screen Library first exits full
    screen and waits for `didExitFullScreen`; the MiniPlayer then appears on the
    normal desktop. Returning to Library shows the windowed Library, not
    full screen. The system-wide F17 shortcut toggles the currently active mode,
    but is ignored while the Library is full screen or entering/leaving it;
    the tray Hide Tracks item is disabled in the same state. MiniPlayer has no separate “return to Library”
    button; the close control is the return path.
  - `LibraryFocusSink` is the main window's initial first responder and is
    re-focused when `.libraryWindowDidShow` is posted by `showLibraryWindow`.
    This prevents SwiftUI from auto-focusing the search field after an explicit
    show without clearing the responder on a timer. Cmd-F still focuses search
    through `.focusSearch`.
  - Window movement is AppKit-native. There is no manual mouse/frame tracking,
    collision solver, or magnetic snapping layer. The Library toolbar has one
    full-width `WindowDragSurface` at the bottom of its ZStack; controls sit
    above it and therefore get hit-test priority, and unclaimed empty
    mouse-downs fall through to `NSWindow.performDrag(with:)`. The MiniPlayer
    cover uses the same native surface beneath its controls. It accepts first
    mouse so dragging works while Tracks is inactive. `isMovable` is false only
    so AppKit's full-size title bar cannot steal control drags. This is the
    SwiftUI analogue of Chromium/Helium's frame-view `mouseDown` fallthrough,
    not a per-gap overlay.
  - MiniPlayer uses two custom Liquid Glass-style traffic lights (close and
    minimize) inside the cover; they stay hidden until the pointer enters the
    window, matching the old compact-player behavior without adding a title-bar
    strip. The close light restores Library. The lights use symmetric 10pt
    top/left margins.
- Sidebar selection is persisted under `sidebarSelection` as a stable string:
  `library:<section>`, `starred`, or `playlist:<uuid>`. A missing, malformed,
  or deleted-playlist value falls back to **Recently Added**. The first launch
  and library switches also use Recently Added as the default view.
- The active scroll viewport is persisted as a single `lastViewportKey` /
  `lastViewportOffset` pair. Only the list currently on screen writes it;
  hidden views are not persisted. Within one app session, `ViewScrollStore`
  keeps in-memory offsets for visited views so switching back restores them;
  after relaunch only the last active view restores its offset, and other
  views start at the top. Do not mix item anchors with this offset.
- Cursor/selection is session-only (`ViewFocusStore`). Switching views in the
  same app session restores the selected items and focus, but quitting and
  relaunching starts with no selected album/song and only the saved scroll
  offset. Artists/Genres fall back to the first item when the session store is
  empty. There is no center-on-selection restore.
- Escape first clears the current list's selection (album grid/list, song
  table, album-detail tracks, artist/genre browser); if nothing is selected it
  clears the active search query. Neither action moves the viewport.
- In the search field, Return moves focus to the content and selects the first
  result when the query is non-empty; Escape clears the query and moves focus
  to the content. Focus returns to `LibraryFocusSinkView` so arrows/Home/End
  immediately operate on the list.
- Home/End/Page Up/Page Down are routed through `KeyboardNavigator` to the
  mounted SwiftUI list. The lists use `ScrollPosition` plus
  `onScrollGeometryChange`, not `ScrollViewReader`, so they always know the
  current content offset, viewport height, and content height. Home/End scroll
  to offset `0` / `maxOffset`, preserving the grid's 22pt and list's 6pt
  content padding at both ends (the last row keeps its album/artist text and
  the bottom gap). Page Up/Down move to the target visible row with the same
  top inset. Keyboard selection scrolls only enough to show the selected item
  completely plus the same padding; it does not center. An off-screen saved
  focus starts arrow navigation from the first item actually visible in the
  current viewport. Viewport persistence saves the exact scroll offset, not a
  top item. Album-grid item frames are computed from the uniform grid layout
  when the SwiftUI preference frames are unavailable after a long scroll jump.
- Opening an album detail from the current grid keeps the mounted grid's scroll
  offset unchanged, so returning leaves the clicked album where it was.
  `Go to Album` from another view scrolls the target album row to the first
  row; the resulting offset is persisted like any other scroll.
- Album cards/rows use single click for selection or album-detail navigation.
  Double-click no longer starts album playback; use the hover Play button or the
  context menu instead.
- Selection and drag:
  - Marquee selection works in Albums, Recently Added, Artists/Genres album panes,
    Songs, Playlists, and album detail.
  - Long-press threshold is `DragController.longPressDuration = 0.1` seconds.
  - Fast drag = marquee; after the long-press threshold, drag = item drag.
  - Dragging outside the window starts a native file drag:
    - Finder copies the files.
    - Text editors receive absolute paths.
  - Internal playlists can receive album/song drops.
- Context menus include Play, Shuffle, Add to Playlist, Play Next, Play Later,
  Get Info, and the conditional Delete item. Songs/Playlist row menus also have
  **Go to Album**, which switches to Albums and opens that song's album detail.
- Album detail keeps the underlying Albums/Recently Added grid mounted while
  the detail view is visible, so returning restores the exact previous scroll
  position and does not force-center an album that is already visible. Keyboard
  navigation in the hidden grid is disabled while detail is open.
- **Go to Album** clears the current search before switching views, then the
  album grid retries a pending `openAlbumID` when the unfiltered list arrives.
  This handles songs whose album title does not match the search query.
- The playback queue is an array of `QueueEntry` values. Each entry has a
  monotonic `UInt32` ID that is exposed as MPD's `Id` and is independent of
  `Song.id`; the same song can appear multiple times with different entry IDs.
  `queue` and `upNext` are read-only song projections for views that do not need
  entry identity. Queue UI, drag/drop, context menus, and MPD all use entry IDs;
  `currentIndex` remains the `Pos`-style position.
- Queue entry IDs and `nextQueueID` persist across relaunch in
  `player_queue`. Removing an entry never reuses its ID; adding the same song
  creates a new entry. Empty/finished/cleared queues delete the row.
- Bulk queue construction (`makeQueueEntries`) must build the occupied-ID set
  once and reuse it. Rebuilding `queueEntries` + `baseQueueEntries` IDs per
  allocation is O(n²); with a restored 20k-entry queue, full-library Play or
  Shuffle stalled for tens of seconds before this was fixed.
- Sidebar **Albums** and **Recently Added** have Play and Shuffle context menus.
  Albums uses the full library sorted by the current album sort; Recently Added
  uses the same order as its content view.
- Playlist song tables expose `Add Seq` and `Add Time` columns. Add Seq is
  visible by default immediately after Genre; Add Time is hidden by default.
  Add times are stored per playlist item, survive reorder/removal, and are
  assigned at addition time. Sorting by either column is supported and sidebar
  double-click playback follows the current table sort.
- Add-to-Playlist submenu starts with **New Playlist**, then a divider, then the
  existing playlist names. New names auto-increment: New Playlist, New Playlist 2,
  etc.
- Play Later appends to the bottom of the queue and sits below Play Next.
- Get Info has Details, Artwork, and File tabs, with tag/artwork writeback for the
  Internal Library.
- Settings > Shortcuts has separate In-App and System-wide tables. Use **+** to
  add an available action and **−** to remove the selected binding. In-App
  bindings are handled by the local key monitor; System-wide bindings use Carbon
  hot keys (`SystemWideShortcuts.swift`) and work in other apps without
  Accessibility permission. Defaults: in-app mute `m`, volume down `-`, volume
  up `=`, play/pause Space, and go to current album `j`; system-wide show/hide
  Tracks `F17` and add/remove the current song from Stared playlist `F18`. The
  star action always targets the current playing song, not row selection.
- Click a Key field to record a combination, press Escape to cancel, or Delete
  to clear it. Modifiers and shifted symbols are supported. The table prevents
  duplicate assignments across both scopes. **Display raw values** shows the
  stored key codes and modifier names instead of the display labels.
- Shortcuts are stored as one JSON array under `shortcut.bindings.v2`. Legacy
  per-action keys (`shortcut.*.v1`, scope and enabled flags) are ignored, not
  migrated. The local handler skips text editing and returns events untouched
  while a recorder is active. Command-[ posts `.goBackRequested`; matching also
  accepts keyCode 33 so the shortcut still works with non-US/IME keyboard input.
- `SidebarVisibilityStore` controls the Library sidebar. It persists windowed
  visibility under `sidebarVisible` (default true) and full-screen visibility
  under `sidebarFullScreenVisible` (default false) independently. It is toggled
  by **View > Hide/Show Sidebar**, Command-Shift-L, or the left toolbar button
  shown only in full screen. These menu/global keys are intentionally not in the
  editable shortcut table.
- The bottom status bar uses `showStatusBar` for windowed mode and
  `showStatusBarFullScreen` for full screen (default true). The View menu and
  Command-/ toggle the state for the current mode.
- While the Library window is the key window, unmodified `1`–`5` select Recently
  Added, Albums, Artists, Songs, and Genres; `8` selects Stared. They are ignored
  while editing text and for every other window.
- Command-F posts `.focusSearch` only when the Library window is key. It no
  longer switches from MiniPlayer/Settings/Get Info to the Library.
- The show/hide player shortcut now calls `NSApp.hide(nil)` when hiding and
  `NSApp.unhide(nil)` before showing, so focus returns to the previously active
  application. The tray card is part of the menu bar, so it does not unhide the
  Library window.
- The Window menu is pruned after launch and after menu additions. SwiftUI's
  scene entries for Tracks, Get Info, and Set Up Tracks Library are removed;
  only the explicit Library/MiniPlayer commands remain.
- System tray (menu bar) is off by default. `TrayController` starts as a
  24-point status item with `opticaldisc.fill`. On a song change or current-song
  star/unstar it flips the icon around its vertical axis to the album cover
  while expanding the item leftwards to 120 points; the cover stays left-aligned
  and the prepared title, artist/album, and star are revealed as the width grows.
  Text truncates with an ellipsis. After `tray.popupDurationMs` (default 1500 ms)
  the width shrinks back to the icon while the cover flips left back to the disc.
  All width, flip, and layout motion uses a circular ease-in-out curve.
- Track-change and star/unstar strips are enabled independently
  (`tray.trackChange`, `tray.starChange`); both default on. Existing installs are
  migrated once through `tray.infostripMigration`. The old
  `tray.onlyWhenLibraryNotFocused` gate is ignored. The status item keeps its
  normal menu click behavior because the SwiftUI host returns `nil` from
  `hitTest`.
- Album covers are prefetched when the current song changes, center-cropped,
  bilinearly downsampled to 64 px, and kept in a 32-entry in-memory
  `NSCache`. The flip waits for that image so it never shows a blank back side;
  if an album has no artwork, its generated color gradient is shown instead.

## 7. Artwork cache and Settings

- Artwork is stored only as 500x500 JPEG files in:
  `~/Library/Caches/com.audia.tracks/Artwork`
- Database artwork BLOBs are zero for library albums.
- `ArtworkCache` uses an in-memory cache plus disk cache. Scans write artwork
  directly into the cache. Rebuild Cache clears the disk cache and performs a
  forced rescan to regenerate it.
- The 45pt top-bar Now Playing cover is downsampled once to its backing-pixel
  size (45 × displayScale, normally 90×90) with a Core Graphics medium-quality
  bilinear draw before displaying, instead of relying on SwiftUI's live scaling.
- Settings shows the current cache size, calculated asynchronously from the
  files under the Artwork cache directory.
- The Internal Library header no longer shows a "Read & Write" label, and the
  External Libraries section no longer lists supported formats.
- JPEG quality control:
  - Plain SwiftUI `TextField`, digits only.
  - Accepted range 15-100, default 80.
  - Commits on Return or focus loss; clamps out-of-range values.
  - The old `NumericQualityField` AppKit wrapper was removed.
  - No `15-100%` hint and no `500x500 px` hint are shown. Size remains hardcoded.
- Settings focus:
  - Opening Settings must not focus the JPEG quality field and must not beep.
  - `SettingsFocusSink` is an invisible, non-editable view used as the initial
    first responder.
  - It refreshes on first open and on later reopens after the window was closed.
  - Do not reintroduce `makeFirstResponder(nil)` in Settings; that was the source
    of the system beep.
  - The quality text field remains clickable and editable. Tested values include
    75, 80, 5 (clamps to 15), and 200 (clamps to 100).
- Settings uses a normal numeric field and a `%` label; no Stepper.
- Appearance > Highlights is a normal label with the color circles to its right,
  matching the other Settings rows. It selects `highlightColor` (default
  `graphite`) and offers System/Multicolor, Blue, Purple, Pink, Red, Orange,
  Yellow, Green, Graphite. Scene roots apply `.accentColor` for native SwiftUI
  controls; custom views use `Theme.highlight`, which reads the saved choice
  directly so popovers and overlays do not depend on accent-environment
  propagation. Outlines, links, active buttons, row hover, and custom controls
  update live. Filled selections use `Theme.selectionFill`: the raw accent in
  light mode and only 5%-darkened in dark mode. The selected sidebar row uses a
  20% tint. `Theme.highlightForeground` switches selected-row text to black for
  bright choices. Queue/History and Get Info tabs use `AccentSegmentedControl`
  because AppKit's segmented picker ignores `.tint` and always uses the system accent.
- Right-click context menus are native SwiftUI `.contextMenu` again. The app
  declares one static `AccentColor` asset (Graphite) via `NSAccentColorName`, so
  native menus use a neutral graphite highlight that works beside any dynamic
  in-app highlight. `scripts/build.sh` compiles
  `Assets/AccentColors.xcassets` into `Assets.car`; this is build-time static and
  does not modify the signed bundle at runtime. Do not make `NSAccentColorName`
  follow the runtime setting: rewriting Info.plist/Assets.car invalidates code
  signing and was rejected.
- View > Appearance has Automatic/Light/Dark. `AppearanceController` applies the
  choice at the AppKit level (`NSApp.appearance` and every window's appearance).
  Automatic sets these to nil so live system appearance changes propagate to all
  windows. Do not regress to only `.preferredColorScheme(nil)`; it can leave a
  previously forced window appearance behind.
- Album display as and Albums sorted by use menu-style dropdowns. The sort choices
  are Album Name/Artist/Year, followed by a Sort direction dropdown
  (Ascending/Descending). Defaults are Album Name + Ascending. Direction applies
  to Albums and artist/genre browser album panes; Recently Added keeps its
  newest-first date order.

## 8. MPD server

The project includes a custom MPD-compatible TCP server in `MPDServer.swift`.

Current configuration:

- Enabled: yes
- All interfaces: yes (`0.0.0.0` and `::`)
- Port: `6600`
- Password: empty
- Protocol greeting: `OK MPD 0.24.0`

Do not disable or reconfigure MPD without an explicit user request. Remote clients
may be connected.

### System volume and MPD

The output-device menu is the single source of truth; there is no separate MPD
volume toggle in Settings.

- The menu contains `System Default`, `System Default with Volume Control`, then
  real Core Audio devices.
- Plain `System Default` uses `PlayerState.volume` (AVPlayer attenuation).
- `System Default with Volume Control` and real output devices lock the player
  at 100% and route MPD `setvol`/`volume` and the in-app slider to the macOS
  output volume through Core Audio.
- When system-volume mode is active, `setvol`/`volume` requests change the
  selected macOS output device. MPD's `volume` command is treated as a
  **relative** change even without a leading `+`; libmpdclient/ncmpcpp sends
  `volume 2` for `+2`. `setvol` is absolute with an optional leading sign. A
  literal `volume 0` is a mute request.
- While system mode is active the app's mute button and the MPD mute path both
  drive the system volume. Core Audio does not clear the device mute flag when
  the scalar volume is raised, so `SystemVolume` explicitly reads/writes
  `kAudioDevicePropertyMute` as well as the scalar volume. `AVPlayer.isMuted` is
  synchronized too.
- `status`, `getvol`, and the `volume` query report the live system volume while
  system mode is active. `setvol`/`volume` changes broadcast `changed: mixer`
  to idle clients.
- The remote system volume control does not use AVPlayer attenuation.

Supported areas:

- Status/current song/queue: `status`, `stats`, `currentsong`, `playlistinfo`,
  `playlistid`, `plchanges`, `plchangesposid`. In `status`, `song` and
  `nextsong` are positions, but `songid` and `nextsongid` are the stable
  `QueueEntry.id` values (never `position + 1`).
- Queue editing: `add`, `addid`, `clear`, `delete`, `deleteid`, `move`, `moveid`,
  `shuffle`, `play`, `playid`, `pause`, `stop`, `next`, `previous`, `seek`,
  `seekid`, `seekcur`, `getvol`, `setvol`, `volume` (including `+`/`-` relative
  values), `repeat`, `random`, `single`, `consume`, `toggle`, `outputs`,
  `enableoutput`, `disableoutput`, `toggleoutput`.
- Library queries: `listall`, `listallinfo`, `lsinfo`, `find`, `search`, `findadd`,
  `searchadd`, `list`, `count`, `update`, `rescan`. `listall` and `listallinfo`
  honor an optional directory URI. `lsinfo` on a directory returns full song
  metadata including `Track`/`Disc`; the root `lsinfo` remains file-only plus
  playlist entries to keep `mpc lsplaylists` fast.
- Audio outputs: `outputs` lists `System Default`, `System Default with Volume
  Control`, then the real output devices, with `outputid`, `outputname`,
  `plugin: coreaudio`, and `outputenabled`. `enableoutput`, `disableoutput`, and
  `toggleoutput` select the same output options exposed by the toolbar menu.
  Plain System Default uses app volume; the volume-control entry and real
  devices lock AVPlayer at 100% and control the macOS output volume.
- Album art: `albumart`, `readpicture`, `binarylimit`. Responses use the 500x500
  JPEG cache, correct size/type, and JPEG magic. The default chunk size is
  262144 bytes so a typical cover fits in one response; clients can still request
  a smaller `binarylimit`. A URI-to-album-ID cache avoids rescanning the whole
  library for every binary chunk.
- Idle: `idle`, `noidle`; queue changes broadcast `playlist`/`player`, stored
  playlist changes broadcast `stored_playlist`. Broadcasts are queued per
  session when that session is between `noidle` and its next `idle`; this is
  required for ncmpcpp/libmpdclient, which leaves idle before sending a volume
  command and only re-enters idle afterwards. Pending changes are delivered
  immediately on the next idle request.
- Stored playlists:
  - `listplaylists`
  - `listplaylist`
  - `listplaylistinfo`
  - `load` including `START:END`
  - `save` with modes `create`, `append`, `replace`
  - `rm`
  - `playlistadd` with optional position
  - `playlistdelete` with optional range
  - `playlistmove`
  - `playlistclear`
  - `rename`
- MPD `lsinfo ""` includes `playlist:` entries so `mpc lsplaylists` works.
- Song responses include both:
  - `added: <ISO8601>` from `Song.dateAdded` (MPD 0.24 field)
  - `Last-Modified: <ISO8601>` mirrored from `dateAdded` for older clients
  - Unknown `dateAdded` returns `added: -1`.
- `Track` and `Disc` are emitted as plain integers. Do not append `/total`:
  strict remote parsers treat the value as an integer and fail on values such as
  `1/12`. Track/disc totals remain available in the Tracks database but are not
  sent in the MPD tag itself.
- Playback state, elapsed time, duration, and queue data are derived from the live
  `PlayerState` on every request. There is no cached `isStopped` flag. Restarting
  the MPD server while audio is playing therefore keeps `state: play` and the
  correct progress instead of reporting a false stop.
- MPD repeat mapping:
  - `repeat 1` + `single 0` -> Repeat All.
  - `repeat 1` + `single 1` (or `single oneshot`) -> Repeat One.
  - `repeat 0` with `single 1` -> stopped-after-current mode; `single: 1` remains
    visible.
  - App UI Repeat One reports `repeat: 1`, `single: 1`; app UI Repeat All reports
    `repeat: 1`, `single: 0`.

### Built-in Stared playlist in MPD

- The virtual `Stared` playlist is listed alongside stored playlists.
- Its order is the current library order of starred tracks.
- `load Stared` works.
- `listplaylist Stared` and `listplaylistinfo Stared` work.
- `playlistadd Stared <uri>` stars the tracks.
- `playlistdelete Stared <position>` unstars them.
- `playlistclear Stared` unstars all of them.
- `rm Stared`, `rename Stared`, `save Stared`, and `playlistmove Stared` are
  rejected with an MPD permission ACK. This is intentional: Stared is virtual and
  its identity is fixed.
- If a user-created stored playlist is named Stared, MPD hides it in favor of the
  built-in one. The app sidebar still uses the Stared virtual row.
- A star change updates `starredPlaylistModified` and the MPD Last-Modified value.

### MPD limitations

- Duplicate copies of the same song collapse in stored playlists because of the
  database primary key. Queue duplicates are supported and receive distinct
  stable MPD `Id` values.
- `listplaylist`/`listplaylistinfo` ranges are not implemented.
- `playlistsearch` and `searchplaylist` are not implemented.
- `added-since` filters, `lastloadedplaylist`, stickers, channels, mounts, and
  partitions are stubs or unsupported.
- The server advertises MPD 0.24.0 and implements the `added` field and save modes,
  but it is not a complete MPD 0.24 implementation.
- MPD has no password and listens on all interfaces by user request. Treat it as a
  trusted-LAN service; do not expose it publicly.

## 9. File deletion

Delete is available from:

- Albums grid and Album list
- Recently Added
- Artists and Genres album headers
- Song table
- Album detail track rows
- Playlist track rows

Rules and behavior:

- The menu item is **Delete...**.
- It is enabled only when every target item is in the Internal Library.
  External tracks, mixed albums, or any read-only target show a disabled item.
- Confirmation is an `NSAlert`:
  - Default button: Cancel.
  - Destructive button: Move to Trash.
  - Message includes the item/album count and file count.
- On confirmation, `Library.deleteSongs`:
  - Rechecks that every target is writable/internal.
  - Moves each existing file to macOS Trash with
    `FileManager.default.trashItem`.
  - Removes the song rows and playlist references from SQLite.
  - Removes empty albums/artists through the existing orphan cleanup.
  - Removes deleted IDs from the current queue, base queue, and history.
  - Reloads the library and selected views.
- Missing files are removed from the database even though there is no file to move.
- If some Trash moves fail, those database rows remain and an alert lists the
  failures. Successfully moved files are still removed.
- Current snapshot evidence: all previous Internal Library audio files are in the
  macOS Trash and the database has zero internal songs. Do not restore them unless
  the user asks.
- Deletion does not remove empty directories or the artwork cache entry for a
  deleted album. That is intentional for now.
- There is no undo beyond the macOS Trash.

External Library removal is separate from Internal file deletion: disabling
requires confirmation and clears the global queue/History; the disabled source
can then be deleted through a second confirmation. Tracks creates a SQLite Online
Backup before deleting that source's songs and playlist-item associations. Empty
user-created playlists are retained; external audio files are never touched.

## 10. Titlebar and traffic lights

The main window uses a hidden/full-size content view and a custom 45pt title bar.

### Build SDK and the macOS 27 window design

SwiftPM records the package's deployment target as the linked SDK version unless
overridden. With the old build the binary contained `LC_BUILD_VERSION sdk 15.0`,
so AppKit deliberately used the legacy window design (flat traffic lights) even
on macOS 27. `scripts/build.sh` now passes the build-only linker override:

```text
swift build -c <config> \
  -Xlinker -platform_version -Xlinker macos \
  -Xlinker 15.0 -Xlinker "$(xcrun --show-sdk-version)"
```

This override is intentionally not in `Package.swift`; using `.unsafeFlags`
there made the package unusable as a dependency. The result is `minos 15.0` and
`sdk 27.0`; the macOS 15 deployment target is kept, but AppKit now opts into the
current design and native Library traffic lights. A bare `swift build` is only
for compiler checks and does not apply the app window-design override.

Do not remove the linker override from `scripts/build.sh`. Building the app
without it silently opts the whole app out of the macOS 26/27 Liquid Glass
window style.

### MiniPlayer traffic lights

The MiniPlayer is its own `NSWindow` hosted by `WindowModeCenter`; it is not a
mode of the Library window. Its `_titlebarHeight` is 0 so there is no title-bar
strip and the cover starts at the top edge. It draws two 14pt controls (close
and minimize) at `leading 10` and `top 10`, using Display P3 colors, specular
top/bottom highlights, a glass rim, and hover glyphs. They fade in with the
existing hover chrome and use gray fills when the window is not key.

The MiniPlayer is resizable from `320` to `560` points wide. Its
`MiniResizeDelegate` is installed on the mini window, and `windowWillResize`
forces `height = width + 42 + 30 + (queue ? queueHeight : 0)`. SwiftUI's
GeometryReader feeds the same width to the square cover, so the cover scales from
the top while the middle and bottom bars stay fixed. The width is kept in
`WindowMode.miniWidth`; the maximum is also clamped to the screen's visible
area.

While the queue is open, a 20pt drag handle spans the bottom edge. Dragging it
down increases the queue height and grows the window downward while the cover's
top stays fixed. Queue height is `140...500` points, further limited by the
screen, and persists in `WindowMode.miniQueueHeight`. The extra height is used
by the queue list, not by the player chrome. Native window resizing is disabled
while the queue is open so the bottom edge always belongs to this handle; width
can be changed again after collapsing the queue.

The square cover has a transparent native drag surface that calls
`NSWindow.performDrag(with:)`. The traffic lights sit above it in the ZStack, so
they still receive clicks; the middle controls and queue handle are outside the
cover drag area. No custom mouse or window-frame tracking is involved.

Do not replace these with `standardWindowButton` views. AppKit owns those views
and reattaches them to `NSTitlebarView` on layout; they are clipped at title-bar
height 0, and giving mini a real 32pt title bar adds a strip and changes the
window height. Reparenting them into the SwiftUI content view also gets undone
by AppKit's title-bar layout pass.

- `Components.swift` swizzles private AppKit selectors:
  - `_titlebarHeight` returns 45 for the main Library window and 0 for the
    separate MiniPlayer window.
  - `_shouldCenterTrafficLights` returns true outside full screen **only for the
    main window**.
- `refreshLibraryTitlebarLayout(for:)` forces a title-bar layout pass by nudging
  the window width by 1pt and restoring the exact frame immediately.
- It is called:
  - During initial window configuration.
  - From an asynchronous fallback after the first layout turn.
  - When creating the MiniPlayer window.
- It is deliberately **not** called from `NSWindow.didBecomeKeyNotification`.
  `WindowDragSurface` calls `makeKey()` before `performDrag(with:)` so an
  inactive window can be dragged immediately; refreshing the title bar there
  would run the width nudge during drag start and produce a visible one-frame
  jitter.
- This fixed a first-open bug where traffic lights were 7pt from the top instead
  of the centered 15pt offset. Resizing the window used to fix it by accident.
- Do not apply `_shouldCenterTrafficLights` to standard windows. AppKit's native
  title bars already position those buttons correctly; forcing the hook moved
  Settings, About Tracks, Get Info, and Setup traffic lights 12pt to the right.
- Measured result after the fix on macOS 27:
  - Library traffic lights use AppKit's native 16pt buttons, centered in the
    45pt bar (about 14.5pt from the top, `x=20`).
  - Standard-scene windows keep their native 32pt title bar, with the button
    group at `x=8`, `y=8`.
  - MiniPlayer is a separate title-bar-free window; its two 14pt lights sit at
    `x=10`, `y=10` with symmetric top/left margins.
  - Resizing does not change the centered offset.
- Do not remove the width nudge: a plain `needsLayout` pass was tested and left
  the initial traffic lights at the stock `8pt` inset instead of the centered
  `14.5pt` offset. The private title-bar height is only re-read during a
  frame/layout pass. Keep the nudge restricted to initial setup and mode
  changes; never run it from a key/activation notification.

## 11. Schema policy

- `createSchema()` creates the current tables and columns for new libraries.
- There are no runtime schema migrations. Old databases missing current columns
  (or still using the old queue columns) are not supported.
- Only `shortcut.bindings.v2` is read; legacy per-action shortcut keys and
  shortcut formats are ignored.
- If a schema change is needed later, introduce a versioned migration from this
  baseline rather than adding another compatibility fallback.

## 12. Key pitfalls and rules

1. Swift 6 concurrency:
   - `Library`, `LibraryDatabase`, `PlayerState`, `MPDServer`, `WindowModeCenter`,
     and `SystemNowPlaying` are `@MainActor`.
   - `MPMediaItemArtwork` invokes its request handler on a background queue.
     Build that artwork in a `nonisolated` helper from `Data`, never by touching
     a `@MainActor` property or cached `NSImage` inside the handler.
   - `LibraryDatabase` intentionally has no deinit; its connection lives for the
     app lifetime.
2. SQLite:
   - Use `SQLITE_TRANSIENT` and existing bind helpers.
   - WAL while running; checkpoint and switch to DELETE on normal quit.
   - Do not validate a copied WAL database with a read-only connection; existing
     `inspect()` uses read-write without CREATE.
   - Queue persistence uses the `queue_entries` / `base_queue_entries` JSON
     arrays and `next_queue_id` in `player_queue`. Save the full queue only when
     its structure changes; use `updatePlayerQueuePosition` for elapsed-time
     checkpoints to avoid rewriting large queues every few seconds.
3. Media keys:
   - Use MediaPlayer (`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`), not
     global event taps.
   - The bundle must be properly ad-hoc signed; verify with `codesign -dv` that
     `Info.plist entries` and `Sealed Resources` are present. Linker-only signing
     is rejected by MediaRemote.
4. Stable IDs:
   - Never change song IDs during path rebases or tag edits. Playlists, queue,
     and play data depend on them.
5. Paths:
   - Canonicalize both the scan root and each file URL. `/tmp` vs `/private/tmp`
     differences can create duplicate songs.
6. Artwork:
   - Do not reintroduce database artwork BLOBs for library albums.
   - The 500x500 size is hardcoded; only JPEG quality is configurable.
7. Settings:
   - Do not use `makeFirstResponder(nil)` when opening Settings.
   - Use `SettingsFocusSink`; the field must not auto-focus or beep.
8. MPD:
   - Keep it enabled and on the current interface/port unless asked otherwise.
   - Stared is virtual and must not be deleted/renamed/overwritten/reordered.
   - Preserve `added` and `Last-Modified` from `date_added`.
   - Do not clear user history or play counts during testing.
9. Deletion:
   - Only Internal Library files may be deleted.
   - Move files to Trash, never `removeItem`.
   - Recheck writeability immediately before deleting.
10. Current user data:
    - Internal files are in Trash; do not restore or rescan them.
    - Original stored playlists, queue, and stars should be preserved.
11. Testing:
    - Use temporary files/playlists and temporary databases for destructive tests.
    - Keep system output muted during playback automation.
    - Do not delete real user audio to verify code.
    - Synthetic `NX_SYSDEFINED` media-key events are ignored by this machine.
      Verify media commands through Control Center's Now Playing accessibility
      tree; it uses the same `MPRemoteCommandCenter` path as hardware keys.
12. UI automation:
    - System Events can inspect windows and standard buttons.
    - `screencapture` is not permitted on this machine; use in-app `cacheDisplay`
      captures through lldb when needed.
    - Control Center Now Playing can be inspected through the MenuBarAgent and
      Control Center accessibility trees to verify artwork/metadata.
13. Git: the project is tracked on `main`; commit owned source/doc changes only.
    Do not commit user-owned icon resources or icon-related build-script edits.

## 13. Useful verification commands

Build and basic state:

```bash
cd /Users/n/Documents/ws/tracks
swift build
bash scripts/build.sh
open build/Tracks.app
pgrep -fl '/build/Tracks.app/Contents/MacOS/Audia'
```

Database:

```bash
sqlite3 ~/Music/Tracks/library.sqlite \
  "select count(*) from songs;
   select count(*) from albums;
   select count(*) from playlists;
   select name from playlists order by name;
   select count(*) from songs where loved=1;
   select current_index, elapsed, next_queue_id,
          json_array_length(queue_entries) from player_queue;"
```

Signature / Now Playing readiness:

```bash
codesign -dv --verbose=2 build/Tracks.app
# Expect Info.plist entries and Sealed Resources in the output.
```

MPD:

```bash
mpc -h 127.0.0.1 -p 6600 status
mpc -h 127.0.0.1 -p 6600 lsplaylists
mpc -h 127.0.0.1 -p 6600 playlist "Stared"
mpc -h 127.0.0.1 -p 6600 load "Stared"
```

Raw protocol (the first line is the MPD greeting):

```bash
printf 'status\n' | nc 127.0.0.1 6600
printf 'listplaylists\n' | nc 127.0.0.1 6600
printf 'listplaylistinfo "Stared"\n' | nc 127.0.0.1 6600
```

Window/traffic-light metrics:

```bash
osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Audia"
    tell window "Tracks"
      set p to position
      set s to size
      set out to {"window", p, s}
      repeat with b in buttons
        try
          set bp to position of b
          set end of out to {(description of b as text), bp}
        end try
      end repeat
      return out
    end tell
  end tell
end tell
APPLESCRIPT
```

Expected when centered: the native Library traffic-light center is about 22.5pt
below the window top (16pt buttons), matching the 45pt title bar. MiniPlayer
traffic lights are custom SwiftUI controls, not standard window buttons.

## 14. Known limitations and possible follow-ups

- Stored playlists cannot contain duplicate copies of a song.
- The MPD implementation is partial MPD 0.24: no list ranges, `playlistsearch`,
  `searchplaylist`, `added-since`, mounts, channels, or partitions.
- MPD `Stared` is read-only for delete/rename/save/reorder by design; add/remove
  map to star changes.
- Deleting songs leaves empty folders and cached artwork behind.
- The artwork cache is not automatically rebuilt when quality changes; use Rebuild
  Cache.
- External Libraries are read-only for audio-file edits. Their Tracks index can
  be disabled/re-enabled or deleted after confirmation; deleting the index does
  not delete the external audio files.
- No security-scoped bookmarks; relevant only if the app is sandboxed later.
- No per-library album isolation.
- No undo for file deletion beyond the macOS Trash.
- The project is tracked on `main`; the app icon source, generated `.icns`, and
  build-time icon handling are part of the repository.

## 15. Handoff summary

Tracks is a native macOS iTunes-style player with a SQLite library, real AVPlayer
playback, Internal/External libraries, organizer-based imports and tag edits,
a 500x500 disk artwork cache, rich multi-selection and drag behavior, a MiniPlayer,
queue/position persistence, macOS Now Playing/media-key integration, a bundled
app icon, and a custom MPD server.

The current MPD server is enabled on all interfaces at port 6600, supports album
art, stored playlists, the virtual Stared playlist, and MPD 0.24 `added` timestamps.
The current Internal Library has no songs; the previous internal files are in the
macOS Trash and should not be restored without the user's request.

For the next change: read this file, inspect the relevant source file, build with
`swift build`, package with `bash scripts/build.sh` (which also signs the bundle),
and test with temporary data. Do not reset the user's library, playlists, stars,
history, queue, MPD settings, or window preferences.
