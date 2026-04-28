import Foundation
import AppKit

/// Claude vision OCR for TMS screenshots. Replaces the prep-claude-ocr stub.
/// Sends the screenshot to Anthropic's API and asks for a strict JSON array
/// of `ScreenshotLoad` rows. `ScreenshotStore` falls back to Apple Vision if
/// this throws.
enum LTLClaudeOCR {
    enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case missingAPIKey
        case imageEncodingFailed
        case requestFailed(status: Int, body: String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Claude OCR not yet integrated (stub)."
            case .missingAPIKey:
                return "No Anthropic API key found."
            case .imageEncodingFailed:
                return "Could not encode screenshot for upload."
            case .requestFailed(let status, let body):
                return "Claude API \(status): \(body.prefix(200))"
            case .malformedResponse(let detail):
                return "Malformed Claude response: \(detail.prefix(200))"
            }
        }
    }

    /// Sonnet 4.6 is the price/accuracy sweet spot for table extraction.
    /// Override with `OFS_CLAUDE_MODEL` if you want Opus.
    private static var model: String {
        ProcessInfo.processInfo.environment["OFS_CLAUDE_MODEL"]
            ?? "claude-sonnet-4-6"
    }

    static func parse(image: NSImage) async throws -> [ScreenshotLoad] {
        guard let key = APIKey.loadClaude() else { throw Error.missingAPIKey }
        guard let pngData = encodePNG(image, maxLongEdge: 1800) else {
            throw Error.imageEncodingFailed
        }
        let base64 = pngData.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": base64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": Self.prompt
                    ]
                ]
            ]]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = payload
        req.timeoutInterval = 90

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Error.malformedResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
            throw Error.requestFailed(status: http.statusCode, body: bodyStr)
        }

        let text = try extractText(data)
        let jsonData = try extractJSONArray(text)
        return try decodeLoads(jsonData)
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

    private static func extractText(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw Error.malformedResponse("no content array; raw: \(raw)")
        }
        var combined = ""
        for block in content {
            if (block["type"] as? String) == "text", let t = block["text"] as? String {
                combined += t
            }
        }
        if combined.isEmpty {
            throw Error.malformedResponse("no text block in response")
        }
        return combined
    }

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
