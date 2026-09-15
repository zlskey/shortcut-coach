# Shortcut Coach

A menu bar app that watches what you do with the mouse and, when the same thing has a
keyboard shortcut, flashes the shortcut on screen. Like Key Promoter X, but for all of macOS.

## Build & run

```bash
./build.sh && open build/ShortcutCoach.app
```

Then grant **System Settings ▸ Privacy & Security ▸ Accessibility** to Shortcut Coach.
Nothing works without it: the app reads the clicked control through the Accessibility API
and listens for clicks through a session event tap.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and you have to
re-grant Accessibility (remove the old entry with "−", add the new build). To avoid that,
sign with a stable identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
```

## What it detects

| You did this with the mouse | Where the shortcut comes from |
| --- | --- |
| Picked any menu bar or right-click menu item | the menu item itself (`AXMenuItemCmdChar` + modifiers) — exact, in any app, any language |
| Clicked a toolbar or window button whose label matches a menu command (Back, Share, Sidebar…) | that app's menu bar, matched by label |
| Closed / minimized / full-screened a window (traffic lights) | the app's Close / Minimize / Enter Full Screen items, falling back to ⌘W, ⌘M, ⌃⌘F |
| Clicked OK / Cancel in a dialog | the window's default and cancel buttons → ↩ and ⎋ |
| Clicked a Dock app, Mission Control, Launchpad | ⌘⇥, ⌘Space, ⌃↑, F4 |
| Dragged the volume slider in Control Center | CoreAudio volume/mute changes that no volume key caused → F10/F11/F12 |
| Clicked Spotlight in the menu bar | ⌘Space |

Hints are deduplicated (3 s), counted, and each one can be muted from the menu bar item,
which also shows your top 10 most-missed shortcuts.

## Architecture

- `EventMonitor` — `CGEvent.tapCreate` session tap on a dedicated thread. Passive: every
  event is passed through untouched. On mouse-up it grabs a snapshot **synchronously**,
  because a clicked menu item stops existing the moment the click is delivered.
- `ClickInspector` — snapshot capture (cheap AX reads, 0.15 s messaging timeout) and,
  off the hot path, the rules that turn a snapshot into a hint.
- `MenuIndex` — walks an app's whole menu bar and indexes titles → shortcuts, cached 30 s
  per process, used for the "this button is also a menu command" matches.
- `VolumeMonitor` — CoreAudio property listeners on the default output device.
- `HUD` — one reusable click-through `NSPanel` with key caps.
- `HintCenter` — dedupe, stats, mute list (`UserDefaults`).

## Known limits

- Brightness and keyboard-backlight sliders have no public API to observe. Not detected.
- Actions with no menu equivalent and no label match (dragging a window to tile it,
  scrolling, resizing) are not detected.
- A toolbar button whose tooltip differs from its menu wording won't match; add aliases in
  `ClickInspector.hint(for:)` if you hit a common one.
