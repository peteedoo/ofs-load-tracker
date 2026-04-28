import Foundation
import Vision
import AppKit

enum LTLOCR {
    struct Token {
        let text: String
        let frame: CGRect  // normalized 0..1 with origin at top-left
    }

    static func recognize(image: NSImage) async throws -> [Token] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ocr", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read image"])
        }
        return try await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try handler.perform([req])
            let observations = req.results ?? []
            var tokens: [Token] = []
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                // Vision returns bounding boxes with origin bottom-left, Y increasing up.
                // Convert to top-left origin so row clustering is intuitive.
                let bb = obs.boundingBox
                let frame = CGRect(x: bb.minX, y: 1.0 - bb.maxY,
                                   width: bb.width, height: bb.height)
                tokens.append(Token(text: candidate.string, frame: frame))
            }
            return tokens
        }.value
    }

    /// Cluster tokens into rows by Y-overlap. Returns rows ordered top→bottom,
    /// each row's tokens ordered left→right.
    static func clusterRows(_ tokens: [Token]) -> [[Token]] {
        let sorted = tokens.sorted { $0.frame.minY < $1.frame.minY }
        var rows: [[Token]] = []
        for t in sorted {
            if var last = rows.last, let first = last.first {
                let lastMidY = first.frame.midY
                if abs(t.frame.midY - lastMidY) < (first.frame.height * 0.6) {
                    last.append(t)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append([t])
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// Heuristic row parser. Anchors each data row by:
    /// - **Load ID** (7-digit number) at the start
    /// - **GUID** at the very end (Petee added this column as a stable anchor)
    /// Anything between them gets pattern-matched: longest 7-12 digit run = PRO,
    /// "Echo Logistics (X)" = carrier, MM/DD/YY = delivery date.
    /// Pickup date is taken from "Pickup : MM/DD/YY (N items)" section rows.
    static func parseTable(_ rows: [[Token]]) -> [ScreenshotLoad] {
        let dateRegex = try? NSRegularExpression(pattern: #"\b(\d{1,2}/\d{1,2}/\d{2,4})\b"#)
        // Standard UUID/GUID, case-insensitive.
        let guidRegex = try? NSRegularExpression(
            pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
        var currentPickupDate: String? = nil
        var out: [ScreenshotLoad] = []

        for r in rows {
            let texts = r.map { $0.text }
            let joined = texts.joined(separator: " ")
            let lower = joined.lowercased()

            // Section header
            if lower.contains("pickup") && lower.contains("items") {
                if let re = dateRegex {
                    let ns = joined as NSString
                    if let m = re.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)) {
                        currentPickupDate = ns.substring(with: m.range)
                    }
                }
                continue
            }
            // Skip header row
            if lower.contains("load id") || (lower.contains("carrier") && lower.contains("shipper")) {
                continue
            }

            // Require a GUID — the row's right-edge anchor. No GUID = not a data row.
            guard let gre = guidRegex else { continue }
            let ns = joined as NSString
            guard gre.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)) != nil else {
                continue
            }

            // Need a Load ID (7-digit number)
            guard let loadID = texts.first(where: {
                $0.count == 7 && $0.allSatisfy(\.isNumber)
            }) else { continue }

            // Carrier: tokens containing "echo" or any of the known LTL names,
            // plus what follows in parentheses.
            let carrierRaw = extractCarrier(joined)

            // PRO: longest 7-12 digit number that isn't the Load ID.
            let pro = extractPRO(texts: texts, excluding: loadID)

            // Status
            let status = extractStatus(joined)

            // Pull every MM/DD/YY date in the row, in left-to-right order.
            // Column order is Pickup date then Delivery date. If we got a
            // pickup date from the section grouping, prefer that; otherwise
            // first match = pickup, second = delivery.
            var allDates: [String] = []
            if let re = dateRegex {
                let ns = joined as NSString
                for m in re.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
                    allDates.append(ns.substring(with: m.range))
                }
            }
            let pickupDate = currentPickupDate ?? allDates.first
            let deliveryDate: String? = {
                if currentPickupDate != nil {
                    return allDates.first { $0 != currentPickupDate }
                }
                return allDates.dropFirst().first
            }()

            out.append(ScreenshotLoad(
                id: loadID,
                status: status,
                carrierRaw: carrierRaw,
                proNumber: pro,
                pickupCity: nil, pickupState: nil,
                dropCity: nil, dropState: nil,
                shipper: nil, consignee: nil,
                pickupDate: pickupDate,
                deliveryDate: deliveryDate,
                weight: nil,
                customerCharges: nil,
                carrierCharges: nil
            ))
        }
        return out
    }

    private static func extractCarrier(_ joined: String) -> String {
        let lower = joined.lowercased()
        // Echo Logistics (XYZ) — capture through the closing paren if present.
        if let echoStart = lower.range(of: "echo logistics") {
            let after = joined[echoStart.lowerBound...]
            if let closeParen = after.firstIndex(of: ")") {
                return String(after[..<after.index(after: closeParen)])
            }
            // No paren — return up to a reasonable cap.
            let prefix = String(after.prefix(60))
            return prefix
        }
        // Other carriers: try to find a known name.
        let known = ["estes express", "tforce", "saia", "fedex", "odfl", "old dominion",
                     "xpo", "rxo", "r+l", "abf", "forward air", "roadrunner", "averitt",
                     "southeastern", "dayton", "holland", "pitt ohio", "aaa cooper", "north park"]
        for k in known {
            if lower.contains(k) {
                if let r = lower.range(of: k) {
                    let lo = r.lowerBound
                    let hi = joined.index(lo, offsetBy: min(40, joined.distance(from: lo, to: joined.endIndex)))
                    return String(joined[lo..<hi])
                }
            }
        }
        return ""
    }

    private static func extractPRO(texts: [String], excluding loadID: String) -> String? {
        var best: String? = nil
        for t in texts {
            // pull the longest digit run from this token
            var current = "", longest = ""
            for ch in t {
                if ch.isNumber { current.append(ch) }
                else {
                    if current.count > longest.count { longest = current }
                    current = ""
                }
            }
            if current.count > longest.count { longest = current }
            guard !longest.isEmpty, longest != loadID,
                  (7...12).contains(longest.count) else { continue }
            if best == nil || longest.count > best!.count { best = longest }
        }
        return best
    }

    private static func extractStatus(_ joined: String) -> String {
        // Take whichever known status phrase appears first (data rows have
        // exactly one status). Order matters — match the most specific first.
        let candidates = [
            "Delivered", "Invoiced", "In Progress (Pickup)", "In Progress (Picke",
            "In Progress", "Covered (Loading)", "Covered (Dispatch)",
            "Covered", "Open"
        ]
        for c in candidates {
            if joined.range(of: c, options: .caseInsensitive) != nil {
                return c
            }
        }
        return ""
    }

    private static func extractDeliveryDate(_ joined: String, excluding pickup: String?,
                                            regex: NSRegularExpression?) -> String? {
        guard let re = regex else { return nil }
        let ns = joined as NSString
        let matches = re.matches(in: joined, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let s = ns.substring(with: m.range)
            if s != pickup { return s }
        }
        return nil
    }

    /// Legacy — kept around but not used.
    static func parseTableLegacy(_ rows: [[Token]]) -> [ScreenshotLoad] {
        guard let headerIdx = rows.firstIndex(where: { row in
            let texts = row.map { $0.text.lowercased() }
            let hasLoad = texts.contains { $0.contains("load") }
            let hasCarrier = texts.contains { $0 == "carrier" || $0.hasPrefix("carrier") }
            let hasShipper = texts.contains { $0.contains("shipper") }
            return hasLoad && (hasCarrier || hasShipper)
        }) else { return [] }

        let header = rows[headerIdx]
        // Build column anchor map: name → centerX. Multiple header tokens may
        // normalize to the same column name (e.g. "Carrier" alone next to a
        // separately-tokenized "Carrier Chgs"). We dedupe by keeping the
        // LEFTMOST x for left-anchor columns and RIGHTMOST for right-anchor
        // columns. Practically: just keep the leftmost — the table grows
        // left-to-right and the first occurrence is the canonical column.
        var byName: [String: CGFloat] = [:]
        for tok in header {
            let name = normalizeHeader(tok.text)
            if let existing = byName[name] {
                byName[name] = min(existing, tok.frame.midX)
            } else {
                byName[name] = tok.frame.midX
            }
        }
        let anchors: [(name: String, x: CGFloat)] = byName.map { (name: $0.key, x: $0.value) }

        var rowsOut: [ScreenshotLoad] = []
        var currentPickupDate: String? = nil
        let dateRegex = try? NSRegularExpression(pattern: #"\b(\d{1,2}/\d{1,2}/\d{2,4})\b"#)

        for r in rows[(headerIdx + 1)...] {
            let joined = r.map(\.text).joined(separator: " ")
            let lowered = joined.lowercased()
            // Section grouping rows like "Pickup : 04/22/26 (17 items)" set the
            // pickup date for all following data rows until the next group.
            if lowered.contains("pickup") && lowered.contains("items") {
                if let re = dateRegex {
                    let ns = joined as NSString
                    if let m = re.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)) {
                        currentPickupDate = ns.substring(with: m.range)
                    }
                }
                continue
            }
            if r.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            var cols: [String: String] = [:]
            for tok in r {
                let nearest = anchors.min(by: { abs($0.x - tok.frame.midX) < abs($1.x - tok.frame.midX) })
                if let n = nearest {
                    let existing = cols[n.name] ?? ""
                    cols[n.name] = existing.isEmpty ? tok.text : "\(existing) \(tok.text)"
                }
            }

            guard let id = cols["loadid"], !id.isEmpty,
                  id.allSatisfy({ $0.isNumber }) else { continue }

            let pro = cols["carrierpro"]?.replacingOccurrences(of: " ", with: "")
            let load = ScreenshotLoad(
                id: id,
                status: cols["status"] ?? "",
                carrierRaw: cols["carrier"] ?? "",
                proNumber: (pro?.isEmpty == false) ? pro : nil,
                pickupCity: cols["pickupcity"],
                pickupState: nil,
                dropCity: cols["dropcity"],
                dropState: nil,
                shipper: cols["shipper"],
                consignee: cols["consignee"],
                pickupDate: currentPickupDate,
                deliveryDate: cols["delivery"],
                weight: cols["weight"],
                customerCharges: cols["customer"],
                carrierCharges: nil
            )
            rowsOut.append(load)
        }
        return rowsOut
    }

    /// Convenience: convert a parsed screenshot row into an LTLLoad if eligible.
    /// PRO may be nil (carrier hasn't assigned one yet); we still surface it so
    /// the user can call if pickup date has passed.
    static func toLTLLoad(_ r: ScreenshotLoad, capturedAt: Date = Date()) -> LTLLoad? {
        guard r.isLTL else { return nil }
        let pro = r.cleanedPRO
        let c = LTLCarrier.from(r.carrierRaw)
        return LTLLoad(
            id: r.id, status: r.status,
            carrierRaw: r.carrierRaw, carrierKey: c.key,
            proNumber: pro,
            pickupCity: r.pickupCity, pickupState: r.pickupState,
            dropCity: r.dropCity, dropState: r.dropState,
            shipper: r.shipper, consignee: r.consignee,
            pickupDate: r.pickupDate, deliveryDate: r.deliveryDate,
            weight: r.weight,
            capturedAt: capturedAt
        )
    }

    private static func normalizeHeader(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("load") && lower.contains("id") { return "loadid" }
        if lower.contains("load") { return "loadid" }
        if lower.contains("status") { return "status" }
        if lower.contains("carrier") && lower.contains("pro") { return "carrierpro" }
        if lower.contains("carrier") && lower.contains("chg") { return "carrierchgs" }
        // OCR sometimes splits "Carrier Pro #" into separate tokens. The bare
        // "Pro" / "Pro #" / "#" tokens always belong to the carrier-pro column.
        if lower == "pro" || lower == "pro#" || lower == "pro #" || lower == "#" { return "carrierpro" }
        if lower == "chgs" { return "carrierchgs" }
        if lower == "carrier" { return "carrier" }
        if lower.contains("pickup") && lower.contains("city") { return "pickupcity" }
        if lower.contains("drop") && lower.contains("city") { return "dropcity" }
        if lower == "st." || lower == "st" { return "stcol" }
        if lower.contains("shipper") { return "shipper" }
        if lower.contains("consignee") { return "consignee" }
        if lower.contains("delivery") && !lower.contains("t") { return "delivery" }
        if lower.contains("weight") { return "weight" }
        if lower.contains("reference") { return "reference" }
        if lower.contains("equipment") { return "equipment" }
        if lower.contains("partial") { return "partial" }
        if lower.contains("length") { return "length" }
        if lower.contains("customer") { return "customer" }
        return lower.replacingOccurrences(of: " ", with: "")
    }
}
