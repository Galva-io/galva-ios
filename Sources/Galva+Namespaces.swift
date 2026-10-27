//
//  Galva+Namespaces.swift
//  Galva
//
//  `AppUser`, `AppEvents` and `InAppMessages` are declared under `Galva`
//  (in Galva.swift); these top-level names are shorthands for them. An app
//  that has its own type called `AppUser`, `AppEvents` or `InAppMessages`
//  uses the qualified name, since there the plain name means the app's type:
//
//      Galva.AppUser.identify(userId: "user_42")
//      Galva.AppEvents.track("onboarding_completed")
//
//  Declaring the types under `Galva`, rather than aliasing top-level types
//  from inside it, means no helper alias shows up in autocompletion.
//

import Foundation

/// Shorthand for ``Galva/AppUser``.
public typealias AppUser = Galva.AppUser

/// Shorthand for ``Galva/AppEvents``.
public typealias AppEvents = Galva.AppEvents

/// Shorthand for ``Galva/InAppMessages``.
public typealias InAppMessages = Galva.InAppMessages
