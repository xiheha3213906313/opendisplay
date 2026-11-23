import AppKit
import AudioToolbox
import CoreAudio

/// Adapted from gprot42/android-opendisplay (GPL-3.0). All sessions share one
/// claim on the default device. Restore only the property we actually changed.
final class SystemAudioMute {
    static let shared = SystemAudioMute()

    private struct Snapshot {
        let uid: String
        let device: AudioDeviceID
        let original: Property
    }

    private enum Property {
        case volume(Float32)
        case mute(UInt32)
    }

    private let queue = DispatchQueue(label: "sender.audio-output")
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var claims: [UUID: () -> Void] = [:]
    private var output: AudioDeviceID?
    private var snapshot: Snapshot?
    private var pendingRestores: [Snapshot] = []
    private var listenersOK = true

    private init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, { [weak self] _, _ in
                self?.deviceListChanged()
            }) != noErr {
                listenersOK = false
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.sync {
                self.claims.removeAll()
                self.restoreOutput()
            }
        }
    }

    func claim(_ id: UUID, onFailure: @escaping () -> Void) -> Bool {
        queue.sync {
            guard listenersOK else { return false }
            deviceListChanged()
            if output == nil, !silenceDefaultOutput() { return false }
            claims[id] = onFailure
            return true
        }
    }

    func release(_ id: UUID) {
        queue.sync {
            guard claims.removeValue(forKey: id) != nil, claims.isEmpty else { return }
            restoreOutput()
        }
    }

    func checkOutput() {
        queue.async {
            self.deviceListChanged()
            guard let device = self.output,
                  !self.isSilenced(device) else { return }
            self.restoreOutput()
            self.reportFailure()
        }
    }

    private func deviceListChanged() {
        pendingRestores = pendingRestores.filter { !restore($0) }
        guard !claims.isEmpty, output != defaultOutput() else { return }
        restoreOutput()
        if !silenceDefaultOutput() { reportFailure() }
    }

    private func reportFailure() {
        let callbacks = Array(claims.values)
        claims.removeAll()
        callbacks.forEach { $0() }
    }

    private func isSilenced(_ device: AudioDeviceID) -> Bool {
        read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)) == 1
            || read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    scope: kAudioDevicePropertyScopeOutput, initial: Float32(0)) == 0
    }

    private func silenceDefaultOutput() -> Bool {
        guard let device = defaultOutput(), let uid = deviceUID(device),
              !pendingRestores.contains(where: { $0.uid == uid }) else { return false }
        let mute = read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
        let volume = read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                          scope: kAudioDevicePropertyScopeOutput, initial: Float32(0))
        if mute == 1 || volume == 0 {
            output = device
            return true
        }
        // Some built-in speakers expose a virtual volume but ignore master mute.
        if let volume, write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(0)) {
            snapshot = Snapshot(uid: uid, device: device, original: .volume(volume))
        } else if let mute, write(device, kAudioDevicePropertyMute, UInt32(1)) {
            snapshot = Snapshot(uid: uid, device: device, original: .mute(mute))
        } else {
            return false
        }
        output = device
        if isSilenced(device) { return true }
        restoreOutput()
        return false
    }

    private func restoreOutput() {
        if let snapshot, !restore(snapshot) {
            pendingRestores.append(snapshot)
            Log.info("audio: will retry output restoration when the device is available")
        }
        snapshot = nil
        output = nil
    }

    private func restore(_ snapshot: Snapshot) -> Bool {
        let device = deviceUID(snapshot.device) == snapshot.uid
            ? snapshot.device : devices().first(where: { deviceUID($0) == snapshot.uid })
        guard let device else { return false }
        // A volume or mute change made by the user during streaming takes precedence.
        switch snapshot.original {
        case .volume(let original):
            let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            guard let current = read(device, selector, scope: kAudioDevicePropertyScopeOutput,
                                     initial: Float32(0)) else { return false }
            return current != 0 || write(device, selector, original)
        case .mute(let original):
            guard let current = read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput,
                                     initial: UInt32(0)) else { return false }
            return current != 1 || write(device, kAudioDevicePropertyMute, original)
        }
    }

    private func defaultOutput() -> AudioDeviceID? {
        let device = read(system, kAudioHardwarePropertyDefaultOutputDevice,
                          scope: kAudioObjectPropertyScopeGlobal, initial: AudioDeviceID(kAudioObjectUnknown))
        return device == kAudioObjectUnknown ? nil : device
    }

    private func deviceUID(_ device: AudioDeviceID) -> String? {
        let uid = read(device, kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal,
                       initial: Optional<Unmanaged<CFString>>.none)
        return (uid ?? nil)?.takeRetainedValue() as String?
    }

    private func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        let width = MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / width)
        let status = ids.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return OSStatus(kAudioHardwareBadPropertySizeError) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        return status == noErr ? Array(ids.prefix(Int(size) / width)) : []
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    private func write<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                          _ value: T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        return withUnsafeBytes(of: value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32($0.count), $0.baseAddress!) == noErr
        }
    }
}
