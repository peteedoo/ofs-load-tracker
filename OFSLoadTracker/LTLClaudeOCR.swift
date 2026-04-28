import Foundation
import AppKit

/// Claude OCR for TMS screenshots. Shells out to the Claude Code CLI
/// (`claude -p`) so we re-use Petee's existing login — no API key needed.
/// `ScreenshotStore` falls back to Apple Vision if this throws.
enum LTLClaudeOCR {
    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case imageEncodingFailed
        case cliFailed(status: Int32, stderr: String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "claude CLI not found. Install with: npm i -g @anthropic-ai/claude-code (or brew install claude)."
            case .imageEncodingFailed:
                return "Could not encode screenshot."
            case .cliFailed(let status, let stderr):
                return "claude exited \(status): \(stderr.prefix(200))"
            case .malformedResponse(let detail):
                return "Malformed CLI response: \(detail.prefix(200))"
            }
        }
    }

    /// Common locations where Homebrew or npm install the CLI. Probed in order.
    private static let cliCandidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.npm-global/bin/claude",
        "\(NSHomeDirectory())/.local/bin/claude",
    ]

    private static func findCLI() -> String? {
        for p in cliCandidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    static func parse(image: NSImage) async throws -> [ScreenshotLoad] {
        guard let cli = findCLI() else { throw Error.cliNotFound }
        guard let pngData = encodePNG(image, maxLongEdge: 1800) else {
            throw Error.imageEncodingFailed
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofs-screenshot-\(UUID().uuidString).png")
        try pngData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fullPrompt = "Read the image at \(tmp.path) and extract every data row. " + Self.prompt

        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["-p", fullPrompt]
            // Run from a writable cwd so the CLI's session/state goes somewhere
            // sensible. tmpDir is fine for one-shot use.
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            if proc.terminationStatus != 0 {
                throw Error.cliFailed(status: proc.terminationStatus, stderr: stderr)
            }
            if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Error.malformedResponse("empty stdout (stderr: \(stderr.prefix(200)))")
            }
            let jsonData = try Self.extractJSONArray(stdout)
            return try Self.decodeLoads(jsonData)
        }.value
    }

    // MARK: - Encoding

    private static func encodePNG(_ image: NSImage, maxLongEdge: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let longEdge = max(w, h)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1.0
        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))

        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let resized = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Response parsing

    /// Strip markdown fences and locate the outermost `[ ... ]` array.
    private static func extractJSONArray(_ text: String) throws -> Data {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.range(of: "```") {
            s = String(s[open.upperBound...])
            if s.lowercased().hasPrefix("json") { s.removeFirst(4) }
            if let close = s.range(of: "```") {
                s = String(s[..<close.lowerBound])
            }
        }
        guard let start = s.firstIndex(of: "["),
              let end = s.lastIndex(of: "]"),
              start < end else {
            throw Error.malformedResponse("no JSON array in: \(s.prefix(200))")
        }
        let slice = String(s[start...end])
        guard let data = slice.data(using: .utf8) else {
            throw Error.malformedResponse("could not encode JSON slice")
        }
        return data
    }

    private static func decodeLoads(_ data: Data) throws -> [ScreenshotLoad] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.malformedResponse("not a JSON array of objects")
        }
        var out: [ScreenshotLoad] = []
        for row in arr {
            guard let id = stringValue(row["id"])
                    ?? stringValue(row["loadId"])
                    ?? stringValue(row["load_id"]),
                  !id.isEmpty else { continue }
            let load = ScreenshotLoad(
                id: id,
                status: stringValue(row["status"]) ?? "",
                carrierRaw: stringValue(row["carrierRaw"])
                    ?? stringValue(row["carrier"])
                    ?? "",
                proNumber: stringValue(row["proNumber"])
                    ?? stringValue(row["pro"])
                    ?? stringValue(row["pro_number"]),
                pickupCity: stringValue(row["pickupCity"])
                    ?? stringValue(row["pickup_city"]),
                pickupState: stringValue(row["pickupState"])
                    ?? stringValue(row["pickup_state"]),
                dropCity: stringValue(row["dropCity"])
                    ?? stringValue(row["drop_city"]),
                dropState: stringValue(row["dropState"])
                    ?? stringValue(row["drop_state"]),
                shipper: stringValue(row["shipper"]),
                consignee: stringValue(row["consignee"]),
                pickupDate: stringValue(row["pickupDate"])
                    ?? stringValue(row["pickup_date"]),
                deliveryDate: stringValue(row["deliveryDate"])
                    ?? stringValue(row["delivery_date"]),
                weight: stringValue(row["weight"]),
                customerCharges: stringValue(row["customerCharges"])
                    ?? stringValue(row["customer_charges"]),
                carrierCharges: stringValue(row["carrierCharges"])
                    ?? stringValue(row["carrier_charges"])
            )
            out.append(load)
        }
        return out
    }

    private static func stringValue(_ v: Any?) -> String? {
        guard let v = v else { return nil }
        if v is NSNull { return nil }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static let prompt = """
    You are an OCR assistant for an LTL/FTL freight Transportation Management System screenshot.
    Extract every data row from the table in the image. Return ONLY a JSON array of objects.
    Do not include commentary, markdown fences, or any other text.

    Each row object must use these exact keys (use null when absent):
      id              — 7-digit Load ID (string of digits)
      status          — status text (e.g. "Delivered", "In Progress (Pickup)", "Covered", "Open")
      carrierRaw      — full carrier string as shown (e.g. "Echo Logistics (Estes Express)")
      proNumber       — PRO / tracking number, digits only (string), or null
      pickupCity      — pickup city or null
      pickupState     — pickup 2-letter state or null
      dropCity        — drop city or null
      dropState       — drop 2-letter state or null
      shipper         — shipper name or null
      consignee       — consignee name or null
      pickupDate      — MM/DD/YY string from a "Pickup : MM/DD/YY (N items)" group header or row, or null
      deliveryDate    — MM/DD/YY string or null
      weight          — weight as shown (string, may include "lbs"), or null
      customerCharges — customer charges (string), or null
      carrierCharges  — carrier charges (string), or null

    Rules:
      • Skip section header rows like "Pickup : MM/DD/YY (N items)" themselves; instead apply the
        section's pickup date to every data row beneath it until the next section.
      • Skip the column header row.
      • Skip totals/footer rows.
      • Preserve the order rows appear in the screenshot.
      • If a cell is empty or unreadable, use null — never invent data.

    Output: a single JSON array. Nothing else.
    """
}
