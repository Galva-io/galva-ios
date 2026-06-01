//
//  Galva+SwiftUI.swift
//  Galva
//
//  SwiftUI integration for in-app messaging. Two public modifiers:
//
//      • `.inAppMessageSheet($message)` — present the WebView sheet driven
//        by a `Binding<InAppMessages.Message?>`. The SDK resolves + downloads
//        the HTML bundle OFF-SCREEN first; the sheet is presented only when
//        the WebView is ready. A failed resolve / download is silent — no
//        sheet ever appears, no spinner flashes, the caller's binding is
//        cleared.
//
//      • `.autoDisplayInAppMessages()` — convenience that iterates
//        `InAppMessages.messages` internally and feeds each value into an
//        `.inAppMessageSheet`. Drop on any root view for zero-config
//        rendering.
//
//  Architecture: the modifier owns a coordinator (`@StateObject`) that
//  resolves the payload, downloads the bundle, and builds the `WKWebView` +
//  `NativeBridge` BEFORE the binding that drives `.sheet(item:)` is set.
//  Caller-facing `presentingMessage` tracks "what to show"; the coordinator's
//  `readyMessage` tracks "what's actually ready to render" — and only that
//  drives the sheet, so a failed bundle download never flashes a sheet open
//  and closed. The coordinator conforms to `InAppMessageHost` so the bridge
//  can call `reveal()` / `dismiss(reason:)` without caring whether it's
//  running under UIKit or SwiftUI.
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

    /// Present the supplied `InAppMessages.Message` as a sheet. The SDK
    /// resolves + downloads the HTML bundle off-screen first; the sheet is
    /// presented **only** when the WebView is ready. If resolve or bundle
    /// download fails, the binding is cleared silently and no sheet is shown
    /// — the user never sees a sheet flash open and close.
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

/// Bridges `Binding<InAppMessages.Message?>` to SwiftUI's `.sheet(item:)`
/// with a prepare-before-present pipeline. The caller-facing binding tracks
/// "what to show"; the coordinator's `readyMessage` tracks "what's actually
/// ready to render" — and only that drives the sheet, so a failed bundle
/// download never flashes a sheet.
private struct InAppMessageSheetModifier: ViewModifier {
    @Binding var presentingMessage: InAppMessages.Message?
    @StateObject private var coordinator = InAppMessagePresentationCoordinator()

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $coordinator.readyMessage,
                onDismiss: coordinator.handleSheetDismissed
            ) { _ in
                InAppMessageSheetView(coordinator: coordinator)
            }
            // Caller set a new message — kick off prepare off-screen. Silent
            // failure clears the caller's binding and presents nothing.
            .onChange(of: presentingMessage?.id) { _ in
                if let target = presentingMessage {
                    coordinator.prepare(target) {
                        // Resolve / bundle download failed — clear the
                        // caller's binding so it can try again later; no
                        // sheet is ever shown.
                        presentingMessage = nil
                    }
                } else {
                    coordinator.dismissCurrent()
                }
            }
            // Coordinator cleared its ready state (sheet dismissed by swipe
            // OR by the bundle's `galva.dismiss()`) — clear the caller's
            // binding too so the next message can flow in.
            .onChange(of: coordinator.readyMessage?.id) { newValue in
                if newValue == nil { presentingMessage = nil }
            }
    }
}

/// `for await` consumer of `InAppMessages.messages` + automatic
/// `.inAppMessageSheet` plumbing. Latest message wins — `inAppMessageSheet`
/// handles the prepare-before-present pipeline for each one.
private struct AutoDisplayInAppMessagesModifier: ViewModifier {
    @State private var presenting: InAppMessages.Message?

    func body(content: Content) -> some View {
        content
            .inAppMessageSheet($presenting)
            .task {
                for await message in InAppMessages.messages {
                    presenting = message
                }
            }
    }
}

// MARK: - Sheet content view

/// Mounts the already-prepared WebView inside the sheet and respects the
/// bundle's `galva.ready()` flag for first-paint timing. No prepare logic
/// lives here — by the time this view appears, the coordinator already
/// holds a ready WebView, so there's no spinner to show.
@MainActor
private struct InAppMessageSheetView: View {
    @ObservedObject var coordinator: InAppMessagePresentationCoordinator

    var body: some View {
        ZStack {
            if let webView = coordinator.webView {
                InAppMessageWebViewRepresentable(webView: webView)
                    .opacity(coordinator.isRevealed ? 1 : 0)
            }
            // No spinner: the sheet is only presented once the WebView is
            // ready. The brief gap between `present` and the bundle's first
            // paint is hidden by the bundle's own `ready()` anti-flash gate
            // (drives `.opacity` above).
        }
        .ignoresSafeArea()
        .applySheetChrome()
    }
}

// MARK: - Coordinator (ObservableObject + InAppMessageHost)

/// Owns the prepare-before-present pipeline + bridge callbacks. Lives on
/// the modifier as a `@StateObject` so its lifetime matches the surrounding
/// view, not the (intermittently presented) sheet content.
@MainActor
private final class InAppMessagePresentationCoordinator: ObservableObject {

    /// Drives `.sheet(item:)`. Non-nil only once the WebView is prepared
    /// (resolve + bundle download complete) — so the sheet never appears
    /// while loading and never flashes on failure.
    @Published var readyMessage: InAppMessages.Message?

    /// Flipped by the bundle's `galva.ready()`. Drives the WebView's
    /// `.opacity` so the bundle controls first-paint timing.
    @Published private(set) var isRevealed: Bool = false

    /// Prepared WebView. Retained through the sheet's presentation; cleared
    /// on real teardown (not on a "replace" mid-show, where a newer message
    /// hot-swaps the prepared bundle).
    private(set) var webView: WKWebView?

    /// Bridge held strongly — `WKUserContentController.add(_:name:)` only
    /// keeps a weak ref, so the channel dies the moment we drop the bridge.
    private var bridge: NativeBridge?

    /// In-flight prepare. Cancelled if a newer message arrives so we never
    /// race two preparations against each other.
    private var prepareTask: Task<Void, Never>?

    /// Resolve + bundle-download `message` off-screen. On success, publishes
    /// `readyMessage` (which presents the sheet). On failure, invokes
    /// `onFail` — the sheet is never presented and no UI is shown.
    ///
    /// Idempotent for the same message id. A new id while a previous sheet
    /// is on screen prepares the new bundle without tearing the old one
    /// down; the swap happens atomically when the new prepare succeeds, so
    /// the user never sees a gap. Failures of a *new* prepare leave the
    /// current sheet intact (the failure is silent and scoped to the new
    /// message).
    func prepare(_ message: InAppMessages.Message, onFail: @escaping () -> Void) {
        if readyMessage?.id == message.id { return }
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            guard let host = self else { return }
            do {
                let prepared = try await SDKCore.shared.prepareInAppMessage(message, host: host)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Atomically swap to the new prepared bundle. SwiftUI's
                    // `sheet(item:)` handles the visual transition because
                    // the item identity changes — no manual dismiss/present
                    // dance. The new bundle hasn't called `ready()` yet, so
                    // reset the reveal flag.
                    self.webView = prepared.webView
                    self.bridge = prepared.bridge
                    self.isRevealed = false
                    self.readyMessage = message
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Drop any prepared state for this message (there shouldn't
                    // be any since we failed before the assignment), schedule
                    // GalvaActor cleanup, and let the caller know the binding
                    // can be cleared. No sheet was ever presented.
                    self.tearDown()
                    onFail()
                }
            }
        }
    }

    /// Caller cleared its binding before any sheet went up — drop the
    /// in-flight prepare. Distinct from `handleSheetDismissed`, which runs
    /// only AFTER a sheet was presented and is now gone.
    func dismissCurrent() {
        tearDown()
    }

    /// SwiftUI's `.sheet(onDismiss:)` callback. Runs when the sheet that WAS
    /// on screen finishes dismissing — by user swipe OR by the bundle's
    /// `galva.dismiss()`. Guarded so a mid-show *replace* (readyMessage
    /// already swapped to a new value) doesn't tear down the replacement.
    func handleSheetDismissed() {
        guard readyMessage == nil else {
            // A newer message took over: the old sheet's `onDismiss` fired
            // after `readyMessage` was already pointed at the replacement.
            // The new sheet keeps the prepared WebView; don't touch it.
            return
        }
        tearDown()
    }

    /// Idempotent state reset. Cancels any in-flight prepare, drops the
    /// WebView + bridge + reveal flag, and asks the SDK to forget the
    /// active message id on the GalvaActor.
    private func tearDown() {
        prepareTask?.cancel()
        prepareTask = nil
        readyMessage = nil
        webView = nil
        bridge = nil
        isRevealed = false
        Task { @GalvaActor in
            await SDKCore.shared.clearActiveMessage()
        }
    }
}

extension InAppMessagePresentationCoordinator: InAppMessageHost {
    var safeAreaInsets: UIEdgeInsets {
        webView?.window?.safeAreaInsets ?? .zero
    }

    func reveal() {
        isRevealed = true
    }

    func dismiss(reason: String?) {
        _ = reason
        // Clearing readyMessage tells SwiftUI to dismiss the sheet, which
        // fires `.sheet(onDismiss: handleSheetDismissed)` — that's where
        // GalvaActor cleanup runs. The modifier's `onChange(of: readyMessage)`
        // then clears the caller's binding.
        readyMessage = nil
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
