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


/// Production preferences: haptics are off when Low Power Mode is on or the user turned the
/// in-app toggle off (`UserDefaults` key `syrusHapticsEnabled`, default on).
public struct SystemHapticPreferences: HapticPreferences {
    public static let defaultsKey = "syrusHapticsEnabled"
    private let defaults: UserDefaults
    private let lowPowerMode: () -> Bool

    public init(
        defaults: UserDefaults = .standard,
        lowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.defaults = defaults
        self.lowPowerMode = lowPowerMode
    }

    public var hapticsEnabled: Bool {
        let toggle = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
        return toggle && !lowPowerMode()
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

    /// Installs the production bridge (UIKit generators + system preferences).
    @discardableResult
    public static func installDefault(
        on configuration: WKWebViewConfiguration,
        allowedHost: @escaping () -> String?
    ) -> WebKitHapticHandler {
        let bridge = HapticBridge(player: UIKitHapticPlayer(), preferences: SystemHapticPreferences())
        return install(on: configuration, bridge: bridge, allowedHost: allowedHost)
    }
}
#endif
