import Foundation
import AppKit

/// Wraps macOS `screencapture` for in-app region capture.
/// User clicks a button → cursor turns to crosshair → drag a box →
/// PNG saved to a temp path → returned to caller as NSImage.
///
/// Cancelling the region selection (Esc) is treated as a graceful
/// `cancelled` error so callers can no-op.
enum Screenshotter {
    enum Error: Swift.Error, LocalizedError {
        case cancelled
        case captureFailed(status: Int32, stderr: String)
        case decodeFailed(path: String)
        case missingTool

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Capture cancelled."
            case .captureFailed(let status, let stderr):
                return "screencapture exited \(status). \(stderr.prefix(200))"
            case .decodeFailed(let path):
                return "Could not load captured image at \(path)."
            case .missingTool:
                return "/usr/sbin/screencapture not found."
            }
        }
    }

    /// Trigger a region-select capture. Resolves with the captured NSImage.
    /// The temp file is deleted before returning.
    static func captureRegion() async throws -> NSImage {
        let toolPath = "/usr/sbin/screencapture"
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw Error.missingTool
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofs-capture-\(UUID().uuidString).png")

        let (status, stderr) = try await runProcess(
            launchPath: toolPath,
            // -i interactive (region select by default), -x silent, -o no shadow on windows
            arguments: ["-i", "-x", "-o", tmpURL.path]
        )

        // screencapture returns 0 even on Esc-cancel; the file just won't exist.
        guard FileManager.default.fileExists(atPath: tmpURL.path) else {
            // Distinguish "user hit Esc" (silent cancel) from a real failure.
            if status == 0 {
                throw Error.cancelled
            }
            throw Error.captureFailed(status: status, stderr: stderr)
        }

        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard status == 0 else {
            throw Error.captureFailed(status: status, stderr: stderr)
        }

        guard let image = NSImage(contentsOf: tmpURL) else {
            throw Error.decodeFailed(path: tmpURL.path)
        }
        return image
    }

    /// Async shim around Process for one-shot tool runs.
    private static func runProcess(
        launchPath: String,
        arguments: [String]
    ) async throws -> (status: Int32, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = arguments
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()

            proc.terminationHandler = { p in
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errStr = String(data: errData ?? Data(), encoding: .utf8) ?? ""
                cont.resume(returning: (p.terminationStatus, errStr))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
