import SwiftUI
import WebKit

/// Store sign-in. Steam signs in natively (`SteamLoginView`); GOG and Epic use an embedded sign-in page that watches for
/// the store's redirect and hands back the authorization code, so nothing has to be copied or pasted.
struct StorefrontLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: Storefront
    let onSignedIn: () -> Void

    @State private var working = false
    @State private var errorMessage: String?
    @State private var showBrowserFallback = false
    @State private var pastedCode = ""

    var body: some View {
        NavigationStack {
            Group {
                switch store {
                case .steam:
                    SteamLoginView {
                        onSignedIn()
                        dismiss()
                    }
                case .gog:
                    webSignIn(startURL: GOGClient.loginURL)
                case .epic:
                    webSignIn(startURL: EpicClient.loginURL)
                }
            }
            .navigationTitle("Sign in to \(store.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: store == .steam ? 520 : 640)
    }

    private func webSignIn(startURL: URL) -> some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            ZStack {
                StorefrontLoginWebView(store: store, startURL: startURL) { code in
                    Task { await finish(code) }
                }
                if working {
                    ProgressView("Signing in…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Divider()
            browserFallback(startURL: startURL)
                .padding(10)
        }
    }

    /// Some providers (Google sign-in, Epic's page at times) refuse or stall inside an embedded view;
    /// signing in in the browser and pasting the result still works.
    private func browserFallback(startURL: URL) -> some View {
        DisclosureGroup("Trouble signing in?", isExpanded: $showBrowserFallback) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store == .gog
                    ? "Open GOG sign-in in your browser and sign in (Google works there). When the page says you're signed in, copy the whole address from the address bar and paste it here."
                    : "Open Epic sign-in in your browser, sign in, and paste the authorizationCode value from the page that appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open in Browser") { NSWorkspace.shared.open(startURL) }
                        .buttonStyle(.bordered)
                    TextField(store == .gog ? "Address or code" : "authorizationCode", text: $pastedCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Use Code") {
                        let code = store == .gog
                            ? GOGClient.authorizationCode(fromPastedText: pastedCode)
                            : EpicClient.authorizationCode(fromPageText: pastedCode)
                        guard let code else {
                            errorMessage = store == .gog
                                ? "That address has no GOG sign-in code. Copy it from the page that appears after signing in."
                                : "That does not look like an Epic authorization code."
                            return
                        }
                        Task { await finish(code) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    @MainActor
    private func finish(_ code: String) async {
        working = true
        defer { working = false }
        do {
            switch store {
            case .steam:
                return
            case .gog:
                try await GOGClient.signIn(code: code)
            case .epic:
                try await EpicClient.signIn(code: code)
            }
            onSignedIn()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StorefrontLoginWebView: NSViewRepresentable {
    let store: Storefront
    let startURL: URL
    let onResult: (String) -> Void

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onResult: onResult) }

    /// A container so sign-in pop-ups (Google, Steam, Discord, Xbox buttons) can be stacked over the main page.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = context.coordinator.makeWebView(configuration: configuration, in: container)
        webView.load(URLRequest(url: startURL))
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let store: Storefront
        let onResult: (String) -> Void
        private var delivered = false
        private weak var container: NSView?

        @discardableResult
        func makeWebView(configuration: WKWebViewConfiguration, in container: NSView) -> WKWebView {
            self.container = container
            let webView = WKWebView(frame: container.bounds, configuration: configuration)
            webView.autoresizingMask = [.width, .height]
            webView.customUserAgent = StorefrontLoginWebView.userAgent
            webView.navigationDelegate = self
            webView.uiDelegate = self
            container.addSubview(webView)
            return webView
        }

        /// WebKit requires the pop-up to use the configuration it passes in, which keeps `window.opener` working.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let container else { return nil }
            return makeWebView(configuration: configuration, in: container)
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard webView !== container?.subviews.first else { return }
            webView.removeFromSuperview()
        }

        init(store: Storefront, onResult: @escaping (String) -> Void) {
            self.store = store
            self.onResult = onResult
        }

        private func deliver(_ value: String) {
            guard !delivered else { return }
            delivered = true
            onResult(value)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if store == .gog, let url = navigationAction.request.url, let code = GOGClient.authorizationCode(fromRedirect: url) {
                decisionHandler(.cancel)
                deliver(code)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard store == .epic, let url = webView.url, EpicClient.isAuthorizationCodePage(url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                guard let text = result as? String, let code = EpicClient.authorizationCode(fromPageText: text) else { return }
                Task { @MainActor in self?.deliver(code) }
            }
        }
    }
}
