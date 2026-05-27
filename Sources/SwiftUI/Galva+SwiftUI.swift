//
//  Galva+SwiftUI.swift
//  Galva
//
//  SwiftUI integration for in-app messaging. Two public modifiers:
//
//      • `.inAppMessageSheet($message)` — present the WebView sheet
//        driven by a `Binding<InAppMessages.Message?>`. Mirrors SwiftUI's
//        own `.sheet(item:)` semantics — non-nil presents, nil dismisses,
//        and the SDK clears the binding when the bundle calls
//        `galva.dismiss()` or the user swipes the sheet down.
//
//      • `.autoDisplayInAppMessages()` — convenience that iterates
//        `InAppMessages.messages` internally and feeds each value into
//        an `.inAppMessageSheet`. Drop on any root view to enable
//        zero-config rendering.
//
//  Architecture: SwiftUI owns the sheet presentation lifecycle. The
//  `InAppMessageSheetCoordinator` (`ObservableObject` + `InAppMessageHost`)
//  resolves the payload, downloads the bundle, and builds the
//  `WKWebView` + `NativeBridge`. The WebView is mounted via
//  `UIViewRepresentable`. The bundle's `galva.ready()` flips the
//  coordinator's `@Published isRevealed` flag; `galva.dismiss()` calls
//  back into the binding-clearing closure passed at init time.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)

// MARK: - Public View modifiers

public extension View {

    /// Present the supplied `InAppMessages.Message` as a sheet. When
    /// `message` becomes non-nil the sheet appears; when the user
    /// dismisses (swipe-down or bundle-driven `galva.dismiss()`) the SDK
    /// clears the binding, which dismisses the sheet.
    ///
    /// Use this when you want full control over which messages render —
    /// e.g. queueing, filtering by workflow, gating on app state.
    ///
    /// ```swift
    /// @State var presenting: InAppMessages.Message?
    ///
    /// var body: some View {
    ///     ContentView()
    ///         .task {
    ///             for await message in InAppMessages.messages {
    ///                 presenting = message
    ///             }
    ///         }
    ///         .inAppMessageSheet($presenting)
    /// }
    /// ```
    func inAppMessageSheet(
        _ message: Binding<InAppMessages.Message?>
    ) -> some View {
        modifier(InAppMessageSheetModifier(presentingMessage: message))
    }

    /// Auto-iterate `InAppMessages.messages` and present each new value
    /// as a sheet. Equivalent to writing the `for await` loop +
    /// `.inAppMessageSheet($state)` by hand — most apps that just want
    /// "render in-app messages as the SDK delivers them" can drop this
    /// on any root view.
    ///
    /// ```swift
    /// var body: some View {
    ///     ContentView()
    ///         .autoDisplayInAppMessages()
    /// }
    /// ```
    func autoDisplayInAppMessages() -> some View {
        modifier(AutoDisplayInAppMessagesModifier())
    }
}

// MARK: - Modifier implementations

/// Bridges `Binding<InAppMessages.Message?>` to SwiftUI's
/// `.sheet(item:)`. The sheet's content view (`InAppMessageSheetView`)
/// owns the coordinator that drives resolve / bundle download / WebView
/// rendering.
private struct InAppMessageSheetModifier: ViewModifier {
    @Binding var presentingMessage: InAppMessages.Message?

    func body(content: Content) -> some View {
        content.sheet(item: $presentingMessage) { message in
            InAppMessageSheetView(
                message: message,
                onDismiss: { presentingMessage = nil }
            )
        }
    }
}

/// `for await` consumer of `InAppMessages.messages` + automatic
/// `.inAppMessageSheet` plumbing. The consumer task lives for the
/// lifetime of the view (cancelled on disappear by `.task`).
private struct AutoDisplayInAppMessagesModifier: ViewModifier {
    @State private var presenting: InAppMessages.Message?

    func body(content: Content) -> some View {
        content
            .inAppMessageSheet($presenting)
            .task {
                for await message in InAppMessages.messages {
                    // Latest message wins — if the SDK delivers a new
                    // one while a previous sheet is still on screen,
                    // SwiftUI's sheet(item:) dismisses the old and
                    // presents the new (item identity changes).
                    presenting = message
                }
            }
    }
}

// MARK: - Sheet content view

/// SwiftUI view that lives inside `.sheet(item:)`. Owns the
/// `InAppMessageSheetCoordinator` via `@StateObject` so its lifecycle
/// is tied to the sheet's appearance.
@MainActor
private struct InAppMessageSheetView: View {
    let message: InAppMessages.Message
    let onDismiss: () -> Void

    @StateObject private var coordinator: InAppMessageSheetCoordinator

    init(message: InAppMessages.Message, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
        // `@StateObject` requires the wrappedValue to be set in init.
        _coordinator = StateObject(
            wrappedValue: InAppMessageSheetCoordinator(
                message: message,
                onDismiss: onDismiss
            )
        )
    }

    var body: some View {
        ZStack {
            // Loading state — shown until the bundle finishes its first
            // paint and the bridge invokes `galva.ready()`. We don't
            // gate on resolve / bundle-download completion separately
            // because the WebView paints over the spinner once the
            // bundle is mounted; the spinner is mostly for the case
            // where the bundle is still being downloaded from the CDN.
            if !coordinator.isRevealed {
                ProgressView()
                    .controlSize(.large)
            }

            // WebView — present as soon as it's been constructed. Stays
            // invisible (`.opacity(0)`) until `isRevealed` flips, so the
            // bundle controls its own first-paint timing.
            if let webView = coordinator.preparedWebView {
                InAppMessageWebViewRepresentable(webView: webView)
                    .opacity(coordinator.isRevealed ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .task {
            await coordinator.prepare()
        }
        .onChange(of: coordinator.failed) { failed in
            // Resolve / bundle download failed — close the sheet so the
            // user isn't staring at an empty spinner forever.
            if failed { onDismiss() }
        }
        .onDisappear {
            coordinator.cleanup()
        }
        .applySheetChrome()
    }
}

// MARK: - Coordinator (ObservableObject + InAppMessageHost)

/// Drives the SwiftUI sheet's lifecycle. Resolves the payload, downloads
/// the bundle, builds the `WKWebView` + `NativeBridge`, and wires bridge
/// callbacks to SwiftUI state. Conforms to `InAppMessageHost` so the
/// bridge can call `reveal()` / `dismiss(reason:)` without caring whether
/// it's running under UIKit or SwiftUI.
@MainActor
private final class InAppMessageSheetCoordinator: ObservableObject {

    let message: InAppMessages.Message
    private let onDismiss: () -> Void

    /// WebView mounted in the sheet via `UIViewRepresentable`. `nil`
    /// while `prepare()` is still resolving + downloading.
    @Published private(set) var preparedWebView: WKWebView?

    /// Flips to `true` when the bundle calls `galva.ready()` — drives the
    /// WebView's `.opacity` so the bundle controls first-paint timing.
    @Published private(set) var isRevealed: Bool = false

    /// Set when resolve or bundle download fails. The view's `onChange`
    /// fires `onDismiss` to close the sheet cleanly.
    @Published private(set) var failed: Bool = false

    /// Bridge held strongly for the lifetime of the sheet —
    /// `WKUserContentController.add(_:name:)` only takes a weak ref, so
    /// the bridge dies the moment we drop it otherwise.
    private var bridge: NativeBridge?

    /// One-shot guard so concurrent `prepare()` invocations (re-entrancy
    /// from `.task` re-firing on view identity changes) don't double-
    /// resolve the same message.
    private var didPrepare: Bool = false

    init(
        message: InAppMessages.Message,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.onDismiss = onDismiss
    }

    /// Run the full SDK preparation flow. Idempotent — repeated calls
    /// short-circuit once the first run completes.
    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        do {
            let prepared = try await SDKCore.shared.prepareInAppMessage(
                message,
                host: self
            )
            self.preparedWebView = prepared.webView
            self.bridge = prepared.bridge
        } catch {
            self.failed = true
        }
    }

    /// Called from the view's `onDisappear`. Clears the active-message
    /// id on the GalvaActor so the bridge doesn't serve stale
    /// `getMessageData()` / `requestPurchase` calls. Idempotent.
    func cleanup() {
        Task { @GalvaActor in
            await SDKCore.shared.clearActiveMessage()
        }
    }
}

extension InAppMessageSheetCoordinator: InAppMessageHost {
    var webView: WKWebView? { preparedWebView }

    /// Insets reflect the *presented sheet's* safe area, which is what
    /// the bundle needs to pad against (sheet grabber, dynamic island,
    /// home indicator). We pull from the WebView's window when mounted;
    /// before mount, return `.zero` — the bundle's first
    /// `getPageContext()` call only fires after the WebView is in the
    /// view hierarchy.
    var safeAreaInsets: UIEdgeInsets {
        preparedWebView?.window?.safeAreaInsets ?? .zero
    }

    func reveal() {
        isRevealed = true
    }

    func dismiss(reason: String?) {
        // Clear the binding — SwiftUI dismisses the sheet, which
        // tears down the view + coordinator. `reason` is forwarded by
        // the bundle's analytics POST (we don't need it native-side).
        _ = reason
        onDismiss()
    }
}

// MARK: - UIViewRepresentable wrapper

/// Mounts the existing `WKWebView` inside the SwiftUI hierarchy.
/// `updateUIView` is a no-op because the WebView's content is driven
/// entirely by the bridge / bundle / pre-loaded HTML file — there's no
/// SwiftUI state to reflect back.
private struct InAppMessageWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { /* no-op */ }
}

// MARK: - Sheet chrome (iOS 16+ presentationDetents + drag indicator)

private extension View {
    /// Apply the visual chrome the UIKit path configures explicitly on
    /// `InAppMessageViewController`'s `sheetPresentationController` —
    /// a single large detent + visible grabber. SwiftUI 16+ has direct
    /// API for both; on iOS 15 we fall through to the platform default
    /// (full-screen-style sheet on iPhone), which is acceptable.
    @ViewBuilder
    func applySheetChrome() -> some View {
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}

#endif // canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
