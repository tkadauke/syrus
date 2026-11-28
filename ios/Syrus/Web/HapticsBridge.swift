import UIKit
import WebKit

/// A haptic the web UI may ask for. Deliberately tiny: the web app never gets
/// to choose arbitrary patterns, durations, or intensities.
enum HapticRequest: Equatable {
    enum ImpactStyle: String, Equatable {
        case light, medium, heavy
    }

    case selection
    case impact(ImpactStyle)

    /// Message-handler name the web view registers; the web side posts to
    /// `window.webkit.messageHandlers.syrusHaptics`.
    static let handlerName = "syrusHaptics"
    static let protocolVersion = 1

    /// Validates an untrusted `postMessage` body. Anything that is not exactly
    /// `{v: 1, kind: "selection"}` or `{v: 1, kind: "impact", style: ...}` is
    /// rejected: unknown keys, wrong types, unknown styles, and unknown versions.
    static func parse(_ body: Any) -> HapticRequest? {
        guard let dictionary = body as? [String: Any] else { return nil }
        guard let version = (dictionary["v"] as? NSNumber), isInteger(version),
              version.intValue == protocolVersion else { return nil }
        guard let kind = dictionary["kind"] as? String else { return nil }
        switch kind {
        case "selection":
            return Set(dictionary.keys) == ["v", "kind"] ? .selection : nil
        case "impact":
            guard Set(dictionary.keys) == ["v", "kind", "style"],
                  let raw = dictionary["style"] as? String,
                  let style = ImpactStyle(rawValue: raw) else { return nil }
            return .impact(style)
        default:
            return nil
        }
    }

    private static func isInteger(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue == Double(number.intValue)
    }
}

/// Drops requests that arrive faster than a human could feel them, so a
/// misbehaving page can never turn the Taptic Engine into a buzzer.
struct HapticThrottle {
    /// Minimum spacing between two haptics of the same weight.
    static let minimumInterval: TimeInterval = 0.04
    /// Strong impacts (commits) are rarer; they also reset the selection window.
    static let minimumImpactInterval: TimeInterval = 0.25

    private var lastSelection: TimeInterval?
    private var lastImpact: TimeInterval?

    mutating func allows(_ request: HapticRequest, at time: TimeInterval) -> Bool {
        switch request {
        case .selection:
            if let last = lastSelection, time - last < Self.minimumInterval { return false }
            // A selection tick right after a commit impact would muddy it.
            if let last = lastImpact, time - last < Self.minimumInterval { return false }
            lastSelection = time
            return true
        case .impact:
            if let last = lastImpact, time - last < Self.minimumImpactInterval { return false }
            lastImpact = time
            return true
        }
    }
}

/// Plays a haptic on the device. Abstracted so the bridge is unit-testable.
@MainActor
protocol HapticPlaying: AnyObject {
    func play(_ request: HapticRequest)
}

@MainActor
final class SystemHapticPlayer: HapticPlaying {
    private let selection = UISelectionFeedbackGenerator()
    private var impacts: [HapticRequest.ImpactStyle: UIImpactFeedbackGenerator] = [:]

    func play(_ request: HapticRequest) {
        // UIKit feedback generators already honour the system "System Haptics"
        // setting and silently do nothing when haptics are disabled or unsupported.
        switch request {
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        case .impact(let style):
            let generator = impacts[style] ?? UIImpactFeedbackGenerator(style: style.uiKitStyle)
            impacts[style] = generator
            generator.impactOccurred()
            generator.prepare()
        }
    }
}

private extension HapticRequest.ImpactStyle {
    var uiKitStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}

/// Receives haptic requests from the web UI. Only the main frame of the
/// selected Syrus server's origin is trusted.
@MainActor
final class HapticsBridge: NSObject, WKScriptMessageHandler {
    private let player: HapticPlaying
    private let now: () -> TimeInterval
    private var throttle = HapticThrottle()

    /// Origin check supplied by the owner (the current server); defaults to deny.
    var isTrusted: (_ isMainFrame: Bool, _ url: URL?) -> Bool = { _, _ in false }

    init(player: HapticPlaying? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.player = player ?? SystemHapticPlayer()
        self.now = now
    }

    /// Returns true when the request was valid, trusted, and played.
    @discardableResult
    func handle(body: Any, isMainFrame: Bool, frameURL: URL?) -> Bool {
        guard isTrusted(isMainFrame, frameURL), let request = HapticRequest.parse(body) else { return false }
        guard throttle.allows(request, at: now()) else { return false }
        player.play(request)
        return true
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handle(body: message.body, isMainFrame: message.frameInfo.isMainFrame, frameURL: message.frameInfo.request.url)
    }
}
