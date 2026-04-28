import Foundation
import AppKit

@MainActor
final class ScreenshotStore: ObservableObject {
    @Published var rows: [ScreenshotLoad] = []
    @Published var ltlLoads: [LTLLoad] = []
    @Published var lastImportedAt: Date?
    @Published var isImporting = false
    @Published var lastError: String?
    @Published var debug: String = ""

    init() { load() }

    private var cacheURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OFSLoadTracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screenshot.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CachedScreenshot.self, from: data) else { return }
        rows = cache.rows
        lastImportedAt = cache.savedAt
        rebuildLTL()
    }

    func importImage(_ image: NSImage) async {
        isImporting = true
        lastError = nil
        debug = "OCR running…"
        defer { isImporting = false }
        do {
            let size = image.size
            debug = "image \(Int(size.width))x\(Int(size.height))…"

            // Prefer Claude API if a key is configured — vision-model parsing
            // beats Apple Vision + column-anchor heuristics on dense tables.
            // Fall back to the local pipeline if Claude isn't available.
            var parsed: [ScreenshotLoad] = []
            var usedClaude = false
            if APIKey.loadClaude() != nil {
                debug = "calling Claude API…"
                do {
                    parsed = try await LTLClaudeOCR.parse(image: image)
                    usedClaude = true
                    debug = "Claude OCR: \(parsed.count) rows"
                } catch {
                    debug = "Claude OCR failed (\(error.localizedDescription)) — falling back to Vision"
                }
            }
            if !usedClaude {
                let tokens = try await LTLOCR.recognize(image: image)
                let clustered = LTLOCR.clusterRows(tokens)
                parsed = LTLOCR.parseTable(clustered)
                let ltlCount = parsed.filter(\.isLTL).count
                debug += " — Vision: tokens \(tokens.count), rows \(clustered.count), parsed \(parsed.count), ltl \(ltlCount)"
            }

            if parsed.isEmpty {
                lastError = "No rows extracted from screenshot. \(debug)"
                return
            }

            let newIDs = Set(parsed.map(\.id))
            let kept = rows.filter { !newIDs.contains($0.id) }
            rows = (kept + parsed).sorted { $0.id < $1.id }
            lastImportedAt = Date()
            persist()
            rebuildLTL()
        } catch {
            lastError = "OCR failed: \(error.localizedDescription)"
        }
    }

    func clearAll() {
        rows = []
        ltlLoads = []
        lastImportedAt = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func persist() {
        let cache = CachedScreenshot(savedAt: Date(), rows: rows)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL)
        }
    }

    private func rebuildLTL() {
        ltlLoads = rows.compactMap { LTLOCR.toLTLLoad($0, capturedAt: lastImportedAt ?? Date()) }
    }

    /// FTL-only screenshot rows. Keyed by load ID so FTL tab can merge with mail data.
    var ftlByID: [String: ScreenshotLoad] {
        var m: [String: ScreenshotLoad] = [:]
        for r in rows where !r.isLTL { m[r.id] = r }
        return m
    }
}
