import Foundation
import AppKit

/// **STUB** — placeholder until the real implementation lands on branch
/// `add-claude-ocr`. The stub throws `notConfigured` so callers can fall
/// back to Apple Vision OCR. The interface here is the contract; the real
/// file replaces this one.
enum LTLClaudeOCR {
    enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case missingAPIKey
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Claude OCR not yet integrated (stub)."
            case .missingAPIKey: return "No Anthropic API key found."
            }
        }
    }

    static func parse(image: NSImage) async throws -> [ScreenshotLoad] {
        throw Error.notConfigured
    }
}
