//
//  InitializationWireModels.swift
//  Galva
//
//  Wire-format models for POST /sdk/initialize.
//
//  Request:
//      { "bridgeProtocolVersion": "1.0" }
//
//  Response:
//      {
//        "meta": { "requestId": "...", "timestamp": "...", "total": N, "nextCursor": "..." },
//        "data": {
//          "webviewVersions": ["1.0.0", ...],
//          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
//          "products": [ … ]
//        }
//      }
//
//  These types are INTERNAL — integrators reach the resolved data through
//  `Galva.shared.initializationData()` (or similar) once that lands. Keeping
//  them off the public surface lets the server evolve fields freely without
//  bumping the SDK's public API.
//

import Foundation

// MARK: - Request

struct InitializeRequest: Sendable, Codable, Hashable {
    let bridgeProtocolVersion: String
}

// MARK: - Response envelope (meta + data)

struct InitializeResponse: Sendable, Codable, Hashable {
    let meta: Meta?
    let data: InitializationData

    struct Meta: Sendable, Codable, Hashable {
        let requestId: String?
        let timestamp: Date?
        let total: Double?
        let nextCursor: String?
    }
}

// MARK: - Initialization data (the useful payload)

struct InitializationData: Sendable, Codable, Hashable {
    let webviewVersions: [String]
    let batchCollection: BatchCollection
    let products: [Product]

    struct BatchCollection: Sendable, Codable, Hashable {
        /// Number of pending messages that forces an immediate flush.
        let flushSize: Double
        /// Time-based flush interval, in milliseconds.
        let flushIntervalMs: Double
    }

    // MARK: Product

    struct Product: Sendable, Codable, Hashable {
        let id: String
        let name: String
        let type: ProductType?
        let status: ProductStatus?
        let platformSpecs: PlatformSpecs?
        let plans: [Plan]

        enum ProductType: String, Sendable, Codable, Hashable {
            case consumable
            case nonConsumable = "non-consumable"
            case renewable
        }

        enum ProductStatus: String, Sendable, Codable, Hashable {
            case active
            case archived
            case deleted
        }

        struct PlatformSpecs: Sendable, Codable, Hashable {
            let appstore: [String: AnyJSONValue]?
            let playstore: [String: AnyJSONValue]?
            let paddle: [String: AnyJSONValue]?
        }
    }

    // MARK: Plan

    struct Plan: Sendable, Codable, Hashable {
        let id: String
        let status: PlanStatus
        let name: String
        let level: Double
        let period: Period
        let platformSpecs: PlanPlatformSpecs

        enum PlanStatus: String, Sendable, Codable, Hashable {
            case active
            case archived
            case draft
            case disabled
            case deleted
        }

        struct Period: Sendable, Codable, Hashable {
            let unit: Unit
            let value: Double
            let humanizedDuration: String

            enum Unit: String, Sendable, Codable, Hashable {
                case day, week, month, year, lifetime
            }
        }

        struct PlanPlatformSpecs: Sendable, Codable, Hashable {
            let appstore: AppStore?
            let playstore: PlayStore?
            let paddle: Paddle?

            struct AppStore: Sendable, Codable, Hashable {
                let subscriptions: [Subscription]

                struct Subscription: Sendable, Codable, Hashable {
                    let id: String?
                    let productId: String?
                }
            }

            struct PlayStore: Sendable, Codable, Hashable {
                let basePlans: [BasePlan]

                struct BasePlan: Sendable, Codable, Hashable {
                    let basePlanId: String?
                    let productId: String?
                }
            }

            struct Paddle: Sendable, Codable, Hashable {
                let basePlans: [BasePlan]

                struct BasePlan: Sendable, Codable, Hashable {
                    let priceId: String?
                    let productId: String?
                }
            }
        }
    }
}
