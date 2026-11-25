import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SenderPermission: String, CaseIterable, Identifiable {
    case screenRecording, accessibility

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .screenRecording: return "Allows OpenDisplay to send your Mac’s picture to the receiver."
        case .accessibility: return "Allows touch and pen input from the receiver. You can stream without it."
        }
    }

    var settingsPane: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        }
    }
}

@MainActor
final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()

    @Published private(set) var selection: SenderPermission?
    private var panel: NSPanel?

    func showOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasSeenPermissionGuide") else { return }
        defaults.set(true, forKey: "hasSeenPermissionGuide")
        if !PermissionMonitor.shared.screenRecording { show() }
    }

    func show(for permission: SenderPermission? = nil) {
        selection = permission
        if panel == nil {
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 410, height: 380),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "OpenDisplay Permissions")
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: PermissionGuideView(guide: self))
            window.center()
            panel = window
        }
        PermissionMonitor.shared.refresh()
        panel?.makeKeyAndOrderFront(nil)
    }

    func openSettings(for permission: SenderPermission) {
        selection = permission
        if let panel, let frame = (panel.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - 24))
        }
        MacPrivacySettings.open(permission.settingsPane)
    }

    func close() { panel?.close() }
}

private struct PermissionGuideView: View {
    @ObservedObject var guide: PermissionGuide
    @ObservedObject private var permissions = PermissionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up OpenDisplay")
                .font(.title2.weight(.semibold))
            ForEach(SenderPermission.allCases) { permission in
                permissionRow(permission)
                if guide.selection == permission && !permissions.isGranted(permission) {
                    manualInstructions
                }
            }
            HStack {
                Spacer()
                Button("Done") { guide.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 410)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func permissionRow(_ permission: SenderPermission) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(permission.title).font(.headline)
                Spacer()
                if permissions.isGranted(permission) {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant…") { permissions.request(permission) }
                    Button("Open Settings") { guide.openSettings(for: permission) }
                }
            }
            Text(permission.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            if permission == .screenRecording {
                Text("If macOS asks, quit and reopen OpenDisplay after allowing access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var manualInstructions: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityLabel(Text("OpenDisplay app icon"))
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            Text("Turn on OpenDisplay in System Settings. If it’s missing, drag this icon into the list or use the + button to select the app.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
