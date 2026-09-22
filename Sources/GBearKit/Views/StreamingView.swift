import AppKit
import SwiftUI

struct StreamingView: View {
    @State private var session: StreamingPairingSession
    @State private var hostManager = PlayniteStreamHostManager.shared
    @State private var confirmDisconnect = false
    @State private var streamLogSavedPath: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(session: StreamingPairingSession = StreamingPairingSession()) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                heroSection
                streamHostSection
                remoteSessionSection
                pairingRequestsSection
                coopSeatsSection

                if case .paired(let deviceName) = session.phase {
                    pairedSections(deviceName: deviceName)
                }

                accessibilitySection
                capabilitiesSection
            }
            .formStyle(.grouped)
            .navigationTitle("Streaming")
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            Task {
                await hostManager.ensureReady()
                await hostManager.refreshPendingPairRequests()
                await hostManager.refreshCoopSession()
                session.refreshHostStatus()
                session.beginListeningForRequests()
            }
        }
        .onDisappear {
            session.stopListeningForRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await hostManager.refreshCapturePermission()
                session.refreshHostStatus()
            }
        }
        .confirmationDialog(
            "Disconnect “\(pairedNameForDialog)” from streaming on this Mac?",
            isPresented: $confirmDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                session.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var pairedNameForDialog: String {
        if case .paired(let name) = session.phase { return name }
        return ""
    }

    private var heroSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stream to your phone")
                        .font(.headline)
                    Text(
                        "On the companion app: Discover your Mac, then tap Pair. Approve or deny the request here — no PINs. Grant Screen Recording for GBear once."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var streamHostSection: some View {
        Section("Streaming host") {
            hostStateRow
            if let lanIP = LocalNetworkAddress.primaryIPv4() {
                LabeledContent("LAN IP (enter in companion Settings)") {
                    Text(lanIP)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Protocol") {
                Text(PlayniteStreamPorts.protocolVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Ports") {
                Text(
                    "control \(PlayniteStreamPorts.controlHTTP), video \(PlayniteStreamPorts.videoTCP), " +
                        "audio \(PlayniteStreamPorts.audioUDP), input \(PlayniteStreamPorts.inputUDP)"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            if hostManager.isVideoStreaming {
                Label("Streaming video to phone", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Stop active stream", role: .destructive) {
                    Task {
                        let logURL = await hostManager.stopActiveVideoStream()
                        session.refreshHostStatus()
                        if let logURL, let saved = PlayniteStreamSessionLog.saveCopyToDownloads(from: logURL) {
                            streamLogSavedPath = saved.path
                            NSWorkspace.shared.activateFileViewerSelecting([saved])
                        } else {
                            streamLogSavedPath = nil
                        }
                    }
                }
            }
            if let streamLogSavedPath {
                Text("Stream log saved to Downloads: \(streamLogSavedPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            screenRecordingPermissionBlock
            if let guidance = hostManager.captureGuidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.statusMessage.isEmpty {
                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = session.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Restart streaming host") {
                Task {
                    await hostManager.restartHost()
                    session.refreshHostStatus()
                }
            }
        }
    }

    @ViewBuilder
    private var remoteSessionSection: some View {
        Section("Remote co-op (session tunnel)") {
            Text(
                "Sign in with Google (or dev token) on the coordinator so your own devices join without invites. Mint an invite for a friend on another network — no port forwarding."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            let coord = GBearSessionCoordinatorClient.shared
            if let email = coord.email {
                LabeledContent("Account") { Text(email) }
            }
            if let sid = coord.remoteSessionID {
                LabeledContent("Remote session") {
                    Text(String(sid.prefix(8)) + "…")
                        .font(.caption.monospaced())
                }
            }
            if let invite = coord.lastInviteCode {
                LabeledContent("Invite code") {
                    Text(invite)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let err = coord.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Dev sign-in") {
                    Task {
                        coord.configure(baseURLString: "http://127.0.0.1:8787")
                        _ = await coord.signIn(idToken: "dev:host@gbear.local")
                    }
                }
                Button("Create remote session") {
                    Task { _ = await coord.createRemoteSession() }
                }
                Button("Mint invite") {
                    Task { _ = await coord.mintInvite() }
                }
            }
            Button("Refresh TURN / ICE") {
                Task { await coord.refreshTURNCredentials() }
            }
            Button("End remote session", role: .destructive) {
                Task { await coord.endRemoteSession() }
            }
        }
    }

    @ViewBuilder
    private var pairingRequestsSection: some View {
        Section("Pairing requests") {
            if hostManager.pendingPairRequests.isEmpty {
                Text("No pending requests. Open the companion app, discover this Mac, and tap Pair.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(hostManager.pendingPairRequests) { request in
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text("\(request.deviceName) is trying to pair")
                                .font(.headline)
                        } icon: {
                            Image(systemName: "iphone.circle")
                        }
                        Text("Device ID: \(request.deviceID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Deny", role: .destructive) {
                                session.deny(request)
                            }
                            Spacer()
                            Button("Pair") {
                                session.approve(request)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var coopSeatsSection: some View {
        Section("Co-op seats (2 players)") {
            if let coop = hostManager.coopSession {
                LabeledContent("Session") {
                    Text(String(coop.sessionID.prefix(8)) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if coop.seats.isEmpty {
                    Text("No viewers joined yet. Companions claim a seat when they start streaming.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coop.seats) { seat in
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Player \(seat.seat) — \(seat.deviceName)", systemImage: seat.seat == 1 ? "1.circle.fill" : "2.circle.fill")
                                .font(.headline)
                            Text(seat.deviceID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            HStack {
                                if seat.seat != 1 {
                                    Button("Make P1") {
                                        Task { _ = await hostManager.reassignSeat(deviceID: seat.deviceID, seat: 1) }
                                    }
                                }
                                if seat.seat != 2 {
                                    Button("Make P2") {
                                        Task { _ = await hostManager.reassignSeat(deviceID: seat.deviceID, seat: 2) }
                                    }
                                }
                                Button("Cursor owner") {
                                    Task { _ = await hostManager.setCursorOwner(deviceID: seat.deviceID) }
                                }
                                if coop.cursorOwnerDeviceID == seat.deviceID {
                                    Text("owns cursor")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                HStack {
                    Button("Create / ensure session") {
                        Task { _ = await hostManager.createCoopSession() }
                    }
                    Button("End session", role: .destructive) {
                        Task { await hostManager.endCoopSession() }
                    }
                }
            } else {
                Text("Create a session to assign Player 1 / Player 2 seats (max 2 viewers).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create co-op session") {
                    Task { _ = await hostManager.createCoopSession() }
                }
            }
        }
    }

    @ViewBuilder
    private var screenRecordingPermissionBlock: some View {
        if hostManager.isCaptureReady {
            Label("Screen Recording enabled for GBear", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if case .running = hostManager.state {
            VStack(alignment: .leading, spacing: 8) {
                Label("Screen Recording required", systemImage: "rectangle.dashed.badge.record")
                    .font(.subheadline.weight(.medium))
                if hostManager.needsScreenCaptureConsent {
                    Text(
                        "Tap Allow below for the macOS permission prompt. You only need to do this once; pairing will not ask again after access is granted."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            _ = await hostManager.requestScreenCaptureAccess()
                            session.refreshHostStatus()
                        }
                    } label: {
                        Label("Allow Screen Recording", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Permission is on but capture is not ready. Restart the streaming host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Screen Recording settings") {
                    PlayniteScreenCapturePipeline.openScreenRecordingSettings()
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var hostStateRow: some View {
        switch hostManager.state {
        case .running where hostManager.isVideoStreaming:
            Label("Streaming to companion", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case .running where session.hostReachable && hostManager.isCaptureReady:
            Label("Ready — pairing OK; stream starts from the phone", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .running where session.hostReachable:
            Label("Host up — grant Screen Recording before streaming", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .running:
            Label("Pairing host listening", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .preparing:
            Label(hostManager.statusLine, systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.secondary)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .idle:
            Label("Not started", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func pairedSections(deviceName: String) -> some View {
        Group {
            Section("Paired device") {
                LabeledContent("Device") {
                    Label(deviceName, systemImage: "iphone")
                }
                LabeledContent("Mac") {
                    Text(ProcessInfo.processInfo.hostName)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Forget pairing…", systemImage: "link.badge.minus", role: .destructive) {
                    confirmDisconnect = true
                }
            }
        }
    }

    private var accessibilitySection: some View {
        Section("Remote touch (Mac pointer)") {
            if AccessibilityPermission.isGranted {
                Label("Accessibility enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Test cursor on streamed display") {
                    PlayniteRemoteInputPlayback.wigglePointerForTest()
                }
                Text("If the Mac cursor jumps, touch injection works. Restart the Mac app after changing Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Accessibility required for phone touch", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(
                    "In System Settings → Privacy & Security → Accessibility, enable **\(AccessibilityPermission.settingsAppName)**. " +
                        "There is no separate “touch” entry — it is the same permission as controller mapping."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Show permission dialog…") {
                    AccessibilityPermission.promptIfNeeded()
                }
                Button("Open Accessibility Settings…") {
                    AccessibilityPermission.openSystemSettings()
                }
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("After pairing") {
            Label("Up to 2 phones: video + audio fan-out; Player 1 / Player 2 seats", systemImage: "person.2")
            Label("Phone: Session → Start Desktop stream", systemImage: "play.circle")
            Label(
                "Video TCP \(PlayniteStreamPorts.videoTCP), audio TCP \(PlayniteStreamPorts.audioTCP)",
                systemImage: "film"
            )
            Label("Co-op pads via PNG1 → virtual Mac gamepads; touch moves pointer (UDP \(PlayniteStreamPorts.inputUDP))", systemImage: "gamecontroller")
            Text(
                "Capture, audio routing, and Mac speaker mute apply only while a companion stream is active " +
                    "(Session → Start Desktop stream). Use phone media volume during a stream."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview("Idle") {
    StreamingView()
}
