import ApplicationServices
import AppKit

/// What was under the cursor at mouse-up. Captured synchronously (the element often
/// disappears the instant the click is delivered — a menu closes, a window closes).
struct ClickSnapshot {
    var role: String?           // after walking up to a meaningful control
    var hitRole: String?        // what was literally under the cursor
    var subrole: String?
    var title: String?
    var desc: String?
    var help: String?
    var parentRole: String?
    var pid: pid_t = 0
    var appName: String?
    var enabled = true
    var clickCount = 1
    var dragged = false

    var menuKeys: [String]?
    var hasSubmenu = false
    var isDefaultButton = false
    var isCancelButton = false
    var dockPath: String?
    var dockAppRunning = false
    var rowLabel: String?
    var inToolbar = false
    var selectedEverything = false
    var windowIsMain: Bool?     // nil when the click wasn't inside a window
    var windowSubrole: String?
    var isTitleBar = false

    // Kept so a window button's real effect can be checked once the click has landed.
    var window: AXUIElement?
    var windowFrame: CGRect?
    var windowWasFullScreen = false
}

enum ClickInspector {

    // MARK: capture (runs inside the event tap — keep it cheap)

    static func snapshot(at point: CGPoint, dragged: Bool, clickCount: Int) -> ClickSnapshot? {
        guard let hit = AX.element(at: point) else { return nil }

        var s = ClickSnapshot()
        s.dragged = dragged
        s.clickCount = clickCount
        s.hitRole = AX.string(hit, kAXRoleAttribute)

        // The hit element may be an image or label inside the real control.
        var el = hit
        var role = s.hitRole
        var hops = 0
        while hops < 3, let r = role, !interestingRoles.contains(r), let parent = AX.element(el, kAXParentAttribute) {
            el = parent
            role = AX.string(el, kAXRoleAttribute)
            hops += 1
        }

        s.role = role
        s.subrole = AX.string(el, kAXSubroleAttribute)
        s.title = AX.string(el, kAXTitleAttribute)
        s.desc = AX.string(el, kAXDescriptionAttribute)
        s.help = AX.string(el, kAXHelpAttribute)
        s.pid = AX.pid(el)
        s.enabled = AX.bool(el, kAXEnabledAttribute) ?? true
        if let parent = AX.element(el, kAXParentAttribute) {
            s.parentRole = AX.string(parent, kAXRoleAttribute)
        }
        s.appName = NSRunningApplication(processIdentifier: s.pid)?.localizedName

        switch role {
        case kAXMenuItemRole:
            s.menuKeys = AX.menuShortcut(el)
            s.hasSubmenu = AX.children(el).contains { AX.string($0, kAXRoleAttribute) == kAXMenuRole }
            return s // menus live outside windows; nothing else to collect
        case "AXDockItem":
            s.dockPath = (AX.raw(el, kAXURLAttribute) as? URL)?.path
            s.dockAppRunning = AX.bool(el, "AXIsApplicationRunning") ?? false
            return s
        case kAXButtonRole:
            for container in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
                guard let win = AX.element(el, container) else { continue }
                if let def = AX.element(win, kAXDefaultButtonAttribute), CFEqual(def, el) { s.isDefaultButton = true }
                if let cancel = AX.element(win, kAXCancelButtonAttribute), CFEqual(cancel, el) { s.isCancelButton = true }
            }
        case kAXRowRole:
            s.rowLabel = AX.rowLabel(el)
        default:
            break
        }

        if let hitRole = s.hitRole, textRoles.contains(hitRole) {
            s.inToolbar = AX.ancestor(hit, role: kAXToolbarRole, maxHops: 4) != nil
            if dragged { s.selectedEverything = AX.selectionCoversEverything(hit) }
        }

        // Which window did this land in, and was it already the active one?
        if let window = AX.element(el, kAXWindowAttribute) ?? AX.element(el, kAXTopLevelUIElementAttribute) {
            s.window = window
            s.windowIsMain = AX.bool(window, kAXMainAttribute)
            s.windowSubrole = AX.string(window, kAXSubroleAttribute)
            if greenButtonSubroles.contains(s.subrole ?? "") {
                s.windowFrame = AX.frame(window)
                s.windowWasFullScreen = AX.bool(window, "AXFullScreen") ?? false
            } else if s.hitRole == kAXWindowRole, let frame = AX.frame(window) {
                // A click on the title bar hits the window itself rather than any control.
                s.isTitleBar = point.y - frame.minY < 40
            }
        }
        return s
    }

    private static let interestingRoles: Set<String> = [
        kAXMenuItemRole, kAXButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXMenuBarItemRole, "AXDockItem", kAXDisclosureTriangleRole,
        kAXRowRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXWindowRole, "AXTab",
    ]
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    private static let navigationMenus: Set<String> = ["go", "bookmarks", "history", "view", "window", "file"]

    // MARK: analysis (runs off the event tap; may walk whole menu bars)

    static func hint(for s: ClickSnapshot, menus: MenuIndex, frontmostPID: pid_t, allowGuesses: Bool) -> Hint? {
        // 1. A menu item that advertises its own shortcut — the most reliable case by far.
        if s.role == kAXMenuItemRole {
            guard s.enabled, !s.hasSubmenu, let title = s.title else { return nil }
            if let keys = s.menuKeys {
                return Hint(action: title, keys: keys, appName: s.appName)
            }
            // The green button's hover menu ("Tile Window to Left of Screen", "Exit Full
            // Screen") shows no shortcuts, but the same commands live in the Window menu.
            guard let alias = windowCommandAlias(title),
                  let m = menus.lookup(pid: s.pid, titles: [alias, title], menus: ["window", "view"]) else { return nil }
            return Hint(action: title, keys: m.keys, appName: s.appName)
        }

        // 2. Dock.
        if s.role == "AXDockItem" {
            guard !s.dragged else { return nil }
            switch s.dockPath ?? "" {
            case let p where p.hasSuffix("Mission Control.app"):
                return Hint(action: "Mission Control", keys: ["⌃", "↑"])
            case let p where p.hasSuffix("Launchpad.app"):
                return Hint(action: "Launchpad", keys: ["F4"])
            default:
                guard s.subrole == "AXApplicationDockItem", let name = s.title else { return nil }
                return s.dockAppRunning
                    ? Hint(action: "Switch to \(name)", keys: ["⌘", "⇥"], note: "hold ⌘ and tap ⇥ to pick an app")
                    : Hint(action: "Open \(name)", keys: ["⌘", "Space"], note: "then type the app name")
            }
        }

        // 3. Selecting all the text in a field by dragging across it.
        if s.selectedEverything {
            let m = menus.lookup(pid: s.pid, titles: ["Select All"])
            return Hint(action: "Select all", keys: m?.keys ?? ["⌘", "A"], appName: s.appName)
        }

        // Everything below is about a plain click, not a drag.
        guard !s.dragged else { return nil }

        // 4. Window buttons (the traffic lights).
        switch s.subrole {
        case kAXCloseButtonSubrole:
            let m = menus.lookup(pid: s.pid, titles: ["Close Window", "Close Tab", "Close"])
            return Hint(action: m?.title ?? "Close window", keys: m?.keys ?? ["⌘", "W"], appName: s.appName)
        case kAXMinimizeButtonSubrole:
            let m = menus.lookup(pid: s.pid, titles: ["Minimize"])
            return Hint(action: "Minimize", keys: m?.keys ?? ["⌘", "M"],
                        note: "⌥⌘M minimizes every window of the app", appName: s.appName)
        case kAXFullScreenButtonSubrole, "AXZoomButton":
            // Handled by greenButtonHint once the window has actually reacted — the same
            // button fills, zooms or goes full screen depending on the app and on which
            // modifiers were held, so guessing here gets it wrong.
            return nil
        case "AXMenuExtra":
            if (s.desc ?? s.title ?? "").localizedCaseInsensitiveContains("spotlight") {
                return Hint(action: "Spotlight", keys: ["⌘", "Space"])
            }
            return nil
        default:
            break
        }

        // 5. Dialog buttons.
        if s.isDefaultButton { return Hint(action: s.title ?? "Confirm", keys: ["↩"], appName: s.appName) }
        if s.isCancelButton { return Hint(action: s.title ?? "Cancel", keys: ["⎋"], appName: s.appName) }

        // 6. Double-clicking the title bar zooms or fills the window.
        if s.isTitleBar, s.clickCount >= 2 {
            guard let m = menus.lookup(pid: s.pid, titles: ["Fill", "Zoom"], menus: ["window"]) else { return nil }
            return Hint(action: m.title, keys: m.keys, appName: s.appName)
        }

        // 7. Picking a tab with the mouse.
        if s.parentRole == kAXTabGroupRole || s.role == "AXTab" {
            let m = menus.lookup(pid: s.pid, titles: ["Show Next Tab", "Select Next Tab", "Next Tab"])
            return Hint(action: "Switch tab", keys: m?.keys ?? ["⌃", "⇥"],
                        note: "⌘1 … ⌘9 jump straight to a tab", appName: s.appName)
        }

        // 8. Clicking into the address/search field of a toolbar.
        if let hitRole = s.hitRole, textRoles.contains(hitRole), s.inToolbar {
            guard let m = menus.lookup(pid: s.pid, titles: ["Open Location", "Search", "Address Bar", "Find"],
                                       menus: ["file", "edit", "view", "window"]) else { return nil }
            return Hint(action: m.title, keys: m.keys, note: "no need to reach for the field", appName: s.appName)
        }

        // 9. Sidebar rows that are also navigation commands (Finder's Downloads, a browser's Bookmarks…).
        if s.role == kAXRowRole, let label = s.rowLabel, let m = menus.lookup(pid: s.pid, titles: [label], menus: navigationMenus) {
            return Hint(action: m.title, keys: m.keys, appName: s.appName)
        }

        // 10. Any other control whose label matches a menu command in the same app —
        //     covers toolbar buttons like Back, Share, Sidebar.
        if let role = s.role,
           [kAXButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXRadioButtonRole].contains(role) {
            let labels = [s.title, s.desc, s.help].compactMap { $0 }.filter { $0.count > 2 && $0.count < 40 }
            if !labels.isEmpty, let m = menus.lookup(pid: s.pid, titles: labels) {
                return Hint(action: m.title, keys: m.keys, appName: s.appName)
            }
        }

        // 11. Nothing specific matched — but if the click also brought a window forward,
        //     that part of it had a shortcut. Off by default: clicking a window to focus it
        //     is often exactly what you meant to do.
        if allowGuesses, s.windowIsMain == false, s.windowSubrole == kAXStandardWindowSubrole {
            if s.pid != frontmostPID {
                return Hint(action: "Switch to \(s.appName ?? "another app")", keys: ["⌘", "⇥"],
                            note: "hold ⌘ and tap ⇥ to pick an app")
            }
            return Hint(action: "Next window of \(s.appName ?? "this app")", keys: ["⌘", "`"], appName: s.appName)
        }
        return nil
    }

    static let greenButtonSubroles: Set<String> = [kAXFullScreenButtonSubrole, "AXZoomButton"]

    /// Run a beat after the green button was clicked: ask the window what actually
    /// happened to it, then name that. Full screen, Fill and Zoom all live on this button.
    static func greenButtonHint(for s: ClickSnapshot, menus: MenuIndex) -> Hint? {
        guard let window = s.window else { return nil }
        let after = AX.frame(window)
        let screen = after.flatMap(screenFrames(containing:))
        let coversDisplay = (after != nil && screen != nil) ? after!.height >= screen!.display.height - 2 : false
        let isFullScreen = (AX.bool(window, "AXFullScreen") ?? false) || coversDisplay

        if isFullScreen != s.windowWasFullScreen {
            // The menu item has flipped its wording by now, so accept either spelling.
            guard let m = menus.lookup(pid: s.pid, titles: ["Exit Full Screen", "Enter Full Screen", "Full Screen"],
                                       menus: ["window", "view"]) else { return nil }
            return Hint(action: isFullScreen ? "Enter full screen" : "Leave full screen",
                        keys: m.keys, appName: s.appName)
        }

        // Not a full screen toggle, so the window was resized in place.
        guard let after, let screen, let before = s.windowFrame,
              let tile = tileTitle(before: before, after: after, screen: screen.visible),
              let m = menus.lookup(pid: s.pid, titles: [tile, "Zoom"], menus: ["window"]) else { return nil }
        return Hint(action: "Move & Resize ▸ \(m.title)", keys: m.keys, appName: s.appName)
    }

    /// Screen rectangles in Accessibility coordinates (origin top left) for the display a
    /// window sits on: `visible` excludes the menu bar and Dock, `display` is the whole screen.
    static func screenFrames(containing frame: CGRect) -> (visible: CGRect, display: CGRect)? {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else { return nil }
        let flip = primary.frame.height
        func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: flip - r.maxY, width: r.width, height: r.height) }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        for screen in screens {
            let display = toAX(screen.frame)
            if display.insetBy(dx: -2, dy: -2).contains(center) {
                return (toAX(screen.visibleFrame), display)
            }
        }
        return nil
    }

    /// "Tile Window to Left of Screen" is the Window menu's "Left". Maps the wordy titles
    /// from the green button's hover menu onto the short ones that carry the shortcuts.
    static func windowCommandAlias(_ title: String) -> String? {
        var t = title
        for prefix in ["Tile Window to ", "Move Window to ", "Tile Window ", "Move to "] {
            if t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        }
        for suffix in [" Side of Screen", " of Screen", " Half of Screen", " Corner of Screen"] {
            if t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        }
        return t == title ? title : t
    }

    // MARK: window tiling

    /// Classifies what a window drag ended up doing, by comparing its frame to the screen.
    static func tileTitle(before: CGRect, after: CGRect, screen: CGRect) -> String? {
        guard abs(after.width - before.width) > 8 || abs(after.height - before.height) > 8 else { return nil }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < max(12, b * 0.08) }

        let fullWidth = near(after.width, screen.width), halfWidth = near(after.width, screen.width / 2)
        let fullHeight = near(after.height, screen.height), halfHeight = near(after.height, screen.height / 2)
        let left = near(after.minX, screen.minX), top = near(after.minY, screen.minY)

        switch (fullWidth, halfWidth, fullHeight, halfHeight) {
        case (true, _, true, _): return "Fill"
        case (_, true, true, _): return left ? "Left" : "Right"
        case (true, _, _, true): return top ? "Top" : "Bottom"
        case (_, true, _, true):
            switch (left, top) {
            case (true, true): return "Top Left"
            case (false, true): return "Top Right"
            case (true, false): return "Bottom Left"
            case (false, false): return "Bottom Right"
            }
        default: return nil
        }
    }
}
