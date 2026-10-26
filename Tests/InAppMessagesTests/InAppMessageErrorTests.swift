//
//  InAppMessageErrorTests.swift
//  GalvaTests
//
//  `message.show(in:)` and `.inAppMessageSheet` only ever throw
//  `InAppMessages.Error`. Covers the one mapping from what the pipeline
//  throws internally (presenter errors, resolve's API errors) to the public
//  cases.
//

import Foundation
@testable import Galva
import XCTest

final class InAppMessageErrorTests: XCTestCase {

    func test_publicErrors_passThrough() {
        let cases: [InAppMessages.Error] = [
            .notConfigured, .messageNotFound, .bundleUnavailable,
            .noPresentingViewController, .requestFailed,
        ]
        for error in cases {
            XCTAssertEqual(InAppMessages.Error(error), error)
        }
    }

    func test_internalErrors_mapToTheirPublicCase() {
        XCTAssertEqual(InAppMessages.Error(InAppMessageError.invalidMessageId), .messageNotFound,
                       "an id Galva never issued is a message Galva can't find")
        XCTAssertEqual(InAppMessages.Error(InAppMessageError.messageNotFound), .messageNotFound)
        XCTAssertEqual(InAppMessages.Error(InAppMessageError.bundleUnavailable), .bundleUnavailable)
        XCTAssertEqual(InAppMessages.Error(InAppMessageError.noPresentingViewController),
                       .noPresentingViewController,
                       "no window to present on is not a configuration problem")
    }

    func test_resolveFailures_mapToRequestFailed() {
        let errors: [any Error] = [
            APIError.http(status: 500, body: Data()),
            APIError.http(status: 401, body: Data()),
            APIError.transport(URLError(.notConnectedToInternet)),
            APIError.invalidResponse,
            APIError.decoding(URLError(.cannotParseResponse)),
            URLError(.timedOut),
        ]
        for error in errors {
            XCTAssertEqual(InAppMessages.Error(error), .requestFailed, "\(error)")
        }
    }
}
