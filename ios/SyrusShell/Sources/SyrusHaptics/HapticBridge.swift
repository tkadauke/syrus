import Foundation

public protocol HapticPlayer {
    func play(_ request: HapticRequest)
}

public protocol HapticPreferences {
    /// False when the user disabled haptics or the device cannot play them.
    var hapticsEnabled: Bool { get }
}

/// Throttles feedback so a misbehaving page cannot cause runaway vibration.
/// Selection ticks are dropped when they arrive faster than `selectionInterval`;
/// impacts (card commits) use the shorter `impactInterval` and are never dropped
/// because of a recent selection tick.
public struct HapticThrottle {
    public let selectionInterval: TimeInterval
    public let impactInterval: TimeInterval
    private var lastSelection: TimeInterval?
    private var lastImpact: TimeInterval?

    public init(selectionInterval: TimeInterval = 0.03, impactInterval: TimeInterval = 0.25) {
        self.selectionInterval = selectionInterval
        self.impactInterval = impactInterval
    }

    public mutating func allows(_ request: HapticRequest, at now: TimeInterval) -> Bool {
        switch request {
        case .selection:
            if let last = lastSelection, now - last < selectionInterval { return false }
            lastSelection = now
        case .impact:
            if let last = lastImpact, now - last < impactInterval { return false }
            lastImpact = now
        }
        return true
    }
}

/// Validates, filters, and plays haptic messages. Platform specifics live behind `HapticPlayer`.
public final class HapticBridge {
    public static let messageHandlerName = "syrusHaptics"

    private let player: HapticPlayer
    private let preferences: HapticPreferences
    private let clock: () -> TimeInterval
    private var throttle: HapticThrottle

    public init(
        player: HapticPlayer,
        preferences: HapticPreferences,
        throttle: HapticThrottle = HapticThrottle(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.player = player
        self.preferences = preferences
        self.throttle = throttle
        self.clock = clock
    }

    /// Returns true when feedback was played.
    @discardableResult
    public func handle(_ body: Any) -> Bool {
        guard preferences.hapticsEnabled, case .success(let request) = HapticRequestParser.parse(body) else { return false }
        guard throttle.allows(request, at: clock()) else { return false }
        player.play(request)
        return true
    }
}
