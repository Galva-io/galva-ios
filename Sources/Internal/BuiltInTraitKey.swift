//
//  BuiltInTraitKey.swift
//  Galva
//
//  Single source of truth for the `$gv_*` wire keys Galva's backend
//  recognizes as built-in user traits on `Message.identify(traits:)`.
//
//  Anywhere the SDK reads or writes one of these keys — both the typed
//  `AppUser.set(.email, …)` setters in Galva.swift and the internal device-
//  trait seeding inside `SDKCore.identify` — must reference this enum
//  rather than spell the literal string. Adding a new built-in trait is
//  a one-line addition here plus a typed setter in `AppUserTraits`.
//

import Foundation

/// Wire keys for Galva's built-in user traits. Caseless namespace so the
/// keys participate in autocomplete (`BuiltInTraitKey.email`) without
/// dragging in `CaseIterable`/`RawRepresentable` machinery the dictionary
/// call sites don't need.
enum BuiltInTraitKey {

    /// `$gv_email` — email address. Validated client-side via
    /// `EmailValidator.isValid(_:)` before send.
    static let email = "$gv_email"

    /// `$gv_fullName` — display name.
    static let fullName = "$gv_fullName"

    /// `$gv_firstName` — given name.
    static let firstName = "$gv_firstName"

    /// `$gv_lastName` — family name.
    static let lastName = "$gv_lastName"

    /// `$gv_country` — ISO 3166 alpha-2 country code.
    static let country = "$gv_country"

    /// `$gv_timezone` — IANA timezone identifier. Auto-attached on every
    /// identify from `TimeZone.current.identifier`.
    static let timezone = "$gv_timezone"

    /// `$gv_languageCode` — BCP 47 language tag. Auto-attached on every
    /// identify from `Locale.current.languageCode`.
    static let languageCode = "$gv_languageCode"

    /// `$gv_totalLifetimeValue` — running LTV in the app's chosen currency.
    static let totalLifetimeValue = "$gv_totalLifetimeValue"

    /// `$gv_appAccountToken` — StoreKit 2 `appAccountToken` UUID
    /// (lower-cased, stringified). Attached by `identify(appAccountToken:)`.
    static let appAccountToken = "$gv_appAccountToken"

    /// `$gv_asa_` — prefix for Apple Search Ads attribution fields, e.g.
    /// `$gv_asa_campaignId`, `$gv_asa_keywordId`. Resolved once per install
    /// from AdServices and re-attached to every identify. See
    /// `AppleSearchAdsAttribution`.
    static let appleSearchAdsPrefix = "$gv_asa_"
}
