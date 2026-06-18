//
//  EmailValidatorTests.swift
//  GalvaTests
//
//  Covers the client-side email validation rules applied before an address is
//  sent to the server (see the Email validation section of the Galva docs):
//    1. Basic RFC 5322 format.
//    2. Exactly one `@` with non-empty local + domain.
//    3. Domain contains at least one dot (with non-empty labels).
//    4. No whitespace.
//

import Foundation
@testable import Galva
import XCTest

final class EmailValidatorTests: XCTestCase {

    // MARK: - Valid

    func test_acceptsTypicalAddresses() {
        let valid = [
            "peter@example.com",
            "a@b.co",
            "first.last@sub.example.co.uk",
            "user+tag@example.com",
            "user_name@example.io",
            "p3ter@ex4mple.com",
            "name!#$%&'*+/=?^_`{|}~-@example.com",  // RFC 5322 specials in local
        ]
        for email in valid {
            XCTAssertTrue(EmailValidator.isValid(email), "should accept \(email)")
        }
    }

    // MARK: - Rule 2: exactly one @, non-empty local + domain

    func test_rejectsMissingAtSymbol() {
        XCTAssertFalse(EmailValidator.isValid("peterexample.com"))
    }

    func test_rejectsMultipleAtSymbols() {
        XCTAssertFalse(EmailValidator.isValid("peter@@example.com"))
        XCTAssertFalse(EmailValidator.isValid("peter@a@example.com"))
    }

    func test_rejectsEmptyLocalPart() {
        XCTAssertFalse(EmailValidator.isValid("@example.com"))
    }

    func test_rejectsEmptyDomainPart() {
        XCTAssertFalse(EmailValidator.isValid("peter@"))
    }

    // MARK: - Rule 3: domain must contain a dot with non-empty labels

    func test_rejectsDomainWithoutDot() {
        XCTAssertFalse(EmailValidator.isValid("peter@example"))
        XCTAssertFalse(EmailValidator.isValid("peter@localhost"))
    }

    func test_rejectsLeadingTrailingOrDoubleDotsInDomain() {
        XCTAssertFalse(EmailValidator.isValid("peter@.example.com"))  // leading
        XCTAssertFalse(EmailValidator.isValid("peter@example.com."))  // trailing
        XCTAssertFalse(EmailValidator.isValid("peter@example..com"))  // double
    }

    // MARK: - Rule 4: no whitespace

    func test_rejectsWhitespace() {
        XCTAssertFalse(EmailValidator.isValid("peter @example.com"))
        XCTAssertFalse(EmailValidator.isValid("peter@ example.com"))
        XCTAssertFalse(EmailValidator.isValid("peter@example.com "))
        XCTAssertFalse(EmailValidator.isValid(" peter@example.com"))
        XCTAssertFalse(EmailValidator.isValid("peter@exa\tmple.com"))
        XCTAssertFalse(EmailValidator.isValid("peter@exa\nmple.com"))
    }

    // MARK: - Rule 1: basic charset / misc

    func test_rejectsEmpty() {
        XCTAssertFalse(EmailValidator.isValid(""))
    }

    func test_rejectsDisallowedCharacters() {
        XCTAssertFalse(EmailValidator.isValid("peter@exa,mple.com"))   // comma in domain
        XCTAssertFalse(EmailValidator.isValid("peter@exam(ple).com"))  // parens
        XCTAssertFalse(EmailValidator.isValid("pe ter@example.com"))   // (also whitespace)
    }

}
