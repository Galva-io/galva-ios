//
//  ControlPanelView.swift
//  GalvaDemo
//
//  Drives every SDK flow from accessibility-labeled buttons so the XCUITest
//  suite can exercise them deterministically (no cross-process simctl). Also
//  surfaces the mock's recorded uploads + perf probes for the tests to read.
//
//  Uses ScrollView + (eager) VStack rather than a List on purpose: List
//  virtualizes rows, dropping off-screen ones from the accessibility tree, so
//  a readout below the fold (e.g. the upload body) becomes unreadable. A plain
//  VStack renders every row up front, keeping all ids + labels in the a11y
//  tree regardless of scroll position.
//

import SwiftUI
import Galva

struct ControlPanelView: View {
    @ObservedObject private var recorder = E2ERecorder.shared
    @ObservedObject private var probe = MetricsProbe.shared

    /// A valid-UUID communication id the mock resolves to a renderable
    /// payload. Used by the deep-link flow.
    private let deepLinkCommunicationId = MockFixtures.deepLinkCommunicationId

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Perf probes first (on-screen at launch for the perf test).
                    section("Metrics (perf)") {
                        metric("metric.memoryMB", probe.memoryMB)
                        metric("metric.launchMs", probe.launchMs)
                        metric("metric.cpuMs", probe.cpuMs)
                        if probe.ready {
                            Text("ready").accessibilityIdentifier("metric.ready")
                        }
                    }

                    section("Identity") {
                        actionButton("Identify user_42", id: "identify") {
                            AppUser.identify(userId: "user_42")
                        }
                        actionButton("Set email", id: "setEmail") {
                            AppUser.set(.email, "e2e@example.com")
                        }
                        actionButton("Log out", id: "logout") {
                            AppUser.logOut()
                        }
                    }

                    section("Events") {
                        actionButton("Track event", id: "track") {
                            AppEvents.track("E2EButtonTapped", attributes: ["src": "e2e"])
                        }
                    }

                    section("In-app messages") {
                        actionButton("Check for messages", id: "checkMessages") {
                            InAppMessages.checkForMessages()
                        }
                        actionButton("Open deep link", id: "openDeepLink") {
                            openDeepLink()
                        }
                    }

                    section("Mock uploads (debug)") {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Galva Demo")
            .onAppear { probe.onFirstFrame() }
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func actionButton(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }

    /// A metric row whose a11y label is the raw number, for the perf test to parse.
    private func metric(_ id: String, _ value: Double) -> some View {
        let text = String(format: "%.3f", value)
        return Text("\(id): \(text)")
            .font(.caption.monospaced())
            .accessibilityIdentifier(id)
            .accessibilityLabel(text)
    }

    private func openDeepLink() {
        guard let url = URL(
            string: "gvdemo://openCommunication?communicationId=\(deepLinkCommunicationId)"
        ) else { return }
        Galva.handleOpenURL(url)
    }
}
