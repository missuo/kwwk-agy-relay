import Foundation

/// One-line operational log on stderr. Users appear as a short hash, never
/// by email, and no message content or token is ever logged.
enum RelayLog {
    static let enabled = ProcessInfo.processInfo.environment["RELAY_LOG"] != "0"

    static func info(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func user(_ user: String) -> String {
        "u:" + Transcript.sha256(user).prefix(8)
    }
}
