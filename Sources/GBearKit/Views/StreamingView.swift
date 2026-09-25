import AppKit
import SwiftUI

struct StreamingView: View {
    @State private var session: StreamingPairingSession
    @State private var hostManager = GBearStreamHostManager.shared
    @State private var guestManager = GBearStreamGuestManager.shared
    @State private var confirmDisconnect = false
    @State private var streamLogSavedPath: String?
    @State private var showGuestVideo = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(session: StreamingPairingSession = StreamingPairingSession()) {
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                heroSection
                streamHostSection
                playOnThisMacSection
                joinComputerSection
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
        .onChange(of: guestManager.phase) { _, phase in
            if phase == .streaming {
                showGuestVideo = true
            }
        }
        .sheet(isPresented: $showGuestVideo) {
            guestVideoSheet
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
                Image(systemName: "gamecontroller")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote couch co-op")
                        .font(.headline)
                    Text(
                        "At most 8 players. This Mac uses one slot when it is playing, so 7 phones or computers can join. An 8th device can join only if it plays as the host in place of this Mac. After people join, use Move to to swap slots."
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
                Text(GBearStreamPorts.protocolVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Ports") {
                Text(
                    "control \(GBearStreamPorts.controlHTTP), video \(GBearStreamPorts.videoTCP), " +
                        "audio \(GBearStreamPorts.audioUDP), input \(GBearStreamPorts.inputUDP)"
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
                        if let logURL, let saved = GBearStreamSessionLog.saveCopyToDownloads(from: logURL) {
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
                            Text("\(request.deviceName) is trying to pair (\(request.clientKind.displayLabel))")
                                .font(.headline)
                        } icon: {
                            Image(systemName: request.clientKind == .computerGuest ? "laptopcomputer" : "iphone.circle")
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
    private var playOnThisMacSection: some View {
        Section("Host player (Player 1)") {
            Text(
                "This Mac is Player 1 unless you pick a paired companion to play in its place. That frees this Mac’s slot so 8 devices can join (the 8th is the host player). Everyone else joins in order (Player 2, 3…). After they join, use Move to to reassign slots."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Picker("Host plays on", selection: hostPlayerBinding) {
                Text("This Mac").tag(GBearCoopSessionState.localHostDeviceID)
                ForEach(hostManager.pairedDevices) { device in
                    Text(device.name).tag(device.deviceID)
                }
                if hostPlayerIsMissingFromPairedList {
                    Text("Selected companion").tag(hostManager.hostPlayerDeviceID)
                }
            }
            if let local = hostManager.coopSession?.seat(for: GBearCoopSessionState.localHostDeviceID) {
                Label("This Mac is playing as Player \(local.seat)", systemImage: "desktopcomputer")
                    .foregroundStyle(.green)
            } else if hostManager.hostPlayerDeviceID == GBearCoopSessionState.localHostDeviceID {
                Text("This Mac will take Player 1 when the session starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Player 1 reserved for \(hostPlayerDisplayName)",
                    systemImage: "iphone"
                )
                .foregroundStyle(.orange)
                Text("Start Desktop stream on that companion to play as the host. This Mac is not occupying a player slot, so up to 8 devices can join.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hostPlayerBinding: Binding<String> {
        Binding(
            get: { hostManager.hostPlayerDeviceID },
            set: { newValue in
                Task { _ = await hostManager.setHostPlayer(deviceID: newValue) }
            }
        )
    }

    private var hostPlayerIsMissingFromPairedList: Bool {
        let id = hostManager.hostPlayerDeviceID
        if id == GBearCoopSessionState.localHostDeviceID { return false }
        return !hostManager.pairedDevices.contains(where: { $0.deviceID == id })
    }

    private var hostPlayerDisplayName: String {
        let id = hostManager.hostPlayerDeviceID
        if id == GBearCoopSessionState.localHostDeviceID {
            return "this Mac"
        }
        return hostManager.pairedDevices.first(where: { $0.deviceID == id })?.name
            ?? hostManager.coopSession?.seat(for: id)?.deviceName
            ?? "companion"
    }

    @ViewBuilder
    private var joinComputerSection: some View {
        Section("Join another computer") {
            Text("Watch the host’s screen on this Mac and play with a local controller. Default is join order (next open seat after the host).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Host LAN IP", text: $guestManager.hostAddress)
            Picker("Join as", selection: $guestManager.preferredSeat) {
                Text("Join in order").tag(0)
                ForEach(1 ... GBearStreamPorts.maxCoopViewers, id: \.self) { seat in
                    Text("Player \(seat)").tag(seat)
                }
            }
            Text(guestManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Pair & join") {
                    Task { await guestManager.pairAndJoin() }
                }
                .disabled(guestManager.phase == .pairing || guestManager.phase == .streaming)
                Button("Leave", role: .destructive) {
                    Task {
                        showGuestVideo = false
                        await guestManager.stop()
                    }
                }
                .disabled(guestManager.phase == .idle)
            }
        }
    }

    private var guestVideoSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text(guestManager.statusMessage)
                    .font(.headline)
                Spacer()
                Button("Close") {
                    showGuestVideo = false
                    Task { await guestManager.stop() }
                }
            }
            .padding()
            GBearGuestVideoView(sample: guestManager.latestSample)
                .frame(minWidth: 640, minHeight: 360)
                .background(.black)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var coopSeatsSection: some View {
        Section("Players (up to \(GBearStreamPorts.maxCoopViewers))") {
            if let coop = hostManager.coopSession {
                LabeledContent("Session") {
                    Text(String(coop.sessionID.prefix(8)) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(coop.capacityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Joined") {
                    Text(
                        coop.localHostIsPlaying
                            ? "This Mac + \(coop.remotePlayerCount) of 7 devices"
                            : "\(coop.remotePlayerCount) of 8 devices"
                    )
                }
                ForEach(1 ... GBearStreamPorts.maxCoopViewers, id: \.self) { number in
                    if let occupant = coop.occupant(seat: number) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "Player \(number) — \(occupant.deviceName)\(occupant.deviceID == coop.hostPlayerDeviceID ? " (host)" : "")",
                                systemImage: occupant.kind == .localHost
                                    ? "desktopcomputer"
                                    : (occupant.kind == .computerGuest ? "laptopcomputer" : "iphone")
                            )
                            .font(.headline)
                            Text("\(occupant.kind.displayLabel) • GBG1 join seat \(occupant.joinSeat)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(occupant.deviceID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            HStack {
                                Menu("Move to") {
                                    ForEach(1 ... GBearStreamPorts.maxCoopViewers, id: \.self) { target in
                                        Button("Player \(target)") {
                                            Task { _ = await hostManager.reassignSeat(deviceID: occupant.deviceID, seat: target) }
                                        }
                                        .disabled(target == occupant.seat)
                                    }
                                }
                                if occupant.wantsVideo {
                                    Button("Cursor owner") {
                                        Task { _ = await hostManager.setCursorOwner(deviceID: occupant.deviceID) }
                                    }
                                    if coop.cursorOwnerDeviceID == occupant.deviceID {
                                        Text("owns cursor")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else if number == 1, coop.reservedHostSeat == 1 {
                        Label(
                            "Player 1 — reserved for \(hostPlayerDisplayName)",
                            systemImage: "hourglass"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Label("Player \(number) — empty", systemImage: "circle")
                            .foregroundStyle(.secondary)
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
                Text("Create a session, then play on this Mac and/or let phones and other computers join in order. Use Move to after people have joined if you need to swap Player 1–8.")
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
                    GBearScreenCapturePipeline.openScreenRecordingSettings()
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
                    GBearRemoteInputPlayback.wigglePointerForTest()
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
            Label(
                "8 player slots: this Mac + 7 devices, or 8 devices if one plays as the host instead of this Mac",
                systemImage: "person.3"
            )
            Label("Phone: Session → Start Desktop stream", systemImage: "play.circle")
            Label(
                "Video TCP \(GBearStreamPorts.videoTCP), audio TCP \(GBearStreamPorts.audioTCP)",
                systemImage: "film"
            )
            Label("Co-op pads via GBG1 → virtual Mac gamepads; touch moves pointer (UDP \(GBearStreamPorts.inputUDP))", systemImage: "gamecontroller")
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
