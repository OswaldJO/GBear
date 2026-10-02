import AppKit
import CoreAudio
import Darwin
import Foundation
import Observation

/// Sends the controller's Select + L1 / R1 volume to the TV instead of the Mac while the Mac's sound goes out
/// over HDMI. Macs only use their built-in HDMI-CEC for display sleep / wake, so volume needs either a USB-CEC
/// adapter (driven through libcec's `cec-client`, any TV) or a Roku TV's network remote (ECP on port 8060).
/// The adapter wins when both are there.
@MainActor
@Observable
final class TVVolumeControl {
    static let shared = TVVolumeControl()

    static let enabledKey = "tvVolumeFromController"
    static let rokuHostKey = "tvRokuHost"

    struct RokuTV: Identifiable, Hashable, Sendable {
        let host: String
        let name: String
        let isTV: Bool
        var id: String { host }
    }

    private(set) var rokus: [RokuTV] = []
    private(set) var isSearching = false
    private(set) var cecClientPath: String?
    private(set) var cecAdapterFound = false
    private(set) var statusMessage = ""

    var rokuHost: String? {
        get { UserDefaults.standard.string(forKey: Self.rokuHostKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: Self.rokuHostKey) }
    }

    @ObservationIgnored private var cecProcess: Process?
    @ObservationIgnored private var cecInput: FileHandle?
    @ObservationIgnored private var searchedOnce = false
    @ObservationIgnored private var lastFailureLog: CFTimeInterval = 0

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        // A write to cec-client after it exits must fail instead of killing GBear.
        signal(SIGPIPE, SIG_IGN)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TVVolumeControl.shared.stopCEC() }
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Volume up / down for the TV. Returns false when the controller should change the Mac's volume instead
    /// (turned off, sound isn't going to an HDMI / DisplayPort output, or no adapter or Roku is set up).
    func changeVolume(up: Bool) -> Bool {
        guard isEnabled, Self.outputIsHDMI else { return false }
        if cecAdapterFound, let path = cecClientPath {
            sendCEC(up ? "volup" : "voldown", clientPath: path)
            return true
        }
        if let host = rokuHost {
            sendRoku(key: up ? "VolumeUp" : "VolumeDown", host: host)
            return true
        }
        if !searchedOnce { refresh() }
        return false
    }

    /// Looks for a USB-CEC adapter and Roku TVs on the network.
    func refresh() {
        guard !isSearching else { return }
        searchedOnce = true
        isSearching = true
        statusMessage = "Looking for a USB-CEC adapter and Roku TVs…"
        Task {
            let cecPath = Self.findCECClient()
            let adapter = if let cecPath { await Self.cecAdapterPresent(clientPath: cecPath) } else { false }
            let found = await Self.discoverRokus()
            cecClientPath = cecPath
            cecAdapterFound = adapter
            rokus = found
            if let saved = rokuHost, !found.contains(where: { $0.host == saved }), !found.isEmpty {
                rokuHost = found.first(where: \.isTV)?.host ?? found.first?.host
            } else if rokuHost == nil {
                rokuHost = found.first(where: \.isTV)?.host ?? found.first?.host
            }
            isSearching = false
            statusMessage = describeRoute()
            DebugLog.log("TV volume: \(statusMessage)")
        }
    }

    func describeRoute() -> String {
        if cecAdapterFound { return "Using the USB-CEC adapter (works with any TV that has HDMI-CEC on)." }
        if let host = rokuHost {
            let name = rokus.first(where: { $0.host == host })?.name ?? host
            return "Using the Roku TV “\(name)” over Wi‑Fi."
        }
        if cecClientPath == nil, rokus.isEmpty {
            return "No Roku TV found and no USB-CEC adapter. The controller changes the Mac's volume."
        }
        if rokus.isEmpty {
            return "cec-client is installed but no USB-CEC adapter is plugged in, and no Roku TV was found."
        }
        return "Pick a Roku TV."
    }

    // MARK: - Output check

    /// True when the default output is an HDMI or DisplayPort device (a TV or monitor's speakers).
    static var outputIsHDMI: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }

    // MARK: - Roku (ECP)

    private func sendRoku(key: String, host: String) {
        guard let url = URL(string: "http://\(host):8060/keypress/\(key)") else { return }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    logFailure("Roku \(host) answered \(http.statusCode) to \(key); check Settings → System → Advanced system settings → Control by mobile apps")
                }
            } catch {
                logFailure("Roku \(host) \(key) failed: \(error.localizedDescription)")
            }
        }
    }

    private func logFailure(_ message: String) {
        let now = CACurrentMediaTime()
        guard now - lastFailureLog > 5 else { return }
        lastFailureLog = now
        DebugLog.log("TV volume: \(message)")
    }

    /// SSDP search for `roku:ecp`, then `/query/device-info` on each answer for its name.
    private nonisolated static func discoverRokus() async -> [RokuTV] {
        let hosts = await Task.detached { ssdpSearch(target: "roku:ecp", timeout: 2.5) }.value
        var found: [RokuTV] = []
        for host in hosts {
            guard let url = URL(string: "http://\(host):8060/query/device-info") else { continue }
            let info = (try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)))
                .flatMap { String(data: $0.0, encoding: .utf8) } ?? ""
            let name = xmlValue("user-device-name", in: info).flatMap { $0.isEmpty ? nil : $0 }
                ?? xmlValue("friendly-device-name", in: info)
                ?? xmlValue("model-name", in: info)
                ?? host
            found.append(RokuTV(host: host, name: name, isTV: xmlValue("is-tv", in: info) == "true"))
        }
        return found.sorted { ($0.isTV ? 0 : 1, $0.name) < ($1.isTV ? 0 : 1, $1.name) }
    }

    private nonisolated static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Multicasts an SSDP M-SEARCH and returns the hosts from each answer's `LOCATION` header.
    private nonisolated static func ssdpSearch(target: String, timeout: TimeInterval) -> [String] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: \(target)\r\nMX: 2\r\n\r\n"
        let bytes = Array(message.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let count = recv(sock, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            let reply = String(decoding: buffer[0..<count], as: UTF8.self)
            for line in reply.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let host = URL(string: value)?.host, !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }

    // MARK: - USB-CEC adapter (libcec)

    private nonisolated static func findCECClient() -> String? {
        ["/opt/homebrew/bin/cec-client", "/usr/local/bin/cec-client"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// `cec-client -l` lists adapters and exits; "Found devices: 0" means none is plugged in.
    private nonisolated static func cecAdapterPresent(clientPath: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: clientPath)
            process.arguments = ["-l"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Found devices:") }),
                  let count = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
                return false
            }
            return count > 0
        }.value
    }

    /// Keeps one `cec-client` running as a playback device and types libcec's interactive commands into it;
    /// `volup` / `voldown` go to the audio system (receiver / soundbar) when there is one, otherwise the TV.
    private func sendCEC(_ command: String, clientPath: String) {
        if cecProcess?.isRunning != true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: clientPath)
            process.arguments = ["-t", "p", "-o", "GBear", "-d", "1"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                Task { @MainActor in
                    let control = TVVolumeControl.shared
                    control.cecProcess = nil
                    control.cecInput = nil
                }
            }
            do {
                try process.run()
            } catch {
                logFailure("cec-client failed to start: \(error.localizedDescription)")
                return
            }
            cecProcess = process
            cecInput = input.fileHandleForWriting
            DebugLog.log("TV volume: started cec-client")
        }
        cecInput?.write(Data("\(command)\n".utf8))
    }

    private func stopCEC() {
        cecInput?.write(Data("q\n".utf8))
        cecProcess?.terminate()
        cecProcess = nil
        cecInput = nil
    }
}
