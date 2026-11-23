import Foundation

struct AndroidVolumeState {
    let minimum: Int
    let maximum: Int
    let index: Int
    let muted: Bool
    let canVolume: Bool
    let canMute: Bool
    let sequence: Int?

    init?(_ fields: [String: Any]) {
        guard let minimum = fields["min"] as? Int, let maximum = fields["max"] as? Int,
              let index = fields["index"] as? Int, minimum >= 0, maximum >= minimum,
              maximum <= 10000, (minimum...maximum).contains(index),
              let muted = fields["muted"] as? Bool,
              let canVolume = fields["canVolume"] as? Bool,
              let canMute = fields["canMute"] as? Bool else { return nil }
        self.minimum = minimum
        self.maximum = maximum
        self.index = index
        self.muted = muted
        self.canVolume = canVolume && maximum > minimum
        self.canMute = canMute
        sequence = fields["sequence"] as? Int
    }

    var scalar: Float {
        maximum > minimum ? Float(index - minimum) / Float(maximum - minimum) : 0
    }

    func index(for scalar: Float) -> Int {
        minimum + Int((Float(maximum - minimum) * scalar).rounded())
    }
}

struct HALVolumeState {
    let volume: Float
    let muted: Bool
    let volumeRevision: Int
    let muteRevision: Int
    let nativeVolume: Bool

    init?(_ fields: [String: Any]) {
        guard let volume = (fields["volume"] as? NSNumber)?.floatValue, (0...1).contains(volume),
              let muted = fields["muted"] as? Bool,
              let volumeRevision = fields["volumeRevision"] as? Int,
              let muteRevision = fields["muteRevision"] as? Int,
              let nativeVolume = fields["nativeVolume"] as? Bool else { return nil }
        self.volume = volume
        self.muted = muted
        self.volumeRevision = volumeRevision
        self.muteRevision = muteRevision
        self.nativeVolume = nativeVolume
    }
}

struct AndroidVolumeCommand {
    let sequence: Int
    let index: Int?
    let muted: Bool?

    func message(id: UUID) -> [String: Any] {
        var fields: [String: Any] = ["type": "audioSetVolume", "id": id.uuidString, "sequence": sequence]
        if let index { fields["index"] = index }
        if let muted { fields["muted"] = muted }
        return fields
    }
}

/// One Android audio request. Queue-confined by VirtualAudioOutputs.
/// One outstanding command preserves ordering; the latest HAL revisions
/// remain available even when many slider changes happen during that command.
struct RemoteAudioVolume {
    private(set) var phone: AndroidVolumeState
    private var volumeRevision: Int?
    private var muteRevision: Int?
    private var volumeFailed = false
    private var muteFailed = false
    private var pending: (command: AndroidVolumeCommand, deadline: DispatchTime)?
    private var sequence = 0
    private var wasSelected = false
    private var listenAfter = DispatchTime.distantFuture

    init(phone: AndroidVolumeState) {
        self.phone = phone
    }

    mutating func receive(_ report: AndroidVolumeState) {
        if let sequence = report.sequence {
            guard let command = pending?.command, command.sequence == sequence else { return }
            finish(command, with: report)
        }
        phone = report
    }

    private mutating func finish(_ command: AndroidVolumeCommand, with report: AndroidVolumeState?) {
        if let index = command.index, report?.index != index { volumeFailed = true }
        if let muted = command.muted, report?.muted != muted { muteFailed = true }
        pending = nil
    }

    /// Returns a HAL state update and, when needed, a single remote write.
    /// Core Audio compares the revisions again when applying the state update.
    mutating func poll(_ hal: HALVolumeState, selected: Bool, now: DispatchTime) ->
        (update: [String: Any], command: AndroidVolumeCommand?) {
        if let active = pending, now >= active.deadline { finish(active.command, with: nil) }
        if selected != wasSelected {
            wasSelected = selected
            // Core Audio restores cached settings as a device becomes the
            // default. Treat those writes as local initialization.
            listenAfter = now + .milliseconds(400)
        }
        let forwardEdits = selected && now >= listenAfter

        let nativeVolume = phone.canVolume && !volumeFailed
        let nativeMute = phone.canMute && !muteFailed
        let volumeChanged = volumeRevision.map { $0 != hal.volumeRevision } ?? false
        let muteChanged = muteRevision.map { $0 != hal.muteRevision } ?? false
        if volumeRevision == nil || !forwardEdits || !nativeVolume { volumeRevision = hal.volumeRevision }
        if muteRevision == nil || !forwardEdits || !nativeMute { muteRevision = hal.muteRevision }

        var command: AndroidVolumeCommand?
        if pending == nil && forwardEdits {
            let index = nativeVolume && volumeChanged ? phone.index(for: hal.volume) : nil
            let muted = nativeMute && muteChanged ? hal.muted : nil
            if index != nil { volumeRevision = hal.volumeRevision }
            if muted != nil { muteRevision = hal.muteRevision }
            // A Core Audio write that rounds to the already active phone
            // setting does not need a network round trip.
            let wantedIndex = index == phone.index ? nil : index
            let wantedMute = muted == phone.muted ? nil : muted
            if wantedIndex != nil || wantedMute != nil {
                sequence += 1
                let next = AndroidVolumeCommand(sequence: sequence, index: wantedIndex, muted: wantedMute)
                pending = (next, now + .seconds(1))
                command = next
            }
        }

        var update: [String: Any] = [:]
        if nativeVolume != hal.nativeVolume {
            update["volumeRevision"] = hal.volumeRevision
            update["nativeVolume"] = nativeVolume
        }
        if nativeVolume, !phone.muted, volumeRevision == hal.volumeRevision,
           pending?.command.index == nil, abs(phone.scalar - hal.volume) > 0.0001 {
            update["volumeRevision"] = hal.volumeRevision
            update["volume"] = phone.scalar
        }
        if nativeMute, muteRevision == hal.muteRevision, pending?.command.muted == nil, phone.muted != hal.muted {
            update["muteRevision"] = hal.muteRevision
            update["muted"] = phone.muted
        }
        return (update, command)
    }
}
