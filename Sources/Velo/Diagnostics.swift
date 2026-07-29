import Foundation
import OSLog

/// Where the app says what happened.
///
/// stdout only exists when the app was started from a terminal — and a
/// terminal-launched process inherits the terminal's privacy grants, so the one
/// launch that can print is the one launch whose permissions are not the app's
/// own. That is precisely backwards for diagnosing a capture that is silent
/// because it was never authorised, so everything also goes to a file that any
/// launch can write and any session can read.
enum VeloLog {

    static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Velo.log")
    }()

    private static let logger = Logger(subsystem: "com.lowlatency.velo", category: "velo")
    /// Off the caller's thread: `write` can be reached from the audio callback,
    /// and a real-time thread has no business touching the filesystem.
    private static let queue = DispatchQueue(label: "com.lowlatency.velo.log", qos: .utility)
    private static let started = Date()

    static func write(_ category: String, _ message: String) {
        print("[velo/\(category)] \(message)")
        fflush(stdout)
        logger.notice("\(message, privacy: .public)")

        let stamp = String(format: "%8.3f", Date().timeIntervalSince(started))
        let line = "\(stamp)  [\(category)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Called once at launch so a log always states which build produced it.
    static func begin() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        let bundle = Bundle.main.bundleIdentifier ?? "unbundled"
        let launchedFromTerminal = isatty(STDOUT_FILENO) == 1
        write("app", "Velo starting — \(bundle), "
              + (launchedFromTerminal ? "launched from a terminal" : "launched by the system"))
    }
}
