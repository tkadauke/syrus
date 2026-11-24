import Foundation
import UIKit
import WebKit

/// A haptic the web app may ask the shell to play.
enum HapticRequest: Equatable {
    /// A light, restrained tick (card drag crossing a distance increment).
    case selection
    /// A distinct, stronger impact (card committed left or right).
    case commit
}

/// Validates messages from the `syrusHaptics` script message handler.
///
/// The accepted payload is exactly `{ "v": 1, "type": "selection" | "commit" }`.
/// Anything else (wrong version, unknown type, extra keys, wrong types) is
/// dropped, so the web layer can never reach beyond these two feedbacks.
enum HapticsMessage {
    static let handlerName = "syrusHaptics"
    static let version = 1

    static func parse(_ body: Any) -> HapticRequest? {
        guard let dictionary = body as? [String: Any], dictionary.count == 2,
              let version = dictionary["v"] as? Int, version == Self.version,
              let type = dictionary["type"] as? String else { return nil }
        switch type {
        case "selection": return .selection
        case "commit": return .commit
        default: return nil
        }
    }
}

/// Plays haptics. Abstracted so tests can observe feedback without hardware.
@MainActor
protocol HapticsPlaying: AnyObject {
    func play(_ request: HapticRequest)
}

/// Drops requests that arrive faster than a device could usefully render, as a
/// second line of defence behind the web layer's own throttling.
struct HapticsThrottle {
    var selectionInterval: TimeInterval = 0.03
    var commitInterval: TimeInterval = 0.2
    private var lastSelection: TimeInterval?
    private var lastCommit: TimeInterval?

    mutating func allows(_ request: HapticRequest, at time: TimeInterval) -> Bool {
        switch request {
        case .selection:
            if let last = lastSelection, time - last < selectionInterval { return false }
            lastSelection = time
        case .commit:
            if let last = lastCommit, time - last < commitInterval { return false }
            lastCommit = time
        }
        return true
    }
}

/// Receives haptic requests from the web view and plays them when valid.
///
/// Requests are only honoured from the main frame of the configured Syrus
/// server, and only while the app is active.
@MainActor
final class HapticsBridge: NSObject, WKScriptMessageHandler {
    private let player: HapticsPlaying
    private let serverProvider: () -> ServerURL?
    private let now: () -> TimeInterval
    private let isActive: () -> Bool
    private var throttle = HapticsThrottle()

    init(
        player: HapticsPlaying,
        serverProvider: @escaping () -> ServerURL?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.player = player
        self.serverProvider = serverProvider
        self.now = now
        self.isActive = isActive
    }

    /// Returns true when feedback was played.
    @discardableResult
    func handle(body: Any, isMainFrame: Bool, origin: URL?) -> Bool {
        guard isMainFrame, let origin, let server = serverProvider(), server.sameOrigin(as: origin),
              isActive(), let request = HapticsMessage.parse(body),
              throttle.allows(request, at: now()) else { return false }
        player.play(request)
        return true
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        let url = components.url
        let isMainFrame = frame.isMainFrame
        Task { @MainActor [weak self] in
            self?.handle(body: body, isMainFrame: isMainFrame, origin: url)
        }
    }
}

/// UIKit feedback generators. iOS applies the system "System Haptics" setting
/// itself, so nothing plays when the user has turned haptics off.
@MainActor
final class SystemHapticsPlayer: HapticsPlaying {
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)

    func play(_ request: HapticRequest) {
        switch request {
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        case .commit:
            impact.impactOccurred(intensity: 1)
            impact.prepare()
        }
    }
}
