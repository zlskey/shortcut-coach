import AppKit

enum HUDPosition: String, CaseIterable {
    case bottomCenter, topCenter, nearCursor, topRight

    var label: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .nearCursor: return "Near the cursor"
        case .topRight: return "Top right"
        }
    }
}

/// A single reusable, click-through overlay panel.
final class HUD {
    static let shared = HUD()

    var position: HUDPosition = .bottomCenter
    private var panel: NSPanel?
    private var stack: NSStackView?
    private var hideWork: DispatchWorkItem?

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = blur
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: blur.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -14),
        ])
        self.stack = stack
        return panel
    }

    func show(_ hint: Hint, duration: TimeInterval = 2.8) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let stack else { return }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(caption("You clicked"))
        text.addArrangedSubview(title(hint.action))
        if let note = hint.note { text.addArrangedSubview(caption(note)) }
        stack.addArrangedSubview(text)

        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.spacing = 4
        hint.keys.forEach { keys.addArrangedSubview(KeyCap(($0))) }
        stack.addArrangedSubview(keys)

        panel.layoutIfNeeded()
        var size = stack.fittingSize
        size.width += 36; size.height += 28
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))

        hideWork?.cancel()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            if panel?.alphaValue == 0 { panel?.orderOut(nil) }
        })
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        switch position {
        case .bottomCenter:
            return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90)
        case .topCenter:
            return NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 20)
        case .topRight:
            return NSPoint(x: frame.maxX - size.width - 20, y: frame.maxY - size.height - 20)
        case .nearCursor:
            let x = min(max(frame.minX + 10, mouse.x - size.width / 2), frame.maxX - size.width - 10)
            let y = min(max(frame.minY + 10, mouse.y - size.height - 28), frame.maxY - size.height - 10)
            return NSPoint(x: x, y: y)
        }
    }

    private func caption(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func title(_ s: String) -> NSTextField {
        let label = NSTextField(labelWithString: s)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }
}

/// A rounded key cap, e.g. ⌘ or "Space".
final class KeyCap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: text.count > 1 ? 14 : 18, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 18),
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
