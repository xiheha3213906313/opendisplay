import SwiftUI
import Network
import Combine
import CoreGraphics

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return String(localized: "Menu bar")
        case .dock: return String(localized: "Dock")
        case .background: return String(localized: "Background only")
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        VirtualAudioOutputs.shared.shutdown()
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        let defaults = UserDefaults.standard
        let showPermissions = !defaults.bool(forKey: "hasSeenPermissionGuide") && !PermissionMonitor.shared.screenRecording
        defaults.set(true, forKey: "hasSeenPermissionGuide")
        if showPermissions || presentation != .menuBar {
            MainWindow.show(prioritizePermissions: showPermissions)
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(prioritizePermissions: Bool = false) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      prioritizePermissions: prioritizePermissions))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // legacy discovery, used for direct cable
    case lan(id: String, name: String)

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .lan(let id, _): return "lan:\(id)"
        case .wifi(let result):
            if case .bonjour(let txt) = result.metadata, let id = txt["id"] {
                return "cable:\(id.lowercased())"
            }
            if case .service(let name, _, _, _) = result.endpoint { return "cable:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender
    let displayIdentityKey: String

    @Published var status = SenderStatus(message: String(localized: "Starting…"))
    @Published var audioStatus: String?
    @Published var framesSent = 0
    var audioOffer: UUID?
    var audioOfferOrder: UInt64 = 0
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // Power actions the receiver offers on the live path (PROTOCOL.md 6.6).
    // Every hello replaces it, so it follows the session on and off the cable.
    @Published var powerActions: [PowerAction] = []
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    var usbHandoffToken: UUID?
    var waitingForUSBCable = false
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false
    var directTarget: ConnectionTarget?

    var transportLabel: String { onUSB ? "USB" : wired ? String(localized: "Cable") : "Wi‑Fi" }

    // The Display size control (extend only): the choice for this device
    // and what each choice gives on it, from the latest hello.
    private var lastHello: PhoneInfo?
    @Published private(set) var displaySize: DisplaySize = .default
    @Published private(set) var displaySizeOutcomes: [DisplaySizeOutcome] = []

    func helloArrived(_ info: PhoneInfo) {
        lastHello = info
        refreshDisplaySize()
    }

    func setDisplaySize(_ size: DisplaySize) {
        guard let info = lastHello else { return }
        sender.setDisplaySize(size, for: info)
        refreshDisplaySize()
    }

    /// Also called when the picker opens: the outcomes can change without a
    /// hello (an HEVC failure, a refused 2x mode).
    func refreshDisplaySize() {
        guard let info = lastHello else { return }
        displaySize = DisplaySizeStore.load(key: sender.displaySizeKey(for: info))
        let outcomes = sender.displaySizeOutcomes(for: info)
        if outcomes != displaySizeOutcomes { displaySizeOutcomes = outcomes }
    }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender, displayIdentityKey: String) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        self.displayIdentityKey = displayIdentityKey
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    // Every cabled device: usbmuxd's iPhones and iPads plus Android devices
    // in accessory mode (udid `aoa:<serial>`). The connection policy treats
    // them alike.
    @Published var usbDevices: [UsbmuxDevice] = []
    private var usbmuxDevices: [UsbmuxDevice] = []
    private var accessoryDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }

    var running: Bool { !sessions.isEmpty }

    @Published private(set) var audioDriverStatus = AudioDriverStatus.checking
    @Published private(set) var fallbackAudioDetail = String(localized: "No receiver is ready for audio. Sound stays on this Mac.")
    private var audioDriverChecks: AnyCancellable?
    private let fallbackAudioCapture = FallbackAudioCapture()
    private var latestAudioOfferOrder: UInt64 = 0
    private var fallbackAudioCaptureRequested = false
    private var fallbackAudioStopping = false
    private var fallbackAudioFailed = false

    private struct FallbackAudioRoute {
        let session: DeviceSession
        let offer: UUID
        let id = UUID()
    }

    private var fallbackAudioRoute: FallbackAudioRoute?

    let lan = LANService(role: .sender, id: LANService.senderInstallationID,
                         name: Host.current().localizedName ?? "Mac",
                         queue: DispatchQueue(label: "opendisplay.lan.sender"))
    private var lanSubscription: AnyCancellable?
    private var pausedLAN = Set(UserDefaults.standard.stringArray(forKey: "lan.pausedReceivers") ?? []) {
        didSet { UserDefaults.standard.set(Array(pausedLAN), forKey: "lan.pausedReceivers") }
    }
    private var resumeLAN = Set(UserDefaults.standard.stringArray(forKey: "lan.resumeReceivers") ?? []) {
        didSet { UserDefaults.standard.set(Array(resumeLAN), forKey: "lan.resumeReceivers") }
    }
    private var browser: NWBrowser?
    private let localLegacyBonjour = LocalBonjour()
    private var legacyBrowseResults: Set<NWBrowser.Result> = []
    /// Local Network access is off for this app. macOS has no API to ask,
    /// but a browse it blocks waits with a policy-denied error.
    @Published private(set) var localNetworkDenied = false
    private var browserRestart: Task<Void, Never>?
    private var browserRestartDelay = Duration.seconds(2)
    private var lastLoggedBrowserState = ""
    private var lastLoggedReceivers: [String]?
    private var usbWatcher: UsbmuxDeviceWatcher?
    private var accessoryWatcher: AccessoryDeviceWatcher?
    private var screenChanges: AnyCancellable?
    private var mainDisplaySelection = MainDisplaySelection()
    private var expectedMainDisplay: (window: UUID, display: CGDirectDisplayID, deadline: ContinuousClock.Instant)?

    private struct DisplayReference {
        let id: CGDirectDisplayID
        let session: DeviceSession?

        @MainActor var activeID: CGDirectDisplayID {
            if let session { return session.sender.virtualDisplayID ?? 0 }
            return id
        }
    }

    private struct USBHandoff {
        let window: AccessoryDetachWindow
        var session: DeviceSession
        let expectedReceiver: String?
        let wasMain: Bool
        let selectionRevision: UInt64
        var returnedAt: ContinuousClock.Instant?
        var mainBeforeRecreation: DisplayReference?
        var returningDisplay: CGDirectDisplayID?
        var restoreTask: Task<Void, Never>?
    }

    private var usbHandoffs: [String: USBHandoff] = [:]

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - A cable can replace a WiFi link for the same receiver. Removing
    //    the cable ends the session and clears that receiver's WiFi resume.
    // `-autostart NO` disables automatic attachment and resume.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Direct-link discovery is tracked per receiver across browse updates.
    private var onDirectCable: Set<String> = []
    // Service names the user disconnected while cabled. The record can
    // vanish and return without a replug (the receiver's display sleeps and
    // wakes, it restarts), and a cable-only receiver's unplug looks the
    // same, so the opt-out simply holds until the user connects by hand.
    // In memory: a relaunched sender starts fresh.
    private var cableOptOut: Set<String> = []
    // Accessory-mode devices whose receiver app quit (`closing`). Dialing one
    // opens the app again, so the next wired-list change must not redial it:
    // the opt-out holds until the device is unplugged or the user connects it.
    // In memory, like cableOptOut.
    private var receiverClosedOnCable: Set<String> = []
    private var attemptedUSB: Set<String> = []
    // Every service seen on the cable this run: a Disconnect counts as a
    // cable opt-out even while the record is briefly gone (receiver asleep).
    private var everOnCable: Set<String> = []

    init() {
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            self?.usbmuxDevices = devices
            self?.wiredDevicesChanged()
        }
        accessoryWatcher = AccessoryDeviceWatcher(onPresence: { [weak self] udid, event in
            self?.accessoryPresenceChanged(udid, event: event)
        }) { [weak self] devices in
            self?.accessoryDevices = devices
            self?.wiredDevicesChanged()
        }
        screenChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.screenConfigurationChanged()
            }
        audioDriverChecks = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshAudioDriverStatus() }
        refreshAudioDriverStatus()
        lanSubscription = lan.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        lan.allow = { [weak self] id, request in
            guard let self else { return false }
            if request == .manual { return true }
            return self.autoConnectEnabled && self.resumeLAN.contains(id) && !self.pausedLAN.contains(id)
                && !self.sessions.contains { $0.deviceID == id && ($0.onUSB || $0.wired) }
        }
        lan.onConnected = { [weak self] link in self?.acceptLAN(link) == true }
        lan.onCodeRequested = { MainWindow.show() }
        lan.start()
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        localLegacyBonjour.changed = { [weak self] in self?.publishLegacyReceivers() }
        localLegacyBonjour.start(type: "_opensidecar._tcp")
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.browserStateChanged(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.legacyBrowseResults = results
                self.publishLegacyReceivers()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func publishLegacyReceivers() {
        discovered = legacyBrowseResults.filter { !localLegacyBonjour.contains($0.endpoint, id: txtID(of: $0)) }
        logDiscoveredReceivers()
        endSessionsWhoseServiceVanished()
        autoConnect()
        connectNewlyCabled()
    }

    /// A browse that fails or is blocked shows no devices and logged nothing
    /// (#463): say why, and start over after a failure, which is final.
    private func browserStateChanged(_ state: NWBrowser.State) {
        let line: String
        switch state {
        case .ready:
            localNetworkDenied = false
            browserRestartDelay = .seconds(2)
            line = "WiFi discovery: browsing for receivers"
        case .waiting(let error):
            localNetworkDenied = Self.isPolicyDenied(error)
            line = localNetworkDenied
                ? "WiFi discovery: blocked, Local Network access is off for this app"
                    + " (System Settings > Privacy & Security > Local Network)"
                : "WiFi discovery: waiting (\(error))"
        case .failed(let error):
            localNetworkDenied = Self.isPolicyDenied(error)
            let delay = browserRestartDelay
            browserRestartDelay = min(delay * 2, .seconds(60))
            browser?.cancel()
            browserRestart?.cancel()
            browserRestart = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.startBrowsing()
            }
            line = "WiFi discovery: failed (\(error)), restarting in \(delay.components.seconds)s"
        default:
            return
        }
        // A browser can flap between the same states; log only a change.
        guard line != lastLoggedBrowserState else { return }
        lastLoggedBrowserState = line
        Log.info(line)
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    /// Which receivers the browse sees, logged when the set changes, so a
    /// report with an empty device list shows whether anything answered.
    private func logDiscoveredReceivers() {
        let names = discovered.compactMap { serviceName(of: $0) }.sorted()
        guard names != lastLoggedReceivers else { return }
        lastLoggedReceivers = names
        Log.info(names.isEmpty
                 ? "WiFi discovery: no receivers found"
                 : "WiFi discovery: found \(names.joined(separator: ", "))")
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"]?.lowercased() }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        guard let id = txtID(of: result) else { return false }
        return installIDByUDID[device.udid]?.lowercased() == id
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, let id = installIDByUDID[device.udid]?.lowercased() else { return false }
            return s.usbUDID == device.udid || s.deviceID == id
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let direct = session(for: ConnectionTarget.wifi(result).sessionID), !direct.failed {
            return direct
        }
        if let id = txtID(of: result), let secure = session(for: "lan:\(id)"), !secure.failed {
            return secure
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            return false
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            guard !receiverClosedOnCable.contains(device.udid),
                  !usbDisabled.contains("usb:\(device.udid)"),
                  !waitingForUSB(device.udid) else { continue }
            if let covering = activeSession(coveringUSB: device) {
                upgradeToUSB(covering, device: device)
            } else if attemptedUSB.insert(device.udid).inserted {
                connect(to: .usb(udid: device.udid))
            }
        }
    }

    private func acceptLAN(_ link: LANService.Authenticated) -> Bool {
        guard !sessions.contains(where: { $0.deviceID == link.id && ($0.onUSB || $0.wired || $0.directTarget != nil) }) else {
            return false
        }
        if let current = session(for: "lan:\(link.id)"), !current.failed {
            guard link.request == .resume else { return false }
            current.sender.replaceLAN(link.connection, receiverID: link.id)
            return true
        }
        pausedLAN.remove(link.id)
        connect(to: .lan(id: link.id, name: link.name), authenticated: link)
        return session(for: "lan:\(link.id)") != nil
    }

    func forgetLAN(_ id: String) {
        if let session = session(for: "lan:\(id)") { disconnect(session) }
        resumeLAN.remove(id)
        lan.forget(id)
    }

    /// A Mac receiver just appeared on the direct cable: connect to it unless
    /// a session already covers it (a live WiFi session moves onto the cable
    /// through the sender's own upgrade probe instead).
    private func connectNewlyCabled() {
        let cabled = discovered.filter { $0.interfaces.contains(where: DirectCable.isDirectLink) }
        let current = Set(cabled.map { ConnectionTarget.wifi($0).sessionID })
        let added = current.subtracting(onDirectCable)
        onDirectCable = current
        everOnCable.formUnion(cabled.compactMap(serviceName))
        guard autoConnectEnabled else { return }
        for result in cabled {
            let target = ConnectionTarget.wifi(result)
            guard added.contains(target.sessionID),
                  let name = serviceName(of: result), !cableOptOut.contains(name),
                  !usbDevices.contains(where: { sameDevice(result, $0) }) else { continue }
            if let existing = activeSession(coveringWiFi: result) {
                if case .lan = existing.target, !existing.onUSB, !existing.wired,
                   let endpoint = cableEndpoint(result) {
                    if let id = existing.deviceID { resumeLAN.remove(id) }
                    existing.directTarget = target
                    existing.sender.switchTransport(to: .tcp(endpoint))
                }
            } else {
                connect(to: target)
            }
        }
    }

    private func cableEndpoint(_ result: NWBrowser.Result) -> NWEndpoint? {
        guard !localLegacyBonjour.contains(result.endpoint, id: txtID(of: result)),
              let interface = result.interfaces.first(where: DirectCable.isDirectLink),
              case let .service(name, type, domain, _) = result.endpoint else { return nil }
        return .service(name: name, type: type, domain: domain, interface: interface)
    }

    private func wiredDevicesChanged() {
        let devices = usbmuxDevices + accessoryDevices
        let detached = Set(usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
        usbDevices = devices
        receiverClosedOnCable.subtract(detached)
        attemptedUSB.subtract(detached)
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detached.contains(udid) else { continue }
            if let serial = AOA.serial(fromUDID: udid) { AccessoryRelay.close(serial: serial) }
            end(session)
        }
        autoConnect()
    }

    private func waitingForUSB(_ udid: String) -> Bool {
        guard let handoff = usbHandoffs[udid] else { return false }
        return handoff.returnedAt == nil
    }

    private func updateMainDisplaySelection() {
        let main = CGMainDisplayID()
        let expected = expectedMainDisplay
        mainDisplaySelection.observe(main: main, active: MainDisplaySelection.activeDisplays(),
                                     requestedMain: expected?.display)
        if let expected, main == expected.display || ContinuousClock.now >= expected.deadline {
            expectedMainDisplay = nil
        }
    }

    private func screenConfigurationChanged() {
        let previouslyActive = mainDisplaySelection.active
        let revision = mainDisplaySelection.selectionRevision
        updateMainDisplaySelection()
        if !usbHandoffs.isEmpty, mainDisplaySelection.selectionRevision != revision {
            let choice = currentMainDisplayReference()
            for udid in Array(usbHandoffs.keys) { usbHandoffs[udid]?.mainBeforeRecreation = choice }
            sessions.forEach { $0.sender.adoptCurrentDisplayOrigin() }
        }
        if let handoff = usbHandoffs.values.first(where: { $0.returningDisplay == mainDisplaySelection.main }),
           !previouslyActive.contains(mainDisplaySelection.main) {
            holdMainDisplayForUSBReturn(handoff)
        }
        withdrawMissingPrimaryDisplays()
        reconcileAudioRouting()
    }

    private func accessoryPresenceChanged(_ udid: String, event: AccessoryDeviceWatcher.Presence) {
        switch event {
        case .lost(let window):
            guard !window.expectedReenumeration,
                  let session = sessions.first(where: { $0.onUSB && $0.usbUDID == udid && !$0.failed }) else { return }
            cancelUSBHandoff(for: session, reason: "USB cable removed again")
            updateMainDisplaySelection()
            let wasMain = session.sender.virtualDisplayID == mainDisplaySelection.main
            usbHandoffs[udid] = USBHandoff(window: window, session: session,
                                            expectedReceiver: session.deviceID, wasMain: wasMain,
                                            selectionRevision: mainDisplaySelection.selectionRevision)
            session.usbHandoffToken = window.id
            if wasMain {
                session.sender.deferDisplayArrangementForUSB(true)
                VirtualAudioOutputs.shared.beginUSBReturn(window, session: session.sender.audioSession)
            }
        case .displayDeadline(let window):
            guard usbHandoffs[udid]?.window.id == window.id else { return }
            withdrawMissingPrimaryDisplays()
        case .returned(let window):
            guard var handoff = usbHandoffs[udid], handoff.window.id == window.id else { return }
            handoff.returnedAt = .now
            usbHandoffs[udid] = handoff
            let session = handoff.session
            if session.waitingForUSBCable {
                end(session, preservingUSBHandoff: true)
                connect(to: .usb(udid: udid), restoringUSB: window.id)
                if usbHandoffs[udid]?.session === session { cancelUSBHandoff(for: session) }
            } else if handoff.wasMain {
                VirtualAudioOutputs.shared.resumeUSBReturn(window.id, session: session.sender.audioSession)
            }
        }
    }

    private func withdrawMissingPrimaryDisplays() {
        let now = ContinuousClock.now
        let main = CGMainDisplayID()
        for handoff in usbHandoffs.values {
            let session = handoff.session
            guard handoff.returnedAt == nil, handoff.window.shouldWithdrawDisplay(at: now),
                  !session.waitingForUSBCable, let display = session.sender.virtualDisplayID,
                  handoff.wasMain || display == main else { continue }
            session.waitingForUSBCable = true
            session.sender.stop()
            session.status = SenderStatus(message: String(localized: "Waiting for the Android USB cable…"))
            session.audioStatus = nil
            reconcileAudioRouting()
            Log.info("AOA: withdrew offline virtual display \(display) after USB disconnect")
        }
    }

    private func prepareReturningUSBDisplay(for session: DeviceSession) {
        guard let udid = session.usbUDID, let handoff = usbHandoffs[udid],
              handoff.session === session, handoff.returnedAt != nil,
              handoff.mainBeforeRecreation == nil else { return }
        updateMainDisplaySelection()
        usbHandoffs[udid]?.mainBeforeRecreation = currentMainDisplayReference()
    }

    private func currentMainDisplayReference() -> DisplayReference {
        let main = mainDisplaySelection.main
        return DisplayReference(id: main, session: sessions.first(where: { $0.sender.virtualDisplayID == main }))
    }

    private func returningUSBDisplayCreated(for session: DeviceSession, display: CGDirectDisplayID) {
        guard let udid = session.usbUDID, var handoff = usbHandoffs[udid],
              handoff.session === session, handoff.returnedAt != nil else { return }
        handoff.returningDisplay = display
        usbHandoffs[udid] = handoff
        updateMainDisplaySelection()
        holdMainDisplayForUSBReturn(handoff)
    }

    private func holdMainDisplayForUSBReturn(_ handoff: USBHandoff) {
        guard handoff.restoreTask == nil, handoff.returningDisplay == mainDisplaySelection.main,
              let previous = handoff.mainBeforeRecreation?.activeID, previous != mainDisplaySelection.main,
              mainDisplaySelection.active.contains(previous) else { return }
        let result = submitMainDisplay(previous, window: handoff.window.id)
        Log.info("AOA: held main display \(previous) pending USB video: \(result)")
    }

    private func finishUSBDisplayReturn(for session: DeviceSession, display: CGDirectDisplayID,
                                        receiver: String?, at instant: ContinuousClock.Instant) {
        guard let udid = session.usbUDID, let handoff = usbHandoffs[udid],
              handoff.session === session, let returnedAt = handoff.returnedAt,
              instant >= returnedAt, handoff.restoreTask == nil else { return }
        if let expected = handoff.expectedReceiver, expected != receiver?.lowercased() {
            cancelUSBHandoff(for: session, reason: "receiver installation changed")
            return
        }
        updateMainDisplaySelection()
        let manuallyChanged = mainDisplaySelection.selectionRevision != handoff.selectionRevision
        let target: CGDirectDisplayID
        if handoff.wasMain, !manuallyChanged {
            target = display
        } else if mainDisplaySelection.main == display,
                  let previous = handoff.mainBeforeRecreation?.activeID, previous != display,
                  mainDisplaySelection.active.contains(previous) {
            // WindowServer can restore the old main during display creation.
            target = previous
        } else {
            let reason = manuallyChanged ? "main display changed manually" : "receiver was not the main display"
            completeUSBDisplayReturn(udid, window: handoff.window.id, result: reason)
            return
        }
        let window = handoff.window.id
        let revision = mainDisplaySelection.selectionRevision
        usbHandoffs[udid]?.restoreTask = Task { [weak self] in
            await self?.restoreUSBMainDisplay(target, returningDisplay: display, udid: udid,
                                              window: window, revision: revision)
        }
    }

    private func submitMainDisplay(_ display: CGDirectDisplayID, window: UUID) -> MainDisplaySelection.Submission {
        expectedMainDisplay = (window, display, .now + .seconds(1))
        sessions.forEach { $0.sender.adoptCurrentDisplayOrigin() }
        let result = MainDisplaySelection.submit(display)
        if case .submitted = result, expectedMainDisplay?.window == window {
            expectedMainDisplay?.deadline = .now + .seconds(1)
        }
        updateMainDisplaySelection()
        if case .failed = result, expectedMainDisplay?.window == window { expectedMainDisplay = nil }
        if case .layoutUnavailable = result, expectedMainDisplay?.window == window { expectedMainDisplay = nil }
        return result
    }

    private func restoreUSBMainDisplay(_ display: CGDirectDisplayID, returningDisplay: CGDirectDisplayID,
                                       udid: String, window: UUID, revision: UInt64) async {
        for attempt in 1...2 {
            guard mayRestoreUSBMainDisplay(udid, window: window, display: returningDisplay, revision: revision) else {
                return
            }
            let result = submitMainDisplay(display, window: window)
            Log.info("AOA: USB main display \(display) attempt \(attempt): \(result); current \(mainDisplaySelection.main)")
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                guard mayRestoreUSBMainDisplay(udid, window: window, display: returningDisplay, revision: revision) else {
                    return
                }
                if mainDisplaySelection.main == display {
                    sessions.forEach { $0.sender.adoptCurrentDisplayOrigin() }
                    completeUSBDisplayReturn(udid, window: window, result: "confirmed main display \(display)")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            } while ContinuousClock.now < deadline
        }
        completeUSBDisplayReturn(udid, window: window,
                                 result: "Quartz did not apply main display \(display); current \(CGMainDisplayID())")
    }

    private func mayRestoreUSBMainDisplay(_ udid: String, window: UUID, display: CGDirectDisplayID,
                                          revision: UInt64) -> Bool {
        guard !Task.isCancelled, let handoff = usbHandoffs[udid], handoff.window.id == window else { return false }
        guard handoff.session.onUSB, handoff.session.sender.virtualDisplayID == display else {
            completeUSBDisplayReturn(udid, window: window, result: "session or display no longer active")
            return false
        }
        updateMainDisplaySelection()
        guard mainDisplaySelection.selectionRevision == revision else {
            completeUSBDisplayReturn(udid, window: window, result: "main display changed manually")
            return false
        }
        return true
    }

    private func completeUSBDisplayReturn(_ udid: String, window: UUID, result: String) {
        guard let handoff = usbHandoffs[udid], handoff.window.id == window else { return }
        usbHandoffs[udid] = nil
        if expectedMainDisplay?.window == window { expectedMainDisplay = nil }
        handoff.session.sender.deferDisplayArrangementForUSB(false)
        Log.info("AOA: USB display return for \(handoff.session.name): \(result)")
    }

    private func cancelUSBHandoff(for session: DeviceSession, reason: String = "session ended") {
        if let udid = session.usbUDID, let handoff = usbHandoffs[udid], handoff.session === session {
            handoff.restoreTask?.cancel()
            completeUSBDisplayReturn(udid, window: handoff.window.id, result: reason)
        }
        guard let token = session.usbHandoffToken else { return }
        session.usbHandoffToken = nil
        VirtualAudioOutputs.shared.cancelUSBReturn(token)
    }

    /// How to dial a cabled device: usbmuxd, or accessory mode for Android.
    private func wiredTransport(udid: String?, port: UInt16) -> SenderTransport {
        if let serial = udid.flatMap(AOA.serial(fromUDID:)) {
            return .accessory(serial: serial)
        }
        return .usb(udid: udid, port: port)
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        session.directTarget = nil
        if let id = session.deviceID { resumeLAN.remove(id) }
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: wiredTransport(udid: device.udid, port: portNum))
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard case .wifi = session.target else { continue }
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        // Failed sessions hold no pipeline: a USB corpse must never win the
        // "keep the cable" rule against a working WiFi session.
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target, !s.failed { return s.deviceID }
            return nil
        })
        for s in sessions where !s.onUSB {
            guard let id = s.deviceID, usbSessionIDs.contains(id) else { continue }
            resumeLAN.remove(id)
            end(s)
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            if udid == nil { return "Manual (\(host):\(port))" }
            return udid.flatMap(AOA.serial(fromUDID:)) == nil ? "iPhone / iPad" : "Android device"
        case .lan(_, let name): return name
        case .wifi(let result):
            return serviceName(of: result) ?? "Cabled Mac"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false, authenticated: LANService.Authenticated? = nil,
                 restoringUSB: UUID? = nil) {
        if case .lan(let id, _) = target, authenticated == nil {
            guard userInitiated, let peer = lan.peers.first(where: { $0.id == id }) else { return }
            lan.connect(to: peer, request: .manual)
            return
        }
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb(let udid):
            usbDisabled.remove(id)
            if userInitiated, let udid { receiverClosedOnCable.remove(udid) }
        case .wifi(let result):
            if userInitiated, let name = serviceName(of: result) { cableOptOut.remove(name) }
        case .lan: break
        }

        let transport: SenderTransport
        var manualReceiverBrowse: LocalBonjour?
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
                manualReceiverBrowse = localLegacyBonjour
            } else {
                transport = wiredTransport(udid: udid, port: portNum)
            }
        case .wifi(let result):
            guard let endpoint = cableEndpoint(result) else { return }
            transport = .tcp(endpoint)
        case .lan:
            guard let authenticated else { return }
            transport = .secure(authenticated.connection, receiverID: authenticated.id)
        }

        let handoff: USBHandoff?
        if case .usb(let udid?) = target, let pending = usbHandoffs[udid],
           pending.window.id == restoringUSB {
            handoff = pending
        } else {
            handoff = nil
        }
        let identityKey = handoff?.session.displayIdentityKey ?? id
        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, displaySerial: Self.displaySerial(for: identityKey),
                               identityOffset: identityOffset(for: identityKey),
                               awaitingWake: awaitingWake,
                               manualReceiverBrowse: manualReceiverBrowse,
                               queue: authenticated?.queue ?? DispatchQueue(label: "sender.video"))
        let session = DeviceSession(id: id, target: target, name: name, sender: sender,
                                    displayIdentityKey: identityKey)
        if let handoff, let udid = session.usbUDID {
            usbHandoffs[udid]?.session = session
            session.usbHandoffToken = handoff.window.id
            sender.deferDisplayArrangementForUSB(true)
            VirtualAudioOutputs.shared.resumeUSBReturn(handoff.window.id, session: sender.audioSession)
        }
        session.deviceID = authenticated?.id
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
            session.directTarget = target
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, !session.waitingForUSBCable, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text.message)")
        }
        sender.onAudioState = { [weak session] status in
            guard session?.waitingForUSBCable == false else { return }
            session?.audioStatus = status
        }
        sender.onAudioOffer = { [weak self, weak session] offer in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            session.audioOffer = offer
            if offer != nil {
                self.latestAudioOfferOrder &+= 1
                session.audioOfferOrder = self.latestAudioOfferOrder
                self.fallbackAudioFailed = false
            }
            self.reconcileAudioRouting()
        }
        sender.onFallbackAudioReady = { [weak self] route, mailbox in
            self?.startFallbackAudio(route: route, mailbox: mailbox)
        }
        sender.onPreparingUSBDisplay = { [weak self, weak session] in
            if let session { self?.prepareReturningUSBDisplay(for: session) }
        }
        sender.onCreatedUSBDisplay = { [weak self, weak session] display in
            if let session { self?.returningUSBDisplayCreated(for: session, display: display) }
        }
        sender.onUSBVideoReady = { [weak self, weak session] display, receiver, instant in
            if let session { self?.finishUSBDisplayReturn(for: session, display: display, receiver: receiver, at: instant) }
        }
        sender.maySaveDisplayArrangement = { [weak self] in self?.usbHandoffs.isEmpty ?? false }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            guard self.sessions.contains(where: { $0 === session }) else { return }
            session.deviceID = info.id?.lowercased()
            session.deviceKind = info.device
            session.helloArrived(info)
            let power = (info.power ?? []).compactMap(PowerAction.init(rawValue:))
            if power != session.powerActions {
                Log.info("session \(session.id) power actions: "
                    + (power.isEmpty ? "none" : power.map(\.rawValue).joined(separator: ",")))
                session.powerActions = power
            }
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID.lowercased()
            }
            if let id = session.deviceID {
                if case .lan = session.target, !session.onUSB, session.directTarget == nil {
                    self.resumeLAN.insert(id)
                }
                else { self.resumeLAN.remove(id) }
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, _ in
            session?.framesSent = frames
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session, !session.waitingForUSBCable else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            let target = self.wiredTarget(for: session)
            self.end(session)
            if self.autoConnectEnabled, case .usb(let udid?) = target,
               !self.usbDisabled.contains("usb:\(udid)"),
               let serial = AOA.serial(fromUDID: udid), AccessoryRelay.reusable(serial: serial) != nil {
                self.connect(to: .usb(udid: udid), awaitingWake: true)
            }
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session, !session.waitingForUSBCable else { return }
            let target = self.wiredTarget(for: session)
            self.end(session)
            if let target { self.connect(to: target, awaitingWake: true) }
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session, !session.waitingForUSBCable else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: identityKey))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session, !session.waitingForUSBCable else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            let retry = self.wiredTarget(for: session)
            var legacyAccessory = false
            if session.onUSB, let udid = session.usbUDID, AOA.serial(fromUDID: udid) != nil {
                if let serial = AOA.serial(fromUDID: udid), AccessoryRelay.reusable(serial: serial) == nil {
                    self.receiverClosedOnCable.insert(udid)
                    legacyAccessory = true
                }
            }
            self.end(session)
            if !legacyAccessory, self.autoConnectEnabled, let retry {
                self.connect(to: retry, awaitingWake: true)
            }
        }
        sender.onPeerRequestedDisconnect = { [weak self, weak session] in
            guard let self, let session else { return }
            self.disconnect(session, notify: false)
        }
        sessions.append(session)
        reconcileAudioRouting()
        Task {
            do {
                try await sender.start()
                self.reconcileAudioRouting()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = SenderStatus(message: String(localized: "Failed: \(error.localizedDescription)"), phase: .failed)
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                self.cancelUSBHandoff(for: session)
                sender.stop()
                self.reconcileAudioRouting()
            }
        }
    }

    private func wiredTarget(for session: DeviceSession) -> ConnectionTarget? {
        if let udid = session.usbUDID, session.onUSB,
           !waitingForUSB(udid), usbDevices.contains(where: { $0.udid == udid }) { return .usb(udid: udid) }
        if let target = session.directTarget, session.wired {
            if let result = wifiService(for: session) { return .wifi(result) }
            return target
        }
        return nil
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession, notify: Bool = true) {
        cancelUSBHandoff(for: session, reason: "user disconnected")
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .lan: break
        case .wifi:
            if let name = session.wifiServiceName, everOnCable.contains(name) {
                cableOptOut.insert(name)
            }
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if case .wifi(let cable) = session.directTarget, let name = serviceName(of: cable) {
            cableOptOut.insert(name)
        }
        if let id = session.deviceID {
            pausedLAN.insert(id)
            resumeLAN.remove(id)
        }
        let finish: () -> Void = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            if let serial = session.usbUDID.flatMap(AOA.serial(fromUDID:)) { AccessoryRelay.close(serial: serial) }
            self.end(session)
        }
        if notify {
            session.sender.notifyExplicitDisconnect { finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
        } else {
            finish()
        }
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = wiredTarget(for: session) ?? session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession, preservingUSBHandoff: Bool = false) {
        if !preservingUSBHandoff { cancelUSBHandoff(for: session) }
        session.sender.stop()
        sessions.removeAll { $0 === session }
        reconcileAudioRouting()
    }

    // MARK: - Audio output

    func refreshAudioDriverStatus() {
        VirtualAudioOutputs.shared.checkInstallStatus { [weak self] status in
            guard let self, self.audioDriverStatus != status else { return }
            self.audioDriverStatus = status
            self.reconcileAudioRouting()
        }
    }

    private func reconcileAudioRouting() {
        let candidates = sessions.filter { !$0.failed && !$0.waitingForUSBCable && $0.audioOffer != nil }
            .sorted { $0.audioOfferOrder < $1.audioOfferOrder }
        if candidates.isEmpty { fallbackAudioFailed = false }
        guard audioDriverStatus == .missing else {
            stopFallbackAudio()
            if !fallbackAudioStopping, audioDriverStatus != .checking {
                sessions.forEach { $0.sender.setAudioMode(.driver) }
            }
            return
        }

        guard #available(macOS 14.2, *), !fallbackAudioFailed else {
            stopFallbackAudio()
            sessions.forEach { $0.sender.setAudioMode(.off) }
            setFallbackAudioDetail(fallbackAudioFailed
                ? String(localized: "Sound stays on this Mac. Check System Audio Recording access and reconnect.")
                : String(localized: "Sound is playing on this Mac. Audio without the driver requires macOS 14.2 or later."))
            return
        }

        let offer = FallbackAudioRouting.preferredOffer(mainDisplay: CGMainDisplayID(), candidates: candidates.map {
            FallbackAudioRouting.Candidate(offer: $0.audioOffer, displayID: $0.sender.virtualDisplayID)
        })
        if fallbackAudioRoute?.offer != offer { stopFallbackAudio() }
        if fallbackAudioRoute == nil, let offer,
           let session = candidates.first(where: { $0.audioOffer == offer }), !fallbackAudioStopping {
            fallbackAudioRoute = FallbackAudioRoute(session: session, offer: offer)
            setFallbackAudioDetail(String(localized: "Connecting audio to \(session.name)…"))
        } else if fallbackAudioRoute == nil {
            setFallbackAudioDetail(String(localized: "No receiver is ready for audio. Sound stays on this Mac."))
        }
        for session in sessions {
            if let route = fallbackAudioRoute, route.session === session {
                session.sender.setAudioMode(.fallback(route: route.id, offer: route.offer))
            } else {
                session.sender.setAudioMode(.off)
            }
        }
    }

    private func setFallbackAudioDetail(_ detail: String) {
        if fallbackAudioDetail != detail { fallbackAudioDetail = detail }
    }

    private func startFallbackAudio(route: UUID, mailbox: AudioOutputMailbox) {
        guard #available(macOS 14.2, *), audioDriverStatus == .missing,
              let target = fallbackAudioRoute, target.id == route else { return }
        fallbackAudioCaptureRequested = true
        fallbackAudioCapture.start(mailbox: mailbox) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.fallbackAudioRoute?.id == route else { return }
                switch result {
                case .success:
                    self.setFallbackAudioDetail(String(localized: "Playing on \(target.session.name) without the driver."))
                case .failure(let error):
                    Log.info("fallback audio: \(error.localizedDescription)")
                    self.fallbackAudioFailed = true
                    self.reconcileAudioRouting()
                }
            }
        }
    }

    private func stopFallbackAudio() {
        guard let route = fallbackAudioRoute else { return }
        fallbackAudioRoute = nil
        route.session.sender.setAudioMode(.off)
        guard fallbackAudioCaptureRequested else { return }
        fallbackAudioCaptureRequested = false
        fallbackAudioStopping = true
        fallbackAudioCapture.stop { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fallbackAudioStopping = false
                self.reconcileAudioRouting()
            }
        }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.compactMap { session -> ConnectionTarget? in
            if let wired = wiredTarget(for: session) { return wired }
            if case .lan = session.target { return nil }
            return session.target
        }
        sessions.forEach { end($0) }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?
        var requiresUpdate = false

        var transportLabel: String {
            let wired = if case .wifi = usbTarget { String(localized: "Cable") } else { "USB" }
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "\(wired) · Wi‑Fi"
            case (true, false): return wired
            case (false, true): return "Wi‑Fi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin { mergedServices.insert(ConnectionTarget.wifi(twin).sessionID) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? label(for: usbTarget),
                usbTarget: usbTarget,
                wifiTarget: nil))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for peer in lan.peers {
            let target = ConnectionTarget.lan(id: peer.id, name: peer.name)
            coveredSessionIDs.insert(target.sessionID)
            if let index = entries.firstIndex(where: { entry in
                guard case .usb(let udid?) = entry.usbTarget else { return false }
                return installIDByUDID[udid]?.lowercased() == peer.id
            }) {
                let entry = entries[index]
                entries[index] = DeviceEntry(id: entry.id, name: entry.name, usbTarget: entry.usbTarget, wifiTarget: target)
            } else {
                entries.append(DeviceEntry(id: target.sessionID, name: peer.name, usbTarget: nil, wifiTarget: target))
            }
        }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            guard let name = serviceName(of: result), !mergedServices.contains(target.sessionID) else { continue }
            let direct = result.interfaces.contains(where: DirectCable.isDirectLink)
            if let id = txtID(of: result), lan.peers.contains(where: { $0.id == id }), !direct { continue }
            coveredSessionIDs.insert(target.sessionID)
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            if direct, let id = txtID(of: result),
               let index = entries.firstIndex(where: { $0.id == "lan:\(id)" }) {
                let entry = entries[index]
                entries[index] = DeviceEntry(id: entry.id, name: entry.name, usbTarget: target,
                                             wifiTarget: entry.wifiTarget)
            } else {
                entries.append(DeviceEntry(id: target.sessionID, name: name,
                                           usbTarget: direct ? target : nil, wifiTarget: nil,
                                           requiresUpdate: !direct))
            }
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published var screenRecording = false
    @Published var accessibility = false
    @Published var audioDriverAlert = false
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    func installAudioDriver() {
        guard let pkg = Bundle.main.url(forResource: "OpenDisplayAudioDriver", withExtension: "pkg"),
              NSWorkspace.shared.open(pkg) else {
            audioDriverAlert = true
            return
        }
    }

    func isGranted(_ permission: SenderPermission) -> Bool {
        switch permission {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject private var permissions = PermissionMonitor.shared
    @State private var settingsUnavailable = false
    var prioritizePermissions = false

    private var showPermissionsFirst: Bool { prioritizePermissions && !permissions.screenRecording }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads, iPhones and Macs as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button("Disconnect All") { controller.disconnectAll() }
                        .controlSize(.large)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                if showPermissionsFirst { permissionsSection }
                Section("Devices") {
                    LANCodeForm(lan: controller.lan, forget: controller.forgetLAN)
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.requiresUpdate
                                         ? String(localized: "Update OpenDisplay on this receiver to connect over Wi-Fi.")
                                         : entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let wired = entry.usbTarget, let wifi = entry.wifiTarget {
                                    Menu("Connect") {
                                        Button("Connect over cable") {
                                            controller.connect(to: wired, userInitiated: true)
                                        }
                                        Button("Connect over Wi-Fi") {
                                            controller.connect(to: wifi, userInitiated: true)
                                        }
                                    }
                                    .controlSize(.small)
                                } else if let target = entry.preferredTarget {
                                    Button("Connect") {
                                        controller.connect(to: target, userInitiated: true)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Picker("Mode", selection: $controller.mode) {
                    Text("Extend").tag(CaptureMode.extend)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.mode) { controller.restartAll() }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                if !showPermissionsFirst { permissionsSection }
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                connectionCount
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                CheckForUpdatesView(product: .sender)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 540)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            controller.refreshAudioDriverStatus()
            controller.lan.retryLocalNetworkDiscovery()
        }
        .onReceive(NotificationCenter.default.publisher(for: VirtualAudioOutputs.devicesChanged)) { _ in
            controller.refreshAudioDriverStatus()
        }
        .alert("Audio driver installer unavailable", isPresented: $permissions.audioDriverAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open an OpenDisplay build that includes the driver installer, then try again.")
        }
        .alert("Could not open System Settings", isPresented: $settingsUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open Privacy & Security in System Settings, then choose the permission you want to grant.")
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            ForEach(SenderPermission.allCases) { permission in
                permissionRow(permission)
            }
            audioDriverRow
            if controller.localNetworkDenied || controller.lan.localNetworkDenied {
                LabeledContent("Local Network access is off.") {
                    Button("Open Settings") { MacPrivacySettings.open("Privacy_LocalNetwork") }
                        .controlSize(.small)
                }
            }
        }
    }

    private var connectionCount: Text {
        switch controller.sessions.count {
        case 0: return Text("Idle")
        case 1: return Text("1 device connected")
        default: return Text("\(controller.sessions.count) devices connected")
        }
    }

    private var audioDriverRow: some View {
        let status = controller.audioDriverStatus
        let detail: String
        switch status {
        case .checking: detail = String(localized: "Checking driver…")
        case .missing: detail = controller.fallbackAudioDetail
        case .restartRequired: detail = String(localized: "Installed. Restart macOS to load the driver.")
        case .ready: detail = String(localized: "Ready for Android sound.")
        case .updateAvailable: detail = String(localized: "Update to use Android system volume controls.")
        }
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: status == .ready ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(status == .ready ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Driver")
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .missing || status == .updateAvailable {
                Button(status == .missing ? LocalizedStringKey("Install…") : LocalizedStringKey("Update…")) {
                    permissions.installAudioDriver()
                }
                .controlSize(.small)
            }
        }
    }

    private func permissionRow(_ permission: SenderPermission) -> some View {
        let granted = permissions.isGranted(permission)
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                if !granted {
                    Text(permission.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if permission == .screenRecording {
                        Text("If macOS asks, quit and reopen OpenDisplay after allowing access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    settingsUnavailable = !PermissionGuide.shared.openSettings(for: permission)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController
    @State private var confirmingShutdown = false
    @State private var choosingDisplaySize = false

    private var statusColor: Color {
        switch session.status.phase {
        case .waiting: return .orange
        case .active: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(verbatim: "\(session.transportLabel) · \(session.status.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let audioStatus = session.audioStatus {
                    Text(audioStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // A live session recovers on its own (liveness watchdog, redial,
            // transport failover), so only a failed start gets a button.
            if session.failed {
                Button("Retry") { controller.retry(session) }
                    .controlSize(.small)
                    .help("Start this connection over")
            }
            if session.powerActions.contains(.shutdown) {
                Button {
                    confirmingShutdown = true
                } label: {
                    Image(systemName: "power")
                }
                .controlSize(.small)
                .help("Shut down \(title)")
                .confirmationDialog("Shut down \(title) now?", isPresented: $confirmingShutdown) {
                    Button("Shut Down", role: .destructive) { session.sender.requestPower(.shutdown) }
                } message: {
                    Text("Apps on it with unsaved changes can still stop the shutdown.")
                }
            }
            if !session.displaySizeOutcomes.isEmpty {
                Button {
                    choosingDisplaySize = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Display size of \(title)")
                .popover(isPresented: $choosingDisplaySize, arrowEdge: .bottom) {
                    DisplaySizePicker(session: session)
                }
            }
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}

/// The per-device desktop size, macOS Displays style: each choice with the
/// exact desktop it gives underneath, and the stream when it is not 1:1.
@MainActor
struct DisplaySizePicker: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display size").font(.headline)
            Picker("Display size", selection: Binding(
                get: { session.displaySize },
                set: { session.setDisplaySize($0) })) {
                ForEach(session.displaySizeOutcomes, id: \.choice) { outcome in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.choice.title)
                        Text(caption(for: outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(outcome.choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(14)
        .fixedSize()
        .onAppear { session.refreshDisplaySize() }
    }

    private func caption(for outcome: DisplaySizeOutcome) -> String {
        let sameAsDefault = outcome.choice != .default
            && outcome.desktop == session.displaySizeOutcomes.first(where: { $0.choice == .default })?.desktop
        return sameAsDefault ? String(localized: "\(outcome.caption) (same as Default)") : outcome.caption
    }
}

