import Foundation

/// Runs a script in the page and returns the numeric result (an HTTP status
/// for the push registration scripts), or nil if the script itself failed.
/// A protocol so push logic can be tested without a live `WKWebView`.
@MainActor
protocol WebScriptRunner: AnyObject {
    func runScript(_ script: String, arguments: [String: Any]) async -> Int?
}
