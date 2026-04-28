import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LTLView: View {
    @ObservedObject var store: ScreenshotStore
    @State private var copiedPro: String? = nil
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LTL").font(.headline)
                Text("(\(store.ltlLoads.count) of \(store.rows.count) parsed)")
                    .font(.caption).foregroundColor(.secondary)
                if let t = store.lastImportedAt {
                    Text("• imported \(t, style: .relative) ago")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Capture region…") { captureRegion() }
                Button("Paste screenshot") { pasteFromPasteboard() }
                Button("Choose file…") { chooseFile() }
                if !store.rows.isEmpty {
                    Button(role: .destructive) { store.clearAll() } label: { Text("Clear") }
                }
            }
            .padding(12)

            if let err = store.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            if !store.debug.isEmpty {
                Text(store.debug).font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }

            if store.isImporting {
                ProgressView("Reading screenshot…").padding()
            }

            Divider()

            if store.ltlLoads.isEmpty && !store.isImporting {
                emptyState
            } else {
                List(store.ltlLoads) { l in
                    LTLRow(load: l, copiedPro: $copiedPro)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 3)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Drop a TMS screenshot here").font(.headline)
            Text("Or use Paste / Choose file. We'll OCR rows with a Carrier Pro # and list them.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        Task { await store.importImage(img) }
                    }
                }
                return
            }
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    if let u = url, let img = NSImage(contentsOf: u) {
                        Task { await store.importImage(img) }
                    }
                }
                return
            }
        }
    }

    private func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) {
            Task { await store.importImage(img) }
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  let u = urls.first, let img = NSImage(contentsOf: u) {
            Task { await store.importImage(img) }
        } else {
            store.lastError = "No image on clipboard."
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            Task { await store.importImage(img) }
        }
    }
    private func captureRegion() {
        Task {
            do {
                let image = try await Screenshotter.captureRegion()
                await store.importImage(image)
            } catch Screenshotter.Error.cancelled {
                // User hit Esc — quietly ignore.
            } catch {
                await MainActor.run {
                    store.lastError = "Capture failed: \(error.localizedDescription)"
                }
            }
        }
    }

}

struct LTLRow: View {
    let load: LTLLoad
    @Binding var copiedPro: String?

    private var carrier: LTLCarrier { LTLCarrier.from(load.carrierRaw) }

    private var pickupIsPast: Bool {
        guard let s = load.pickupDate else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MM/dd/yy", "M/d/yy", "MM/dd/yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                let cal = Calendar.current
                let today = cal.startOfDay(for: Date())
                return cal.startOfDay(for: d) < today
            }
        }
        return false
    }

    private var needsCall: Bool {
        load.proNumber == nil && pickupIsPast
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(load.id)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(carrier.displayName).font(.subheadline)
                if !load.status.isEmpty {
                    Text(load.status).font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(width: 180, alignment: .leading)

            // PRO # (or placeholder)
            HStack(spacing: 4) {
                if let pro = load.proNumber {
                    Text(pro)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.accentColor)
                    if copiedPro == pro {
                        Text("✓ copied").font(.caption).foregroundColor(.green)
                    }
                } else {
                    Text("No PRO yet").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((needsCall ? Color.red : .orange).opacity(0.18))
                        .foregroundColor(needsCall ? .red : .orange)
                        .cornerRadius(4)
                }
            }
            .frame(width: 130, alignment: .leading)
            .onTapGesture { copyPro() }

            // Lane + dates
            VStack(alignment: .leading, spacing: 2) {
                Text(lane).font(.caption)
                HStack(spacing: 8) {
                    if let p = load.pickupDate {
                        Text("P \(p)").font(.caption2).foregroundColor(.secondary)
                    }
                    if let d = load.deliveryDate {
                        Text("D \(d)").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 220, alignment: .leading)

            Spacer()

            HStack(spacing: 8) {
                if needsCall {
                    Label("Call carrier", systemImage: "phone.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.red.opacity(0.18))
                        .foregroundColor(.red)
                        .cornerRadius(6)
                }
                if let pro = load.proNumber, let url = carrier.trackingURL(pro: pro) {
                    Button("Track") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(pro, forType: .string)
                        copiedPro = pro
                        NSWorkspace.shared.open(url)
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if copiedPro == pro { copiedPro = nil }
                        }
                    }
                }
                if carrier.hasAPI {
                    Text("API").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.18))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var lane: String {
        let p = [load.pickupCity].compactMap { $0 }.joined(separator: " ")
        let d = [load.dropCity].compactMap { $0 }.joined(separator: " ")
        if p.isEmpty && d.isEmpty { return "" }
        return "\(p) → \(d)"
    }

    private func copyPro() {
        guard let pro = load.proNumber else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pro, forType: .string)
        copiedPro = pro
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedPro == pro { copiedPro = nil }
        }
    }
}
