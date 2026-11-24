#if os(iOS)
import UIKit
import WebKit

/// Plays haptics through UIKit feedback generators.
public final class UIKitHapticPlayer: HapticPlayer {
    private let selection = UISelectionFeedbackGenerator()
    private var impacts: [HapticRequest.ImpactStyle: UIImpactFeedbackGenerator] = [:]

    public init() {}

    public func play(_ request: HapticRequest) {
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

extension HapticRequest.ImpactStyle {
    var uiKitStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        case .soft: return .soft
        case .rigid: return .rigid
        }
    }
}

/// Registers as the `syrusHaptics` script message handler. Only main-frame messages from the
/// Syrus origin are honored.
public final class WebKitHapticHandler: NSObject, WKScriptMessageHandler {
    private let bridge: HapticBridge
    private let allowedHost: () -> String?

    public init(bridge: HapticBridge, allowedHost: @escaping () -> String?) {
        self.bridge = bridge
        self.allowedHost = allowedHost
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let host = allowedHost(), message.frameInfo.securityOrigin.host == host
        else { return }
        bridge.handle(message.body)
    }
}
#endif
