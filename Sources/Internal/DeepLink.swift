//
//  DeepLink.swift
//  Galva
//
//  Parses Galva deep links into a strongly-typed route. Galva owns URL
//  schemes that begin with `gv` (e.g. `gvAbc123://…`, the per-app scheme
//  Galva assigns); every other scheme — `http`/`https`, the host app's own
//  custom schemes — is ignored so the app's existing links pass through
//  untouched.
//
//  Shape:
//
//      gv<scheme>://<action>?<query…>
//
//  `action` selects the route (e.g. `openCommunication`) and the query
//  carries that route's parameters (e.g. `communicationId`). Parsing is
//  fully static: a successful `parse(_:)` yields a `DeepLink` case whose
//  associated values are the route's required parameters, already validated
//  and extracted — handlers never reach back into a `[String: String]` bag
//  at runtime. A failure yields a `ParseError` describing exactly what was
//  wrong (unknown action, missing parameter, …) for diagnostics.
//
//  Routing is case-insensitive: URL hosts are case-normalized by Foundation,
//  so route names are matched with `caseInsensitiveCompare` against the
//  canonical camelCase constants in `Route`.
//
//  Routing lives in `SDKCore.handleOpenURL(_:)`; each route's handler lives
//  in its own `DeepLink+<Route>.swift` extension so new paths are cheap to
//  add (see `DeepLink+OpenCommunication.swift`).
//

import Foundation

/// A parsed Galva deep link. Each case is one route; its associated values
/// are that route's required, pre-validated parameters. Add a case here, a
/// `Route` constant, a `parse` branch, and a handler to support a new path.
enum DeepLink: Sendable, Hashable {

    /// `gv…://openCommunication?communicationId=<id>&<extra…>` — open the
    /// targeted communication's in-app message. `communicationId` is the
    /// required, non-empty route parameter; `parameters` is the full query
    /// dictionary (including `communicationId`), forwarded into the bundle as
    /// `window.galvaDeepLinkParams`.
    case openCommunication(communicationId: String, parameters: [String: String])

    /// Canonical route names (camelCase). The single source of truth for
    /// matching — `parse(_:)` compares the URL's action against these
    /// case-insensitively, and error diagnostics report these spellings.
    enum Route {
        static let openCommunication = "openCommunication"
    }

    /// The canonical (camelCase) action name for this link. Used for logging.
    var actionName: String {
        switch self {
        case .openCommunication: return Route.openCommunication
        }
    }

    /// Whether resolving this route needs an identified user. `true` for
    /// routes that resolve a user-targeted communication — such a link
    /// arriving before `identify()` is deferred until identity is available.
    /// A future route that works for anonymous users returns `false`.
    var requiresIdentity: Bool {
        switch self {
        case .openCommunication: return true
        }
    }

    /// Why a URL could not be parsed into a `DeepLink`. Carries only
    /// non-sensitive identifiers (scheme, action name, parameter *names*) —
    /// never parameter values or the full URL, which can carry tokens.
    enum ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        /// The scheme doesn't begin with `gv` — not a Galva link.
        case notGalvaScheme
        /// `URLComponents` couldn't decompose the URL.
        case malformedURL
        /// No action could be derived from the host or path.
        case missingAction
        /// The action isn't one Galva knows how to route.
        case unknownAction(String)
        /// The matched route is missing a required query parameter.
        case missingParameter(action: String, name: String)

        var description: String {
            switch self {
            case .notGalvaScheme:
                return "scheme is not a Galva scheme (must begin with \"gv\")"
            case .malformedURL:
                return "URL could not be decomposed into components"
            case .missingAction:
                return "no action in host or path (expected gv…://<action>?…)"
            case .unknownAction(let action):
                return "unknown action \"\(action)\""
            case .missingParameter(let action, let name):
                return "action \"\(action)\" is missing required parameter \"\(name)\""
            }
        }
    }

    /// `true` when `url` is a Galva deep link: its scheme begins with `gv`
    /// (case-insensitive). HTTP(S) and unrelated schemes return `false`.
    /// Pure + synchronous so `Galva.handleOpenURL(_:)` can decide whether to
    /// claim the URL without hopping actors. A `true` here does NOT guarantee
    /// `parse(_:)` succeeds — the action may still be unknown or incomplete.
    static func canHandle(_ url: URL) -> Bool {
        (url.scheme?.lowercased().hasPrefix("gv")) == true
    }

    /// Parse `url` into a typed `DeepLink`, or a `ParseError` explaining why
    /// it couldn't be routed. The action is taken from the URL host
    /// (`gv://openCommunication?…`) or, when the host is empty, the first
    /// path component (`gv:///openCommunication?…`), matched case-insensitively
    /// against `Route`.
    static func parse(_ url: URL) -> Result<DeepLink, ParseError> {
        guard canHandle(url) else { return .failure(.notGalvaScheme) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedURL)
        }

        let hostAction = components.host.flatMap { $0.isEmpty ? nil : $0 }
        let pathAction = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        guard let action = hostAction ?? pathAction, !action.isEmpty else {
            return .failure(.missingAction)
        }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { parameters[item.name] = value }
        }

        // Match against canonical camelCase route names, case-insensitively.
        if action.caseInsensitiveCompare(Route.openCommunication) == .orderedSame {
            guard let communicationId = parameters["communicationId"],
                  !communicationId.isEmpty else {
                return .failure(.missingParameter(
                    action: Route.openCommunication, name: "communicationId"
                ))
            }
            return .success(.openCommunication(
                communicationId: communicationId, parameters: parameters
            ))
        }

        return .failure(.unknownAction(action))
    }
}
