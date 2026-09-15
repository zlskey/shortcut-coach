import AppKit
import ApplicationServices

/// Debugging aid: writes every running app's menu shortcuts, exactly as the Accessibility
/// API reports them, plus the window buttons of each app's front window. Useful when a
/// hint is wrong or missing and you need to see what the system actually says.
enum MenuDump {
    static let path = URL(fileURLWithPath: "/tmp/shortcutcoach-menus.txt")

    static func write() -> URL? {
        var out: [String] = ["Shortcut Coach menu dump — \(Date())"]

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName else { continue }
            out.append("\n=== \(name) (pid \(app.processIdentifier)) ===")

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 2.0)

            if let window = (AX.raw(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first {
                out.append("--- front window buttons ---")
                for child in AX.children(window) where AX.string(child, kAXRoleAttribute) == kAXButtonRole {
                    let subrole = AX.string(child, kAXSubroleAttribute) ?? "-"
                    let desc = AX.string(child, kAXDescriptionAttribute) ?? "-"
                    out.append("  \(subrole)  description=\(desc)")
                }
            }

            guard let bar = AX.element(axApp, kAXMenuBarAttribute) else {
                out.append("  (no menu bar)")
                continue
            }
            out.append("--- menus ---")
            walk(bar, depth: 0, into: &out)
        }

        let text = out.joined(separator: "\n")
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            Log.always("menu dump failed: \(error)")
            return nil
        }
    }

    private static func walk(_ element: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 6 else { return }
        for child in AX.children(element) {
            if AX.string(child, kAXRoleAttribute) == kAXMenuItemRole, let title = AX.string(child, kAXTitleAttribute) {
                let indent = String(repeating: "  ", count: depth)
                let cmdChar = AX.string(child, "AXMenuItemCmdChar")
                let modifiers = AX.int(child, "AXMenuItemCmdModifiers")
                let glyph = AX.int(child, "AXMenuItemCmdGlyph")
                let virtualKey = AX.int(child, "AXMenuItemCmdVirtualKey")
                let keys = AX.menuShortcut(child)

                if cmdChar != nil || glyph != nil || virtualKey != nil {
                    let raw = cmdChar.map { c in
                        c.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()
                    } ?? "-"
                    out.append("\(indent)\(title)  [char=\(raw) mods=\(modifiers.map(String.init) ?? "-") "
                               + "glyph=\(glyph.map(String.init) ?? "-") vk=\(virtualKey.map(String.init) ?? "-")] "
                               + "→ \(keys?.joined() ?? "none")")
                } else {
                    out.append("\(indent)\(title)")
                }
            }
            walk(child, depth: depth + 1, into: &out)
        }
    }
}
