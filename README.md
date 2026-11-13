# stage-layouts

Save and rebuild macOS Stage Manager layouts with Hammerspoon: which windows share a
stage, and where each window sits, per display setup and per Desktop.

macOS forgets stage groups on restart and has no API for them. This module reads the
Stage Manager strip through the accessibility tree (each strip button lists its windows
and offers "add to stage", the same as Shift-clicking it) and replays that on restore.

## Requirements

- macOS with Stage Manager on.
- [Hammerspoon](https://www.hammerspoon.org/) with Accessibility permission.
- For the `stage-layout` CLI: the `hs` command-line tool, and `hs.ipc` loaded in your
  Hammerspoon config (see Install). Install the CLI from the Hammerspoon console with
  `hs.ipc.cliInstall()`.

## Install

Clone the repo anywhere, then add to `~/.hammerspoon/init.lua`:

```lua
require("hs.ipc") -- lets the `hs` CLI (and so `stage-layout`) reach Hammerspoon
dofile(os.getenv("HOME") .. "/path/to/stage-layouts/stage-layouts.lua")
```

Reload Hammerspoon. Optionally put `stage-layout` on your `PATH`:

```bash
ln -s "$PWD/stage-layout" ~/.local/bin/stage-layout
```

## Usage

Hotkeys:

| Keys | Action |
|------|--------|
| ctrl+alt+cmd+S | Save the stages on the Desktop(s) you are looking at, for this display setup |
| ctrl+alt+cmd+R | Rebuild them |

CLI (talks to the running Hammerspoon; results arrive as notifications):

```bash
stage-layout save      # same as ctrl+alt+cmd+S
stage-layout restore   # same as ctrl+alt+cmd+R
stage-layout list      # show what is saved
```

Saving again overwrites only the Desktops you are looking at; other Desktops and display
setups are kept.

Automatic restores (each can be turned off, see Settings):

- after a boot, once login items have opened their windows;
- when the set of connected screens changes;
- after a boot, the first time you visit each Desktop.

Hammerspoon reloads during the day do not rearrange windows.

## Data

Layouts are stored in `~/.config/stage-layouts/layouts.json`, keyed by display setup and
by each Desktop's position on its screen (Space IDs change on restart). Apps whose window
floats over every stage (always-on-top panels) are detected on save and recorded in the
file's `ignoreApps` map (bundle ID to app name); add entries there to leave other apps
alone.

## Settings

Set fields on the global `STAGE_LAYOUTS` table after the `dofile` line, or edit the top of
`stage-layouts.lua`:

| Field | Default | Meaning |
|-------|---------|---------|
| `launchMissing` | `true` | On restore, open saved apps that are not running |
| `launchWait` | `20` | Seconds to wait for launched apps to show a window |
| `retries` / `retryDelay` | `2` / `30` | Extra passes for windows that were not open yet |
| `autoRestoreOnBoot` / `bootDelay` | `true` / `30` | Restore after boot, after this many seconds |
| `autoRestoreOnScreenChange` | `true` | Restore when the connected screens change |
| `autoRestoreOnFirstDesktopVisit` | `true` | After boot, restore each Desktop on first visit |
| `hotkeyMods`, `captureKey`, `restoreKey` | ctrl+alt+cmd, `s`, `r` | Hotkeys |

Debug logging: `STAGE_LAYOUTS.log.setLogLevel("debug")` in the Hammerspoon console.

## Limitations

- Windows cannot be moved between Desktops: `hs.spaces.moveWindowToSpace` is a no-op on
  macOS 26. A window found on the wrong Desktop is reported in the restore notification,
  not moved. Move it yourself, then restore again.
- `hs.window` only sees windows on the current Desktop, so each Desktop is restored when
  you are on it.
