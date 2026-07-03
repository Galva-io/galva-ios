//
//  MockFixtures.swift
//  GalvaDemo
//
//  Canned backend responses for the in-process mock, hand-shaped to decode
//  against the SDK's real wire models (InitializeResponse,
//  CommunicationListResponse, ResolveResponse). Dates use the SDK's ISO-8601
//  format (fractional seconds, `Z`). `flushSize: 1` makes the message queue
//  flush after every event so upload assertions don't wait on a batch window.
//

import Foundation

enum MockFixtures {

    /// Poll message id (must be a valid UUID — `CommunicationItem.id: UUID`).
    static let pollMessageId = "11111111-1111-1111-1111-111111111111"
    /// Deep-link target communication id.
    static let deepLinkCommunicationId = "22222222-2222-2222-2222-222222222222"
    /// Second, distinct message for the `showInAppMessageTwice` scenario. Shares
    /// bundle `1.0.0` with `pollMessageId` so its presentation is a cache hit.
    static let secondMessageId = "44444444-4444-4444-4444-444444444444"

    private static let createdAt = "2026-06-18T10:30:00.000Z"

    /// `POST /sdk/initialize` — one webview version, fast flush, no SKUs.
    static let initialize = """
    {"data":{"webviewVersions":["1.0.0"],"batchCollection":{"flushSize":1,"flushIntervalMs":200}}}
    """

    /// `GET /identities/communications` — scenario-dependent message list.
    /// `second` selects the second message for `showInAppMessageTwice` (flipped
    /// by the demo's "Next message" control).
    static func poll(for scenario: E2EScenario, second: Bool = false) -> String {
        switch scenario {
        case .showInAppMessage, .showInAppMessageUIKit:
            return message(id: pollMessageId)
        case .showInAppMessageTwice:
            return message(id: second ? secondMessageId : pollMessageId)
        case .deepLinkTarget, .deepLinkRace:
            // Nothing until the test flips `second` (via "Next message"), which
            // delivers a poll message that must YIELD to an active deep-link.
            return second ? message(id: secondMessageId) : #"{"success":true,"data":[],"meta":{"nextCursor":null}}"#
        case .noMessages:
            return #"{"success":true,"data":[],"meta":{"nextCursor":null}}"#
        }
    }

    private static func message(id: String) -> String {
        """
        {"success":true,"data":[{"id":"\(id)","type":"trial-rescue-in-app","workflowType":"trial-rescue","createdAt":"\(createdAt)"}],"meta":{"nextCursor":null}}
        """
    }

    /// `POST /identities/communications/{id}/resolve` — a renderable payload
    /// for the active message (the bundle reads `title` via getMessageData).
    static func resolve(for scenario: E2EScenario) -> String {
        switch scenario {
        case .noMessages:
            return #"{"data":{"valid":false}}"#
        case .showInAppMessage, .showInAppMessageUIKit, .showInAppMessageTwice, .deepLinkTarget, .deepLinkRace:
            return """
            {"data":{"valid":true,"webviewVersion":"1.0.0","payload":{"title":"E2E Offer","communicationId":"\(deepLinkCommunicationId)","source":"e2e"}}}
            """
        }
    }

    /// The in-app message HTML bundle, served as `<cdn>/1.0.0.html`. Read from
    /// the app resource so it's a real, editable file the download+cache path
    /// exercises end to end.
    static func testBundleHTML() -> Data {
        if let url = Bundle.main.url(forResource: "TestBundle", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return Data("<html><body><h1>missing TestBundle.html</h1></body></html>".utf8)
    }
}
