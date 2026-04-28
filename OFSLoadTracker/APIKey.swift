import Foundation

enum APIKey {
    /// Loads the Anthropic API key for Claude OCR. Search order:
    /// 1. `OFS_CLAUDE_API_KEY` env var (useful when launching from Terminal)
    /// 2. `~/.config/ofs-load-tracker/api-key` (single line, plain text)
    ///
    /// Keychain support could be layered on later. For a single-user tool
    /// the file approach keeps the bar low.
    static func loadClaude() -> String? {
        if let env = ProcessInfo.processInfo.environment["OFS_CLAUDE_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ofs-load-tracker", isDirectory: true)
            .appendingPathComponent("api-key")
    }
}
