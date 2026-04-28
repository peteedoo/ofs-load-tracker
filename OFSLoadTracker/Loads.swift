import Foundation

struct Load: Identifiable, Hashable {
    let id: String
    let carrier: String
    var tmsStatus: String? = nil      // raw status text from latest screenshot, if any
    var conflictNote: String? = nil   // populated when TMS and email disagree
    var isLTL: Bool { carrier.lowercased().contains("echo logistics") }
}

enum LoadStatus: Equatable {
    case unknown
    case skippedLTL
    case noCarrierReply
    case dispatched
    case atPickup
    case loadedRolling
    case atDelivery       // includes lumper / unloading
    case glennHandled(podName: String?)
    case delivered(podName: String?)
    case silent

    var label: String {
        switch self {
        case .unknown: return "—"
        case .skippedLTL: return "LTL — skip"
        case .noCarrierReply: return "No carrier reply"
        case .dispatched: return "Dispatched"
        case .atPickup: return "At pickup"
        case .loadedRolling: return "Loaded & rolling"
        case .atDelivery: return "At delivery"
        case .glennHandled: return "Handled (Glenn)"
        case .delivered: return "Delivered ✓"
        case .silent: return "Silent — check in"
        }
    }

    var color: String {
        switch self {
        case .delivered, .glennHandled: return "green"
        case .loadedRolling: return "blue"
        case .atPickup, .atDelivery: return "purple"
        case .dispatched: return "orange"
        case .silent, .noCarrierReply: return "red"
        case .skippedLTL, .unknown: return "gray"
        }
    }

    var canDraftCheckin: Bool {
        switch self {
        case .silent, .noCarrierReply, .dispatched, .atPickup, .loadedRolling, .atDelivery:
            return true
        default: return false
        }
    }

    var canForwardPOD: Bool {
        if case .delivered(let pod) = self, pod != nil { return true }
        return false
    }
}
