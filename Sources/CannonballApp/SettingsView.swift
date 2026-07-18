import SwiftUI
import CannonballCore
#if os(iOS)
import UIKit
#endif

/// Tessie credential entry — keychain-persisted, applied to the live client
/// without a restart.
struct SettingsView: View {
    let model: AppModel
    @State private var vin = SecretsStore.tessieVIN ?? ""
    @State private var token = SecretsStore.tessieToken ?? ""
    @State private var savedAt: Date?
    @State private var status = TessieClient.ConnectionStatus()
    @State private var resetDone = false
    @AppStorage("raceModeEnabled") private var raceMode = true
    @AppStorage("canBridgeEnabled") private var canBridge = false
    @AppStorage("canBridgeHost") private var canHost = "192.168.4.1"
    @State private var bridgeStats = PandaClient.BridgeStats()
    @State private var probeResults: [BridgeProbe.Result] = []
    @State private var probing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $raceMode) {
                        Label("Race mode", systemImage: raceMode ? "flag.checkered" : "moon.zzz")
                    }
                    .onChange(of: raceMode) { _, on in model.setRaceMode(on) }
                } footer: {
                    Text(raceMode
                        ? "The copilot is live: coaching notifications for charging, pace, preconditioning, and fallbacks."
                        : "Quiet mode: no coaching notifications. Planning, maps, charts, the Car tab, and the logbook keep working.")
                }
                Section("Connection") {
                    HStack(spacing: 10) {
                        Circle().fill(statusColor).frame(width: 10, height: 10)
                        Text(statusText).font(.callout)
                    }
                }
                Section("Tessie") {
                    TextField("VIN", text: $vin)
                    #if os(iOS)
                        .textInputAutocapitalization(.characters)
                    #endif
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField("API token", text: $token)
                }
                Section {
                    Button("Save & Reconnect") {
                        let v = vin.trimmingCharacters(in: .whitespacesAndNewlines)
                        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        vin = v; token = t
                        model.applySecrets(vin: v, token: t)
                        savedAt = .init()
                    }
                    .disabled(vin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    if savedAt != nil {
                        Label("Saved. Cloud telemetry reconnects automatically.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Stored in the iOS keychain on this phone only.")
                    }
                }
                Section {
                    Toggle(isOn: $canBridge) {
                        Label("S3XY Commander CAN bridge", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .onChange(of: canBridge) { _, on in
                        model.setCANBridge(enabled: on, host: canHost)
                    }
                    if canBridge {
                        TextField("Bridge IP", text: $canHost)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { model.setCANBridge(enabled: true, host: canHost) }
                        HStack(spacing: 10) {
                            Circle().fill(bridgeColor).frame(width: 10, height: 10)
                            Text(bridgeText).font(.callout)
                        }
                        if bridgeStats.frames > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(bridgeStats.frames) frames · \(bridgeStats.decodedSignals) decoded")
                                Text("Top IDs: " + bridgeStats.topAddresses
                                    .map { String(format: "0x%03X×%d", $0.address, $0.count) }
                                    .joined(separator: "  "))
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            probing = true
                            probeResults = []
                            Task {
                                probeResults = await BridgeProbe.run(host: canHost)
                                probing = false
                            }
                        } label: {
                            if probing {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Probing \(canHost)…")
                                }
                            } else {
                                Label("Run bridge probe", systemImage: "stethoscope")
                            }
                        }
                        .disabled(probing)
                        ForEach(probeResults) { result in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: result.success
                                    ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(result.success ? .green : .secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.label).font(.caption.weight(.semibold))
                                    Text(result.outcome)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        #if os(iOS)
                        if probeResults.contains(where: { $0.outcome.contains("Local Network") || $0.outcome.contains("Network is down") }) {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Open CannonGlobe settings to allow Local Network",
                                      systemImage: "lock.open")
                                    .font(.callout.weight(.semibold))
                            }
                        }
                        #endif
                    }
                } header: {
                    Text("CAN bridge")
                } footer: {
                    Text(canBridge
                        ? "Join the Commander's Wi-Fi, then run the probe to identify its protocol. Receive-only on the car's bus. If every row says 'no response', check Settings > Privacy & Security > Local Network and make sure CannonGlobe is allowed."
                        : "Live BMS data over the Commander's Wi-Fi hotspot. Enable when the Commander is installed.")
                }
                Section {
                    Button("Reset learned efficiency", role: .destructive) {
                        resetDone = false
                        Task {
                            await model.resetLearnedEfficiency()
                            resetDone = true
                        }
                    }
                } header: {
                    Text("Car swap")
                } footer: {
                    Text(resetDone
                        ? "Reset complete. Reseeded from this car's own drive history."
                        : "Changing the VIN resets this automatically. Use the button if you want a clean slate without changing cars: it wipes the learned Wh/mi fit and charge-curve corrections, then reseeds from the configured car's drive history.")
                }
            }
            .navigationTitle("Settings")
            .task {
                while !Task.isCancelled {
                    status = await model.tessieStatus()
                    if canBridge { bridgeStats = await model.canBridgeStats() }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var bridgeColor: Color {
        switch bridgeStats.state {
        case .streaming: .green
        case .probing: .yellow
        case .lost: .red
        case .disconnected: .secondary.opacity(0.5)
        }
    }

    private var bridgeText: String {
        switch bridgeStats.state {
        case .streaming:
            if let last = bridgeStats.lastFrameAt {
                return "Streaming · last frame \(Int(Date().timeIntervalSince(last)))s ago"
            }
            return "Streaming"
        case .probing: return "Listening for the Commander at \(canHost)…"
        case .lost: return "Signal lost, retrying"
        case .disconnected: return "Off"
        }
    }

    private var statusColor: Color {
        if status.lastError != nil { return .red }
        if let last = status.lastUpdate, Date().timeIntervalSince(last) < 60 { return .green }
        return .secondary.opacity(0.5)
    }

    private var statusText: String {
        if let err = status.lastError { return err }
        if let last = status.lastUpdate {
            let age = Int(Date().timeIntervalSince(last))
            let channel = status.streamingConnected ? "streaming" : "polling"
            return "Live (\(channel)) · updated \(age)s ago"
        }
        return (SecretsStore.tessieVIN ?? "").isEmpty
            ? "Not configured" : "Waiting for first update…"
    }
}
