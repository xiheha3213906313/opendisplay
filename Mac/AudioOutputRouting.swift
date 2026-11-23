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

    func nextOutput(current uid: String?, ready: [String], isAndroid: Bool) -> String? {
        if isAndroid {
            return ready.contains(where: { $0 == uid }) ? nil : ready.first ?? localOutput
        }
        return userSelectedLocal ? nil : ready.first
    }
}
