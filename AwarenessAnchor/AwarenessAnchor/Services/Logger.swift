import Foundation

/// Simple file logger for debugging
class Logger {
    static let shared = Logger()

    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.awarenessanchor.logger")

    private init() {
        // Log to ~/Library/Logs/AwarenessAnchor/
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("AwarenessAnchor")

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("app.log")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"

        // Clear log on launch (keep it small)
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)

        log("Logger initialized", category: "System")
        log("Log file: \(logFileURL.path)", category: "System")
    }

    func log(_ message: String, category: String = "General") {
        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(category)] \(message)\n"

            // Also print to console
            print(line, terminator: "")

            // Append to file
            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    var logFilePath: String {
        logFileURL.path
    }
}

// Convenience functions
func appLog(_ message: String, category: String = "General") {
    Logger.shared.log(message, category: category)
}
