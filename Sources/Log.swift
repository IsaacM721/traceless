import Foundation
import os

/// Writes every step to ~/Library/Logs/Traceless/Traceless.log and to the unified log
/// (subsystem com.isaacmendez.Traceless), so each uninstall can be audited afterwards.
final class Log: @unchecked Sendable {
    static let shared = Log()

    let fileURL: URL
    var echo = false

    private let logger = Logger(subsystem: "com.isaacmendez.Traceless", category: "general")
    private let queue = DispatchQueue(label: "traceless.log")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Traceless", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("Traceless.log")
    }

    func callAsFunction(_ message: String, _ level: String = "INFO") {
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
        logger.log("\(message, privacy: .public)")
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        queue.async { [fileURL] in
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    func flush() { queue.sync {} }
}

let log = Log.shared

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

extension String {
    var tildePath: String { (self as NSString).abbreviatingWithTildeInPath }
}
