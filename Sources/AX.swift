import ApplicationServices
import AppKit

/// Thin helpers over the C Accessibility API.
enum AX {
    static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.15) // never stall the mouse for long
        return el
    }()

    static func element(at point: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el)
        guard err == .success, let el else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }

    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let s = raw(el, attr) as? String, !s.isEmpty else { return nil }
        return s
    }

    static func int(_ el: AXUIElement, _ attr: String) -> Int? {
        (raw(el, attr) as? NSNumber)?.intValue
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        (raw(el, attr) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (raw(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return pid
    }

    /// Screen frame in Accessibility coordinates (origin top left, y growing downwards).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posValue = raw(el, kAXPositionAttribute), let sizeValue = raw(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func ancestor(_ el: AXUIElement, role: String, maxHops: Int = 6) -> AXUIElement? {
        var current = el
        for _ in 0..<maxHops {
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == role { return parent }
            current = parent
        }
        return nil
    }

    /// The visible label of a table/outline row (rows themselves have no title).
    static func rowLabel(_ row: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        for child in children(row) {
            if string(child, kAXRoleAttribute) == kAXStaticTextRole,
               let value = raw(child, kAXValueAttribute) as? String, !value.isEmpty {
                return value
            }
            if let nested = rowLabel(child, depth: depth + 1) { return nested }
        }
        return nil
    }

    /// True when the element's entire text is selected (a "select all" done by dragging).
    static func selectionCoversEverything(_ el: AXUIElement) -> Bool {
        guard let total = int(el, kAXNumberOfCharactersAttribute), total > 40,
              let rangeValue = raw(el, kAXSelectedTextRangeAttribute) else { return false }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return false }
        return range.length >= total
    }

    static func menuShortcut(_ item: AXUIElement) -> [String]? {
        KeyFormatter.keys(
            cmdChar: string(item, "AXMenuItemCmdChar"),
            virtualKey: int(item, "AXMenuItemCmdVirtualKey"),
            glyph: int(item, "AXMenuItemCmdGlyph"),
            modifiers: int(item, "AXMenuItemCmdModifiers"))
    }
}

struct MenuCommand {
    var title: String
    var keys: [String]
    var menu: String   // the top level menu it lives in, e.g. "Window"
}

/// Walks an app's menu bar and indexes every item that has a shortcut, by normalized title.
/// Used to answer "the toolbar button you clicked is also File ▸ X, which is ⌘X".
final class MenuIndex {
    private var cache: [pid_t: (date: Date, items: [String: [MenuCommand]])] = [:]
    private let lock = NSLock()

    /// `menus` restricts the search to those top level menus (normalized), which keeps
    /// loose matches — a sidebar row, a toolbar field — from hitting unrelated commands.
    func lookup(pid: pid_t, titles: [String], menus: Set<String>? = nil) -> MenuCommand? {
        let items = index(for: pid)
        for title in titles {
            guard let matches = items[KeyFormatter.normalize(title)] else { continue }
            if let menus {
                if let hit = matches.first(where: { menus.contains(KeyFormatter.normalize($0.menu)) }) { return hit }
            } else if let hit = matches.first {
                return hit
            }
        }
        return nil
    }

    private func index(for pid: pid_t) -> [String: [MenuCommand]] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[pid], Date().timeIntervalSince(c.date) < 30 { return c.items }

        var items: [String: [MenuCommand]] = [:]
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if let bar = AX.element(app, kAXMenuBarAttribute) {
            var visited = 0
            func walk(_ el: AXUIElement, depth: Int, menu: String) {
                guard depth < 5, visited < 3000 else { return }
                for child in AX.children(el) {
                    visited += 1
                    let title = AX.string(child, kAXTitleAttribute)
                    if depth == 0 {
                        walk(child, depth: depth + 1, menu: title ?? "")
                        continue
                    }
                    if AX.string(child, kAXRoleAttribute) == kAXMenuItemRole,
                       let title, let keys = AX.menuShortcut(child) {
                        items[KeyFormatter.normalize(title), default: []]
                            .append(MenuCommand(title: title, keys: keys, menu: menu))
                    }
                    walk(child, depth: depth + 1, menu: menu)
                }
            }
            walk(bar, depth: 0, menu: "")
        }
        cache[pid] = (Date(), items)
        return items
    }
}
