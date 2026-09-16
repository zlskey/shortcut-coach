import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = EventMonitor()
    private let volume = VolumeMonitor()
    private let menus = MenuIndex()
    private let analysis = DispatchQueue(label: "ShortcutCoach.Analysis", qos: .utility)
    private var permissionTimer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private lazy var scrolls = ScrollWatcher()
    private lazy var drags = WindowDragWatcher(menus: menus)

    private let frontLock = NSLock()
    private var _frontmostPID: pid_t = 0
    private var frontmostPID: pid_t {
        get { frontLock.lock(); defer { frontLock.unlock() }; return _frontmostPID }
        set { frontLock.lock(); _frontmostPID = newValue; frontLock.unlock() }
    }
    private var lastDockClick = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUD.shared.position = HUDPosition(rawValue: UserDefaults.standard.string(forKey: "hudPosition") ?? "")
            ?? .bottomCenter

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Shortcut Coach")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onClick = { [weak self] snapshot in self?.handle(snapshot) }
        monitor.onMouseDown = { [weak self] point in self?.drags.mouseDown(at: point) }
        monitor.onScroll = { [weak self] point in self?.scrolls.scrolled(at: point) }
        volume.onChange = { [weak self] change in self?.handle(change) }
        scrolls.onHint = { HintCenter.shared.offer($0) }
        drags.onHint = { HintCenter.shared.offer($0) }
        volume.start()
        observeWorkspace()

        Log.always("launched from \(Bundle.main.bundlePath); accessibility=\(AXIsProcessTrusted())")
        if AXIsProcessTrusted() {
            startMonitoring()
        } else {
            requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    // MARK: permissions

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        updateStatusIcon(trusted: false)
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.startMonitoring()
        }
    }

    private func startMonitoring() {
        updateStatusIcon(trusted: true)
        guard monitor.start() else {
            Log.always("event tap refused — Accessibility is granted to a different copy of the app?")
            updateStatusIcon(trusted: false)
            return
        }
        Log.always("watching: accessibility granted, event tap running")
    }

    private func updateStatusIcon(trusted: Bool) {
        let name = trusted ? "command" : "exclamationmark.triangle"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Shortcut Coach")
        statusItem.button?.image?.isTemplate = true
    }

    // MARK: events

    private func handle(_ snapshot: ClickSnapshot) {
        drags.mouseUp(dragged: snapshot.dragged)
        guard snapshot.pid != ownPID, HintCenter.shared.isEnabled else { return }
        if snapshot.role == "AXDockItem" { lastDockClick = Date() }
        if !snapshot.dragged, ClickInspector.greenButtonSubroles.contains(snapshot.subrole ?? "") {
            analysis.asyncAfter(deadline: .now() + 0.8) { [menus] in   // let the window react first
                guard let hint = ClickInspector.greenButtonHint(for: snapshot, menus: menus) else { return }
                HintCenter.shared.offer(hint)
            }
            return
        }

        let front = frontmostPID
        let allowGuesses = HintCenter.shared.guessesEnabled
        analysis.async { [menus] in
            let hint = ClickInspector.hint(for: snapshot, menus: menus, frontmostPID: front, allowGuesses: allowGuesses)
            Log.trace("""
                click role=\(snapshot.role ?? "-") subrole=\(snapshot.subrole ?? "-") \
                title=\(snapshot.title ?? "-") app=\(snapshot.appName ?? "-") \
                → \(hint.map { "\($0.action) \($0.keysText)" } ?? "no hint")
                """)
            guard let hint else { return }
            HintCenter.shared.offer(hint)
        }
    }

    /// Two things worth hinting that produce no click of their own: switching Space by
    /// clicking around in Mission Control, and launching an app by hunting for its icon.
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostPID = app?.processIdentifier ?? 0
        }

        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, HintCenter.shared.guessesEnabled, self.monitor.mouseLikelyResponsible else { return }
            HintCenter.shared.offer(Hint(action: "Switch Spaces", keys: ["⌃", "→"],
                                         note: "⌃← and ⌃→ move between Spaces"))
        }

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, HintCenter.shared.guessesEnabled, self.monitor.mouseLikelyResponsible,
                  Date().timeIntervalSince(self.lastDockClick) > 3,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, let name = app.localizedName else { return }
            HintCenter.shared.offer(Hint(action: "Open \(name)", keys: ["⌘", "Space"],
                                         note: "Spotlight launches anything in two keystrokes"))
        }
    }

    private func handle(_ change: VolumeMonitor.Change) {
        guard HintCenter.shared.isEnabled,
              !monitor.volumeKeyUsedRecently,
              monitor.mouseLikelyResponsible else { return }
        let hint: Hint
        switch change {
        case .up:
            hint = Hint(action: "Volume up", keys: ["F12"], note: "hold ⇧⌥ for quarter steps")
        case .down:
            hint = Hint(action: "Volume down", keys: ["F11"], note: "hold ⇧⌥ for quarter steps")
        case .muteToggled:
            hint = Hint(action: "Mute", keys: ["F10"])
        }
        HintCenter.shared.offer(hint)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let center = HintCenter.shared
        let trusted = AXIsProcessTrusted()

        let status = "Accessibility: \(trusted ? "granted" : "NOT granted") · watching: \(monitor.isRunning ? "yes" : "no")"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        if !trusted || !monitor.isRunning {
            let item = NSMenuItem(title: "Open Accessibility settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let retry = NSMenuItem(title: "Retry now", action: #selector(retryMonitoring), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show hints", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = center.isEnabled ? .on : .off
        menu.addItem(toggle)

        let guesses = NSMenuItem(title: "Also guess at Spaces, launches and window focus",
                                 action: #selector(toggleGuesses), keyEquivalent: "")
        guesses.target = self
        guesses.state = center.guessesEnabled ? .on : .off
        guesses.toolTip = "These have no click of their own to inspect, so they are inferred and can misfire."
        menu.addItem(guesses)

        let positionItem = NSMenuItem(title: "Hint position", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        for position in HUDPosition.allCases {
            let item = NSMenuItem(title: position.label, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            item.state = HUD.shared.position == position ? .on : .off
            positionMenu.addItem(item)
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        let launch = NSMenuItem(title: "Open at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let top = center.stats.sorted { $0.value.count > $1.value.count }.prefix(10)
        if top.isEmpty {
            menu.addItem(NSMenuItem(title: "No missed shortcuts yet", action: nil, keyEquivalent: ""))
        } else {
            let total = center.stats.values.reduce(0) { $0 + $1.count }
            menu.addItem(NSMenuItem(title: "Missed \(total) time\(total == 1 ? "" : "s") — click to mute", action: nil, keyEquivalent: ""))
            let muted = center.muted
            for (id, stat) in top {
                let title = "\(stat.count)×  \(stat.action)  \(stat.keys.joined())"
                let item = NSMenuItem(title: title, action: #selector(toggleMute(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = muted.contains(id) ? .off : .on
                menu.addItem(item)
            }
            let reset = NSMenuItem(title: "Reset statistics", action: #selector(resetStats), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }

        menu.addItem(.separator())
        let test = NSMenuItem(title: "Show a sample hint", action: #selector(showSample), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let dump = NSMenuItem(title: "Dump menu shortcuts (debug)", action: #selector(dumpMenus), keyEquivalent: "")
        dump.target = self
        menu.addItem(dump)
        let quit = NSMenuItem(title: "Quit Shortcut Coach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        HintCenter.shared.isEnabled.toggle()
        if !HintCenter.shared.isEnabled { HUD.shared.hide() }
    }

    @objc private func toggleGuesses() {
        HintCenter.shared.guessesEnabled.toggle()
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = HUDPosition(rawValue: raw) else { return }
        HUD.shared.position = position
        UserDefaults.standard.set(raw, forKey: "hudPosition")
        HUD.shared.show(Hint(action: "Hints will appear here", keys: ["⌘", "K"]), duration: 1.4)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        HintCenter.shared.toggleMute(id)
    }

    @objc private func resetStats() { HintCenter.shared.resetStats() }

    @objc private func retryMonitoring() {
        monitor.stop()
        if AXIsProcessTrusted() {
            startMonitoring()
        } else {
            requestAccessibility()
        }
    }

    @objc private func showSample() {
        HUD.shared.show(Hint(action: "New Folder", keys: ["⇧", "⌘", "N"], note: "this is what a hint looks like"))
    }

    @objc private func dumpMenus() {
        analysis.async {
            let url = MenuDump.write()
            DispatchQueue.main.async {
                HUD.shared.show(Hint(action: url == nil ? "Dump failed" : "Wrote \(MenuDump.path.path)", keys: ["✓"]))
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
