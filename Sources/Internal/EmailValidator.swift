//
//  EmailValidator.swift
//  Galva
//
//  Client-side email validation, applied before an address is sent to the
//  server so an invalid email never reaches ingestion. Mirrors the backend's
//  ingestion rules (see the Email validation section of the Galva docs):
//
//    1. Basic RFC 5322 format (conservative character set).
//    2. Exactly one `@`, with non-empty local and domain parts.
//    3. The domain contains at least one `.` (dot) forming non-empty labels.
//    4. No whitespace anywhere.
//
//  Deliberately conservative + dependency-free (no regex engine): the goal is
//  to catch obviously-malformed input early, not to be a full RFC 5322 parser.
//  The server remains the source of truth and re-validates on ingestion.
//

import Foundation

enum EmailValidator {

    /// Characters permitted in the local part (before `@`). RFC 5322 dot-atom
    /// plus the common specials — alphanumerics and `.!#$%&'*+/=?^_`{|}~-`.
    private static let localAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: ".!#$%&'*+/=?^_`{|}~-")
        return set
    }()

    /// Characters permitted in the domain part (after `@`): alphanumerics,
    /// hyphen, and dot (label separator).
    private static let domainAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-.")
        return set
    }()

    /// `true` when `email` passes Galva's basic ingestion rules. Pure +
    /// synchronous — safe to call from anywhere.
    static func isValid(_ email: String) -> Bool {
        guard !email.isEmpty else { return false }

        // Rule 4: reject any whitespace (space, tab, newline, …).
        if email.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }

        // Rule 2: exactly one "@" splitting into non-empty local + domain.
        let parts = email.components(separatedBy: "@")
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }

        // Rule 3: the domain has at least one dot, and every label between
        // dots is non-empty (rejects "a@b.", "a@.b", "a@b..c").
        guard domain.contains(".") else { return false }
        let labels = domain.components(separatedBy: ".")
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }

        // Rule 1: basic RFC 5322 character sanity for local + domain.
        guard isSubset(local, of: localAllowed),
              isSubset(domain, of: domainAllowed) else { return false }

        return true
    }

    private static func isSubset(_ string: String, of set: CharacterSet) -> Bool {
        string.unicodeScalars.allSatisfy { set.contains($0) }
    }
}
