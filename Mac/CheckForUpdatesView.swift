import AppKit
import SwiftUI

@MainActor
final class ApplicationUpdates: ObservableObject {
    static let shared = ApplicationUpdates()

    @Published private(set) var isChecking = false

    func check(_ product: MainBranchUpdates.Product) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
            let alert = NSAlert()
            do {
                if let update = try await MainBranchUpdates.check(product: product, version: version, build: build) {
                    alert.messageText = String(localized: "OpenDisplay \(update.version) is available")
                    alert.informativeText = String(localized: "Download the disk image and open it to install the update.")
                    alert.addButton(withTitle: String(localized: "Download…"))
                    alert.addButton(withTitle: String(localized: "Later"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(update.url)
                    }
                    return
                }
                alert.messageText = String(localized: "OpenDisplay is up to date")
            } catch {
                Log.info("Update check failed: \(error)")
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Could not check for updates")
                alert.informativeText = String(localized: "Try again later.")
            }
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

struct CheckForUpdatesView: View {
    let product: MainBranchUpdates.Product
    @ObservedObject private var updater = ApplicationUpdates.shared

    var body: some View {
        Button("Check for Updates…") { updater.check(product) }
            .controlSize(.small)
            .disabled(updater.isChecking)
    }
}
