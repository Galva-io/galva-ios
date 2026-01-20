//
//  Application+Consumer.swift
//  Galva
//
//  Created by Peter Vu on 12/9/25.
//

import Foundation

extension GalvaApp {
    struct CDPMessageConsumer: MessageConsumer {
        let configuration: Configuration
        private let queueManager: SwiftQueueManager

        init(configuration: Configuration) {
            self.configuration = configuration
            queueManager = SwiftQueueManagerBuilder(
                creator: SendBatchingMessageJobCreator(logger: configuration.logger)
            ).build()
        }

        func consume(messages: [Message]) async throws {
            configuration.logger.log(
                .info,
                message: "CDPMessageConsumer: Starting to consume \(messages.count) messages",
                error: nil
            )
            let params: SendBatchingMessageJobParams = .init(
                messages: messages,
                configuration: configuration
            )
            configuration.logger.log(
                .info,
                message: "CDPMessageConsumer: Creating job params with \(messages.count) messages",
                error: nil
            )

            let encoder = JSONEncoder()
            let paramsEncoded = try encoder.encode(params)
            configuration.logger.log(
                .info,
                message: "CDPMessageConsumer: Encoded params, size: \(paramsEncoded.count) bytes",
                error: nil
            )

            guard
                let paramsJSON = try JSONSerialization.jsonObject(with: paramsEncoded)
                as? [String: Any]
            else {
                let error = NSError(
                    domain: "co.unstatic.revflow", code: 1000,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to serialize params to JSON"]
                )
                configuration.logger.log(
                    .error, message: "CDPMessageConsumer: Failed to serialize params to JSON",
                    error: error
                )
                throw error
            }
            
            configuration.logger.log(
                .info, message: "CDPMessageConsumer: Successfully serialized params to JSON",
                error: nil
            )

            configuration.logger.log(
                .info,
                message:
                "CDPMessageConsumer: Scheduling job with type: \(SendBatchingMessageJob.type)",
                error: nil
            )

            JobBuilder(type: SendBatchingMessageJob.type)
                .internet(atLeast: .cellular)
                .persist()
                .retry(limit: .unlimited)
                .service(quality: .background)
                .with(params: paramsJSON)
                .schedule(manager: queueManager)

            configuration.logger.log(
                .info,
                message:
                "CDPMessageConsumer: Job scheduled successfully for \(messages.count) messages",
                error: nil
            )
        }
    }

    private struct SendBatchingMessageJobParams: Codable {
        let messages: [Message]
        let configuration: Configuration
    }

    private struct SendBatchingMessageJobCreator: JobCreator {
        let logger: any GalvaLogger

        func create(type _: String, params: [String: Any]?) -> any Job {
            guard let params else {
                logger.log(
                    .warning,
                    message:
                    "SendBatchingMessageJobCreator: No params provided, returning EmptyJob",
                    error: nil
                )
                return EmptyJob(logger: logger)
            }

            do {
                let decoder = JSONDecoder()
                let paramsData = try JSONSerialization.data(withJSONObject: params)
                let params: SendBatchingMessageJobParams = try decoder.decode(
                    SendBatchingMessageJobParams.self, from: paramsData
                )
                logger.log(
                    .info,
                    message:
                    "SendBatchingMessageJobCreator: Successfully created job with \(params.messages.count) messages",
                    error: nil
                )
                return SendBatchingMessageJob(params: params)
            } catch {
                logger.log(
                    .error, message: "SendBatchingMessageJobCreator: Failed to decode params",
                    error: error
                )
                return EmptyJob(logger: logger)
            }
        }
    }

    private struct SendBatchingMessageJob: Job, Sendable {
        static let type = "SendBatchingMessageJob"

        let params: SendBatchingMessageJobParams
        
        nonisolated(unsafe)
        private let defaultDateFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            return formatter
        }()
        
        func run() async throws {
            
        }

        func onRun(callback: any JobResult) {
            params.configuration.logger.log(
                .info,
                message:
                "SendBatchingMessageJob: Starting to process \(params.messages.count) messages",
                error: nil
            )

            let batchEndpoint = params.configuration.serverUrl.appendingPathComponent("endUsers:batch:client")
            params.configuration.logger.log(
                .info,
                message:
                "SendBatchingMessageJob: Sending to endpoint: \(batchEndpoint.absoluteString)",
                error: nil
            )

            var urlRequest = URLRequest(url: batchEndpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue(params.configuration.apiKey, forHTTPHeaderField: "X-API-Key")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                let now = Date()
                params.configuration.logger.log(
                    .info,
                    message:
                    "SendBatchingMessageJob: Encoding \(params.messages.count) messages at \(defaultDateFormatter.string(from: now))",
                    error: nil
                )

                let messagesData = try jsonEncoder.encode(params.messages)
                let messagesJSONArray =
                    try (JSONSerialization.jsonObject(with: messagesData) as? [[String: Any]]) ?? []
                params.configuration.logger.log(
                    .info,
                    message: "SendBatchingMessageJob: Encoded \(messagesJSONArray.count) messages",
                    error: nil
                )

                let modifiedMessagesToSend = messagesJSONArray.map {
                    originalMessageJSON -> [String: Any] in
                    var modifiedMessage = originalMessageJSON
                    modifiedMessage["sentAt"] = defaultDateFormatter.string(from: now)
                    return modifiedMessage
                }
                params.configuration.logger.log(
                    .info,
                    message: "SendBatchingMessageJob: Added sentAt timestamp to all messages",
                    error: nil
                )

                let modifiedMessagesData = try JSONSerialization.data(withJSONObject: [
                    "batch": modifiedMessagesToSend,
                ])

                params.configuration.logger.log(
                    .info,
                    message:
                    "SendBatchingMessageJob: Request body size: \(modifiedMessagesData.count) bytes",
                    error: nil
                )
                urlRequest.httpBody = modifiedMessagesData

                params.configuration.logger.log(
                    .info, message: "SendBatchingMessageJob: Sending HTTP request", error: nil
                )

                let dataTask = URLSession.shared.dataTask(with: urlRequest) {
                    _, response, error in
                    if let httpResponse = response as? HTTPURLResponse {
                        params.configuration.logger.log(
                            .info,
                            message:
                            "SendBatchingMessageJob: Received response with status code: \(httpResponse.statusCode)",
                            error: nil
                        )

                        switch httpResponse.statusCode {
                        case 200 ..< 300:
                            params.configuration.logger.log(
                                .info,
                                message:
                                "SendBatchingMessageJob: Successfully sent \(params.messages.count) messages",
                                error: nil
                            )
                            callback.done(.success)
                        case 300...:
                            let error = NSError(
                                domain: "co.unstatic.revflow", code: httpResponse.statusCode,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "HTTP error: \(httpResponse.statusCode)",
                                ]
                            )
                            params.configuration.logger.log(
                                .error,
                                message:
                                "SendBatchingMessageJob: HTTP error \(httpResponse.statusCode)",
                                error: error
                            )
                            callback.done(.fail(error))
                        default:
                            let error = NSError(
                                domain: "co.unstatic.revflow", code: httpResponse.statusCode,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Unexpected status code: \(httpResponse.statusCode)",
                                ]
                            )
                            params.configuration.logger.log(
                                .error,
                                message:
                                "SendBatchingMessageJob: Unexpected status code \(httpResponse.statusCode)",
                                error: error
                            )
                            callback.done(.fail(error))
                        }
                    } else if let error {
                        params.configuration.logger.log(
                            .error, message: "SendBatchingMessageJob: Network error", error: error
                        )
                        callback.done(.fail(error))
                    } else {
                        let error = NSError(
                            domain: "co.unstatic.revflow", code: 1001,
                            userInfo: [NSLocalizedDescriptionKey: "No response received"]
                        )
                        params.configuration.logger.log(
                            .error, message: "SendBatchingMessageJob: No response received",
                            error: error
                        )
                        callback.done(.fail(error))
                    }
                }

                dataTask.resume()
            } catch {
                params.configuration.logger.log(
                    .error, message: "SendBatchingMessageJob: Failed to prepare request",
                    error: error
                )
                callback.done(.fail(error))
            }
        }

        private var jsonEncoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                let dateString = defaultDateFormatter.string(from: date)
                try container.encode(dateString)
            }

            return encoder
        }

        func onRetry(error: any Error) -> RetryConstraint {
            params.configuration.logger.log(
                .warning, message: "SendBatchingMessageJob: Retrying after error", error: error
            )
            return .exponential(initial: 5)
        }

        func onRemove(result: JobCompletion) {
            switch result {
            case .success:
                params.configuration.logger.log(
                    .info,
                    message:
                    "SendBatchingMessageJob: Job completed successfully and removed from queue",
                    error: nil
                )
            case .fail:
                params.configuration.logger.log(
                    .error, message: "SendBatchingMessageJob: Job failed and removed from queue",
                    error: nil
                )
            @unknown default:
                params.configuration.logger.log(
                    .warning, message: "SendBatchingMessageJob: Job removed with unknown result",
                    error: nil
                )
            }
        }
    }

    private struct EmptyJob: Job {
        let logger: any GalvaLogger
        
        func run() async throws {
            logger.log(.info, message: "EmptyJob: Running empty job (no-op)", error: nil)
        }

        func onRetry(error: any Error) -> RetryConstraint {
            logger.log(.warning, message: "EmptyJob: Retry requested but canceling", error: error)
            return .cancel
        }

        func onRun(callback: any JobResult) {
            logger.log(.info, message: "EmptyJob: Running empty job (no-op)", error: nil)
            callback.done(.success)
        }

        func onRemove(result: JobCompletion) {
            logger.log(
                .info, message: "EmptyJob: Removed from queue with result: \(result)", error: nil
            )
        }
    }
}
