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
    private var _lastClick = Date.distantPast
    private var _mouseIsDown = false
    private var _lastVolumeKey = Date.distantPast
    private var _lastKey = Date.distantPast
    private var _lastGesture = Date.distantPast

    /// For changes that arrive without a click of their own — volume, Spaces, launches —
    /// this is the test for "the mouse did it". A trackpad gesture or a keystroke in the
    /// recent past means it almost certainly wasn't.
    var mouseLikelyResponsible: Bool {
        state.lock(); defer { state.unlock() }
        let now = Date()
        guard _mouseIsDown || now.timeIntervalSince(_lastClick) < 1.2 else { return false }
        return now.timeIntervalSince(_lastKey) > 1.5 && now.timeIntervalSince(_lastGesture) > 2.0
    }

    var volumeKeyUsedRecently: Bool {
        state.lock(); defer { state.unlock() }
        return Date().timeIntervalSince(_lastVolumeKey) < 2.0
    }

    private static let systemDefined = CGEventType(rawValue: 14)!
    /// NSEvent gesture types (gesture, magnify, swipe, smart magnify). Not in CGEventType,
    /// but they do flow through a session tap.
    private static let gestureTypes: ClosedRange<UInt32> = 29...32

    func start() -> Bool {
        guard !isRunning else { return true }
        let mouseAndGestures: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << 14) |                                   // NX_SYSDEFINED — media keys
            (29...32).reduce(0) { $0 | (1 << $1) }         // trackpad gestures
        let withKeys = mouseAndGestures | (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        // Keyboard events may need Input Monitoring on top of Accessibility; if the tap is
        // refused, fall back to watching the mouse only rather than watching nothing.
        let tapOrNil = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: withKeys,
                                         callback: callback, userInfo: refcon)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                 options: .defaultTap, eventsOfInterest: mouseAndGestures,
                                 callback: callback, userInfo: refcon)
        guard let tap = tapOrNil else { return false }

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

        if Self.gestureTypes.contains(type.rawValue) {
            state.lock(); _lastGesture = Date(); state.unlock()
            return passthrough
        }

        switch type {
        case .leftMouseDown:
            state.lock(); downPoint = event.location; _mouseIsDown = true; _lastClick = Date(); state.unlock()
            onMouseDown?(event.location)

        case .leftMouseDragged:
            break

        case .keyDown:
            state.lock(); _lastKey = Date(); state.unlock()

        case .scrollWheel:
            onScroll?(event.location)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let location = event.location
            state.lock()
            let start = downPoint
            _mouseIsDown = false
            _lastClick = Date()
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
