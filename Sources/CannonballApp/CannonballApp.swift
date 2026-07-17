import SwiftUI
import CannonballCore

/// App shell. The Xcode app target is a thin wrapper: it declares
/// `@main struct Shell: App { var body: some Scene { CannonballScene() } }`
/// plus Info.plist keys and entitlements (docs §2.6, README "Building").
public struct CannonballScene: Scene {
    @State private var model: AppModel

    public init() {
        // Secrets.plist (untracked, see README) → RunConfig.
        let secrets = Bundle.main.url(forResource: "Secrets", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }
        _model = State(initialValue: AppModel(config: RunConfig(
            tessieVIN: secrets?["TessieVIN"] as? String ?? "",
            tessieToken: secrets?["TessieToken"] as? String ?? "")))
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
    enum Tab { case drive, charge, compare }

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(model: model.dashboard)
                .tag(Tab.drive)
                .tabItem { Label("Drive", systemImage: "road.lanes") }
            ChargeScreenView(model: model.charge)
                .tag(Tab.charge)
                .tabItem { Label("Charge", systemImage: "bolt.fill") }
            CompareScreenView(model: model.compare)
                .tag(Tab.compare)
                .tabItem { Label("Compare", systemImage: "arrow.triangle.branch") }
        }
    }
}
