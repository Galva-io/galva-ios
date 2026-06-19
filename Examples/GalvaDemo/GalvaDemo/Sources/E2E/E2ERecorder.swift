//
//  E2ERecorder.swift
//  GalvaDemo
//
//  Shared sink the mock URLProtocol writes intercepted event uploads into,
//  and that the control panel observes — so identity/track UI tests can
//  assert on what actually left the SDK (the `/identities/batchCollect`
//  request bodies).
//

import Foundation
import Combine

final class E2ERecorder: ObservableObject {
    static let shared = E2ERecorder()

    @Published private(set) var uploadCount = 0
    @Published private(set) var lastUploadBody = ""

    private init() {}

    /// Called from a URL loading thread; hop to main for the @Published writes.
    func recordUpload(_ body: String) {
        DispatchQueue.main.async {
            self.uploadCount += 1
            self.lastUploadBody = body
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.uploadCount = 0
            self.lastUploadBody = ""
        }
    }
}
