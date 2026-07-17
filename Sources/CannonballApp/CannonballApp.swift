import SwiftUI
import CannonballCore

/// App shell. The Xcode app target is a thin wrapper: it declares
/// `@main struct Shell: App { var body: some Scene { CannonballScene() } }`
/// plus Info.plist keys and entitlements (docs §2.6, README "Building").
public struct CannonballScene: Scene {
    @State private var model: AppModel

    public init() {
        // Keychain (in-app Settings) first, Secrets.plist as the dev fallback.
        let secrets = Bundle.main.url(forResource: "Secrets", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }
        func clean(_ value: String?) -> String {
            let v = value ?? ""
            return v.hasPrefix("YOUR_") ? "" : v   // ignore template placeholders
        }
        _model = State(initialValue: AppModel(config: RunConfig(
            tessieVIN: clean(SecretsStore.tessieVIN ?? secrets?["TessieVIN"] as? String),
            tessieToken: clean(SecretsStore.tessieToken ?? secrets?["TessieToken"] as? String))))
    }

    public var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)   // night-drive default
        }
    }
}

struct RootView: View {
    let model: AppModel
    @State private var tab: Tab = .drive
    enum Tab { case drive, charge, car, compare, settings }

    var body: some View {
        TabView(selection: $tab) {
            DriveScreen(model: model, dashboard: model.dashboard)
                .tag(Tab.drive)
                .tabItem { Label("Drive", systemImage: "road.lanes") }
            ChargeTabView(model: model)
                .tag(Tab.charge)
                .tabItem { Label("Charge", systemImage: "bolt.fill") }
            CarView(model: model)
                .tag(Tab.car)
                .tabItem { Label("Car", systemImage: "car.fill") }
            CompareScreenView(model: model.compare)
                .tag(Tab.compare)
                .tabItem { Label("Compare", systemImage: "arrow.triangle.branch") }
            SettingsView(model: model)
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
