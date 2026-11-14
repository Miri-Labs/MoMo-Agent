import Foundation
import XCTest
@testable import MoMoAgentClient

final class AgentTransportFailureTests: XCTestCase {
    func testPolicyAndCertificateFailuresNeverEnterLinkRecovery() {
        for code in [URLError.appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
                     .serverCertificateUntrusted, .serverCertificateHasBadDate, .clientCertificateRequired, .unsupportedURL] {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue,
                                userInfo: [NSUnderlyingErrorKey: POSIXError(.ECONNRESET)])
            XCTAssertTrue(AgentTransportFailure.isConfigurationFailure(error))
            XCTAssertFalse(AgentTransportFailure.isSocketOrLinkFailure(error))
            XCTAssertFalse(AgentTransportFailure.isTransient(error))
        }
        XCTAssertFalse(AgentTransportFailure.isTransient(URLError(.cancelled)))
        XCTAssertFalse(AgentTransportFailure.isTransient(URLError(.cannotDecodeContentData)))
    }

    func testValidatedProxyBadURLCompatibilityAndRealLinkFailuresRemainRetryable() {
        for info: [String: Any] in [[:], [NSUnderlyingErrorKey: POSIXError(.ECONNREFUSED)]] {
            XCTAssertTrue(AgentTransportFailure.isSocketOrLinkFailure(
                NSError(domain: NSURLErrorDomain, code: URLError.badURL.rawValue, userInfo: info)))
        }
        for code in [URLError.timedOut, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(AgentTransportFailure.isTransient(URLError(code)))
        }
        XCTAssertTrue(AgentTransportFailure.isTransient(POSIXError(.ECONNRESET)))
        XCTAssertTrue(AgentTransportFailure.isTransient(AgentClientError.http(status: 429, code: nil, message: nil, retryAfter: 30)))
        XCTAssertFalse(AgentTransportFailure.isTransient(RelayError.authentication))
    }
}
