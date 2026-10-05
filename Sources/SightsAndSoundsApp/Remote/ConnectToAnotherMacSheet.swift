import AppKit
import SightsAndSoundsRemote
import SwiftUI

/// File ▸ Open Library ▸ Connect to Another Mac…: give this Mac a pairing
/// code from the Mac that holds the libraries, and wait to be let in.
struct ConnectToAnotherMacSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var deviceName = Host.current().localizedName ?? "This Mac"
    @State private var asking: Task<Void, Never>?
    @State private var failure: String?

    private var code: PairingCode? { PairingCode(text: codeText) }
    private var isAsking: Bool { asking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Another Mac")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
            Text("On the Mac that holds the library, open Settings \u{25B8} Remote Access, turn it on, and choose Show a Pairing Code. Copy the code there and paste it here. Both Macs have to be on the same local network.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                TextEditor(text: $codeText)
                    .font(Theme.mono(11))
                    .frame(height: 62)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Surface.raised))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Border.standard, lineWidth: 1))
                    .disabled(isAsking)
                    .accessibilityLabel("Pairing code")
                Button("Paste") {
                    codeText = NSPasteboard.general.string(forType: .string) ?? codeText
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(isAsking)
            }
            Text(codeLine)
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(code == nil && !codeText.isEmpty ? Theme.Status.warnText : Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("This Mac\u{2019}s name")
                    .font(Theme.ui(Theme.TypeScale.body))
                TextField("", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isAsking)
            }
            Text("What the other Mac is shown when it is asked whether to let this one in, and in its list afterwards.")
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)

            if isAsking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for someone at \(code?.hostName ?? "the other Mac") to allow this Mac\u{2026}")
                        .font(Theme.ui(Theme.TypeScale.body))
                }
            }
            if let failure {
                Text(failure)
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    asking?.cancel()
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(code == nil || isAsking || !app.remoteLibraries.isAvailable
                        || deviceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.Surface.dialog)
        .foregroundStyle(Theme.Text.primary)
        .onDisappear { asking?.cancel() }
    }

    private var codeLine: String {
        if let code { return "A code from \(code.hostName), at \(code.address) port \(code.port)." }
        if codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The code begins SAS-PAIR- and is one long line."
        }
        return "That is not a whole pairing code yet."
    }

    private func connect() {
        failure = nil
        let text = codeText, name = deviceName.trimmingCharacters(in: .whitespaces)
        let remote = app.remoteLibraries
        asking = Task {
            do {
                try await remote.pair(codeText: text, as: name)
                asking = nil
                dismiss()
            } catch is CancellationError {
                asking = nil
            } catch {
                asking = nil
                if !Task.isCancelled { failure = "\(error)" }
            }
        }
    }
}

/// The other Mac has moved: a new address from its router, or a new
/// port chosen there. The pairing is kept.
struct RemoteHostAddressSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let host: SavedHost

    @State private var address = ""
    @State private var port = ""

    private var parsedPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }
    private var isValid: Bool {
        RemoteAddress.isLocalNetwork(address.trimmingCharacters(in: .whitespaces)) && (parsedPort ?? 0) != 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where \(host.name) Is")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
            Text("Its address and port are shown in its Settings \u{25B8} Remote Access. Changing them here keeps the pairing.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .frame(width: 90)
            }
            if !isValid {
                Text("An address on the local network, such as 192.168.1.20, and a port.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let newAddress = address.trimmingCharacters(in: .whitespaces)
                    guard let parsedPort else { return }
                    Task { await app.remoteLibraries.move(host.id, toAddress: newAddress, port: parsedPort) }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.Surface.dialog)
        .foregroundStyle(Theme.Text.primary)
        .onAppear {
            address = host.address
            port = "\(host.port)"
        }
    }
}
