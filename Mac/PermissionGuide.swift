import AppKit
import CoreGraphics
import SwiftUI

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
final class PermissionGuide {
    static let shared = PermissionGuide()

    private static let settingsBundleID = "com.apple.systempreferences"
    private var tracking: Task<Void, Never>?

    func openSettings(for permission: SenderPermission) -> Bool {
        tracking?.cancel()
        guard MacPrivacySettings.open(permission.settingsPane) else { return false }
        tracking = Task { await followSettings(for: permission) }
        return true
    }

    private func followSettings(for permission: SenderPermission) async {
        let content = DropHintHostingView(rootView: PermissionDropHint { [weak self] in
            self?.tracking?.cancel()
        })
        let size = content.fittingSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = content
        defer { panel.close() }

        let clock = ContinuousClock()
        let launchDeadline = clock.now + .seconds(8)
        var windowID: CGWindowID?
        var missingSince: ContinuousClock.Instant?
        while !Task.isCancelled && !PermissionMonitor.shared.isGranted(permission) {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let settings = frontmost.flatMap { $0.bundleIdentifier == Self.settingsBundleID ? $0 : nil }
            if let settings,
               let window = Self.visibleWindow(owner: settings.processIdentifier, matching: windowID),
               let frame = Self.panelFrame(forQuartzBounds: window.bounds, size: size) {
                windowID = window.id
                missingSince = nil
                if frame != panel.frame { panel.setFrame(frame, display: panel.isVisible) }
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else {
                if panel.isVisible { panel.orderOut(nil) }
                if let windowID {
                    // A window can briefly disappear when Spaces or its frame change.
                    if Self.windowExists(windowID) {
                        missingSince = nil
                    } else {
                        if missingSince == nil { missingSince = clock.now }
                        if let missingSince, clock.now - missingSince >= .milliseconds(400) { return }
                    }
                } else if clock.now >= launchDeadline {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(settings == nil ? 300 : 125))
        }
    }

    private static func visibleWindow(owner: pid_t, matching id: CGWindowID?) -> (id: CGWindowID, bounds: CGRect)? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == owner,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  id == nil || number == id,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 240, rect.height >= 160 else { continue }
            return (number, rect)
        }
        return nil
    }

    private static func windowExists(_ windowID: CGWindowID) -> Bool {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowNumber as String] as? CGWindowID == windowID }
    }

    private static func panelFrame(forQuartzBounds bounds: CGRect, size: CGSize) -> CGRect? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        // Quartz uses the primary display's top-left as its origin.
        let window = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                            width: bounds.width, height: bounds.height)
        func overlap(_ screen: NSScreen) -> CGFloat {
            let intersection = screen.frame.intersection(window)
            return intersection.width * intersection.height
        }
        guard let screen = screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 else { return nil }
        return panelFrame(under: window, in: screen.visibleFrame, size: size)
    }

    static func panelFrame(under window: CGRect, in screen: CGRect, size: CGSize) -> CGRect {
        let gap: CGFloat = 6
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(window.maxX - width, screen.minX), screen.maxX - width)
        let below = window.minY - gap - height
        let above = window.maxY + gap
        let y: CGFloat
        if below >= screen.minY {
            y = min(below, screen.maxY - height)
        } else if above + height <= screen.maxY {
            y = above
        } else {
            y = max(screen.minY, min(window.maxY - gap, screen.maxY) - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class DropHintHostingView: NSHostingView<PermissionDropHint> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PermissionDropHint: View {
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityLabel(Text("OpenDisplay app icon"))
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            Text("Drag this icon into the list and turn it on, or add it with +.")
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.separator)
                .allowsHitTesting(false)
        }
    }
}
