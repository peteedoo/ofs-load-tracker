import SwiftUI

enum LoadFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case delivered = "Delivered"
    case skipped = "Skipped"
    case ltl = "LTL"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var scanner = MailScanner()
    @StateObject private var screenshots = ScreenshotStore()
    @State private var filter: LoadFilter = .all
    @State private var copiedID: String? = nil
    @State private var actionMessage: String? = nil

    private var filteredLoads: [Load] {
        scanner.loads.filter { l in
            let s = scanner.statuses[l.id] ?? .unknown
            switch filter {
            case .all: return true
            case .active:
                switch s {
                case .dispatched, .atPickup, .loadedRolling, .atDelivery,
                     .silent, .noCarrierReply: return true
                default: return false
                }
            case .delivered:
                if case .delivered = s { return true }
                return false
            case .skipped:
                if case .skippedLTL = s { return true }
                if case .glennHandled = s { return true }
                return false
            case .ltl:
                return false  // handled in separate view
            }
        }
    }

    var body: some View {
        if filter == .ltl {
            VStack(spacing: 0) {
                topBar
                LTLView(store: screenshots)
            }
            .frame(minWidth: 760, minHeight: 520)
        } else {
            ftlBody
        }
    }

    private var topBar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(LoadFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
            Spacer()
        }
        .padding(12)
    }

    private var ftlBody: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(LoadFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)

                Spacer()

                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning Mail…").font(.caption).foregroundColor(.secondary)
                } else if let t = scanner.lastScanAt {
                    Text("Updated \(t, style: .relative) ago")
                        .font(.caption).foregroundColor(.secondary)
                }

                Button(action: { Task { await scanner.scanAll() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
            }
            .padding(12)

            if let err = scanner.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            if let msg = actionMessage {
                Text(msg).font(.caption).foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            Divider()

            List(filteredLoads) { load in
                LoadRow(load: load,
                        status: scanner.statuses[load.id] ?? .unknown,
                        copiedID: $copiedID,
                        onCopy: { copy(load) },
                        onDraft: { Task { await draft(load) } },
                        onForward: { Task { await forward(load) } })
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            scanner.tmsRows = screenshots.ftlByID
            await scanner.scanAll()
        }
        .onChange(of: screenshots.rows) { _ in
            scanner.tmsRows = screenshots.ftlByID
            Task { await scanner.scanAll() }
        }
    }

    private func copy(_ load: Load) {
        LoadActions.copyToClipboard(load.id)
        copiedID = load.id
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedID == load.id { copiedID = nil }
        }
    }

    private func draft(_ load: Load) async {
        let greet = greetingFor(load.carrier)
        do {
            try await LoadActions.draftCheckin(loadID: load.id, greeting: greet)
            flash("Draft opened for \(load.id)")
        } catch {
            flash("Draft failed: \(error.localizedDescription)")
        }
    }

    private func forward(_ load: Load) async {
        do {
            try await LoadActions.forwardPOD(loadID: load.id)
            flash("Forward draft opened for \(load.id)")
        } catch {
            flash("Forward failed: \(error.localizedDescription)")
        }
    }

    private func flash(_ msg: String) {
        actionMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if actionMessage == msg { actionMessage = nil }
        }
    }

    private func greetingFor(_ carrier: String) -> String {
        // Conservative default
        return "y'all"
    }
}

struct LoadRow: View {
    let load: Load
    let status: LoadStatus
    @Binding var copiedID: String?
    let onCopy: () -> Void
    let onDraft: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Text(load.id)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.accentColor)
                    if copiedID == load.id {
                        Text("✓ copied").font(.caption).foregroundColor(.green)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(load.carrier)
                    .foregroundColor(load.isLTL ? .secondary : .primary)
                if let tms = load.tmsStatus, !tms.isEmpty {
                    Text("TMS: \(tms)").font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(width: 220, alignment: .leading)

            StatusBadge(status: status)
                .frame(width: 170, alignment: .leading)

            if let note = load.conflictNote {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(note).font(.caption).foregroundColor(.orange)
                }
                .help(note)
            }

            Spacer()

            HStack(spacing: 8) {
                if status.canDraftCheckin {
                    Button("Check-in", action: onDraft)
                }
                if status.canForwardPOD {
                    Button("Forward POD", action: onForward)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(status == .skippedLTL ? 0.55 : 1.0)
    }
}

struct StatusBadge: View {
    let status: LoadStatus

    var body: some View {
        Text(status.label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bgColor.opacity(0.18))
            .foregroundColor(bgColor)
            .cornerRadius(6)
    }

    private var bgColor: Color {
        switch status.color {
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "red": return .red
        case "gray": return .gray
        default: return .gray
        }
    }
}
