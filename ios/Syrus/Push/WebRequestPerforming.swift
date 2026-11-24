import Foundation
import WebKit

/// Sends same-origin JSON requests *from inside the web view*, so native code
/// reuses the signed-in session cookie and the page's CSRF token instead of
/// holding any credential of its own.
struct WebResponse: Equatable {
    var status: Int
    /// Response text, truncated by the page script so a misbehaving server
    /// cannot hand the app an unbounded string.
    var body: String

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }
}

@MainActor
protocol WebRequestPerforming: AnyObject {
    /// Returns the response, or `nil` if the page isn't ready (no document
    /// loaded yet / not on the server's origin). GET requests ignore `jsonBody`.
    func perform(method: String, path: String, jsonBody: [String: Any]) async throws -> WebResponse?
}

extension WebRequestPerforming {
    /// Status-only convenience for callers that don't read the body.
    func send(method: String, path: String, jsonBody: [String: Any]) async throws -> Int? {
        try await perform(method: method, path: path, jsonBody: jsonBody)?.status
    }
}

extension WebViewModel: WebRequestPerforming {
    private static let script = """
    const meta = document.querySelector("meta[name='csrf-token']");
    const headers = { "Content-Type": "application/json", "Accept": "application/json" };
    if (meta && meta.content) { headers["X-CSRF-Token"] = meta.content; }
    const init = { method, headers, credentials: "same-origin" };
    if (method !== "GET") { init.body = body; }
    const response = await fetch(path, init);
    const text = await response.text();
    return JSON.stringify({ status: response.status, body: text.slice(0, 16384) });
    """

    func perform(method: String, path: String, jsonBody: [String: Any]) async throws -> WebResponse? {
        guard let server, let url = webView.url, server.sameOrigin(as: url) else { return nil }
        let bodyData = try JSONSerialization.data(withJSONObject: jsonBody)
        let result = try await webView.callAsyncJavaScript(
            Self.script,
            arguments: ["path": path, "method": method, "body": String(decoding: bodyData, as: UTF8.self)],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let text = result as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let status = (object["status"] as? NSNumber)?.intValue
        else { return nil }
        return WebResponse(status: status, body: object["body"] as? String ?? "")
    }
}
