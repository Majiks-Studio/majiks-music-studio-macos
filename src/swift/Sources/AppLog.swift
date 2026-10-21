import Foundation

enum AppLog {
    static func debug(_ message: @autoclosure () -> String) {
#if DEBUG
        fputs("[DEBUG] \(message())\n", stderr)
#endif
    }

    static func info(_ message: @autoclosure () -> String) {
        fputs("[INFO] \(message())\n", stderr)
    }

    static func error(_ message: @autoclosure () -> String) {
        fputs("[ERROR] \(message())\n", stderr)
    }
}
