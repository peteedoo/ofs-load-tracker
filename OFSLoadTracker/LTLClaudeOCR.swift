import Foundation
import AppKit

/// Claude vision OCR for TMS screenshots, via the local `claude` CLI.
/// Uses Petee's Claude Pro/Max subscription (no Anthropic API key required).
///
/// Flow:
///   1. Encode NSImage to a temp PNG.
///   2. Shell out to `/opt/homebrew/bin/claude -p "<prompt with @path>"`.
///   3. Parse the stdout JSON array into [ScreenshotLoad].
///   4. Clean up the temp file.
///
/// `ScreenshotStore` falls back to Apple Vision (`LTLOCR`) if this throws.
enum LTLClaudeOCR {
    enum Error: Swift.Error, LocalizedError {
        case missingCLI
        case imageEncodingFailed
        case cliFailed(status: Int32, stderr: String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                return "Claude CLI not found. Install Claude Code (e.g. via Homebrew)."
            case .imageEncodingFailed:
                return "Could not encode screenshot for the CLI."
            case .cliFailed(let status, let stderr):
                return "claude CLI exited \(status): \(stderr.prefix(300))"
            case .malformedResponse(let detail):
                return "Malformed Claude response: \(detail.prefix(300))"
            }
        }
    }

    /// Override with `OFS_CLAUDE_MODEL` if you want Opus, etc.
    private static var modelOverride: String? {
        let env = ProcessInfo.processInfo.environment["OFS_CLAUDE_MODEL"]
        return (env?.isEmpty == false) ? env : nil
    }

    /// Override with `OFS_CLAUDE_PATH` if `claude` lives elsewhere.
    private static var cliPath: String? {
        if let env = ProcessInfo.processInfo.environment["OFS_CLAUDE_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func parse(image: NSImage) async throws -> [ScreenshotLoad] {
        guard let cli = cliPath else { throw Error.missingCLI }
        guard let pngData = encodePNG(image, maxLongEdge: 1800) else {
            throw Error.imageEncodingFailed
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofs-ocr-\(UUID().uuidString).png")
        try pngData.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Build prompt. The @path tells claude to attach the PNG as image input.
        let prompt = Self.buildPrompt(imagePath: tmpURL.path)
        var args = ["-p", prompt, "--output-format", "text"]
        if let model = modelOverride {
            args.append(contentsOf: ["--model", model])
        }

        let (status, stdout, stderr) = try await runProcess(
            launchPath: cli,
            arguments: args,
            // Allow claude to read the temp file.
            environment: nil,
            timeout: 120
        )
        guard status == 0 else {
            throw Error.cliFailed(status: status, stderr: stderr)
        }
        let arrayData = try extractJSONArray(stdout)
        return try decodeLoads(arrayData)
    }

    // MARK: - Prompt

    private static func buildPrompt(imagePath: String) -> String {
        // Prepend @path so claude attaches the file as image input.
        // Keep the structured-output instructions strict and quiet.
        return """
        @\(imagePath)

        \(Self.basePrompt)
        """
    }

    private static let basePrompt = """
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
      customerCharges — customer charge amount as shown (string, may include "$"), or null
      carrierCharges  — carrier charge amount as shown (string, may include "$"), or null

    Output: a single JSON array with one object per data row. No prose. No code fences. No leading or trailing text.
    """

    // MARK: - PNG encoding

    private static func encodePNG(_ image: NSImage, maxLongEdge: CGFloat) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxLongEdge ? maxLongEdge / longest : 1.0
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        guard let colorSpace = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: Int(newSize.width),
                height: Int(newSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: newSize))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Response parsing (same shape as the old API version)

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
            throw Error.malformedResponse("no JSON array in: \(s.prefix(300))")
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

    // MARK: - Process runner

    private static func runProcess(
        launchPath: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = arguments
            // Inherit a sane PATH so claude can find node, etc.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            if let extra = environment {
                for (k, v) in extra { env[k] = v }
            }
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { p in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(data: outData ?? Data(), encoding: .utf8) ?? ""
                let errStr = String(data: errData ?? Data(), encoding: .utf8) ?? ""
                cont.resume(returning: (p.terminationStatus, outStr, errStr))
            }
            do {
                try proc.run()
                // Coarse timeout. If claude is still running after the deadline, kill it.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning {
                        proc.terminate()
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
