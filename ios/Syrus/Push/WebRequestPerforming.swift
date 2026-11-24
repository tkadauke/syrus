import Foundation
import WebKit

/// Sends same-origin JSON requests *from inside the web view*, so native code
/// reuses the signed-in session cookie and the page's CSRF token instead of
/// holding any credential of its own.
@MainActor
protocol WebRequestPerforming: AnyObject {
    /// Returns the HTTP status, or `nil` if the page isn't ready (no
    /// document loaded yet / not on the server's origin).
    func send(method: String, path: String, jsonBody: [String: Any]) async throws -> Int?
}

extension WebViewModel: WebRequestPerforming {
    private static let script = """
    const meta = document.querySelector("meta[name='csrf-token']");
    const headers = { "Content-Type": "application/json", "Accept": "application/json" };
    if (meta && meta.content) { headers["X-CSRF-Token"] = meta.content; }
    const response = await fetch(path, { method, headers, credentials: "same-origin", body });
    return response.status;
    """

    func send(method: String, path: String, jsonBody: [String: Any]) async throws -> Int? {
        guard let server, let url = webView.url, server.sameOrigin(as: url) else { return nil }
        let bodyData = try JSONSerialization.data(withJSONObject: jsonBody)
        let result = try await webView.callAsyncJavaScript(
            Self.script,
            arguments: ["path": path, "method": method, "body": String(decoding: bodyData, as: UTF8.self)],
            in: nil,
            contentWorld: .defaultClient
        )
        return (result as? NSNumber)?.intValue
    }
}
