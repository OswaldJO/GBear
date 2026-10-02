import CoreImage.CIFilterBuiltins
import SwiftUI

/// Native Steam sign-in: account name + password with Steam Guard, or a QR code scanned in the Steam Mobile app.
struct SteamLoginView: View {
    let onSignedIn: () -> Void

    private enum Method: String, CaseIterable, Identifiable {
        case password = "Password"
        case qr = "QR Code"
        var id: Self { self }
    }

    private enum Step: Equatable {
        case credentials
        case waiting
        case approve
        case code(SteamAuth.Confirmation)
    }

    @State private var method: Method = .password
    @State private var step: Step = .credentials
    @State private var accountName = ""
    @State private var password = ""
    @State private var code = ""
    @State private var session: SteamAuth.Session?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            if step == .credentials {
                Picker("Sign-in method", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            Group {
                switch (method, step) {
                case (.qr, _): qrContent
                case (.password, .credentials): credentialsContent
                case (.password, .waiting): ProgressView("Signing in…")
                case (.password, .approve): approveContent
                case (.password, .code(let type)): codeContent(type)
                }
            }
            .frame(maxWidth: 340)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            Text("Your password goes straight to Steam, encrypted with Steam's key, and is never saved. GBear keeps only a sign-in token in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: method) {
            session = nil
            step = .credentials
            code = ""
            errorMessage = nil
            if method == .qr { await startQR() }
        }
        .task(id: session) { await pollUntilDone() }
    }

    // MARK: Steps

    private var credentialsContent: some View {
        VStack(spacing: 10) {
            TextField("Steam account name", text: $accountName)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { Task { await signIn() } }
            Text("Use your Steam account name, not your email address.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if working { ProgressView().controlSize(.small) } else { Text("Sign In") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(working || accountName.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var approveContent: some View {
        let byEmail = !(session?.confirmations.contains(.deviceConfirmation) ?? false)
        return VStack(spacing: 14) {
            Image(systemName: byEmail ? "envelope.badge" : "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(byEmail ? "Open the email from Steam and approve this sign-in." : "Approve this sign-in in the Steam Mobile app.")
                .font(.headline)
                .multilineTextAlignment(.center)
            ProgressView("Waiting for approval…")
                .controlSize(.small)
            if session?.confirmations.contains(.deviceCode) == true {
                Button("Enter a Steam Guard code instead") { step = .code(.deviceCode) }
                    .buttonStyle(.link)
            }
            Button("Back") { restartPasswordSignIn() }
                .buttonStyle(.bordered)
        }
    }

    private func codeContent(_ type: SteamAuth.Confirmation) -> some View {
        VStack(spacing: 12) {
            Image(systemName: type == .emailCode ? "envelope" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(type == .emailCode
                ? "Enter the code Steam emailed to \(session?.emailDomain.map { "your \($0) address" } ?? "you")."
                : "Enter the Steam Guard code from the Steam Mobile app or your authenticator.")
                .multilineTextAlignment(.center)
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .onSubmit { Task { await submitCode(type) } }
            Button {
                Task { await submitCode(type) }
            } label: {
                Group {
                    if working { ProgressView().controlSize(.small) } else { Text("Continue") }
                }
                .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(working || code.trimmingCharacters(in: .whitespaces).count < 5)
            if type == .deviceCode, session?.confirmations.contains(.deviceConfirmation) == true {
                Button("Approve in the Steam Mobile app instead") { step = .approve }
                    .buttonStyle(.link)
            }
            Button("Back") { restartPasswordSignIn() }
                .buttonStyle(.bordered)
        }
    }

    private var qrContent: some View {
        VStack(spacing: 14) {
            if let url = session?.challengeURL, let image = Self.qrImage(url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView()
                    .frame(width: 224, height: 224)
            }
            Text("Open the Steam Mobile app, tap the Steam Guard shield, and scan this code.")
                .multilineTextAlignment(.center)
            if working { ProgressView("Signing in…").controlSize(.small) }
        }
    }

    // MARK: Actions

    private func signIn() async {
        guard !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            let begun = try await SteamAuth.beginWithCredentials(
                accountName: accountName.trimmingCharacters(in: .whitespaces),
                password: password
            )
            password = ""
            if begun.confirmations.contains(.deviceConfirmation) || begun.confirmations.contains(.emailConfirmation) {
                step = .approve
            } else if begun.confirmations.contains(.deviceCode) {
                step = .code(.deviceCode)
            } else if begun.confirmations.contains(.emailCode) {
                step = .code(.emailCode)
            } else {
                step = .waiting
            }
            session = begun
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitCode(_ type: SteamAuth.Confirmation) async {
        guard let current = session, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            try await SteamAuth.submitCode(code, type: type, session: current)
            code = ""
            if case .done(let tokens) = try await SteamAuth.poll(current) {
                await finish(tokens)
            } else {
                step = .waiting
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startQR() async {
        do {
            session = try await SteamAuth.beginWithQR()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollUntilDone() async {
        guard let current = session else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(current.interval))
            if Task.isCancelled { return }
            do {
                switch try await SteamAuth.poll(current) {
                case .pending(let next):
                    if next != current {
                        session = next
                        return
                    }
                case .done(let tokens):
                    await finish(tokens)
                    return
                }
            } catch {
                if Task.isCancelled { return }
                if method == .qr {
                    await startQR()
                } else {
                    errorMessage = error.localizedDescription
                    restartPasswordSignIn(keepError: true)
                }
                return
            }
        }
    }

    private func finish(_ tokens: SteamAuth.Tokens) async {
        working = true
        defer { working = false }
        do {
            try await SteamAuth.completeSignIn(tokens)
            onSignedIn()
        } catch {
            errorMessage = error.localizedDescription
            if method == .qr {
                await startQR()
            } else {
                restartPasswordSignIn(keepError: true)
            }
        }
    }

    private func restartPasswordSignIn(keepError: Bool = false) {
        session = nil
        code = ""
        step = .credentials
        if !keepError { errorMessage = nil }
    }

    private static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
