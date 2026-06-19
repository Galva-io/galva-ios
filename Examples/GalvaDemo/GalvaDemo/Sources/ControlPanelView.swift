//
//  ControlPanelView.swift
//  GalvaDemo
//
//  Drives every SDK flow from accessibility-labeled buttons so the XCUITest
//  suite can exercise them deterministically (no cross-process simctl). Also
//  surfaces the mock's recorded uploads so identity/track tests can assert on
//  what actually left the SDK.
//

import SwiftUI
import Galva

struct ControlPanelView: View {
    @ObservedObject private var recorder = E2ERecorder.shared

    /// A valid-UUID communication id the mock resolves to a renderable
    /// payload. Used by the deep-link flow.
    private let deepLinkCommunicationId = MockFixtures.deepLinkCommunicationId

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    Button("Identify user_42") {
                        AppUser.identify(userId: "user_42")
                    }
                    .accessibilityIdentifier("identify")

                    Button("Set email") {
                        AppUser.set(.email, "e2e@example.com")
                    }
                    .accessibilityIdentifier("setEmail")

                    Button("Log out") {
                        AppUser.logOut()
                    }
                    .accessibilityIdentifier("logout")
                }

                Section("Events") {
                    Button("Track event") {
                        AppEvents.track("E2EButtonTapped", attributes: ["src": "e2e"])
                    }
                    .accessibilityIdentifier("track")
                }

                Section("In-app messages") {
                    Button("Check for messages") {
                        InAppMessages.checkForMessages()
                    }
                    .accessibilityIdentifier("checkMessages")

                    Button("Open deep link") {
                        openDeepLink()
                    }
                    .accessibilityIdentifier("openDeepLink")
                }

                Section("Mock uploads (debug)") {
                    Text("uploads: \(recorder.uploadCount)")
                        .accessibilityIdentifier("uploadCount")
                    Text(recorder.lastUploadBody.isEmpty ? "—" : recorder.lastUploadBody)
                        .font(.caption.monospaced())
                        .lineLimit(8)
                        .accessibilityIdentifier("uploadDebug")
                        // Force the full body onto the a11y label so XCUITest
                        // can substring-match regardless of visual truncation.
                        .accessibilityLabel(recorder.lastUploadBody)
                }
            }
            .navigationTitle("Galva Demo")
        }
    }

    private func openDeepLink() {
        guard let url = URL(
            string: "gvdemo://openCommunication?communicationId=\(deepLinkCommunicationId)"
        ) else { return }
        Galva.handleOpenURL(url)
    }
}
