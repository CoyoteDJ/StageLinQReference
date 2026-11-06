import SwiftUI

@main struct StageLinQReferenceApp: App {
    @StateObject private var model = ReferenceModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene { WindowGroup { StartupView(model: model) }.onChange(of: scenePhase) { phase in if phase == .background { model.stop() } } }
}
