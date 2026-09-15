import Foundation

/// Verbose tracing, off unless someone asks for it:
///     defaults write com.shortcutcoach.app debug -bool YES
/// Read it back with:
///     log stream --predicate 'process == "ShortcutCoach"' --level debug
enum Log {
    static var verbose = UserDefaults.standard.bool(forKey: "debug")

    static func trace(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        NSLog("[coach] %@", message())
    }

    static func always(_ message: String) {
        NSLog("[coach] %@", message)
    }
}
