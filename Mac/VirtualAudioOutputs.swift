import CoreAudio
import Foundation

enum AudioDriverStatus: Equatable {
    case checking, missing, restartRequired, ready, updateAvailable
}

/// Transfers the latest packet without queuing one closure per audio block on
/// a sender whose network and video queue is busy.
final class AudioOutputMailbox {
    private let lock = NSLock()
    private var pending: (Data, DispatchTime)?
    private let delivery: DispatchSourceUserDataAdd

    init(queue: DispatchQueue, receive: @escaping (Data) -> Void) {
        delivery = DispatchSource.makeUserDataAddSource(queue: queue)
        delivery.setEventHandler { [weak self] in
            guard let self, let packet = self.take(),
                  DispatchTime.now() < packet.1 else { return }
            receive(packet.0)
        }
        delivery.resume()
    }

    func offer(_ packet: Data) {
        lock.lock()
        pending = (packet, .now() + .milliseconds(80))
        lock.unlock()
        delivery.add(data: 1)
    }

    private func take() -> (Data, DispatchTime)? {
        lock.lock()
        defer { lock.unlock() }
        let packet = pending
        pending = nil
        return packet
    }

    deinit { delivery.cancel() }
}

/// One Core Audio registry for all sender sessions. Changing output here
/// follows the system's default media route. Volume is handled by each
/// virtual device's own controls.
final class VirtualAudioOutputs {
    static let shared = VirtualAudioOutputs()
    static let devicesChanged = Notification.Name("OpenDisplayAudioDevicesChanged")

    private static let protocolVersion = 2
    private static let versionProperty: AudioObjectPropertySelector = 0x6f647672 // odvr
    private static let registryProperty: AudioObjectPropertySelector = 0x6f647267 // odrg
    private static let pcmProperty: AudioObjectPropertySelector = 0x6f647063 // odpc
    private static let volumeProtocolProperty: AudioObjectPropertySelector = 0x6f647670 // odvp
    private static let volumeControlProperty: AudioObjectPropertySelector = 0x6f647663 // odvc
    #if DEBUG
    private static let bundleID = "app.opendisplay.audio.driver.debug"
    #else
    private static let bundleID = "app.opendisplay.audio.driver"
    #endif

    private struct Route {
        let session: UUID
        let uid: String
        let name: String
        let mailbox: AudioOutputMailbox
        let onFailure: (String) -> Void
        let request: UUID
        let sendVolume: (AndroidVolumeCommand) -> Void
        var volume: RemoteAudioVolume?
        var didReadVolume = false
        var onRegistered: (() -> Void)?
    }

    private struct PendingDefault {
        let origin: String?
        let destination: String
        let expires: DispatchTime
    }

    private let queue = DispatchQueue(label: "sender.audio-outputs")
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let registryToken = UUID().uuidString as CFString
    private let heartbeat: DispatchSourceTimer
    private let pcmTimer: DispatchSourceTimer
    private var audioParticipants = Set<UUID>()
    private var routes: [Route] = []
    private var objectIDs: [String: AudioObjectID] = [:]
    private var routing = AudioOutputRouting()
    private var pendingDefault: PendingDefault?
    private var nextVolumePoll = DispatchTime.now()

    private init() {
        heartbeat = DispatchSource.makeTimerSource(queue: queue)
        pcmTimer = DispatchSource.makeTimerSource(queue: queue)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, queue, { [weak self] _, _ in
                self?.refreshDevices()
                if selector == kAudioHardwarePropertyDevices {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.devicesChanged, object: nil)
                    }
                }
            })
        }
        heartbeat.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        heartbeat.setEventHandler { [weak self] in self?.renewRegistry() }
        heartbeat.resume()
        pcmTimer.setEventHandler { [weak self] in self?.drainPCM() }
        pcmTimer.resume()
    }

    func checkDriver(_ completion: @escaping (String?) -> Void) {
        queue.async { completion(self.driverProblem()) }
    }

    func checkInstallStatus(_ completion: @escaping (AudioDriverStatus) -> Void) {
        queue.async {
            let infoURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
                .appendingPathComponent(Self.bundleID.hasSuffix(".debug") ? "OpenDisplay Audio Dev.driver" : "OpenDisplay Audio.driver")
                .appendingPathComponent("Contents/Info.plist")
            let installed = (try? Data(contentsOf: infoURL))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
            let build = (installed?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
            let status: AudioDriverStatus
            if let driver = self.checkedDriver(), self.supportsVolume(driver) {
                status = .ready
            } else if installed?["CFBundleIdentifier"] as? String == Self.bundleID, build >= 3 {
                status = .restartRequired
            } else if self.driverObject() != nil || installed != nil {
                status = .updateAvailable
            } else {
                status = .missing
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    func register(session: UUID, deviceID: UUID, name: String, mailbox: AudioOutputMailbox,
                  request: UUID = UUID(), volume: AndroidVolumeState? = nil,
                  sendVolume: @escaping (AndroidVolumeCommand) -> Void = { _ in },
                  onFailure: @escaping (String) -> Void, onRegistered: @escaping () -> Void) {
        queue.async {
            guard let plugin = self.checkedDriver() else {
                onFailure(self.driverProblem() ?? "The OpenDisplay audio driver is unavailable.")
                return
            }
            self.audioParticipants.insert(session)
            self.observeDefault()
            let uid = Self.bundleID + "." + deviceID.uuidString
            let cleanName = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            // The driver validates CFString length in UTF-16 code units.
            let name = String(String.UnicodeScalarView(cleanName.prefix(46)))
            let baseName = name.isEmpty ? "Android" : name
            var updated = self.routes
            let current = updated.first(where: { $0.uid == uid })
            let occupied = Set(updated.filter { $0.uid != uid }.map(\.name))
            let distinct = ([baseName] + (2...17).map { "\(baseName) (\($0))" })
                .first(where: { !occupied.contains($0) }) ?? baseName
            let route = Route(session: session, uid: uid, name: current?.name ?? distinct,
                              mailbox: mailbox, onFailure: onFailure, request: request, sendVolume: sendVolume,
                              volume: self.supportsVolume(plugin) ? volume.map(RemoteAudioVolume.init) : nil,
                              onRegistered: onRegistered)
            if let volume, route.volume != nil {
                Log.info("audio: Android media controls volume=\(volume.canVolume) mute=\(volume.canMute)")
            }
            if let existing = updated.firstIndex(where: { $0.uid == uid }) {
                updated[existing] = route
            } else {
                updated.append(route)
            }
            guard self.writeRegistry(updated, on: plugin) else {
                onFailure("Could not register the Android sound output. Reconnect or reinstall the OpenDisplay audio driver.")
                return
            }
            let first = self.routes.isEmpty
            self.routes = updated
            if first {
                self.pcmTimer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            }
            self.refreshDevices()
            if current?.volume != nil, route.volume == nil, let object = self.objectIDs[uid],
               let fields = self.cfProperty(object, Self.volumeControlProperty, qualifier: self.registryToken) as? [String: Any],
               let state = HALVolumeState(fields), state.nativeVolume {
                self.writeProperty(object, Self.volumeControlProperty,
                                   value: ["nativeVolume": false, "volumeRevision": state.volumeRevision] as CFDictionary,
                                   qualifier: self.registryToken)
            }
        }
    }

    func receiveVolume(session: UUID, request: UUID, state: AndroidVolumeState) {
        queue.async {
            guard let position = self.routes.firstIndex(where: { $0.session == session && $0.request == request })
            else { return }
            self.routes[position].volume?.receive(state)
            self.syncVolumes(now: .now())
        }
    }

    func unregister(session: UUID, ended: Bool = false) {
        queue.async {
            let removed = self.routes.filter { $0.session == session }
            if !removed.isEmpty {
                self.observeDefault()
                self.routes.removeAll { $0.session == session }
                self.reconcileDefault(removing: removed.map(\.uid))
                if let plugin = self.checkedDriver() { _ = self.writeRegistry(self.routes, on: plugin) }
                self.refreshDevices()
            }
            if ended { self.audioParticipants.remove(session) }
            if self.audioParticipants.isEmpty && self.routes.isEmpty {
                self.routing = AudioOutputRouting()
                self.pendingDefault = nil
            }
        }
    }

    /// Called before AppKit exits so the old default is restored before the
    /// driver withdraws its devices. The driver lease covers abrupt exits.
    func shutdown() {
        queue.sync {
            let removed = routes.map(\.uid)
            observeDefault()
            routes.removeAll()
            reconcileDefault(removing: removed)
            if !removed.isEmpty, let plugin = checkedDriver() { _ = writeRegistry([], on: plugin) }
            pcmTimer.schedule(deadline: .distantFuture)
        }
    }

    private func renewRegistry() {
        guard !routes.isEmpty else { return }
        if let plugin = checkedDriver(), writeRegistry(routes, on: plugin) {
            refreshDevices()
            return
        }
        let failed = routes
        observeDefault()
        routes.removeAll()
        reconcileDefault(removing: failed.map(\.uid))
        objectIDs = [:]
        pcmTimer.schedule(deadline: .distantFuture)
        failed.forEach { $0.onFailure("The OpenDisplay audio driver stopped responding. Reconnect to restore audio.") }
    }

    private func refreshDevices() {
        objectIDs = Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            findOutput(route.uid).map { (route.uid, $0) }
        })
        if routes.isEmpty { pcmTimer.schedule(deadline: .distantFuture) }
        syncVolumes(now: .now())
        reconcileDefault()
        for index in routes.indices where objectIDs[routes[index].uid] != nil {
            let callback = routes[index].onRegistered
            routes[index].onRegistered = nil
            callback?()
        }
    }

    private func drainPCM() {
        let now = DispatchTime.now()
        if now >= nextVolumePoll {
            nextVolumePoll = now + .milliseconds(80)
            syncVolumes(now: now)
        }
        for route in routes {
            guard let object = objectIDs[route.uid],
                  let pcm = cfProperty(object, Self.pcmProperty, qualifier: registryToken) as? Data, !pcm.isEmpty,
                  let payload = AudioWire.packHALSamples(pcm) else { continue }
            route.mailbox.offer(payload)
        }
    }

    private func syncVolumes(now: DispatchTime) {
        guard routes.contains(where: { $0.volume != nil }) else { return }
        let selected = number(system, kAudioHardwarePropertyDefaultOutputDevice)
        for index in routes.indices {
            guard var volume = routes[index].volume, let object = objectIDs[routes[index].uid],
                  let fields = cfProperty(object, Self.volumeControlProperty, qualifier: registryToken) as? [String: Any],
                  let hal = HALVolumeState(fields) else { continue }
            if !routes[index].didReadVolume {
                routes[index].didReadVolume = true
                Log.info("audio: HAL volume synchronization started")
            }
            let result = volume.poll(hal, selected: object == selected, now: now)
            routes[index].volume = volume
            if !result.update.isEmpty {
                writeProperty(object, Self.volumeControlProperty, value: result.update as CFDictionary,
                              qualifier: registryToken)
            }
            if let command = result.command { routes[index].sendVolume(command) }
        }
    }

    private func reconcileDefault(removing: [String] = []) {
        guard !routes.isEmpty || !removing.isEmpty else { return }
        let current = observeDefault()
        if let pendingDefault, !removing.contains(pendingDefault.destination) { return }
        pendingDefault = nil
        let isAndroid = current.map(isVirtual) ?? false
        let ready = routes.map(\.uid).filter { objectIDs[$0] != nil }
        let candidate = routing.nextOutput(current: current, ready: ready, isAndroid: isAndroid)
        if let candidate, let device = findOutput(candidate) {
            select(device, uid: candidate, origin: current)
        } else if let current, removing.contains(current) || (isAndroid && routes.isEmpty),
                  let (uid, device) = fallbackLocalOutput() {
            select(device, uid: uid, origin: current)
        }
    }

    @discardableResult
    private func observeDefault() -> String? {
        let uid = number(system, kAudioHardwarePropertyDefaultOutputDevice)
            .flatMap { cfProperty($0, kAudioDevicePropertyDeviceUID) as? String }
        if let pending = pendingDefault {
            if uid == pending.destination {
                routing.didSwitch(to: pending.destination, isAndroid: isVirtual(pending.destination))
                pendingDefault = nil
                return uid
            }
            if uid == pending.origin, DispatchTime.now() < pending.expires { return uid }
            pendingDefault = nil
        }
        routing.observe(uid, isAndroid: uid.map(isVirtual) ?? false)
        return uid
    }

    private func select(_ id: AudioObjectID, uid: String, origin: String?) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        if AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: device)), &device) == noErr {
            pendingDefault = PendingDefault(origin: origin, destination: uid, expires: .now() + .milliseconds(800))
            observeDefault()
        } else {
            Log.info("audio: Core Audio rejected the default output change")
        }
    }

    private func fallbackLocalOutput() -> (String, AudioObjectID)? {
        if let saved = routing.localOutput, let device = findOutput(saved) { return (saved, device) }
        let outputs: [(String, AudioObjectID)] = objectList(kAudioHardwarePropertyDevices).compactMap { device in
            guard let uid = cfProperty(device, kAudioDevicePropertyDeviceUID) as? String,
                  !isVirtual(uid), isOutput(device) else { return nil }
            return (uid, device)
        }
        return outputs.first(where: { number($0.1, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn })
            ?? outputs.first
    }

    private func findOutput(_ uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let string = uid as CFString
        var qualifier = Unmanaged.passUnretained(string)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout.size(ofValue: qualifier)),
                                         &qualifier, &size, &device) == noErr,
              device != kAudioObjectUnknown, isOutput(device) else { return nil }
        return device
    }

    private func isOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func isVirtual(_ uid: String) -> Bool {
        let prefix = Self.bundleID + "."
        return uid.hasPrefix(prefix) && UUID(uuidString: String(uid.dropFirst(prefix.count))) != nil
    }

    private func driverObject() -> AudioObjectID? {
        objectList(kAudioHardwarePropertyPlugInList).first {
            (cfProperty($0, kAudioPlugInPropertyBundleID) as? String) == Self.bundleID
        }
    }

    private func checkedDriver() -> AudioObjectID? {
        guard let object = driverObject(),
              (cfProperty(object, Self.versionProperty) as? NSNumber)?.intValue == Self.protocolVersion else { return nil }
        return object
    }

    private func supportsVolume(_ plugin: AudioObjectID) -> Bool {
        (cfProperty(plugin, Self.volumeProtocolProperty) as? NSNumber)?.intValue == 1
    }

    private func driverProblem() -> String? {
        guard let plugin = driverObject() else { return "Install the OpenDisplay audio driver and restart to use Android sound." }
        guard (cfProperty(plugin, Self.versionProperty) as? NSNumber)?.intValue == Self.protocolVersion else {
            return "Update the OpenDisplay audio driver and restart to use Android sound."
        }
        return nil
    }

    private func writeRegistry(_ entries: [Route], on plugin: AudioObjectID) -> Bool {
        let value = ["token": registryToken, "devices": entries.map { ["uid": $0.uid, "name": $0.name] }] as CFDictionary
        return writeProperty(plugin, Self.registryProperty, value: value)
    }

    @discardableResult
    private func writeProperty(_ object: AudioObjectID, _ property: AudioObjectPropertySelector,
                               value: CFDictionary, qualifier: CFString? = nil) -> Bool {
        var arg = Unmanaged.passUnretained(value)
        var address = address(property)
        let size = UInt32(MemoryLayout.size(ofValue: arg))
        let result: OSStatus
        if let qualifier {
            var token = Unmanaged.passUnretained(qualifier)
            result = AudioObjectSetPropertyData(object, &address, UInt32(MemoryLayout.size(ofValue: token)),
                                                &token, size, &arg)
        } else {
            result = AudioObjectSetPropertyData(object, &address, 0, nil, size, &arg)
        }
        if result != noErr {
            Log.info("audio: driver rejected \(property == Self.registryProperty ? "registry" : "volume") update (\(result))")
        }
        return result == noErr
    }

    private func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let width = MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / width)
        let result = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        return result == noErr ? Array(objects.prefix(Int(size) / width)) : []
    }

    private func cfProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            qualifier: CFString? = nil) -> CFTypeRef? {
        var address = address(selector)
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status: OSStatus
        if let qualifier {
            var arg = Unmanaged.passUnretained(qualifier)
            status = AudioObjectGetPropertyData(object, &address, UInt32(MemoryLayout.size(ofValue: arg)),
                                                &arg, &size, &value)
        } else {
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
