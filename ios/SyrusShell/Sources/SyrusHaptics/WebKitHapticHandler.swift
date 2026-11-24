#if canImport(WebKit)
import WebKit
#endif
#if os(iOS)
import UIKit

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

#endif

#if canImport(WebKit)
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

/// Single integration point for the shell: call once while building the `WKWebViewConfiguration`
/// so the page can reach the haptics bridge. The returned handler is retained by the
/// configuration's user content controller.
public enum HapticsInstaller {
    @discardableResult
    public static func install(
        on configuration: WKWebViewConfiguration,
        bridge: HapticBridge,
        allowedHost: @escaping () -> String?
    ) -> WebKitHapticHandler {
        let handler = WebKitHapticHandler(bridge: bridge, allowedHost: allowedHost)
        configuration.userContentController.removeScriptMessageHandler(forName: HapticBridge.messageHandlerName)
        configuration.userContentController.add(handler, name: HapticBridge.messageHandlerName)
        return handler
    }
}
#endif
