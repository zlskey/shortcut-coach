import AppKit

struct HintStat: Codable {
    var action: String
    var keys: [String]
    var count: Int
    var lastSeen: Date
}

/// Decides whether a hint is worth showing, counts them, and keeps the mute list.
final class HintCenter {
    static let shared = HintCenter()

    private let defaults = UserDefaults.standard
    private var recent: [String: Date] = [:]
    private let lock = NSLock()

    var isEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Hints for things with no click of their own to inspect — switching Spaces, launching
    /// an app, clicking a window to focus it. They are guesses, so they stay off unless asked.
    var guessesEnabled: Bool {
        get { defaults.object(forKey: "guesses") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "guesses") }
    }

    var stats: [String: HintStat] {
        get {
            guard let data = defaults.data(forKey: "stats"),
                  let decoded = try? JSONDecoder().decode([String: HintStat].self, from: data) else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "stats")
        }
    }

    var muted: Set<String> {
        get { Set(defaults.stringArray(forKey: "muted") ?? []) }
        set { defaults.set(Array(newValue), forKey: "muted") }
    }

    func toggleMute(_ id: String) {
        var m = muted
        if m.contains(id) { m.remove(id) } else { m.insert(id) }
        muted = m
    }

    func resetStats() { stats = [:] }

    /// Safe to call from any thread.
    func offer(_ hint: Hint) {
        guard isEnabled, !muted.contains(hint.id) else { return }

        lock.lock()
        let now = Date()
        let seenRecently = (recent[hint.id].map { now.timeIntervalSince($0) < 3.0 }) ?? false
        recent[hint.id] = now
        if recent.count > 200 { recent = recent.filter { now.timeIntervalSince($0.value) < 60 } }
        lock.unlock()
        guard !seenRecently else { return }

        var all = stats
        var stat = all[hint.id] ?? HintStat(action: hint.action, keys: hint.keys, count: 0, lastSeen: now)
        stat.count += 1
        stat.lastSeen = now
        all[hint.id] = stat
        stats = all

        DispatchQueue.main.async { HUD.shared.show(hint) }
    }
}
