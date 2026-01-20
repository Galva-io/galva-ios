//
//  Logger.swift
//  Galva
//
//  Created by Peter Vu on 12/9/25.
//

enum GalvaLoggerLogLevel: Int {
    /// Basic information about scheduling, running job and completion
    case info = 1
    /// Important but non fatal information
    case warning = 2
    /// Something went wrong during the scheduling or the execution
    case error = 3

    var name: String {
        switch self {
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }
}

protocol GalvaLogger: Sendable {
    func log(_ level: GalvaLoggerLogLevel, message: String, error: Error?)
}

class GalvaConsoleLogger: GalvaLogger, @unchecked Sendable {
    func log(_ level: GalvaLoggerLogLevel, message: String, error: (any Error)?) {
        if let error {
            let errorString = String(describing: error)
            debugPrint("[\(level.name)] \(message). \(errorString)")
        } else {
            debugPrint("[\(level.name)] \(message)")
        }
    }
}
