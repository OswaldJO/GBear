import SwiftUI
import WebKit

/// Embedded store sign-in page. Watches for the store's redirect and hands back the SteamID or authorization code.
struct StorefrontLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: Storefront
    let onSignedIn: () -> Void

    @State private var working = false
    @State private var errorMessage: String?

    private var startURL: URL {
        switch store {
        case .steam: return SteamClient.openIDLoginURL
        case .gog: return GOGClient.loginURL
        case .epic: return EpicClient.loginURL
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ZStack {
                    StorefrontLoginWebView(store: store, startURL: startURL) { result in
                        Task { await finish(result) }
                    }
                    if working {
                        ProgressView("Signing in…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .navigationTitle("Sign in to \(store.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    @MainActor
    private func finish(_ value: String) async {
        working = true
        defer { working = false }
        do {
            switch store {
            case .steam:
                StorefrontCredentials.steamID = value
                StorefrontCredentials.setAccountName(await SteamClient.personaName() ?? value, for: .steam)
            case .gog:
                try await GOGClient.signIn(code: value)
            case .epic:
                try await EpicClient.signIn(code: value)
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

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onResult: onResult) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: Storefront
        let onResult: (String) -> Void
        private var delivered = false

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
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            switch store {
            case .steam:
                if let steamID = SteamClient.steamID(fromOpenIDReturn: url) {
                    decisionHandler(.cancel)
                    deliver(steamID)
                    return
                }
            case .gog:
                if let code = GOGClient.authorizationCode(fromRedirect: url) {
                    decisionHandler(.cancel)
                    deliver(code)
                    return
                }
            case .epic:
                break
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
