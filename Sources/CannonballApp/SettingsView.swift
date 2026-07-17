import SwiftUI

/// Tessie credential entry — keychain-persisted, applied to the live client
/// without a restart.
struct SettingsView: View {
    let model: AppModel
    @State private var vin = SecretsStore.tessieVIN ?? ""
    @State private var token = SecretsStore.tessieToken ?? ""
    @State private var savedAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tessie") {
                    TextField("VIN", text: $vin)
                        .textInputAutocapitalization(.characters)
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
            }
            .navigationTitle("Settings")
        }
    }
}
