import Foundation
import os

/// Centralized logger that writes to both os_log and a file for easy tailing.
enum TBLog {
    private static let subsystem = "com.tokenbar"
    private static let osLog = OSLog(subsystem: subsystem, category: "general")
    private static let logFile: URL = {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar.log")
        // Clear on launch
        try? "".write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }()

    static var logPath: String { logFile.path }

    static func log(_ message: String, category: String = "general") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)"
        os_log("%{public}@", log: osLog, type: .default, line)
        print(line)
        // Also append to file
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        }
    }
}
