import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SightsAndSoundsRemote
import SwiftUI

/// Settings ▸ Remote Access: whether other Macs may use this one's
/// libraries, which have been approved, and the code that lets one more
/// in.
struct RemoteAccessSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var showingCode = false
    @State private var revoking: ApprovedDevice?
    /// How many Macs were approved when the code went up: one more when
    /// the sheet comes down means the code was used.
    @State private var approvedBeforeCode = 0
    /// What became of the last code — said here, because the sheet is
    /// gone by the time there is anything to say.
    @State private var lastCodeOutcome: String?

    private var model: RemoteAccessModel { app.remoteAccess }

    var body: some View {
        Form {
            ScopeHeader(scope: .app, storage: "The approved Macs are kept in a file only you can read.")

            Section("Remote Access") {
                Toggle("Let approved Macs use this Mac\u{2019}s libraries", isOn: Binding(
                    get: { model.isOn },
                    set: { on in Task { await model.setOn(on) } }))
                    .disabled(!model.isAvailable || model.isChanging)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if model.portIsTaken {
                        Button("Use Another Port") { Task { await model.useAnotherPort() } }
                            .help("Each Mac already approved will have to be given the new port")
                    }
                }
            }

            Section("Pair a Mac") {
                let addresses = model.addresses
                if addresses.count > 1 {
                    Picker("This Mac\u{2019}s address", selection: $address) {
                        ForEach(addresses, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Show a Pairing Code\u{2026}") {
                    let chosen = addresses.contains(address) ? address : (addresses.first ?? "")
                    Task {
                        await model.beginPairing(address: chosen)
                        approvedBeforeCode = model.devices.count
                        lastCodeOutcome = nil
                        showingCode = model.pairingCode != nil
                    }
                }
                .disabled(!model.isOn || addresses.isEmpty)
                Text(pairingLine(addresses))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastCodeOutcome {
                    Text(lastCodeOutcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Approved Macs") {
                if model.devices.isEmpty {
                    Text("No Mac has been approved.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(Self.history(of: device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke\u{2026}") { revoking = device }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            if address.isEmpty { address = model.addresses.first ?? "" }
        }
        .sheet(isPresented: $showingCode, onDismiss: {
            Task {
                await model.endPairing()
                await model.refresh()
                if model.devices.count > approvedBeforeCode,
                   let newest = model.devices.max(by: { $0.approvedAt < $1.approvedAt }) {
                    lastCodeOutcome = "The last code was used by \(newest.name)."
                } else if lastCodeOutcome == nil {
                    lastCodeOutcome = "The last code was withdrawn unused."
                }
            }
        }) {
            PairingCodeSheet(model: model) { ranOut in
                if ranOut { lastCodeOutcome = "The last code ran out before a Mac used it." }
                showingCode = false
            }
        }
        // The name is the other Mac's word for itself, so it is shown
        // as that, on its own line, not inside the question.
        .confirmationDialog(
            "Revoke this Mac?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { device in
            Button("Revoke", role: .destructive) { Task { await model.revoke(device.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("\(device.name)\n\nIt is disconnected now and cannot connect again. To let it back in, pair it again with a new code.")
        }
    }

    private var statusLine: String {
        if !model.isAvailable { return "Unavailable." }
        if model.isOn, let port = model.port {
            return "On, listening on port \(port). Nothing is advertised on the network: another Mac finds this one only by being given a pairing code. Only Macs on the local network are answered."
        }
        return "Off. No Mac can connect, approved or not. The approved Macs are kept for when it is turned on again."
    }

    private func pairingLine(_ addresses: [String]) -> String {
        if addresses.isEmpty { return "This Mac has no address on a local network just now, so there is nowhere for another Mac to connect to." }
        if !model.isOn { return "Turn remote access on to pair a Mac." }
        return "On the other Mac, choose Connect to Another Mac\u{2026} and give it the code. You will be asked here before it is let in."
    }

    static func history(of device: ApprovedDevice) -> String {
        let approved = "Approved \(device.approvedAt.formatted(date: .abbreviated, time: .shortened))"
        guard let last = device.lastConnectedAt else { return "\(approved) \u{00B7} has not connected yet" }
        return "\(approved) \u{00B7} last connected \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The code, to be read off the screen or copied. It is on offer only
/// while this is up: closing it withdraws the code.
private struct PairingCodeSheet: View {
    let model: RemoteAccessModel
    /// Called with `true` when the host withdrew the code (used, or out
    /// of time) and `false` when Done was pressed.
    let close: (Bool) -> Void
    @State private var copied = false
    /// When the sheet went up — the code is good for ten minutes from
    /// here, and the time left is said in words rather than implied by
    /// the sheet vanishing.
    @State private var shownAt = Date()
    private static let lifetime: TimeInterval = 10 * 60

    private func timeLeft(at now: Date) -> String {
        let remaining = max(0, Self.lifetime - now.timeIntervalSince(shownAt))
        let minutes = Int(remaining / 60)
        let seconds = Int(remaining) % 60
        if remaining <= 0 { return "The code has run out." }
        if minutes >= 2 { return "Good for about \(minutes) more minutes and for one Mac." }
        return "Good for \(minutes):\(String(format: "%02d", seconds)) more and for one Mac."
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pairing Code")
                .font(.headline)
            if let code = model.pairingCode {
                if let image = QRCode.image(of: code.text) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("The pairing code as a QR code")
                }
                Text(code.text)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.text, forType: .string)
                    copied = true
                }
                TimelineView(.periodic(from: shownAt, by: 1)) { context in
                    Text(timeLeft(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("For \(code.address), port \(code.port). Anyone who sees it in that time can ask to be let in, and you will be asked before they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("The code has been used or has run out.")
                    .foregroundStyle(.secondary)
            }
            Button("Done") { close(false) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .onAppear { shownAt = Date() }
        // Used, or out of time: there is nothing left here to show, and
        // the pane behind says which it was.
        .onChange(of: model.pairingCode) { _, code in
            copied = false
            if code == nil { close(true) }
        }
    }
}

/// A QR code of some text, as black modules on white.
enum QRCode {
    static func image(of text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // One point per module is too small to be read by a camera off
        // a screen; scaled up whole, so the edges stay sharp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
