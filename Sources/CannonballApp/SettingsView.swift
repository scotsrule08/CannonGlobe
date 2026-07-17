import SwiftUI
import CannonballCore

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
                    try? await Task.sleep(for: .seconds(2))
                }
            }
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
