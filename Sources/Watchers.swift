import AppKit
import ApplicationServices

/// Notices when a burst of scrolling ends at the very top or very bottom of a view —
/// the classic "I scrolled for ten seconds instead of pressing ⌘↑".
final class ScrollWatcher {
    var onHint: ((Hint) -> Void)?

    private let queue = DispatchQueue(label: "ShortcutCoach.Scroll", qos: .utility)
    private var lastScroll = Date.distantPast
    private var area: AXUIElement?
    private var startFraction: Double?
    private var endWork: DispatchWorkItem?

    func scrolled(at point: CGPoint) {
        queue.async { [self] in
            let now = Date()
            if now.timeIntervalSince(lastScroll) > 0.6 {   // a new burst
                area = Self.scrollArea(at: point)
                startFraction = area.flatMap(Self.verticalFraction)
            }
            lastScroll = now

            endWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            endWork = work
            queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private func finish() {
        defer { area = nil; startFraction = nil }
        guard let area, let start = startFraction, let end = Self.verticalFraction(area) else { return }
        if start > 0.2, end <= 0.002 {
            onHint?(Hint(action: "Jump to the top", keys: ["⌘", "↑"], note: "↖ Home does it too"))
        } else if start < 0.8, end >= 0.998 {
            onHint?(Hint(action: "Jump to the bottom", keys: ["⌘", "↓"], note: "↘ End does it too"))
        }
    }

    private static func scrollArea(at point: CGPoint) -> AXUIElement? {
        guard let hit = AX.element(at: point) else { return nil }
        if AX.string(hit, kAXRoleAttribute) == kAXScrollAreaRole { return hit }
        return AX.ancestor(hit, role: kAXScrollAreaRole, maxHops: 8)
    }

    /// 0 = scrolled to the top, 1 = scrolled to the bottom.
    private static func verticalFraction(_ area: AXUIElement) -> Double? {
        guard let bar = AX.element(area, kAXVerticalScrollBarAttribute),
              let value = (AX.raw(bar, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
        return value
    }
}

/// Notices a window being dragged into one of macOS's tiled positions.
final class WindowDragWatcher {
    var onHint: ((Hint) -> Void)?

    private let menus: MenuIndex
    private let queue = DispatchQueue(label: "ShortcutCoach.WindowDrag", qos: .utility)
    private var window: AXUIElement?
    private var frameBefore: CGRect?
    private var pid: pid_t = 0

    init(menus: MenuIndex) { self.menus = menus }

    func mouseDown(at point: CGPoint) {
        queue.async { [self] in
            window = nil; frameBefore = nil
            guard let hit = AX.element(at: point), AX.string(hit, kAXRoleAttribute) == kAXWindowRole,
                  let frame = AX.frame(hit), point.y - frame.minY < 40 else { return }
            window = hit
            frameBefore = frame
            pid = AX.pid(hit)
        }
    }

    func mouseUp(dragged: Bool) {
        queue.asyncAfter(deadline: .now() + 0.7) { [self] in   // let the tiling animation settle
            defer { window = nil; frameBefore = nil }
            guard dragged, let window, let before = frameBefore, let after = AX.frame(window) else { return }
            guard let screen = ClickInspector.screenFrames(containing: after)?.visible,
                  let tile = ClickInspector.tileTitle(before: before, after: after, screen: screen),
                  let command = menus.lookup(pid: pid, titles: [tile], menus: ["window"]) else { return }
            onHint?(Hint(action: "Move & Resize ▸ \(command.title)", keys: command.keys,
                         appName: NSRunningApplication(processIdentifier: pid)?.localizedName))
        }
    }

}
