import SwiftUI
import Sparkle

@MainActor
enum ApplicationUpdates {
    static func makeController() -> SPUStandardUpdaterController? {
        let info = Bundle.main
        guard let key = info.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let address = info.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: address), let host = url.host else { return nil }
        #if DEBUG
        let loopback = url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        guard url.scheme == "https" || loopback else { return nil }
        #else
        guard url.scheme == "https", host == "raw.githubusercontent.com",
              url.path.hasPrefix("/xiheha3213906313/opendisplay/sparkle-feeds/") else { return nil }
        #endif
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        return controller
    }
}

/// "Check for Updates…" button wired to Sparkle. Follows Sparkle 2's
/// documented SwiftUI pattern: a small view model publishes the updater's
/// `canCheckForUpdates` so the button disables itself while a check is
/// already running (or the updater isn't ready). Shared by the sender and
/// the receiver app.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater.updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater.updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .controlSize(.small)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
