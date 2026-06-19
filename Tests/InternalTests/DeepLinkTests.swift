//
//  DeepLinkTests.swift
//  GalvaTests
//
//  Covers the deep-link parser + the public `Galva.handleOpenURL(_:)` gate:
//    • Only `gv…` schemes are claimed; http(s) / other schemes are ignored.
//    • `parse(_:)` yields a strongly-typed `DeepLink` case whose associated
//      values are the route's validated parameters (no runtime
//      `parameters["…"]` digging in handlers).
//    • Routing is case-insensitive (host or path action).
//    • Failures yield a precise `ParseError` for diagnostics.
//    • `Galva.handleOpenURL` returns true only for a Galva URL.
//

import Foundation
@testable import Galva
import XCTest

final class DeepLinkTests: XCTestCase {

    // MARK: - canHandle

    func test_canHandle_acceptsGVSchemes() {
        XCTAssertTrue(DeepLink.canHandle(URL(string: "gv://openCommunication?x=1")!))
        XCTAssertTrue(DeepLink.canHandle(URL(string: "gvabc123://openCommunication")!))
        XCTAssertTrue(DeepLink.canHandle(URL(string: "GV://openCommunication")!)) // case-insensitive
    }

    func test_canHandle_rejectsNonGVSchemes() {
        XCTAssertFalse(DeepLink.canHandle(URL(string: "https://example.com/openCommunication")!))
        XCTAssertFalse(DeepLink.canHandle(URL(string: "http://example.com")!))
        XCTAssertFalse(DeepLink.canHandle(URL(string: "myapp://openCommunication")!))
        XCTAssertFalse(DeepLink.canHandle(URL(string: "mailto:x@y.co")!))
    }

    // MARK: - parse success → typed case

    func test_parse_openCommunication_hostForm() throws {
        let link = try parsedSuccess("gvabc://openCommunication?communicationId=comm_123&foo=bar")
        guard case let .openCommunication(communicationId, parameters) = link else {
            return XCTFail("expected .openCommunication, got \(link)")
        }
        XCTAssertEqual(communicationId, "comm_123")
        // Full query dict is carried for `window.galvaDeepLinkParams` injection.
        XCTAssertEqual(parameters["communicationId"], "comm_123")
        XCTAssertEqual(parameters["foo"], "bar")
    }

    func test_parse_openCommunication_actionIsCaseInsensitive() throws {
        let link = try parsedSuccess("gvabc://OpenCommunication?communicationId=x")
        guard case .openCommunication = link else {
            return XCTFail("case-insensitive action should still route to .openCommunication")
        }
    }

    func test_parse_openCommunication_pathForm_whenHostEmpty() throws {
        // gv:///openCommunication — empty host, action comes from the path.
        let link = try parsedSuccess("gvabc:///openCommunication?communicationId=x")
        guard case let .openCommunication(communicationId, _) = link else {
            return XCTFail("expected .openCommunication, got \(link)")
        }
        XCTAssertEqual(communicationId, "x")
    }

    // MARK: - parse failure → typed reason

    func test_parse_rejectsNonGVScheme() {
        XCTAssertEqual(
            parsedFailure("https://example.com/openCommunication?communicationId=x"),
            .notGalvaScheme
        )
    }

    func test_parse_missingCommunicationId() {
        XCTAssertEqual(
            parsedFailure("gvabc://openCommunication?foo=bar"),
            .missingParameter(action: "openCommunication", name: "communicationId")
        )
    }

    func test_parse_emptyCommunicationId_isMissing() {
        XCTAssertEqual(
            parsedFailure("gvabc://openCommunication?communicationId="),
            .missingParameter(action: "openCommunication", name: "communicationId")
        )
    }

    func test_parse_unknownAction() {
        XCTAssertEqual(
            parsedFailure("gvabc://unknownroute?communicationId=x"),
            .unknownAction("unknownroute")
        )
    }

    func test_parse_missingAction() {
        // No host, no path → no action to route on.
        XCTAssertEqual(parsedFailure("gvabc://?communicationId=x"), .missingAction)
    }

    func test_parseError_descriptionIsDescriptive() {
        // The reason text the router logs must name the action + missing param
        // (and never leak values — asserted here by what it *does* contain).
        let reason = DeepLink.ParseError
            .missingParameter(action: "openCommunication", name: "communicationId")
            .description
        XCTAssertTrue(reason.contains("openCommunication"))
        XCTAssertTrue(reason.contains("communicationId"))
    }

    // MARK: - Public gate

    func test_handleOpenURL_returnsTrueForGalvaURL() {
        XCTAssertTrue(Galva.handleOpenURL(URL(string: "gvabc://openCommunication?communicationId=x")!))
    }

    func test_handleOpenURL_returnsFalseForNonGalvaURL() {
        XCTAssertFalse(Galva.handleOpenURL(URL(string: "https://example.com")!))
        XCTAssertFalse(Galva.handleOpenURL(URL(string: "myapp://openCommunication")!))
    }

    // MARK: - Helpers

    private func parsedSuccess(_ string: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> DeepLink {
        switch DeepLink.parse(URL(string: string)!) {
        case .success(let link):
            return link
        case .failure(let error):
            XCTFail("expected success, got failure: \(error)", file: file, line: line)
            throw error
        }
    }

    private func parsedFailure(_ string: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> DeepLink.ParseError? {
        switch DeepLink.parse(URL(string: string)!) {
        case .success(let link):
            XCTFail("expected failure, got success: \(link)", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }
}
