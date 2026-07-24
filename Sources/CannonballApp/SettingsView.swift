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
    @AppStorage("nrelApiKey") private var nrelKey = "DEMO_KEY"
    @State private var bridgeStats = PandaClient.BridgeStats()
    @State private var probeResults: [BridgeProbe.Result] = []
    @State private var probing = false
    @StateObject private var ble = BLEScanner()

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
                        Divider()
                        Button {
                            ble.start()
                        } label: {
                            if ble.scanning {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Scanning Bluetooth…")
                                }
                            } else {
                                Label("Scan for Bluetooth devices", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .disabled(ble.scanning)
                        if !ble.stateText.isEmpty && ble.stateText != "Idle" {
                            Text(ble.stateText).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(ble.devices) { d in
                            Button {
                                ble.inspect(d)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(d.name).font(.caption.weight(.semibold))
                                        if d.name.hasPrefix("ENH") || d.name.contains("S3XY")
                                            || d.name.contains("CAN") {
                                            Image(systemName: "star.fill")
                                                .font(.caption2).foregroundStyle(.yellow)
                                        }
                                        Spacer()
                                        Text("\(d.rssi) dBm").font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if !d.services.isEmpty {
                                        Text("services: " + d.services.joined(separator: ", "))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("tap to inspect").font(.caption2).foregroundStyle(.blue)
                                }
                            }
                        }
                        if !ble.inspectName.isEmpty {
                            Divider()
                            HStack {
                                Text(ble.inspectName).font(.caption.weight(.bold))
                                Spacer()
                                Button("Disconnect") { ble.disconnect() }
                                    .font(.caption)
                            }
                            Text(ble.inspectState).font(.caption2).foregroundStyle(.secondary)
                            ForEach(ble.chars) { c in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(shortUUID(c.characteristic))
                                            .font(.caption2.monospaced().weight(.semibold))
                                        Text(c.properties).font(.caption2)
                                            .foregroundStyle(c.notifying ? .green : .secondary)
                                        Spacer()
                                        if c.packets > 0 {
                                            Text("\(c.packets) pkt").font(.caption2.monospaced())
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    if !c.lastBytes.isEmpty {
                                        Text(c.lastBytes).font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("CAN bridge")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To stream live BMS data:")
                        Text("1. In the S3XY Gadgets app → Commander settings, turn on \"Enable ScanMyTesla support.\"")
                        Text("2. Join the S3XY_OBD Wi-Fi (password 12345678); turn off any VPN.")
                        Text("3. Toggle this on. Frames start on UDP 1338 (Panda) once support is enabled.")
                        Text("The stream is off by default, so a probe with no open ports means step 1 isn't done yet. Receive-only on the car's bus.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Section {
                    TextField("NREL API key (optional)", text: $nrelKey)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Charger finder")
                } footer: {
                    Text("The Chargers tab uses the DOE Alternative Fuels Data Center. The built-in DEMO_KEY has tight rate limits; a free key from developer.nrel.gov/signup removes them.")
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

    /// Short-form a 128-bit UUID to its distinguishing head, keep 16-bit whole.
    private func shortUUID(_ uuid: String) -> String {
        uuid.count > 8 ? String(uuid.prefix(8)) : uuid
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
