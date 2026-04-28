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
            let tokens = try await LTLOCR.recognize(image: image)
            debug = "tokens: \(tokens.count)"
            let clustered = LTLOCR.clusterRows(tokens)
            debug = "tokens: \(tokens.count), rows: \(clustered.count)"
            let parsed = LTLOCR.parseTable(clustered)
            let ltlCount = parsed.filter(\.isLTL).count
            debug = "tokens: \(tokens.count), rows: \(clustered.count), parsed: \(parsed.count), ltl: \(ltlCount)"
            // Always log which rows were rejected by the LTL filter so we can
            // see the carrier/PRO values that didn't pass.
            let nonLTL = parsed.filter { !$0.isLTL }
            if !nonLTL.isEmpty {
                let preview = nonLTL.prefix(8).map {
                    "  \($0.id) | carrier=\"\($0.carrierRaw)\" | pro=\"\($0.proNumber ?? "")\""
                }.joined(separator: "\n")
                lastError = "Rejected \(nonLTL.count) rows from LTL (showing first 8):\n\(preview)"
            }
            if parsed.isEmpty {
                let preview = clustered.prefix(3).enumerated().map { (i, row) in
                    "row\(i): " + row.map(\.text).joined(separator: " | ")
                }.joined(separator: "\n")
                lastError = "Header detection failed.\n\(preview)"
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
