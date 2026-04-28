import Foundation

struct LoadSummary: Codable {
    let id: String
    let latestDate: Date
    let latestSender: String
    let latestAttachments: [String]
    let latestBody: String
    let allAttachments: [String]
    let carrierSender: String
}

struct CachedScan: Codable {
    let savedAt: Date
    let summaries: [LoadSummary]
}

@MainActor
final class MailScanner: ObservableObject {
    @Published var loads: [Load] = []
    @Published var statuses: [String: LoadStatus] = [:]
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var lastScanCount: Int = 0
    @Published var lastScanAt: Date?

    private let petee = "poldfield@onlinefreight.com"

    init() {
        loadCache()
    }

    private var cacheURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OFSLoadTracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CachedScan.self, from: data) else { return }
        applySummaries(cache.summaries)
        lastScanAt = cache.savedAt
    }

    private func saveCache(_ summaries: [LoadSummary]) {
        let cache = CachedScan(savedAt: Date(), summaries: summaries)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL)
        }
    }

    /// TMS rows from the latest screenshot, keyed by load ID. Set by the host
    /// view when the screenshot store updates so conflict detection stays
    /// in sync.
    var tmsRows: [String: ScreenshotLoad] = [:]

    private func applySummaries(_ summaries: [LoadSummary]) {
        var newLoads: [Load] = []
        var newStatuses: [String: LoadStatus] = [:]

        // Start from the union of email-discovered IDs and TMS-known FTL IDs so
        // we surface things the screenshot has but email doesn't (and vice versa).
        var byID: [String: LoadSummary] = [:]
        for s in summaries { byID[s.id] = s }

        let allIDs = Set(byID.keys).union(tmsRows.keys)
        for id in allIDs {
            // skip TMS LTL rows here — they live in the LTL tab
            if let tms = tmsRows[id], tms.isLTL { continue }

            let summary = byID[id]
            let tms = tmsRows[id]
            let carrierFromEmail = summary.map { Self.nameFromSender($0.carrierSender) } ?? ""
            let carrier = !carrierFromEmail.isEmpty ? carrierFromEmail : (tms?.carrierRaw ?? "—")
            var load = Load(id: id, carrier: carrier.isEmpty ? "—" : carrier)
            load.tmsStatus = tms?.status

            let mailStatus: LoadStatus = summary.map { Self.classify(summary: $0) } ?? .noCarrierReply
            let final: LoadStatus = load.isLTL ? .skippedLTL : mailStatus
            load.conflictNote = Self.detectConflict(mailStatus: mailStatus, tms: tms, hasEmail: summary != nil)
            newLoads.append(load)
            newStatuses[id] = final
        }
        newLoads.sort { (a, b) in
            let da = byID[a.id]?.latestDate ?? .distantPast
            let db = byID[b.id]?.latestDate ?? .distantPast
            return da > db
        }
        loads = newLoads
        statuses = newStatuses
        lastScanCount = summaries.count
    }

    static func detectConflict(mailStatus: LoadStatus, tms: ScreenshotLoad?, hasEmail: Bool) -> String? {
        guard let tms = tms else {
            // email-only load means it's not in the TMS — flag it
            return hasEmail ? "Not in TMS screenshot" : nil
        }
        let raw = tms.status.lowercased()
        let isDeliveredTMS = raw.contains("deliver") || raw.contains("invoiced")
        switch mailStatus {
        case .delivered, .glennHandled:
            if !isDeliveredTMS && !raw.contains("loading") {
                return "Email shows POD; TMS still \"\(tms.status)\""
            }
        case .silent, .noCarrierReply, .dispatched, .atPickup, .loadedRolling, .atDelivery:
            if isDeliveredTMS {
                return "TMS shows Delivered; no POD email yet"
            }
        case .skippedLTL, .unknown:
            break
        }
        if !hasEmail && !raw.isEmpty && !raw.contains("open") && !raw.contains("covered") {
            return "TMS active but no email thread"
        }
        return nil
    }

    func scanAll() async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let script = buildScanScript()
        do {
            let raw = try await runOSAScript(script)
            let summaries = Self.parseOutput(raw)
            applySummaries(summaries)
            lastScanAt = Date()
            saveCache(summaries)
        } catch {
            lastError = "Mail scan failed: \(error.localizedDescription)"
        }
    }

    private func buildScanScript() -> String {
        return Self.scanScriptText
    }

    static let scanScriptText: String = """
        set RS to character id 30
        set US to character id 31
        set GS to character id 29
        set cutoff to (current date) - (14 * days)

        set loadIDs to {}
        set latestDates to {}
        set latestSenders to {}
        set latestAtts to {}
        set allAttsList to {}
        set carrierNames to {}
        set sourceMsgs to {}

        tell application "Mail"
            -- find poldfield account once
            set petAcct to missing value
            try
                repeat with acct in accounts
                    try
                        repeat with addr in (email addresses of acct)
                            if (addr as string) contains "poldfield" then
                                set petAcct to acct
                                exit repeat
                            end if
                        end repeat
                        if petAcct is not missing value then exit repeat
                    end try
                end repeat
            end try

            -- collect candidate messages from inbox + petee's sent
            set candidates to {}
            try
                set candidates to candidates & (messages of inbox whose (date received > cutoff) and (subject contains "Load #"))
            end try
            try
                if petAcct is not missing value then
                    set candidates to candidates & (messages of (sent mailbox of petAcct) whose (date sent > cutoff) and (subject contains "Load #"))
                end if
            end try

            repeat with m in candidates
                try
                    set subj to subject of m
                    set scanFrom to 0
                    try
                        set p to offset of "Load #" in subj
                        if p > 0 then set scanFrom to p + 6
                    end try
                    if scanFrom = 0 then
                        try
                            set p2 to offset of "Load#" in subj
                            if p2 > 0 then set scanFrom to p2 + 5
                        end try
                    end if
                    if scanFrom > 0 then
                        set i to scanFrom
                        repeat while i <= (length of subj) and (character i of subj) is " "
                            set i to i + 1
                        end repeat
                        set startI to i
                        repeat while i <= (length of subj)
                            set ch to character i of subj
                            if (id of ch) >= 48 and (id of ch) <= 57 then
                                set i to i + 1
                            else
                                exit repeat
                            end if
                        end repeat
                        if i > startI then
                            set theID to text startI thru (i - 1) of subj
                            -- pull message metadata
                            set d to current date
                            try
                                set d to date received of m
                            on error
                                try
                                    set d to date sent of m
                                end try
                            end try
                            set s to sender of m
                            set attStr to ""
                            try
                                repeat with a in (mail attachments of m)
                                    set attStr to attStr & (name of a) & "|"
                                end repeat
                            end try
                            -- find existing entry
                            set idx to 0
                            repeat with k from 1 to (count of loadIDs)
                                if item k of loadIDs = theID then
                                    set idx to k
                                    exit repeat
                                end if
                            end repeat
                            if idx = 0 then
                                set end of loadIDs to theID
                                set end of latestDates to d
                                set end of latestSenders to s
                                set end of latestAtts to attStr
                                set end of allAttsList to attStr
                                if s contains "@onlinefreight.com" then
                                    set end of carrierNames to ""
                                else
                                    set end of carrierNames to s
                                end if
                                set end of sourceMsgs to m
                            else
                                set item idx of allAttsList to (item idx of allAttsList) & attStr
                                if d > (item idx of latestDates) then
                                    set item idx of latestDates to d
                                    set item idx of latestSenders to s
                                    set item idx of latestAtts to attStr
                                    set item idx of sourceMsgs to m
                                end if
                                if (item idx of carrierNames) = "" and (s does not contain "@onlinefreight.com") then
                                    set item idx of carrierNames to s
                                end if
                            end if
                        end if
                    end if
                end try
            end repeat

            -- only read body when we actually need it: no POD attachment seen
            -- and there IS a carrier reply (otherwise classification is forced).
            set output to ""
            repeat with i from 1 to (count of loadIDs)
                set bodyText to ""
                set atts to (item i of allAttsList)
                set carrier to (item i of carrierNames)
                set hasPOD to (atts contains ".pdf") or (atts contains "POD") or (atts contains "BOL") or (atts contains "CamScanner")
                if (carrier is not "") and (not hasPOD) then
                    try
                        set bodyText to content of (item i of sourceMsgs)
                    end try
                    if (length of bodyText) > 2000 then
                        set bodyText to text 1 thru 2000 of bodyText
                    end if
                end if
                set output to output & RS & (item i of loadIDs) & GS & ((item i of latestDates) as string) & US & (item i of latestSenders) & US & (item i of latestAtts) & US & bodyText & US & atts & US & carrier
            end repeat
        end tell
        return output
        """

    static func parseOutput(_ raw: String) -> [LoadSummary] {
        let RS = "\u{001E}"
        let US = "\u{001F}"
        let GS = "\u{001D}"
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        formatter.locale = Locale(identifier: "en_US")

        var result: [LoadSummary] = []
        let records = raw.components(separatedBy: RS).filter { !$0.isEmpty }
        for rec in records {
            guard let gsRange = rec.range(of: GS) else { continue }
            let id = String(rec[rec.startIndex..<gsRange.lowerBound])
            let rest = String(rec[gsRange.upperBound...])
            let parts = rest.components(separatedBy: US)
            guard parts.count >= 6 else { continue }
            let dateStr = parts[0]
            let sender = parts[1]
            let latestAttStr = parts[2]
            let body = parts[3]
            let allAttStr = parts[4]
            let carrierSender = parts[5]
            let d = formatter.date(from: dateStr) ?? Date.distantPast
            let latestAtts = latestAttStr.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            let allAtts = allAttStr.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            result.append(LoadSummary(
                id: id,
                latestDate: d,
                latestSender: sender,
                latestAttachments: latestAtts,
                latestBody: body,
                allAttachments: allAtts,
                carrierSender: carrierSender
            ))
        }
        return result
    }

    static let loadIDRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"Load\s*#\s*(\d{6,8})"#, options: [.caseInsensitive])
    }()

    static func extractLoadID(from subject: String) -> String? {
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let m = loadIDRegex.firstMatch(in: subject, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: subject) else { return nil }
        return String(subject[r])
    }

    static func nameFromSender(_ raw: String) -> String {
        // Format: "Display Name <email@host>" — return Display Name, or fallback to email's local part
        if let lt = raw.firstIndex(of: "<"), lt > raw.startIndex {
            let name = String(raw[raw.startIndex..<lt]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        // Just an email address
        if let at = raw.firstIndex(of: "@") {
            return String(raw[raw.startIndex..<at])
        }
        return raw
    }

    static func classify(summary s: LoadSummary) -> LoadStatus {
        if s.carrierSender.isEmpty {
            return .noCarrierReply
        }

        let latestSenderLower = s.latestSender.lowercased()
        let latestFromOFS = latestSenderLower.contains("@onlinefreight.com")
        let latestFromGlenn = latestSenderLower.contains("gbachman@onlinefreight.com")
        let body = s.latestBody.lowercased()

        // POD detection: scan attachment names across the whole thread, but only
        // count those that look like delivery docs (pdf/POD/BOL/CamScanner).
        var podName: String? = nil
        var hasLumper = false
        for a in s.allAttachments {
            let lower = a.lowercased()
            if lower.contains("lumper") { hasLumper = true }
            if lower.contains("pod") || lower.contains("bol")
                || lower.hasPrefix("camscanner") || lower.hasSuffix(".pdf") {
                if podName == nil { podName = a }
            }
        }
        if body.contains("lumper") { hasLumper = true }

        if podName != nil, latestFromGlenn {
            return .glennHandled(podName: podName)
        }
        if podName != nil {
            return .delivered(podName: podName)
        }

        // If latest is OFS asking a question, fall back to keywords in the quoted history
        let isStale = Date().timeIntervalSince(s.latestDate) > 2 * 24 * 3600

        if hasLumper
            || body.contains("at the receiver") || body.contains("at receiver")
            || body.contains("unloading") || body.contains("at delivery")
            || body.contains("getting unloaded") || body.contains("getting empty")
            || body.contains("being unloaded") {
            return .atDelivery
        }

        if body.contains("loaded and rolling") || body.contains("loaded & rolling")
            || body.contains("rolling") || body.contains("picked up")
            || body.contains("loaded now") || body.contains("getting loaded")
            || body.contains(" loaded") || body.contains("we are loaded")
            || body.contains("driver loaded") {
            return .loadedRolling
        }

        if body.contains("onsite") || body.contains("on site") || body.contains("on-site")
            || body.contains("at the shipper") || body.contains("at shipper")
            || body.contains("checked in") || body.contains("in the dock")
            || body.contains("at pickup") || body.contains("at the pickup")
            || body.contains("driver is here") || body.contains("driver here")
            || body.contains("is at pickup") || body.contains("driver already onsite") {
            return .atPickup
        }

        // Carrier has replied at some point, but latest body has no movement keywords.
        if !latestFromOFS {
            // latest is from carrier but says nothing actionable — treat as dispatched
            return isStale ? .silent : .dispatched
        }
        // Latest is from OFS asking → no recent carrier movement → dispatched/silent
        return isStale ? .silent : .dispatched
    }

    private func runOSAScript(_ script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", script]
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if proc.terminationStatus != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "unknown"
                throw NSError(domain: "osascript", code: Int(proc.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
