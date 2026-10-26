//
//  WorkflowTypeTests.swift
//  GalvaTests
//
//  `InAppMessages.WorkflowType` is an extensible struct: known types keep
//  their server values, and a type this SDK version doesn't know still
//  arrives and falls to a switch's `default`.
//

import Foundation
@testable import Galva
import XCTest

final class WorkflowTypeTests: XCTestCase {

    func test_knownTypes_keepTheirServerValues() {
        XCTAssertEqual(InAppMessages.WorkflowType.trialRescue.rawValue, "trial-rescue")
        XCTAssertEqual(InAppMessages.WorkflowType.cancellationRecovery.rawValue, "cancellation-recovery")
        XCTAssertEqual(InAppMessages.WorkflowType.winback.rawValue, "winback")
        XCTAssertEqual(InAppMessages.WorkflowType.paymentRecovery.rawValue, "payment-recovery")
        XCTAssertEqual(InAppMessages.WorkflowType.allCases.count, 4)
    }

    func test_serverValue_equalsKnownType() {
        XCTAssertEqual(InAppMessages.WorkflowType(rawValue: "trial-rescue"), .trialRescue)
        XCTAssertNotEqual(InAppMessages.WorkflowType(rawValue: "price-increase"), .trialRescue)
    }

    func test_switchWithDefault_handlesKnownUnknownAndMissingTypes() {
        // The pattern the public docs show.
        func theme(for type: InAppMessages.WorkflowType?) -> String {
            switch type {
            case .trialRescue?:          return "trial"
            case .cancellationRecovery?: return "save"
            default:                     return "default"
            }
        }

        XCTAssertEqual(theme(for: .trialRescue), "trial")
        XCTAssertEqual(theme(for: .cancellationRecovery), "save")
        XCTAssertEqual(theme(for: InAppMessages.WorkflowType(rawValue: "price-increase")), "default")
        XCTAssertEqual(theme(for: nil), "default")
    }
}
