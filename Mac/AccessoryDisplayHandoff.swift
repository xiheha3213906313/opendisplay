import CoreGraphics
import Foundation

struct AccessoryDetachWindow {
    static let displayDelay: Duration = .seconds(2)
    static let deviceDelay: Duration = .seconds(10)

    let id = UUID()
    let start: ContinuousClock.Instant
    let expectedReenumeration: Bool

    var displayDeadline: ContinuousClock.Instant { start + Self.displayDelay }
    var deviceDeadline: ContinuousClock.Instant { start + Self.deviceDelay }

    func shouldWithdrawDisplay(at now: ContinuousClock.Instant) -> Bool {
        !expectedReenumeration && now >= displayDeadline && now < deviceDeadline
    }

    func acceptsReturn(at now: ContinuousClock.Instant) -> Bool { now < deviceDeadline }
}

/// Quartz reports the resulting configuration, including WindowServer's own
/// main-display choice when the set of active displays changes.
struct MainDisplaySelection {
    private(set) var main: CGDirectDisplayID = 0
    private(set) var active = Set<CGDirectDisplayID>()
    private(set) var selectionRevision: UInt64 = 0

    mutating func observe(main: CGDirectDisplayID, active: Set<CGDirectDisplayID>,
                          requestedMain: CGDirectDisplayID? = nil) {
        if self.main != 0, main != 0, main != self.main, active == self.active, main != requestedMain {
            selectionRevision &+= 1
        }
        self.main = main
        self.active = active
    }

    static func activeDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Set(displays.prefix(Int(count)))
    }

    static func rebasedOrigins(_ origins: [CGDirectDisplayID: CGPoint],
                               main display: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        guard let origin = origins[display] else { return nil }
        return origins.mapValues { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
    }

    enum Submission: CustomStringConvertible {
        case alreadyMain, submitted, layoutUnavailable
        case failed(String, CGError)

        var description: String {
            switch self {
            case .alreadyMain: "already main"
            case .submitted: "submitted"
            case .layoutUnavailable: "layout unavailable"
            case .failed(let operation, let error): "\(operation) failed (Quartz \(error.rawValue))"
            }
        }
    }

    @MainActor
    static func submit(_ display: CGDirectDisplayID) -> Submission {
        if display != 0, CGMainDisplayID() == display { return .alreadyMain }
        let displays = activeDisplays().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let origins = Dictionary(uniqueKeysWithValues: displays.map { ($0, CGDisplayBounds($0).origin) })
        guard let requested = rebasedOrigins(origins, main: display), origins != requested else {
            return .layoutUnavailable
        }
        var configuration: CGDisplayConfigRef?
        let start = CGBeginDisplayConfiguration(&configuration)
        guard start == .success else { return .failed("begin configuration", start) }
        for (id, origin) in requested.sorted(by: { $0.key < $1.key }) {
            guard let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y) else {
                CGCancelDisplayConfiguration(configuration)
                return .layoutUnavailable
            }
            let result = CGConfigureDisplayOrigin(configuration, id, x, y)
            guard result == .success else {
                CGCancelDisplayConfiguration(configuration)
                return .failed("configure display \(id)", result)
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        return result == .success ? .submitted : .failed("commit configuration", result)
    }
}
