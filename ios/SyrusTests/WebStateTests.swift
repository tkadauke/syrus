import XCTest
@testable import Syrus

final class WebFailureTests: XCTestCase {
    private func classify(_ code: Int) -> WebFailure {
        WebFailure.classify(NSError(domain: NSURLErrorDomain, code: code))
    }

    func testOfflineAndTimeoutAreAttributedToTheNetwork() {
        XCTAssertEqual(classify(NSURLErrorNotConnectedToInternet).kind, .offline)
        XCTAssertEqual(classify(NSURLErrorTimedOut).kind, .timedOut)
        XCTAssertEqual(classify(NSURLErrorCannotFindHost).kind, .unreachable)
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost] {
            XCTAssertEqual(classify(code).source, .network)
        }
    }

    func testCertificateProblemsBlameTheServerAndRetryWontHelp() {
        for code in [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate] {
            let failure = classify(code)
            XCTAssertEqual(failure.kind, .untrustedCertificate)
            XCTAssertEqual(failure.source, .server)
            XCTAssertFalse(failure.retryCanHelp)
        }
        XCTAssertEqual(classify(NSURLErrorSecureConnectionFailed).kind, .secureConnectionFailed)
    }

    func testHTTPStatusClassification() {
        XCTAssertEqual(WebFailure.classify(statusCode: 503)?.kind, .serverError(503))
        XCTAssertEqual(WebFailure.classify(statusCode: 503)?.source, .server)
        XCTAssertEqual(WebFailure.classify(statusCode: 401)?.kind, .authExpired(401))
        XCTAssertEqual(WebFailure.classify(statusCode: 403)?.source, .session)
        XCTAssertNil(WebFailure.classify(statusCode: 200))
        XCTAssertNil(WebFailure.classify(statusCode: 404))
    }

    func testRetryTitleAndOnlineRetryPolicy() {
        XCTAssertEqual(WebFailure(kind: .authExpired(401)).retryTitle, "Sign in again")
        XCTAssertTrue(WebFailure(kind: .offline).retriesWhenOnline)
        XCTAssertFalse(WebFailure(kind: .serverError(500)).retriesWhenOnline)
        XCTAssertEqual(WebFailure(kind: .contentCrashed).source, .app)
    }

    func testCancellationIsNotAFailure() {
        XCTAssertTrue(WebFailure.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(WebFailure.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    func testEveryFailureHasSpokenSummary() {
        let kinds: [WebFailure.Kind] = [.offline, .timedOut, .unreachable, .untrustedCertificate,
                                        .secureConnectionFailed, .connectionLost, .serverError(500),
                                        .authExpired(401), .contentCrashed, .other("x")]
        for kind in kinds {
            let failure = WebFailure(kind: kind)
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertTrue(failure.spokenSummary.contains(failure.title))
        }
    }
}

@MainActor
final class WebViewModelStateTests: XCTestCase {
    private let server = try! ServerURL.parse("https://syrus.example.com")

    private func makeModel() -> WebViewModel {
        let model = WebViewModel(monitorsNetwork: false)
        model.load(server: server)
        return model
    }

    func testFailureThenRetryReturnsToLoading() {
        let model = makeModel()
        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertEqual(model.state, .failed(WebFailure(kind: .timedOut)))
        model.reload()
        XCTAssertEqual(model.state, .loading)
    }

    func testCancelledNavigationDoesNotFail() {
        let model = makeModel()
        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(model.state, .loading)
    }

    func testRegainingConnectivityRetriesRecoverableFailures() {
        let model = makeModel()
        model.connectivityChanged(isOnline: false)
        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertFalse(model.isOnline)
        model.connectivityChanged(isOnline: true)
        XCTAssertTrue(model.isOnline)
        XCTAssertEqual(model.state, .loading)
    }

    func testRegainingConnectivityDoesNotRetryCertificateFailures() {
        let model = makeModel()
        model.connectivityChanged(isOnline: false)
        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        model.connectivityChanged(isOnline: true)
        XCTAssertEqual(model.state, .failed(WebFailure(kind: .untrustedCertificate)))
    }

    func testAuthExpiryShowsSessionFailureAndRetryRestartsAtServerRoot() {
        let model = makeModel()
        model.mainFrameResponded(statusCode: 401)
        XCTAssertEqual(model.state, .failed(WebFailure(kind: .authExpired(401))))
        model.reload()
        XCTAssertEqual(model.state, .loading)
    }

    func testRepeatedContentCrashSurfacesAppFailure() {
        let model = makeModel()
        model.contentProcessTerminated()
        // First crash with a page in flight: transparently reload.
        XCTAssertEqual(model.state, .loading)
        model.contentProcessTerminated()
        // A second crash before any successful load is surfaced as an app problem.
        XCTAssertEqual(model.state, .failed(WebFailure(kind: .contentCrashed)))
    }

    func testResumeRetriesRecoverableFailureOnlyWhenOnline() {
        let model = makeModel()
        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        model.resume()
        XCTAssertEqual(model.state, .loading)

        model.fail(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        model.resume()
        XCTAssertEqual(model.state, .failed(WebFailure(kind: .untrustedCertificate)))
    }

    func testTearDownClearsFailure() {
        let model = makeModel()
        model.mainFrameResponded(statusCode: 503)
        model.tearDown()
        XCTAssertEqual(model.state, .idle)
    }
}
