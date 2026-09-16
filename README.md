# Shortcut Coach

A macOS menu bar app that watches what you do with the mouse and, whenever the same thing
has a keyboard shortcut, flashes the shortcut on screen.

```
┌───────────────────────────────────────────────┐
│  You clicked                                  │
│  New Folder                        ⇧   ⌘   N  │
└───────────────────────────────────────────────┘
```

[Key Promoter X](https://github.com/halirutan/IntelliJ-Key-Promoter-X) does this inside
JetBrains IDEs. Shortcut Coach does it for the whole system: menus, toolbars, the Dock,
window buttons, Finder's sidebar, the volume slider.

## Install

Grab `ShortcutCoach.zip` from [Releases](../../releases), unzip, and move
**ShortcutCoach.app** to `/Applications`. The release build is ad-hoc signed and not
notarized, so clear the download quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/ShortcutCoach.app
```

Or build it yourself (needs Xcode's Swift toolchain, macOS 13+):

```bash
./build.sh && open build/ShortcutCoach.app
```

Then grant **System Settings ▸ Privacy & Security ▸ Accessibility**. Nothing works without
it — that permission is what lets the app see clicks and ask the system what you clicked on.

> **Rebuilding?** macOS ties the Accessibility grant to the app's signature, so an ad-hoc
> build is a new app every time and has to be re-approved. Sign with a stable identity to
> keep the permission: `SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh`

## Privacy

The app reads the control you clicked, the frontmost app's menu bar, and the system volume.
It has no network code of any kind. The only thing written to disk is a count per hint
(`"Copy ⌘C — 14 times"`) in `UserDefaults`, so the menu can show your most-missed shortcuts.
No text you type, no window contents, no history.

## What it detects

| You did this with the mouse | The hint | How it's worked out |
| --- | --- | --- |
| Picked any menu bar or right-click menu item | that item's shortcut | the menu item itself (`AXMenuItemCmdChar` + modifier bits) — exact, in every app and every language |
| Clicked a toolbar button that mirrors a menu command (Back, Share, Sidebar…) | that command's shortcut | label matched against the app's menu bar |
| Closed, minimized or full-screened a window | ⌘W, ⌘M, ⌃⌘F | the app's own Close / Minimize / Enter Full Screen items, with those as fallbacks |
| Clicked OK or Cancel in a dialog | ↩ / ⎋ | the window's default and cancel buttons |
| Double-clicked a title bar | Zoom / Fill | Window ▸ Move & Resize |
| Dragged a window to a screen edge to tile it | the real tiling shortcut | window frame before/after the drag, classified against the screen |
| Clicked a Dock app, Mission Control, Launchpad | ⌘⇥, ⌘Space, ⌃↑, F4 | Dock item role and URL |
| Clicked a background window *(off by default)* | ⌘⇥ or ⌘\` | the window's `AXMain` was false at the moment of the click |
| Clicked a tab | ⌃⇥, ⌘1–9 | parent is a tab group |
| Clicked into a toolbar search or address field | ⌘L / ⌘F | text field with a toolbar ancestor |
| Clicked Finder's sidebar (Downloads, Applications…) | ⌥⌘L, ⇧⌘A… | row label matched against navigation menus only |
| Dragged across a field to select all its text | ⌘A | selection length equals the character count |
| Scrolled all the way to the top or bottom | ⌘↑ / ⌘↓ | scrollbar hit 0.0 or 1.0 at the end of a scroll burst |
| Dragged the volume slider in Control Center | F10 / F11 / F12 | a CoreAudio volume change that no volume key caused |
| Switched Space by clicking in Mission Control *(off by default)* | ⌃← / ⌃→ | Space-changed notification while the mouse was busy |
| Hunted for an app icon to launch it *(off by default)* | ⌘Space | app-launched notification while the mouse was busy |

Three of those rows have no click of their own to inspect — they're inferred from a system
notification plus recent mouse activity, so they can misfire when you did the same thing
with a gesture or a shortcut. They're off until you turn on **"Also guess at Spaces,
launches and window focus"** in the menu. The inference is also guarded: a trackpad gesture
in the last 2 seconds, or a keystroke in the last 1.5, means the mouse didn't do it.

Most hints are read from the app's own menus rather than hardcoded, so they stay correct in
non-English systems, in apps with custom shortcuts, and across macOS versions.

Hints are deduplicated for 3 seconds and counted. The menu bar item lists your ten
most-missed shortcuts and lets you mute any of them individually — worth doing for the
last few rows above, which fire on things you sometimes genuinely mean to do by hand.

## How it works

| File | Role |
| --- | --- |
| [`EventMonitor.swift`](Sources/EventMonitor.swift) | `CGEvent.tapCreate` session tap on a dedicated thread. Passive: every event is passed through untouched. |
| [`ClickInspector.swift`](Sources/ClickInspector.swift) | Snapshot capture and the rules that turn a snapshot into a hint. |
| [`AX.swift`](Sources/AX.swift) | Accessibility helpers, plus the per-app menu index. |
| [`Watchers.swift`](Sources/Watchers.swift) | Scroll bursts and window-drag tiling. |
| [`VolumeMonitor.swift`](Sources/VolumeMonitor.swift) | CoreAudio volume and mute listeners. |
| [`HUD.swift`](Sources/HUD.swift) | One reusable click-through `NSPanel` with key caps. |
| [`HintCenter.swift`](Sources/HintCenter.swift) | Deduplication, stats, mute list. |

Two details do most of the work.

**The clicked element is captured synchronously, inside the event tap.** A menu item stops
existing the moment the click reaches the app, so the snapshot has to be taken while the
event is still in flight. Everything expensive — walking an app's menu bar, matching
labels — happens afterwards on a background queue.

**The shortcuts are not a lookup table.** macOS already tells you: every menu item exposes
its own key equivalent through the Accessibility API. Toolbar buttons, sidebar rows and
window buttons are resolved by finding the matching command in the same app's menus, so the
app knows Safari's Back button is ⌘[ without knowing anything about Safari.

## Limitations

- Brightness and keyboard-backlight sliders can't be observed through any public API.
- Actions with no menu equivalent and no matching label — resizing a window, dragging a file —
  have no shortcut to suggest, and aren't detected.
- A toolbar button whose tooltip is worded differently from its menu command won't match.
  Add aliases in `ClickInspector.hint(for:)` if you hit a common one.

## Ideas worth building

- Watch the keyboard too, and auto-mute a hint once you've actually used that shortcut a
  few times, so the app stops nagging about what you've already learned.
- A weekly summary: which habits cost you the most keystrokes.
- Pinch-to-zoom → ⌘+ / ⌘−.

## License

MIT
