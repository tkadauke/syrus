import SwiftUI
import WebKit

/// SwiftUI host for the controller's `WKWebView`.
struct SyrusWebView: UIViewRepresentable {
    @ObservedObject var controller: WebController

    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
