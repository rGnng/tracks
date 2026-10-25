# Tracks (internal target: Audia) - Agent Handoff

Last updated: 2026-10-25

This file is the handoff snapshot for a future coding agent. Read it before changing
the project, then verify the current code and running state.

## 1. Product and scope

- Native macOS music player with an iTunes 12-style interface.
- Product name: **Tracks**. Internal module, executable, and bundle identity: **Audia**
  (`com.audia.tracks`).
- SwiftUI plus targeted AppKit. No WebView. Light and dark appearance are supported.
- Real playback through `AVPlayer`, not a mock transport. The queue, history, play
  counts, stars, playlists, and library are backed by SQLite.
- Single main window with two modes: Library and MiniPlayer.
- No cloud service, no account system, and no multiple-window document model.

## 2. Environment and build

- Project root: `/Users/n/Documents/ws/tracks`
- Parent directory `/Users/n/Documents/ws` is a git repository, but `tracks/` is
  currently untracked. There is no commit.
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
`build/Tracks.app/Contents/MacOS/Audia`, and writes `Info.plist` with
`CFBundleName=Tracks`.

Primary database:

```bash
sqlite3 ~/Music/Tracks/library.sqlite \
  "select count(*) from songs; select count(*) from albums; select * from libraries;"
```

If no Internal Library exists, the fallback database path is
`~/Library/Application Support/Tracks/library.sqlite`.

## 3. Current runtime snapshot

- App is running from `/Users/n/Documents/ws/tracks/build/Tracks.app`.
- Main window frame at the time of this snapshot: about `1322 x 823`.
- MPD is enabled, listening on all interfaces, port `6600`, empty password.
- Current database: `~/Music/Tracks/library.sqlite` (WAL while the app is running).
- Database counts:
  - 20,669 songs
  - 2,143 albums
  - 5,481 artists
  - 2 stored playlists, 37 stored playlist items
  - 3 starred songs
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
- `PRAGMA user_version = 1`.
- Do not clear playback history, play counts, stars, playlists, or user window
  preferences while testing.

## 4. Source map

```text
Package.swift
README.md
agent.md
scripts/build.sh
scripts/generate_library.swift
Sources/Audia/
  AudiaApp.swift             App entry, AppDelegate, menus, Settings window, setup window
  Theme.swift                Light/dark colors and layout constants
  Models.swift               Artwork, Song, Album, Playlist, MusicLibrary, sidebar models
  Library.swift              Library singleton, scanning, playlists, read-only rules, delete API
  LibraryDatabase.swift      SQLite schema, sync/prune, playlists, migrations, song deletion
  LibraryOrganizer.swift     Canonical file names and tag-driven file relocation
  LibraryDeletion.swift      Delete confirmation UI and partial-failure alert
  FLACLibrary.swift          FLAC/AVFoundation metadata readers and LibraryScanner
  MediaImporter.swift        Import into Internal Library with organizer naming
  TagWriter.swift            Tag/artwork writeback for supported formats
  ArtworkCache.swift         500x500 JPEG disk cache, quality setting, rebuild
  MPDServer.swift            Custom MPD TCP server, queue/playlists/album art
  PlayerState.swift          AVPlayer engine, queue, history, shuffle/repeat
  AudioDevices.swift         Core Audio output device enumeration and selection
  WindowMode.swift           Library/MiniPlayer window modes and metrics
  MiniPlayerView.swift       Compact player UI and custom mini traffic lights
  Components.swift           WindowConfigurator, titlebar layout, shared controls
  ContentView.swift          Root layout, sidebar/player/content composition
  PlayerToolbar.swift        Top transport bar, seek, volume, output, search
  SidebarView.swift          Library and playlist sidebar
  ContentPane.swift          Content routing and album sort/view settings
  ContentViews.swift         Album grid/list, album detail, song table, selection
  BrowserViews.swift         Artists/Genres master-detail browsers
  ContextMenus.swift         Shared album/song context menus
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

Never recompute song IDs during normal open/move/rebase operations. Recompute only
for the one-time legacy migration.

### Core schema

```sql
artists(id TEXT PK, name TEXT UNIQUE)
albums(id TEXT PK, title, artist_id, genre, year, artwork BLOB,
       UNIQUE(title, artist_id))
songs(id TEXT PK, path TEXT UNIQUE, title, artist_id, album_id,
      genre, year, track, track_total, disc, disc_total, comments,
      duration, date_added, play_count, rating, loved, last_played,
      skip_count, mtime, file_size)
libraries(id TEXT PK, path TEXT UNIQUE, kind TEXT, name TEXT, date_added)
playlists(id TEXT PK, name TEXT, date_created REAL, date_modified REAL)
playlist_items(playlist_id, song_id, position,
               PRIMARY KEY(playlist_id, song_id))
```

Important schema decisions:

- Artwork BLOBs were removed from the database. Album rows keep metadata and the
  artwork cache key; the 500x500 JPEG lives on disk.
- `songs.loved` is the star flag and backs the built-in Stared playlist.
- `playlists.date_modified` was added for MPD `Last-Modified`. Migration runs on
  open and falls back to `date_created` for old rows.
- `playlist_items` has a primary key on `(playlist_id, song_id)`, so a stored
  playlist cannot contain duplicate copies of the same song.
- `date_added` is first-discovery time:
  - Internal imports: import time.
  - External tracks: file modification time.
  - Existing rows preserve it across rescans and tag edits.
- `Album.addedAt` is `max(song.dateAdded)` and drives the Recently Added order.
- WAL is used while running. On normal termination, `closeForTermination()`
  checkpoints and switches the journal back to DELETE so `library.sqlite` is
  self-contained.

### Scanning and import

- Supported files: FLAC, MP3, M4A, WAV, AIFF, OGG/Opus.
- `LibraryScanner` skips unchanged files by `mtime + file_size`, resolves symlinks
  for each file, and reads metadata concurrently.
- Internal imports use `LibraryOrganizer`:
  - Canonical path: `<Album Artist>/<Album>/[disc-]track.title-artist.ext`
  - Track digits: at least 2, expand automatically for 3+ digit track numbers.
  - Disc prefix only when present.
- Internal tag edits write tags back to the file, then relocate/rename it to the
  canonical path while preserving the song ID, stars, play counts, playlists,
  and `date_added`.
- Get Info supports Mixed values with italic placeholders; submitting empty mixed
  fields preserves the underlying value.

## 6. Playback, queue, and UI behavior

- `PlayerState` uses `AVPlayer`/`AVPlayerItem`, with real Core Audio output devices.
- Queue operations: append, insert, remove, move, shuffle, clear, play by position/
  song, history, auto-next on end.
- `baseQueue` preserves normal order when shuffle is toggled off.
- Repeat modes: Off, All, One; persisted in UserDefaults.
- History is most-recent-first, persisted by song ID.
- Main window modes:
  - Library: normal main window, minimum about `1040 x 640`.
  - MiniPlayer: width `320`; cover `320`; middle `42`; bottom `30`; queue panel
    adds `201`. Window shortcuts are Command-1 / Command-2.
  - MiniPlayer uses custom three-dot traffic lights inside the cover.
- Selection and drag:
  - Marquee selection works in Albums, Recently Added, Artists/Genres album panes,
    Songs, Playlists, and album detail.
  - Long-press threshold is `DragController.longPressDuration = 0.25` seconds.
  - Fast drag = marquee; after the long-press threshold, drag = item drag.
  - Dragging outside the window starts a native file drag:
    - Finder copies the files.
    - Text editors receive absolute paths.
  - Internal playlists can receive album/song drops.
- Context menus include Play, Shuffle, Add to Playlist, Play Next, Play Later,
  Get Info, and the conditional Delete item.
- Sidebar **Albums** and **Recently Added** also have Play and Shuffle context
  menus. Albums uses the full library; Recently Added uses the same album order
  as the Recently Added view. This is the app-level "shuffle all" entry point.
- Add-to-Playlist submenu starts with **New Playlist**, then a divider, then the
  existing playlist names. New names auto-increment: New Playlist, New Playlist 2,
  etc.
- Play Later appends to the bottom of the queue and sits below Play Next.
- Get Info has Details, Artwork, and File tabs, with tag/artwork writeback for the
  Internal Library.

## 7. Artwork cache and Settings

- Artwork is stored only as 500x500 JPEG files in:
  `~/Library/Caches/com.audia.tracks/Artwork`
- Database artwork BLOBs are zero for library albums.
- `ArtworkCache` uses an in-memory cache plus disk cache and a detached pre-cache
  scan. Rebuild Cache clears and regenerates the disk cache.
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

Supported areas:

- Status/current song/queue: `status`, `stats`, `currentsong`, `playlistinfo`,
  `playlistid`, `plchanges`, `plchangesposid`.
- Queue editing: `add`, `addid`, `clear`, `delete`, `deleteid`, `move`, `moveid`,
  `shuffle`, `play`, `playid`, `pause`, `stop`, `next`, `previous`, `seek`,
  `seekid`, `seekcur`, `setvol`, `volume`, `repeat`, `random`, `single`, `consume`,
  `toggle`.
- Library queries: `listall`, `listallinfo`, `lsinfo`, `find`, `search`, `findadd`,
  `searchadd`, `list`, `count`, `update`, `rescan`.
- Album art: `albumart`, `readpicture`, `binarylimit`. Responses use the 500x500
  JPEG cache, correct size/type, and JPEG magic. The default chunk size is
  262144 bytes so a typical cover fits in one response; clients can still request
  a smaller `binarylimit`. A URI-to-album-ID cache avoids rescanning the whole
  library for every binary chunk.
- Idle: `idle`, `noidle`; queue changes broadcast `playlist`/`player`, stored
  playlist changes broadcast `stored_playlist`.
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
- Playback state, elapsed time, duration, and queue data are derived from the live
  `PlayerState` on every request. There is no cached `isStopped` flag. Restarting
  the MPD server while audio is playing therefore keeps `state: play` and the
  correct progress instead of reporting a false stop.

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
  database primary key. Queue duplicates are supported.
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

## 10. Titlebar and traffic lights

The main window uses a hidden/full-size content view and a custom 45pt title bar.

- `Components.swift` swizzles private AppKit selectors:
  - `_titlebarHeight` returns 45 for the main Library window.
  - `_shouldCenterTrafficLights` returns true outside full screen.
- `refreshBrowserTitlebarLayout(for:)` forces a title-bar layout pass by nudging
  the window width by 1pt and restoring the exact frame immediately.
- It is called:
  - During initial window configuration.
  - From `NSWindow.didBecomeKeyNotification` for the first and later key changes.
  - From an asynchronous fallback after registration.
  - From `WindowModeCenter` when switching Library/MiniPlayer.
- This fixed a first-open bug where traffic lights were 7pt from the top instead
  of the centered 15pt offset. Resizing the window used to fix it by accident.
- Measured result after the fix:
  - Fresh launch with no saved frame: window `y=60`, traffic lights `y=75`
    (button height 14, 15pt top offset).
  - Restored saved frame: window `y=196`, traffic lights `y=211`.
  - Resizing does not change the centered offset.
- Do not remove the key-window refresh or the width nudge. The private title-bar
  height is only re-read during a frame/layout pass.

## 11. Key pitfalls and rules

1. Swift 6 concurrency:
   - `Library`, `LibraryDatabase`, `PlayerState`, `MPDServer`, and `WindowModeCenter`
     are `@MainActor`.
   - `LibraryDatabase` intentionally has no deinit; its connection lives for the
     app lifetime.
2. SQLite:
   - Use `SQLITE_TRANSIENT` and existing bind helpers.
   - WAL while running; checkpoint and switch to DELETE on normal quit.
   - Do not validate a copied WAL database with a read-only connection; existing
     `inspect()` uses read-write without CREATE.
3. Stable IDs:
   - Never change song IDs during path rebases or tag edits. Playlists and play
     data depend on them.
4. Paths:
   - Canonicalize both the scan root and each file URL. `/tmp` vs `/private/tmp`
     differences can create duplicate songs.
5. Artwork:
   - Do not reintroduce database artwork BLOBs for library albums.
   - The 500x500 size is hardcoded; only JPEG quality is configurable.
6. Settings:
   - Do not use `makeFirstResponder(nil)` when opening Settings.
   - Use `SettingsFocusSink`; the field must not auto-focus or beep.
7. MPD:
   - Keep it enabled and on the current interface/port unless asked otherwise.
   - Stared is virtual and must not be deleted/renamed/overwritten/reordered.
   - Preserve `added` and `Last-Modified` from `date_added`.
   - Do not clear user history or play counts during testing.
8. Deletion:
   - Only Internal Library files may be deleted.
   - Move files to Trash, never `removeItem`.
   - Recheck writeability immediately before deleting.
9. Current user data:
   - Internal files are in Trash; do not restore or rescan them.
   - Original stored playlists and stars should be preserved.
10. Testing:
    - Use temporary files and temporary databases for destructive tests.
    - Do not delete real user audio to verify code.
11. UI automation is limited:
    - System Events can inspect windows and standard buttons.
    - `screencapture` is not permitted on this machine.
    - Context-menu automation through accessibility is unreliable; verify menu
      wiring in code and manually when possible.
12. The project is not committed. Do not assume git history is available.

## 12. Useful verification commands

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
   select count(*) from songs where loved=1;"
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

Expected when centered: traffic-light `y` is 15pt below the window top with a
14pt button; the center is at 22pt, matching the 45pt title bar.

## 13. Known limitations and possible follow-ups

- Stored playlists cannot contain duplicate copies of a song.
- The MPD implementation is partial MPD 0.24: no list ranges, `playlistsearch`,
  `searchplaylist`, `added-since`, mounts, channels, or partitions.
- MPD `Stared` is read-only for delete/rename/save/reorder by design; add/remove
  map to star changes.
- Deleting songs leaves empty folders and cached artwork behind.
- The artwork cache is not automatically rebuilt when quality changes; use Rebuild
  Cache.
- External Libraries are read-only and cannot be edited or deleted through Tracks.
- No security-scoped bookmarks; relevant only if the app is sandboxed later.
- No per-library album isolation.
- No undo for file deletion beyond the macOS Trash.
- `MockData` may still be present as dead code in `Models.swift`.
- The project is untracked in git and has no commit.

## 14. Handoff summary

Tracks is a native macOS iTunes-style player with a SQLite library, real AVPlayer
playback, Internal/External libraries, organizer-based imports and tag edits,
a 500x500 disk artwork cache, rich multi-selection and drag behavior, a MiniPlayer,
file deletion to Trash, and a custom MPD server.

The current MPD server is enabled on all interfaces at port 6600, supports album
art, stored playlists, the virtual Stared playlist, and MPD 0.24 `added` timestamps.
The current Internal Library has no songs; the previous internal files are in the
macOS Trash and should not be restored without the user's request.

For the next change: read this file, inspect the relevant source file, build with
`swift build`, package with `bash scripts/build.sh`, and test with temporary data.
Do not reset the user's library, playlists, stars, history, MPD settings, or
window preferences.
