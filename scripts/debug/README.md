# Tracks debug CLI

`scripts/debug/audiactl` is a reusable Accessibility-based test helper for the
running app. It replaces the ad-hoc scripts used during navigation and viewport
investigation.

The terminal running it needs macOS Accessibility permission. The app must be
running as `Tracks.app` (`com.audia.tracks`).

The Debug panel shortcut is `Control-Option-Command-D`. The panel does not open
at launch by default. The CLI opens it through its menu item so it does not
depend on the system Dock shortcut. All panel checkboxes start unchecked and
persist their state.

## Commands

```bash
# Debug-window metrics (all sections or one section)
scripts/debug/audiactl metrics
scripts/debug/audiactl metrics AlbumGrid
scripts/debug/audiactl raw-metrics

# Open the Debug album locator, enter an album UUID and jump
scripts/debug/audiactl locate 893CF518-EC57-46F1-716E-4CD3F8AB048F

# Windows and focus
scripts/debug/audiactl windows
scripts/debug/audiactl focus Tracks
scripts/debug/audiactl focus Debug

# Buttons, text fields and keyboard
scripts/debug/audiactl press Debug "Locate Album…"
scripts/debug/audiactl type Debug 893CF518-EC57-46F1-716E-4CD3F8AB048F
scripts/debug/audiactl key 124              # right arrow
scripts/debug/audiactl key 121              # page down
scripts/debug/audiactl key 3 cmd            # command-F
scripts/debug/audiactl key 2 control option cmd  # control-option-command-D (Debug)
scripts/debug/audiactl clear-flags

# Mouse input
scripts/debug/audiactl click 500 158
scripts/debug/audiactl click 500 840 shift   # Shift-click range selection
scripts/debug/audiactl rightclick 500 200    # Open a row context menu
scripts/debug/audiactl drag 450 200 950 520

# Layout helpers
scripts/debug/audiactl resize 1040 820

# Album order helpers. The app sorts album titles with localizedStandardCompare;
# the CLI applies the same ordering to the library database.
scripts/debug/audiactl album-at-index 1438
scripts/debug/audiactl album-index 893CF518-EC57-46F1-716E-4CD3F8AB048F
scripts/debug/audiactl album-at-index 1438 --db /path/to/library.sqlite
```

`key` always targets the main `Tracks` window and releases synthetic modifiers
afterwards, so Command/Option tests do not leave a stuck modifier.

`locate` opens the Debug window if needed (via its menu item, not a global
hotkey), reveals the UUID field, types the UUID, presses Locate, then prints the
`Album Locator` metrics.

## Typical viewport checks

```bash
scripts/debug/audiactl locate 893CF518-EC57-46F1-716E-4CD3F8AB048F
scripts/debug/audiactl metrics AlbumGrid
scripts/debug/audiactl key 21               # Songs
scripts/debug/audiactl key 19               # back to Albums
scripts/debug/audiactl metrics AlbumGrid     # offset should match the first read
```

`metrics` output is one `Section.label = value` pair per line, for example:

```text
AlbumGrid.offset = 87919.0
AlbumGrid.selected = 0
Navigation.focus = albumGrid
```

## Launch viewport checks

The active viewport is persisted at graceful quit under
`tracks.lastViewport.{key,offset,itemCount}` and restored after the view has
loaded. Selections are not restored.

```bash
scripts/debug/audiactl key 21              # Songs
scripts/debug/audiactl key 121             # Page Down
scripts/debug/audiactl metrics SongTable   # note offset
osascript -e 'tell application id "com.audia.tracks" to quit'
open build/Tracks.app
scripts/debug/audiactl metrics SongTable   # offset should match
```

Use a graceful quit; force-killing the process skips `applicationWillTerminate`
and therefore does not persist the active viewport.

## Album index mapping

With `--db` omitted, the CLI checks the configured
`com.audia.tracks.databaseFolderPath`, then:

```text
~/Music/Tracks/library.sqlite
~/Library/Application Support/Tracks/library.sqlite
```

It only includes albums that have at least one song, matching the app's grid.
