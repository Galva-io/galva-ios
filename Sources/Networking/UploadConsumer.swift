//
//  UploadConsumer.swift
//  Galva
//
//  Bridges `MessageQueue` (throws-on-failure protocol) to `Uploader`
//  (returns-an-outcome actor).
//
//  Queue contract:
//    return  → batch deleted from storage
//    throw   → batch retained, retried after exponential backoff
//
//  Mapping:
//    .success   → return  (deleted)
//    .permanent → return  (LOGGED then deleted — won't help to retry)
//    .retryable → throw   (kept, retried)
//
//  Quarantine table for permanent failures is on the v2 roadmap. For now
//  we accept the rare data loss on 4xx in exchange for queue liveness.
//

import Foundation

struct UploadConsumer: MessageConsumer {
    let uploader: any MessageUploader
    let logger: any GalvaLogger

    func consume(messages: [Message]) async throws {
        let outcome = await uploader.upload(messages: messages)
        switch outcome {
        case .success:
            logger.info(.uploader, "uploaded batch", metadata: ["size": String(messages.count)])
        case .permanent(let error):
            logger.error(.uploader, "permanent failure — dropping batch",
                         metadata: ["size": String(messages.count)],
                         error: error)
            // Return normally so queue deletes them — retrying won't help.
        case .retryable(let error):
            logger.warning(.uploader, "retryable failure — will retry",
                           metadata: ["size": String(messages.count)],
                           error: error)
            throw error
        }
    }
}
