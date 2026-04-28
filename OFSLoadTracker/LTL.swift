import Foundation

struct LTLLoad: Codable, Identifiable, Hashable {
    var id: String
    var status: String
    var carrierRaw: String
    var carrierKey: String
    var proNumber: String?
    var pickupCity: String?
    var pickupState: String?
    var dropCity: String?
    var dropState: String?
    var shipper: String?
    var consignee: String?
    var pickupDate: String?
    var deliveryDate: String?
    var weight: String?
    var capturedAt: Date
}

struct CachedLTL: Codable {
    let savedAt: Date
    let loads: [LTLLoad]
}

/// Generic row pulled from the TMS screenshot. Splits later into FTL or LTL.
struct ScreenshotLoad: Codable, Hashable {
    var id: String
    var status: String
    var carrierRaw: String
    var proNumber: String?
    var pickupCity: String?
    var pickupState: String?
    var dropCity: String?
    var dropState: String?
    var shipper: String?
    var consignee: String?
    var pickupDate: String?
    var deliveryDate: String?
    var weight: String?
    var customerCharges: String?
    var carrierCharges: String?

    var cleanedPRO: String? {
        guard let raw = proNumber, !raw.isEmpty else { return nil }
        // OCR sometimes glues neighboring columns into the PRO field
        // (e.g. "12ft411214845" = Length + actual PRO). Extract the longest
        // contiguous digit run and use that.
        var best = ""
        var current = ""
        for ch in raw {
            if ch.isNumber {
                current.append(ch)
            } else {
                if current.count > best.count { best = current }
                current = ""
            }
        }
        if current.count > best.count { best = current }
        return best.isEmpty ? nil : best
    }

    var isEcho: Bool { carrierRaw.lowercased().contains("echo") }

    /// True if this row should appear in the LTL tab. Includes rows that have a
    /// real PRO *or* are Echo Logistics loads pending a PRO (we still want to
    /// see those so we can call when a pickup date passes).
    var isLTL: Bool {
        if let pro = cleanedPRO, (7...12).contains(pro.count) { return true }
        return isEcho
    }
}

struct CachedScreenshot: Codable {
    let savedAt: Date
    let rows: [ScreenshotLoad]
}

enum LTLCarrier {
    case estes
    case tforce
    case saia
    case fedexFreight
    case odfl
    case xpoRxo
    case rlCarriers
    case abf
    case forwardAir
    case roadrunner
    case averitt
    case sefl
    case dayton
    case holland
    case pittOhio
    case aaaCooper
    case northPark
    case other(String)

    /// Best-guess match from a free-form carrier name (e.g. "Echo Logistics (Estes Express)")
    static func from(_ raw: String) -> LTLCarrier {
        let l = raw.lowercased()
        if l.contains("estes") { return .estes }
        if l.contains("tforce") || l.contains("t-force") || l.contains("ups freight") { return .tforce }
        if l.contains("saia") { return .saia }
        if l.contains("fedex") { return .fedexFreight }
        if l.contains("odfl") || l.contains("old dominion") { return .odfl }
        if l.contains("xpo") || l.contains("rxo") { return .xpoRxo }
        if l.contains("r+l") || l.contains("rl carriers") || l.contains("rlcarriers") { return .rlCarriers }
        if l.contains("abf") || l.contains("arcb") { return .abf }
        if l.contains("forward air") { return .forwardAir }
        if l.contains("roadrunner") { return .roadrunner }
        if l.contains("averitt") { return .averitt }
        if l.contains("southeastern") || l.contains("sefl") { return .sefl }
        if l.contains("dayton") { return .dayton }
        if l.contains("holland") { return .holland }
        if l.contains("pitt ohio") || l.contains("pittohio") { return .pittOhio }
        if l.contains("aaa cooper") || l.contains("aaacooper") { return .aaaCooper }
        if l.contains("north park") { return .northPark }
        return .other(raw)
    }

    var key: String {
        switch self {
        case .estes: return "estes"
        case .tforce: return "tforce"
        case .saia: return "saia"
        case .fedexFreight: return "fedex"
        case .odfl: return "odfl"
        case .xpoRxo: return "rxo"
        case .rlCarriers: return "rl"
        case .abf: return "abf"
        case .forwardAir: return "forwardair"
        case .roadrunner: return "roadrunner"
        case .averitt: return "averitt"
        case .sefl: return "sefl"
        case .dayton: return "dayton"
        case .holland: return "holland"
        case .pittOhio: return "pittohio"
        case .aaaCooper: return "aaacooper"
        case .northPark: return "northpark"
        case .other: return "other"
        }
    }

    var displayName: String {
        switch self {
        case .estes: return "Estes Express"
        case .tforce: return "TForce Freight"
        case .saia: return "Saia"
        case .fedexFreight: return "FedEx Freight"
        case .odfl: return "Old Dominion"
        case .xpoRxo: return "RXO / XPO"
        case .rlCarriers: return "R+L Carriers"
        case .abf: return "ABF Freight"
        case .forwardAir: return "Forward Air"
        case .roadrunner: return "Roadrunner"
        case .averitt: return "Averitt"
        case .sefl: return "Southeastern Freight"
        case .dayton: return "Dayton Freight"
        case .holland: return "Holland"
        case .pittOhio: return "Pitt Ohio"
        case .aaaCooper: return "AAA Cooper"
        case .northPark: return "North Park"
        case .other(let raw): return raw
        }
    }

    /// Public tracking URL given a PRO number. Returns nil for unknown carriers.
    func trackingURL(pro: String) -> URL? {
        let p = pro.replacingOccurrences(of: " ", with: "")
        switch self {
        case .estes:
            return URL(string: "https://www.estes-express.com/myestes/shipment-tracking/?type=PRO&pros=\(p)")
        case .tforce:
            return URL(string: "https://www.tforcefreight.com/ltl/apex/f?p=212:7:::NO::P7_TRACE_BY:PRO%2C\(p)")
        case .saia:
            return URL(string: "https://www.saia.com/track/details?proNumber=\(p)")
        case .fedexFreight:
            return URL(string: "https://www.fedex.com/fedextrack/?trknbr=\(p)")
        case .odfl:
            return URL(string: "https://www.odfl.com/Trace/standardResultsSingle.faces?searchType=PRO&pro=\(p)")
        case .xpoRxo:
            return URL(string: "https://rxo.com/track?proNumber=\(p)")
        case .rlCarriers:
            return URL(string: "https://www2.rlcarriers.com/freight/shipping/shipment-tracing?pro=\(p)")
        case .abf:
            return URL(string: "https://arcb.com/tools/tracking.html#/\(p)")
        case .forwardAir:
            return URL(string: "https://www.forwardair.com/Tracking?awbNumber=\(p)")
        case .roadrunner:
            return URL(string: "https://www.rrts.com/Tracking/Trace.aspx?pro=\(p)")
        case .averitt:
            return URL(string: "https://www.averittexpress.com/wps/portal/!ut/p/Tracking?proNum=\(p)")
        case .sefl:
            return URL(string: "https://www.sefl.com/Tracing/index.jsp?proNumber=\(p)")
        case .dayton:
            return URL(string: "https://www.daytonfreight.com/Tracking/?pro=\(p)")
        case .holland:
            return URL(string: "https://my.hollandregional.com/tools/tracking?pro=\(p)")
        case .pittOhio:
            return URL(string: "https://www.pittohio.com/En/PublicTools/Tracking?pro=\(p)")
        case .aaaCooper:
            return URL(string: "https://www.aaacooper.com/atrace/onetracingdetail.aspx?probill=\(p)")
        case .northPark:
            return URL(string: "https://www.npts.com/Tools/Tracking?pro=\(p)")
        case .other:
            return nil
        }
    }

    /// Whether we have an actual API integration that returns live status (vs. just a URL).
    var hasAPI: Bool {
        switch self {
        case .fedexFreight: return true   // Phase 2 — requires dev creds, off by default
        default: return false
        }
    }
}
