import Combine
import Foundation

public protocol AnalyticEvent {
    var eventName: String { get }
    var attributes: [String: any Sendable]? { get }
}

public final class GalvaApp: Sendable {
    static let sdkVersion: String = "1.0.0"
    static let apiVersion: String = "1"

    public let configuration: Configuration
    private let queue: MessageQueue
    private let consumer: CDPMessageConsumer
    private let queueRunLoopTask: Task<Void, Never>

    public init(configuration: Configuration) {
        let consumer = CDPMessageConsumer(configuration: configuration)
        self.configuration = configuration
        self.consumer = consumer
        
        let queue = MessageQueue(consumer: consumer,
                                 options: .init(batchingWindow: .init(timeWindow: configuration.flushInterval,
                                                                      maxCount: 50)))
        
        self.queue = queue

        queueRunLoopTask = Task(
            priority: .background,
            operation: { [weak queue] in
                await queue?.startRunloop()
            }
        )
    }

    public func track<E: AnalyticEvent>(event: E) {
        track(event: event.eventName, attributes: event.attributes)
    }

    public func track(event: String, attributes: [String: any Sendable]? = nil) {
        Task(priority: .background) {
            await queue.emit(
                .track(
                    event: event,
                    userId: currentUserId,
                    anonymousId: anonymousId,
                    apiVersion: Self.apiVersion,
                    properties: attributes,
                    context: Self.currentContext
                ))
        }
    }

    public func identify(userId: String, traits: [String: Any]? = nil) {
        let traitsToUpdate = traits?
            .mapValues({
                Message.TraitUpdateOperation(operation: .set, value: RevFlowPrimitive(rawValue: $0))
            })
        
        Task(priority: .background) {
            currentUserId = userId
            await queue.emit(.identify(userId: userId,
                                       anonymousId: anonymousId,
                                       apiVersion: Self.apiVersion,
                                       traits: traitsToUpdate,
                                       context: Self.currentContext))
        }
    }

    deinit {
        queueRunLoopTask.cancel()
    }
}

private extension GalvaApp {
    var anonymousId: String {
        if let previouslySavedId = UserDefaults.standard.string(forKey: "__GVAnonymousId") {
            return previouslySavedId
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "__GVAnonymousId")
            return newID
        }
    }

    var currentUserId: String? {
        get {
            UserDefaults.standard.string(forKey: "__GVUserId")
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "__GVUserId")
            } else {
                UserDefaults.standard.removeObject(forKey: "__GVUserId")
            }
        }
    }
}

public extension GalvaApp {
    struct Configuration: Codable, Sendable {
        public var apiKey: String
        public var flushQueueSize: Int = 10
        public var flushInterval: TimeInterval
        public var optOut: Bool
        public var useBatch: Bool
        let serverUrl: URL
        public var flushEventsOnClose: Bool

        var logger: any GalvaLogger {
            GalvaConsoleLogger()
        }

        public init(
            apiKey: String,
            flushInterval: TimeInterval = 5,
            optOut: Bool = false,
            useBatch: Bool = true,
            flushEventsOnClose: Bool = true
        ) {
            self.apiKey = apiKey
            self.flushInterval = flushInterval
            self.optOut = optOut
            self.useBatch = useBatch
            serverUrl = URL(string: "https://api.galva.dev")!
            self.flushEventsOnClose = flushEventsOnClose
        }
    }

}
