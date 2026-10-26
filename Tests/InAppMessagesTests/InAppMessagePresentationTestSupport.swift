//
//  InAppMessagePresentationTestSupport.swift
//  GalvaTests
//
//  Helpers for the UIKit / WebKit presentation tests, which run on the iOS
//  Simulator:
//    • `InAppMessageStubServer` — a valid resolve for any message, a
//      caller-supplied HTML page as its bundle, and optionally a list of
//      pending messages, through `URLProtocolStub`
//    • `RecordingHost` — records what the bridge and the WebView's
//      navigation policy ask of the presentation
//    • `waitUntil` — bounded polling on the main actor, with
//      `generousTimeout` for anything that should happen
//
//  The test runner is not an app: WebKit loads pages and delivers script
//  messages, but UIKit never finishes a view controller transition, so a
//  `present` completion never fires.
//

import Foundation
@_spi(Testing) @testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

enum InAppMessageStubServer {

    /// The webview version every resolve pins.
    static let version = "1.0.0"

    /// Resolves every message as valid, pinned to `version`, and serves
    /// `html` as that version's bundle — and `listing` as the pending
    /// messages. Anything else fails with a 500.
    static func handler(html: String, listing: [UUID] = []) -> URLProtocolStub.Handler {
        { request in
            let url = request.url!
            if url.host == "webview.galva.test" {
                return (URLProtocolStub.httpResponse(url: url, status: 200), Data(html.utf8))
            }
            if url.path == SDKConstants.communicationListPath {
                let items = listing.map { id -> [String: Any] in
                    [
                        "id": id.uuidString,
                        "type": "trial-rescue-in-app",
                        "workflowType": "trial-rescue",
                        "createdAt": ISO8601DateFormatter.galva.string(from: Date()),
                    ]
                }
                let body = try JSONSerialization.data(withJSONObject: [
                    "success": true,
                    "data": items,
                    "meta": ["nextCursor": NSNull()],
                ] as [String: Any])
                return (URLProtocolStub.httpResponse(url: url, status: 200), body)
            }
            guard url.path.hasSuffix("/resolve") else {
                return (URLProtocolStub.httpResponse(url: url, status: 500), Data())
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "data": [
                    "valid": true,
                    "webviewVersion": version,
                    "payload": ["kind": "test"],
                ],
            ] as [String: Any])
            return (URLProtocolStub.httpResponse(url: url, status: 200), body)
        }
    }

    /// Message ids resolved so far, in request order.
    static var resolvedIds: [String] {
        URLProtocolStub.requests.compactMap { request -> String? in
            guard let url = request.url, url.path.hasSuffix("/resolve") else { return nil }
            return url.deletingLastPathComponent().lastPathComponent
        }
    }
}

/// An in-app message with a server-shaped (UUID) id.
func makeInAppMessage() -> InAppMessages.Message {
    InAppMessages.Message(id: UUID().uuidString.lowercased(), workflowType: nil, createdAt: Date())
}

/// Records what the bridge and the navigation policy ask of the host.
@MainActor
final class RecordingHost: InAppMessageHost {
    var webView: WKWebView?
    var safeAreaInsets: UIEdgeInsets { .zero }
    private(set) var revealCount = 0
    private(set) var dismissReasons: [String?] = []

    func reveal() { revealCount += 1 }
    func dismiss(reason: String?) { dismissReasons.append(reason) }
}

/// How long to wait for something that should happen: WebKit loading a page,
/// a `show` getting through to UIKit. Generous, because on a freshly booted
/// simulator (as on a CI runner) WebKit's first page load can take most of a
/// minute while it launches its processes and waits on system daemons. It
/// costs nothing when things work: `waitUntil` returns as soon as its
/// condition holds.
let generousTimeout: TimeInterval = 120

/// Poll `condition` until it holds or `seconds` pass. Returns whether it held.
@MainActor
func waitUntil(within seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

#endif
