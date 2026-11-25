import CoreGraphics
import Foundation

/// Tracks the user's choice separately from changes made by OpenDisplay.
struct AudioOutputRouting {
    private(set) var localOutput: String?
    private(set) var lastOutput: String?
    private(set) var userSelectedLocal = false
    private var routedToAndroid = false

    mutating func observe(_ uid: String?, isAndroid: Bool) {
        guard let uid, uid != lastOutput else { return }
        if !isAndroid {
            localOutput = uid
            if routedToAndroid { userSelectedLocal = true }
        } else {
            routedToAndroid = true
            userSelectedLocal = false
        }
        lastOutput = uid
    }

    mutating func didSwitch(to uid: String, isAndroid: Bool) {
        if isAndroid {
            routedToAndroid = true
        } else {
            localOutput = uid
        }
        lastOutput = uid
    }

    mutating func preserveLocalOutput(_ uid: String) {
        didSwitch(to: uid, isAndroid: false)
        userSelectedLocal = true
    }

    func nextOutput(current uid: String?, ready: [String], isAndroid: Bool) -> String? {
        if isAndroid {
            return ready.contains(where: { $0 == uid }) ? nil : ready.first ?? localOutput
        }
        return userSelectedLocal ? nil : ready.first
    }
}

struct AudioOutputSelection {
    private(set) var uid: String?
    private(set) var revision: UInt64 = 0

    mutating func observe(_ newUID: String?, automatic: Bool) {
        guard let newUID else { return }
        if let uid, uid != newUID, !automatic { revision &+= 1 }
        uid = newUID
    }
}

struct USBOutputReturn {
    let selectedUID: String?
    let selectionRevision: UInt64

    func mayRestore(_ uid: String, currentRevision: UInt64) -> Bool {
        selectedUID == uid && selectionRevision == currentRevision
    }
}

enum FallbackAudioRouting {
    struct Candidate {
        let offer: UUID?
        let displayID: CGDirectDisplayID?
    }

    static func preferredOffer(mainDisplay: CGDirectDisplayID, candidates: [Candidate]) -> UUID? {
        candidates.first { $0.displayID == mainDisplay && $0.offer != nil }?.offer
            ?? candidates.lazy.compactMap(\.offer).first
    }
}
