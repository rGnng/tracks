# Tracks

Tracks is a native macOS music player for a local music library. Its information
architecture and density are modeled on iTunes 12, but the implementation is
modern: SwiftUI and targeted AppKit, real `AVPlayer` playback, a SQLite-backed
library, native window behavior, and first-class keyboard navigation.

Tracks is deliberately local-first. There is no web view, cloud service,
account system, or document model. The library, playlists, stars, play counts,
queue, and history live on this Mac.

- **Product name:** Tracks
- **Internal module / executable:** Audia
- **Bundle identifier:** `com.audia.tracks`
- **UI:** native SwiftUI + AppKit, no WebView
- **Minimum macOS:** 15
- **App icon:** `Resources/AppIcon.icns` (source: `design/app-icon.svg` / `design/app-icon.png`)

## Design principles

- **Native first.** Window dragging, menus, context menus, text fields, media
  keys, full-screen behavior, and the MiniPlayer are AppKit-native. Custom
  drawing is reserved for places where the stock control would get in the way.
- **Local first.** Everything is stored in SQLite plus a disk artwork cache.
  External libraries are indexed in place and never modified.
- **Keyboard and pointer are peers.** Main lists support arrows, Page Up/Down,
  Home/End, in-app section shortcuts, and native text editing/commands. The
  mouse adds marquee selection, item dragging, and direct manipulation.
- **Restrained motion.** Animations are short and functional: the menu-bar card
  flip, the MiniPlayer chrome, album-detail transitions, and list reveals.
- **Non-destructive management.** Missing tracks are reviewed, not silently
  deleted. Deletion moves files to the Trash. Removing an External Library
  creates a database backup and never touches its audio files.

## Library

- **Recently Added**, **Albums**, **Artists**, **Songs**, and **Genres** in the
  sidebar, plus the virtual **Stared** playlist (starred tracks) and user
  playlists.
- **Albums** can be shown as a cover grid or a compact list. Sort by Album Name,
  Artist, or Year, ascending or descending. Recently Added keeps its own
  newest-first order.
- **Artists** and **Genres** use master-detail browsers, with album panes that
  follow the current album sort. An empty genre is shown as italic `#Unknown`
  at the bottom of the Genres list.
- The **Songs** table has adjustable column visibility and order, including
  Track, Name, Time, Artist, Album Artist, Album, Genre, and Plays.
- Playlist tables add **Add Seq** and **Add Time**. Add Seq appears after Genre
  by default; Add Time is hidden by default and renders with the system
  date/time format.
- Double-clicking a sidebar playlist, Albums, or Recently Added plays it in the
  current content-view sort order.
- Context menus provide Play, Shuffle, Add to Playlist, Play Next, Play Later,
  Get Info, Go to Album/Artist, and a conditional Delete item. Internal
  playlists can also receive album and song drops.

## Playback

- Real playback through `AVPlayer`, with Core Audio output-device selection.
- A persistent queue with **Up Next** and **History** tabs. Up Next supports
  drag-to-reorder; the currently playing entry and the already-played prefix
  stay fixed.
- The queue, stable queue-entry IDs, current track, and playback position are
  stored in SQLite. After relaunch the queue is restored paused; Play resumes
  from the saved position instead of restarting the track.
- Shuffle affects the unplayed queue. Enabling it while playing keeps the
  current track and shuffles the remainder; turning it off restores the normal
  album order. Repeat modes are Off, All, and One. Active Shuffle and Repeat
  controls get a subtle highlight.
- Playback History is most-recent-first and capped at 50 entries.
- Missing files are marked in memory only. Confirmed missing tracks are skipped,
  permission/decoder errors are not marked missing, and one hundred consecutive
  missing files pause playback with a warning.
- macOS **Now Playing** publishes title, artist, album, duration, elapsed time,
  queue position, and cached artwork. Hardware media keys and Control Center
  use `MPRemoteCommandCenter`; Control Center shows previous/next, not
  skip-by-15-second buttons.
- The output menu offers plain **System Default**, **System Default with Volume
  Control**, and every real Core Audio device. The volume-control option locks
  player attenuation and routes the app volume controls to the macOS output.
- Volume level and output selection persist across launches.

## Library management

- One writable **Internal Library** and any number of read-only **External
  Libraries**. Tracks owns the Internal Library's `library.sqlite` and `Music/`
  folder; it never writes into an External Library.
- **Quick Scan** discovers and imports new paths only. **Full Scan** also
  refreshes files whose modification time or size changed. File contents are
  never hashed.
- Missing files found by Full Scan are shown in a searchable review table. Only
  explicitly selected rows are removed from the Tracks index; Cancel changes
  nothing.
- **Relocate** matches the full relative path under a new library root, keeping
  song IDs, playlists, stars, and play counts. Unmatched tracks use the same
  review flow.
- Internal imports use a canonical
  `<Album Artist>/<Album>/[disc-]track.title-artist.ext` layout. Tag edits write
  back to the file and relocate it while preserving the song ID and play data.
- **Get Info** has Details, Artwork, and File tabs. Mixed-value fields use
  italic placeholders; submitting an empty mixed field preserves the underlying
  value. Read-only fields remain selectable and copyable.
- Multi-disc albums are ordered by disc then track. Album detail shows the
  effective disc count and `disc-track` labels. Get Info keeps the stored track
  and disc totals as-is so saving does not fill intentionally empty tags.
- **Delete** is available only for Internal Library files, requires
  confirmation, and moves files to the macOS Trash before removing their index
  rows.
- Disabling an External Library hides its songs, stops playback, and clears the
  global queue and History, but keeps its indexed rows for later re-enable.
  Deleting a disabled External Library creates a timestamped SQLite Online
  Backup first and removes only Tracks index data.

## Interaction details

### Keyboard-first navigation

- While the Library window is focused, `1`–`5` select Recently Added, Albums,
  Artists, Songs, and Genres; `8` selects Stared.
- Arrow keys move the focused item. Page Up/Down and Home/End scroll the focused
  viewport without changing the selection. Page navigation keeps one row of
  overlap; Home/End preserve the grid's 22pt and list's 6pt content padding.
- Left/Right move between split regions where one exists: Sidebar to content,
  and Artists/Genres list to the track pane. Command-F focuses search; Command-1/2
  switch between Library and MiniPlayer.
- Keyboard selection scrolls only enough to reveal the item completely, not to
  center it. If the previous selection is off-screen after manual scrolling,
  arrow navigation starts from the first item actually visible.

### Search and Escape

- Return in the search field moves focus to the content.
- Escape in the search field clears the query and moves focus to the content.

### Selection and drag

- Click selects; Command-click toggles; Shift-click extends a range. Album
  cards in the grid open album detail on single click; list rows and song rows
  select. Use the hover Play button or context menu to play.
- A quick drag draws a marquee and selects every intersecting album, song, or
  track. After the 100ms long-press threshold, the same gesture becomes an item
  drag instead.
- Drag albums or songs onto a playlist in the sidebar to add them. Drag outside
  the window to start a native file drag: Finder copies the files, and text
  editors receive absolute paths.
- Album-grid hit testing and navigation use the deterministic `AlbumGridLayout`
  frame model. Cached rendered frames are debug-only and cannot move the
  viewport or selection after a lazy-grid jump.

### Remembered place

- Within one app session, visiting a view again restores its exact scroll offset.
  Selections are not restored, so a changed list cannot resurrect a stale item.
- Across relaunches, only the viewport of the view that was active at a graceful
  quit is restored. Selection is never restored. The offset is applied after the
  list has loaded and is ignored when the list item count changed.
- Restored offsets use raw content coordinates and preserve the grid's 22pt and
  list's 6pt top padding. No rendered frames or viewport anchors are stored.
  The saved viewport covers the main list area; album detail and the
  Artists/Genres right-hand pane are not persisted.
- Album detail keeps the underlying grid mounted while open. Returning leaves
  the clicked album where it was. **Go to Album** opens that album detail; it no
  longer scrolls the parent grid to the album.

### Windows and chrome

- The Library window and MiniPlayer are separate windows and are never shown
  together. Closing MiniPlayer restores Library; there is no separate
  return-to-Library button.
- MiniPlayer is resizable from 320 to 560 points wide. Its square cover grows
  with the window; the queue panel has its own adjustable height. Two custom
  Liquid Glass-style traffic lights live inside the cover and appear on hover.
- Window movement is native AppKit dragging. Empty toolbar chrome falls through
  to `NSWindow.performDrag(with:)`, while controls keep hit-test priority. There
  is no manual frame tracking, collision solver, or magnetic snapping layer.
- The sidebar is stored independently for windowed and full-screen modes.
  Command-Shift-L toggles it; full screen defaults to hidden and shows a
  toolbar toggle. The status bar is likewise independent per mode and toggles
  with Command-/.
- The show/hide shortcut uses app-level hide/show semantics: hiding returns
  focus to the previous application, and showing activates Tracks.

### Queue details

- The queue popover has no visible resize handles. Invisible left/right edge
  drags adjust its width; a 10pt splitter below the Clear row adjusts only the
  list height. Both persist.
- Queue rows show title, artist, album, duration, and a gray star. The star is
  a status indicator here, not a toggle. Row context menus use stable entry IDs,
  so duplicate copies of the same song remain distinct.
- Play Next inserts directly after the current track; Play Later appends to the
  bottom. The queue is persisted structurally, while elapsed position is
  checkpointed every five seconds and on pause/termination.

### Menu-bar card

- Optional menu-bar icon, off by default. It starts as a 24pt `opticaldisc.fill`
  item. On track change or current-song star/unstar it flips around its vertical
  axis to the album cover and expands leftwards to 120 points, revealing the
  title, artist/album, and star.
- The cover is prefetched, center-cropped, bilinearly downsampled, and cached
  before the flip, so the back of the card never flashes empty. Albums without
  artwork show their generated color gradient.
- After a configurable display duration (default 1500 ms), the card shrinks
  back to the icon first, then flips back to the disc. Song-change and
  star/unstar triggers are independent toggles. The normal status-item menu
  still opens on click.
- **Play control action** is an independent toggle. When enabled, Play, Pause,
  and Stop briefly flip the idle disc to the matching transport icon, hold it
  for 1000 ms, then flip back to the disc. If the track card is already open,
  Play leaves it in place; Pause and Stop replace it with the transport icon.
- The card is part of the menu bar, so it does not unhide the Library window.

### Settings and appearance

- Settings is organized into **General**, **Library**, **Shortcuts**, and
  **Services**. The Library page header shows live album and song counts and
  scan progress.
- Appearance supports Automatic, Light, and Dark, applied at the AppKit level so
  live system changes propagate to every window.
- Highlight color offers System/Multicolor, Blue, Purple, Pink, Red, Orange,
  Yellow, Green, and Graphite. Native context menus keep a neutral graphite
  accent so they remain readable beside the in-app highlight.
- Shortcuts are split into In-App and System-wide tables. Add an action with
  **+**, remove it with **−**, and click its Key field to record a combination.
  Defaults: mute `m`, volume down `-`, volume up `=`, play/pause Space, go to
  current album `j`; system-wide show/hide Tracks `F17` and star/unstar the
  current song `F18`. The star action targets the playing song, not the row
  selection.
- Opening Settings does not focus a text field or beep. The JPEG-quality field
  commits on Return or focus loss and clamps to 15–100.
- The status bar summarizes the current selection with item count, total
  duration, and total file size, using Finder-style decimal MB/GB units.

### Artwork

- Artwork is stored only as JPEG files up to 500×500 under
  `~/Library/Caches/com.audia.tracks/Artwork`; the database keeps no artwork
  BLOBs.
- The 45pt Now Playing cover is downsampled once to its backing-pixel size
  before display, instead of relying on live SwiftUI scaling.
- Now Playing, MiniPlayer, Control Center, and the menu-bar card resolve artwork
  through the song's album relationship, so repeated album titles cannot select
  another album's cover.
- Settings shows the current cache size and allows a full cache rebuild, which
  clears the disk cache and forces a rescan.

## MPD server

Tracks includes an optional MPD-compatible TCP server, disabled by default. It
can listen on loopback or all interfaces, on a configurable port (default 6600),
with an optional password. Treat exposure beyond a trusted LAN as unsafe.

Supported areas include status/current song/queue, library browse and search,
stored playlists, album art, idle notifications, audio outputs, and the virtual
**Stared** playlist. Queue entries have stable MPD `Id` values independent of
song IDs, so duplicate queue copies remain distinct. `status.songid` and
`status.nextsongid` expose those entry IDs; `song`/`nextsong` remain positions.

The server is not a complete MPD 0.24 implementation. `playlistsearch`,
stickers, channels, mounts, and partitions are not implemented; stored playlists
cannot contain duplicate copies of the same song because of the database primary
key.

## Build and run

```bash
# Build and launch the signed app bundle
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

### Debugging

- Debug panel shortcut: `Control-Option-Command-D`. Plain `Option-Command-D`
  belongs to the system Dock. The panel does not open at launch by default; use
  the shortcut, the Debug menu item, or enable **Open with app** inside it. All
  panel checkboxes start unchecked and remember their state across launches.
- `scripts/debug/audiactl` is the reusable Accessibility test CLI. It can read
  Debug metrics, locate album UUIDs, send keys, resize windows, drag selections
  and map album indices. See `scripts/debug/README.md`.

```bash
scripts/debug/audiactl metrics AlbumGrid
scripts/debug/audiactl locate 893CF518-EC57-46F1-716E-4CD3F8AB048F
scripts/debug/audiactl album-at-index 1438
```

## App icon

The icon source files live in `design/`. Regenerate the `.icns` from the
1024px source image with:

```bash
./scripts/make-icon.sh
```

This writes `Resources/AppIcon.icns`, which the build script and app bundle use.

## Data

The primary database is:

```text
~/Music/Tracks/library.sqlite
```

The fallback location, when no Internal Library exists, is:

```text
~/Library/Application Support/Tracks/library.sqlite
```

Artwork is cached as JPEG files up to 500×500 under:

```text
~/Library/Caches/com.audia.tracks/Artwork
```

Stored playlists use `playlist_items.added_at` for per-item addition times. The
active playback queue, stable queue-entry IDs, current position, and paused
elapsed time are stored in the singleton `player_queue` table.

## Project layout

```text
Sources/Audia/
  App and chrome        AudiaApp, ContentView, PlayerToolbar, StatusBarView,
                        SidebarView, SidebarVisibility, WindowMode, Components
  Content views         ContentPane, ContentViews, BrowserViews, ContextMenus,
                        PlaylistActions, MarqueeSelection, ListScroll
  Library and data      Library, LibraryDatabase, LibraryOrganizer,
                        LibraryDeletion, LibraryRelocationMatcher, Models
  Metadata and artwork  FLACLibrary, ArtworkCache, MediaImporter, TagWriter,
                        GetInfo
  Playback              PlayerState, AudioDevices, SystemVolume, SystemNowPlaying
  Input and navigation  DragController, NavigationRouter, NavigationCenter,
                        KeyboardShortcut, SystemWideShortcuts
  View state and layout SessionViewState, AlbumGridLayout, ListScroll
  Focus and integration LibraryFocusSink, SettingsFocusSink, TrayController,
                        MPDServer
  Debug                 DebugSupport, scripts/debug/audiactl
  MiniPlayer            MiniPlayerView, WindowMode
  Theme                 Theme

Assets/AccentColors.xcassets  Static Graphite accent for native menus
Resources/AppIcon.icns        Built app icon
design/                       Icon source and previews
scripts/build.sh              App bundle build and signing
scripts/make-icon.sh          Icon regeneration
```

## Development notes

- `agent.md` is the detailed handoff document with schema, runtime behavior,
  pitfalls, and verification commands.
- Keep UI work native; do not introduce a web view.
- Use temporary playlists and sample files for destructive testing. Do not
  clear the user's playlists, stars, history, queue, or play counts.
- The MPD implementation covers the commands used by Tracks and common MPD
  clients; it is not a complete MPD 0.24 implementation.
- MediaRemote and Now Playing require the signed bundle produced by
  `scripts/build.sh`.
