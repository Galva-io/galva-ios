//
//  DurableRequestQueueTests.swift
//  GalvaTests
//
//  Covers the guaranteed-delivery queue for `shouldRetry` apiFetch:
//    • 2xx → delivered + removed.
//    • other 4xx → permanent → dropped (never wedges the queue).
//    • 5xx / network → retained for retry; a later drain delivers it.
//    • size cap evicts oldest (FIFO).
//    • SQLite store survives across instances (cross-launch durability).
//

import Foundation
@testable import Galva
import XCTest

final class DurableRequestQueueTests: XCTestCase {

    private static let base = URL(string: "https://api.galva.io")!

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Delivery / drop / retry

    func test_enqueue_deliversOn2xx_andRemoves() async {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
        }
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/x", method: "POST", body: nil, headers: [:])
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 0, "a 2xx request should be delivered and removed")
        }
    }

    func test_enqueue_dropsOnPermanent4xx() async {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 404), Data())
        }
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/missing", method: "GET", body: nil, headers: [:])
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 0, "a permanent 4xx must be dropped, not retried forever")
        }
    }

    func test_enqueue_retainsOnRetryable5xx() async {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 503), Data())
        }
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/flaky", method: "POST", body: nil, headers: [:])
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 1, "a 5xx must be retained for retry")
        }
    }

    func test_retryable_thenRecovers_delivers() async {
        // First attempt fails (503) → retained. Then the endpoint recovers
        // (200) and a fresh drain delivers it. Proves eventual delivery.
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 503), Data())
        }
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/x", method: "POST", body: nil, headers: [:])
            var pending = await queue.pendingCount
            XCTAssertEqual(pending, 1)

            // Endpoint recovers. A forced drain (as foreground / the scheduled
            // retry would issue) bypasses the backoff window and re-attempts.
            URLProtocolStub.handler = { _ in
                (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
            }
            await queue.drain(force: true)
            pending = await queue.pendingCount
            XCTAssertEqual(pending, 0, "request must eventually deliver once the endpoint recovers")
        }
    }

    func test_backoffWindow_unforcedDrainDoesNotReattempt() async {
        // After a transient failure the queue is backing off. An unforced
        // drain (what a burst of enqueues triggers) must NOT hit the network
        // again — it defers to the scheduled retry. We prove it by counting
        // requests that reach the stub.
        let counter = RequestCounter()
        URLProtocolStub.handler = { _ in
            counter.bump()
            return (URLProtocolStub.httpResponse(url: Self.base, status: 503), Data())
        }
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/x", method: "POST", body: nil, headers: [:])
            // First enqueue attempted once (→ 503 → backing off).
            XCTAssertEqual(counter.value, 1)

            // Several more unforced drains while inside the backoff window:
            // none should reach the network.
            await queue.drain()
            await queue.drain()
            await queue.drain()
            XCTAssertEqual(counter.value, 1, "unforced drains during backoff must not hit the network")

            // A forced drain (foreground / scheduled retry) is allowed through.
            await queue.drain(force: true)
            XCTAssertEqual(counter.value, 2, "a forced drain bypasses the backoff window")
        }
    }

    func test_retainsOnTransportError() async {
        // No handler set → URLProtocolStub fails the request (transport error).
        URLProtocolStub.handler = nil
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/x", method: "POST", body: nil, headers: [:])
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 1, "network/transport failure must retain for retry (the network-lost case)")
        }
    }

    // MARK: - Auth injection on replay

    func test_replay_injectsAPIKeyAndForwardsBodyMethod() async {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
        }
        let body = Data(#"{"answer":"yes"}"#.utf8)
        await Harness.run { queue, _ in
            await queue.enqueue(path: "/survey", method: "PUT", body: body, headers: ["X-Custom": "1"])
            _ = await queue.pendingCount
        }
        let captured = URLProtocolStub.lastRequest
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.galva.io/survey")
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.httpBody, body)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "pk_test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-Custom"), "1")
    }

    // MARK: - Size cap

    func test_sizeCap_evictsOldest() async {
        // 503 keeps everything retained so the cap is what bounds growth.
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 503), Data())
        }
        await Harness.run(maxStored: 3) { queue, _ in
            for i in 0..<6 {
                await queue.enqueue(path: "/x\(i)", method: "POST", body: nil, headers: [:])
            }
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 3, "queue must not grow past the cap; oldest evicted FIFO")
        }
    }

    // MARK: - Cross-launch durability (SQLite)

    func test_sqliteStore_survivesAcrossInstances() async {
        let path = NSTemporaryDirectory().appending("galva-proxy-test-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Instance A — store a request, then drop the reference.
        do {
            let store = try! SQLiteProxyRequestStore(dbPath: path)
            let req = DurableProxyRequest(path: "/x", method: "POST", body: Data("hi".utf8), headers: ["A": "B"])
            try! await store.store(req)
            let count = try! await store.count()
            XCTAssertEqual(count, 1)
        }
        // Instance B — same path, simulating a fresh launch.
        do {
            let store = try! SQLiteProxyRequestStore(dbPath: path)
            let rows = try! await store.fetchOldest(limit: 10)
            XCTAssertEqual(rows.count, 1, "request must survive across store instances (app relaunch)")
            XCTAssertEqual(rows.first?.path, "/x")
            XCTAssertEqual(rows.first?.method, "POST")
            XCTAssertEqual(rows.first?.body, Data("hi".utf8))
            XCTAssertEqual(rows.first?.headers["A"], "B")
        }
    }

    // MARK: - GalvaActor is not blocked by the `while true` drain loop

    func test_drain_returnsPromptlyWhenEmpty() async {
        // The clearest termination check: draining an empty queue must return,
        // not spin forever in `while true`. If the loop didn't `return` on an
        // empty fetch, this test would hang (and time out).
        await Harness.run { queue, _ in
            await queue.drain(force: true)
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 0)
        }
    }

    func test_drain_doesNotBlockActor_whileNetworkInFlight() async {
        // Proof that the `while true` loop releases the GalvaActor at its
        // `await` points: hold a replay parked inside the loop (the stub blocks
        // on a gate), then issue another GalvaActor-isolated call. If the loop
        // monopolized the actor, that call could not complete until drain
        // finished — but drain can't finish until we open the gate, so the
        // call returning here proves the actor stayed responsive mid-loop.
        let gate = Gate()
        URLProtocolStub.handler = { _ in
            gate.entered.signal()      // a replay is now in flight (drain parked at await)
            gate.release.wait()        // hold it there until the test says go
            return (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
        }

        await Harness.run { queue, store in
            // Seed directly (not via enqueue — enqueue would await the blocked drain).
            try? await store.store(
                DurableProxyRequest(path: "/x", method: "POST", body: nil, headers: [:])
            )

            // Start the drain; it parks inside `while true` at the network await.
            let drainTask = Task { @GalvaActor in await queue.drain(force: true) }

            // Wait (off the actor) until the replay is actually in flight.
            let entered = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    cont.resume(returning: gate.entered.wait(timeout: .now() + 3) == .success)
                }
            }
            XCTAssertTrue(entered, "replay should be in flight (drain parked mid-loop)")

            // THE ASSERTION: a GalvaActor call returns while the drain loop is
            // parked and the gate is still closed (so drain provably hasn't
            // finished). A blocked actor would make this hang.
            let pendingDuringDrain = await queue.pendingCount
            XCTAssertEqual(pendingDuringDrain, 1,
                           "actor stayed responsive while the drain loop was in flight")

            // Let it finish.
            gate.release.signal()
            await drainTask.value
            let pendingAfter = await queue.pendingCount
            XCTAssertEqual(pendingAfter, 0)
        }
    }

    func test_concurrentDrains_doNotDeadlock() async {
        // Two overlapping drains: the `isDraining` guard makes one bail
        // immediately while the other runs. Both must return (no deadlock),
        // and everything drains.
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
        }
        await Harness.run { queue, store in
            for i in 0..<3 {
                try? await store.store(
                    DurableProxyRequest(path: "/x\(i)", method: "POST", body: nil, headers: [:])
                )
            }
            async let first: Void = queue.drain(force: true)
            async let second: Void = queue.drain(force: true)
            _ = await (first, second)
            let pending = await queue.pendingCount
            XCTAssertEqual(pending, 0, "overlapping drains must both return and deliver everything")
        }
    }

    // MARK: - Helpers

    /// Two-phase gate the `@Sendable` stub handler uses to park a replay
    /// in flight: `entered` fires when the request reaches the stub,
    /// `release` holds it there until the test opens it. `@unchecked
    /// Sendable` — `DispatchSemaphore` is itself thread-safe.
    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    /// Lock-protected hit counter the `@Sendable` URLProtocolStub handler can
    /// safely bump from whatever queue URLSession calls it on.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func bump() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }

    // MARK: - Harness

    @GalvaActor
    private enum Harness {
        static func run(
            maxStored: Int = 500,
            _ body: @GalvaActor (DurableRequestQueue, InMemoryProxyRequestStore) async -> Void
        ) async {
            let client = APIClient(
                baseURL: base,
                apiKey: "pk_test",
                session: URLProtocolStub.makeSession(),
                logger: SilentLogger()
            )
            let store = InMemoryProxyRequestStore()
            let queue = DurableRequestQueue(
                store: store,
                client: client,
                logger: SilentLogger(),
                maxStored: maxStored
            )
            await body(queue, store)
        }
    }
}
