import AppKit

/// Session-wide event tap on its own thread. It never modifies events — it only looks.
final class EventMonitor {
    /// All called off the main thread, on the tap thread — keep the work tiny.
    var onClick: ((ClickSnapshot) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onScroll: ((CGPoint) -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private let state = NSLock()
    private var downPoint: CGPoint = .zero
    private var _lastMouseActivity = Date.distantPast
    private var _mouseIsDown = false
    private var _lastVolumeKey = Date.distantPast

    var mouseLikelyResponsible: Bool {
        state.lock(); defer { state.unlock() }
        return _mouseIsDown || Date().timeIntervalSince(_lastMouseActivity) < 2.5
    }
    var volumeKeyUsedRecently: Bool {
        state.lock(); defer { state.unlock() }
        return Date().timeIntervalSince(_lastVolumeKey) < 2.0
    }

    private static let systemDefined = CGEventType(rawValue: 14)!

    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << 14) // NX_SYSDEFINED — media keys

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { proxy, type, event, refcon in
                                              guard let refcon else { return Unmanaged.passUnretained(event) }
                                              let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                                              return monitor.handle(proxy: proxy, type: type, event: event)
                                          },
                                          userInfo: refcon)
        else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        isRunning = true

        let thread = Thread { [weak self] in
            guard let self, let source = self.source else { return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "ShortcutCoach.EventTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        thread?.cancel()
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        thread = nil; source = nil; tap = nil; runLoop = nil
    }

    // MARK: tap callback (hot path — the whole system waits on this)

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }

        switch type {
        case .leftMouseDown:
            state.lock(); downPoint = event.location; _mouseIsDown = true; _lastMouseActivity = Date(); state.unlock()
            onMouseDown?(event.location)

        case .leftMouseDragged:
            state.lock(); _lastMouseActivity = Date(); state.unlock()

        case .scrollWheel:
            state.lock(); _lastMouseActivity = Date(); state.unlock()
            onScroll?(event.location)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let location = event.location
            state.lock()
            let start = downPoint
            _mouseIsDown = false
            _lastMouseActivity = Date()
            state.unlock()
            let dragged = type == .leftMouseUp && hypot(location.x - start.x, location.y - start.y) > 8
            let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
            if let snapshot = ClickInspector.snapshot(at: location, dragged: dragged, clickCount: clicks) {
                onClick?(snapshot)
            }

        case Self.systemDefined:
            if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
                let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
                // NX_KEYTYPE_SOUND_UP / _DOWN / _MUTE
                if keyCode == 0 || keyCode == 1 || keyCode == 7 {
                    state.lock(); _lastVolumeKey = Date(); state.unlock()
                }
            }

        default:
            break
        }
        return passthrough
    }
}
