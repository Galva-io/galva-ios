//
//  SDKCore.swift
//  Galva
//
//  Internal singleton that owns all SDK state. The public API in Galva.swift
//  is a thin layer that hops onto `GalvaActor` and calls methods here.
//
//  ┌────────────────────────────────────────────────────────────────────────┐
//  │  Threading                                                              │
//  │  • Every mutable property is GalvaActor-isolated.                       │
//  │  • `cachedEndUserId` mirrors the identified user id in a lock so the    │
//  │    public synchronous getter `AppUser.identifiedUserId` can read it     │
//  │    from any thread without awaiting.                                    │
//  │                                                                         │
//  │  Lifecycle                                                              │
//  │  • configure() — captures the UI snapshot on MainActor, wires up        │
//  │                  IdentityStore + Uploader + MessageQueue.               │
//  │  • identify/track/logOut — enqueue a Message; queue does the rest.      │
//  │                                                                         │
//  │  All emits go through MessageQueue → UploadConsumer → Uploader → HTTP.  │
//  └────────────────────────────────────────────────────────────────────────┘
//

import Foundation

@GalvaActor
final class SDKCore {

    nonisolated static let shared = SDKCore()
    nonisolated private init() {}

    // MARK: State

    private var configured = false
    private var apiKey: String?
    private var autoTrack: Galva.AutoTrackCategory = []
    private var logLevel: Galva.LogLevel = .warning
    private var deviceToken: String?

    private var identity: IdentityStore?
    private var queue: MessageQueue?
    private var uploader: Uploader?
    private var contextProvider: ContextProvider?
    private var logger: any GalvaLogger = GalvaConsoleLogger()

    /// Thread-safe mirror of the identified endUserId. Mutated whenever
    /// identify/logOut runs on GalvaActor; read by `AppUser.identifiedUserId`
    /// from any context without awaiting. The lock itself is nonisolated so
    /// the read path doesn't need to hop onto GalvaActor.
    nonisolated private static let _identifiedUserIdLock = NSLock()
    nonisolated(unsafe) private static var _identifiedUserId: String?

    nonisolated var cachedEndUserId: String? {
        Self._identifiedUserIdLock.lock()
        defer { Self._identifiedUserIdLock.unlock() }
        return Self._identifiedUserId
    }

    private func setCachedEndUserId(_ value: String?) {
        Self._identifiedUserIdLock.lock()
        Self._identifiedUserId = value
        Self._identifiedUserIdLock.unlock()
    }

    var currentEndUserId: String? { identity?.endUserId }
    var currentAnonymousId: String? { identity?.anonymousId }

    // MARK: Configure

    func configure(
        apiKey: String,
        autoTrack: Galva.AutoTrackCategory,
        logLevel: Galva.LogLevel
    ) async {
        guard !configured else {
            logger.log(.warning, message: "Galva.configure called more than once — ignoring", error: nil)
            return
        }

        self.apiKey = apiKey
        self.autoTrack = autoTrack
        self.logLevel = logLevel
        let identity = IdentityStore()
        self.identity = identity

        // Capture UI-bound system properties once on MainActor.
        let snapshot = await MainActor.run { DeviceSnapshot.capture() }
        self.contextProvider = ContextProvider(deviceToken: deviceToken, snapshot: snapshot)
        setCachedEndUserId(identity.endUserId)

        let uploader = Uploader(
            baseURL: SDKConstants.defaultBaseURL,
            apiKey: apiKey,
            session: .shared,
            logger: logger
        )
        self.uploader = uploader

        let consumer = UploadConsumer(uploader: uploader, logger: logger)
        let queue = MessageQueue(
            consumer: consumer,
            options: .init(
                batchingWindow: .init(
                    timeWindow: SDKConstants.defaultFlushInterval,
                    maxCount: SDKConstants.defaultFlushAtCount
                )
            ),
            name: "default",
            logger: logger
        )
        self.queue = queue

        await queue.startRunloop()
        configured = true
        logger.log(.info, message: "Galva SDK configured", error: nil)
    }

    func setDeviceToken(_ token: String) {
        self.deviceToken = token
        // Preserve the existing UI snapshot when updating the device token.
        let snapshot = contextProvider?.snapshot ?? .empty
        self.contextProvider = ContextProvider(deviceToken: token, snapshot: snapshot)
    }

    // MARK: Identify / Logout

    func identify(
        userId: String?,
        appAccountToken: UUID?,
        traits: [String: AnyJSONValue]?
    ) async {
        guard let queue, let identity, let contextProvider else {
            logger.log(.warning, message: "identify called before configure()", error: nil)
            return
        }
        if let userId {
            identity.setEndUserId(userId)
            setCachedEndUserId(userId)
        }

        var mergedTraits = traits ?? [:]
        if let token = appAccountToken {
            mergedTraits["$gv_appAccountToken"] = .string(token.uuidString)
        }

        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .identify(traits: mergedTraits.isEmpty ? nil : mergedTraits)
        )
        await queue.emit(msg)
    }

    func logOut() async {
        guard let identity else { return }
        identity.setEndUserId(nil)
        identity.rotateAnonymousId()
        setCachedEndUserId(nil)
    }

    // MARK: Track

    func track(event: String, properties: [String: AnyJSONValue]?) async {
        guard let queue, let identity, let contextProvider else {
            logger.log(.warning, message: "track called before configure()", error: nil)
            return
        }
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .track(event: event, properties: properties, sourceType: nil, sourceId: nil)
        )
        await queue.emit(msg)
    }

    // MARK: Communication endpoints

    func createEndpoint(_ endpoint: CommunicationEndpoint) async {
        guard let queue, let identity, let contextProvider else { return }
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .createCommunicationEndpoint(endpoint)
        )
        await queue.emit(msg)
    }

    func deleteEndpoint(_ endpoint: CommunicationEndpoint) async {
        guard let queue, let identity, let contextProvider else { return }
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .deleteCommunicationEndpoint(endpoint)
        )
        await queue.emit(msg)
    }

    func setPreference(
        channel: CommunicationEndpoint.ChannelType,
        disabled: Bool?,
        categories: [String: Bool]?
    ) async {
        guard let queue, let identity, let contextProvider else { return }
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .setCommunicationPreference(
                channelType: channel,
                disabled: disabled,
                categories: categories
            )
        )
        await queue.emit(msg)
    }
}
