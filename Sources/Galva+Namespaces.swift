//
//  Galva+Namespaces.swift
//  Galva
//
//  `Galva.AppUser`, `Galva.AppEvents` and `Galva.InAppMessages`: the same
//  types as the top-level names, for an app that has its own type called
//  `AppUser`, `AppEvents` or `InAppMessages`. In such an app the plain name
//  means the app's type, and `Galva.AppUser` can't name the SDK's either —
//  `Galva` there is this enum, not the module — so these aliases are how it
//  reaches the SDK:
//
//      Galva.AppUser.identify(userId: "user_42")
//      Galva.AppEvents.track("onboarding_completed")
//
//  The underscored aliases are a hop the nested ones need: inside `Galva`,
//  `AppUser` would mean the nested alias itself. They're not for use.
//

import Foundation

public typealias _GalvaAppUser = AppUser
public typealias _GalvaAppEvents = AppEvents
public typealias _GalvaInAppMessages = InAppMessages

public extension Galva {

    /// The SDK's `AppUser`, for an app with its own type of that name.
    typealias AppUser = _GalvaAppUser

    /// The SDK's `AppEvents`, for an app with its own type of that name.
    typealias AppEvents = _GalvaAppEvents

    /// The SDK's `InAppMessages`, for an app with its own type of that name.
    typealias InAppMessages = _GalvaInAppMessages
}
