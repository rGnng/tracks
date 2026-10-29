# Tracks debug CLI

`scripts/debug/audiactl` is a reusable Accessibility-based test helper for the
running app. It replaces the ad-hoc scripts used during navigation and viewport
investigation.

The terminal running it needs macOS Accessibility permission. The app must be
running as `Tracks.app` (`com.audia.tracks`).

The Debug panel shortcut is `Control-Option-Command-D`. The CLI opens the panel
through its menu item so it does not depend on the system Dock shortcut.

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

# Layout helpers
scripts/debug/audiactl resize 1040 820
scripts/debug/audiactl drag 450 200 950 520

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

## Album index mapping

With `--db` omitted, the CLI checks:

```text
~/Music/Tracks/library.sqlite
~/Library/Application Support/Tracks/library.sqlite
```

It only includes albums that have at least one song, matching the app's grid.
