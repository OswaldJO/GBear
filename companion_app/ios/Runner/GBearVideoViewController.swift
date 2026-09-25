import AVFoundation
import Network
import UIKit
import VideoToolbox

/// Full-screen H.264 player for GBear `GBV1` frames (iOS).
final class GBearVideoViewController: UIViewController {
  var onStreamEnded: ((String?) -> Void)?

  /// Simulator: receive/log frames only — AVSampleBufferDisplayLayer + VT often crash under Flutter.
  private static let simulatorReceiveOnly: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }()

  private let host: String
  private let port: UInt16
  private let streamWidth: Int
  private let streamHeight: Int

  private var connection: NWConnection?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var formatDescription: CMFormatDescription?
  private var decompressionSession: VTDecompressionSession?
  private var presentationTicks: Int64 = 0
  private var framesReceived = 0
  private var framesDisplayed = 0
  private var stopping = false
  private var connectTimeoutWorkItem: DispatchWorkItem?
  private let networkQueue = DispatchQueue(label: "GBearVideo.network", qos: .userInitiated)
  private let decodeQueue = DispatchQueue(label: "GBearVideo.decode", qos: .userInitiated)

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.textColor = .white
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.numberOfLines = 0
    label.isHidden = true
    return label
  }()

  private lazy var stopButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle("Stop", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    if #available(iOS 15.0, *) {
      var config = UIButton.Configuration.plain()
      config.title = "Stop"
      config.baseForegroundColor = .white
      config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
      button.configuration = config
    } else {
      button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
    }
    button.layer.cornerRadius = 10
    button.clipsToBounds = true
    button.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
    return button
  }()

  init(host: String, port: UInt16, width: Int, height: Int) {
    self.host = host
    self.port = port
    self.streamWidth = width
    self.streamHeight = height
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    displayLayer.videoGravity = .resizeAspect

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    stopButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)
    view.addSubview(stopButton)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      stopButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      stopButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
    ])

    if Self.simulatorReceiveOnly {
      showStatus("Connecting (simulator receive-only)…")
      GBearStreamLog.i("Simulator receive-only mode — TCP/log without H.264 display")
    } else {
      showStatus("Connecting to \(host):\(port)…")
    }
    GBearStreamLog.i("Starting stream host=\(host) video=\(port) \(streamWidth)x\(streamHeight)")
  }

  func removeFromFlutterParentIfNeeded() {
    guard parent != nil else { return }
    willMove(toParent: nil)
    view.removeFromSuperview()
    removeFromParent()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard connection == nil, !stopping else { return }
    startConnection()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !Self.simulatorReceiveOnly else { return }
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    if displayLayer.superlayer == nil {
      displayLayer.frame = view.bounds
      view.layer.insertSublayer(displayLayer, at: 0)
    } else {
      displayLayer.frame = view.bounds
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isBeingDismissed {
      tearDownConnection()
    }
  }

  @objc private func stopTapped() {
    guard !stopping else { return }
    stopping = true
    GBearStreamLog.i("Stop tapped on stream overlay")
    finishStream(reason: "stopped from companion (iOS)")
  }

  func stopFromHost(notifyFlutter: Bool = false) -> String? {
    guard !stopping else { return GBearStreamLog.logFilePath() }
    stopping = true
    return finishStream(reason: "stopped from companion (session)", notifyFlutter: notifyFlutter)
  }

  @discardableResult
  private func finishStream(reason: String, notifyFlutter: Bool = true) -> String? {
    tearDownConnection()
    let path = GBearStreamLog.endSession(
      reason: "\(reason) (received=\(framesReceived) displayed=\(framesDisplayed))"
    )
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.closePlayerUI {
        if notifyFlutter {
          self.onStreamEnded?(path)
        }
      }
    }
    return path
  }

  private func closePlayerUI(completion: (() -> Void)?) {
    if parent != nil {
      removeFromFlutterParentIfNeeded()
      completion?()
    } else if presentingViewController != nil {
      dismiss(animated: true) { completion?() }
    } else {
      completion?()
    }
  }

  private func tearDownConnection() {
    connectTimeoutWorkItem?.cancel()
    connectTimeoutWorkItem = nil
    connection?.cancel()
    connection = nil
    if let session = decompressionSession {
      VTDecompressionSessionInvalidate(session)
      decompressionSession = nil
    }
    formatDescription = nil
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = text.isEmpty
    }
  }

  private func hideStatus() {
    showStatus("")
  }

  private func startConnection() {
    let tcp = NWParameters.tcp
    connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: tcp
    )
    connection?.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .waiting(let error):
        GBearStreamLog.w("TCP waiting: \(error.localizedDescription)")
      case .preparing:
        GBearStreamLog.i("TCP preparing…")
      case .ready:
        self.connectTimeoutWorkItem?.cancel()
        self.connectTimeoutWorkItem = nil
        GBearStreamLog.i("TCP connected, waiting for GBV1 frames")
        DispatchQueue.main.async { self.hideStatus() }
        self.receiveHeader()
      case .failed(let error):
        self.connectTimeoutWorkItem?.cancel()
        self.connectTimeoutWorkItem = nil
        GBearStreamLog.e("TCP failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
          self.showStatus("Connection failed")
          self.finishStream(reason: "connection failed")
        }
      case .cancelled:
        break
      default:
        break
      }
    }
    connection?.start(queue: networkQueue)
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.stopping, self.framesReceived == 0 else { return }
      GBearStreamLog.e("TCP connect timeout (12s) to \(self.host):\(self.port)")
      DispatchQueue.main.async {
        self.showStatus("Could not reach Mac video port")
        self.finishStream(reason: "tcp connect timeout")
      }
    }
    connectTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  private func receiveHeader() {
    guard let connection, !stopping else { return }
    connection.receive(minimumIncompleteLength: 13, maximumLength: 13) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        GBearStreamLog.e("Header read error: \(error.localizedDescription)")
        DispatchQueue.main.async { self.finishStream(reason: "header read error") }
        return
      }
      if isComplete {
        GBearStreamLog.i("TCP stream ended")
        DispatchQueue.main.async { self.finishStream(reason: "tcp closed") }
        return
      }
      guard let data, data.count == 13 else {
        GBearStreamLog.w("Short header (\(data?.count ?? 0) bytes); resyncing")
        self.receiveHeader()
        return
      }
      let magic = data.withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
      guard magic == GBearVideoFrameFormat.magic else {
        GBearStreamLog.e("Bad magic 0x\(String(magic, radix: 16)); resyncing")
        self.receiveHeader()
        return
      }
      let length = data.withUnsafeBytes {
        UInt32(littleEndian: $0.load(fromByteOffset: 4, as: UInt32.self))
      }
      let flags = data[8]
      let isKeyframe = (flags & 0x1) != 0
      let maxFrame = 8 * 1024 * 1024
      guard length > 0, length <= maxFrame else {
        GBearStreamLog.e("Invalid frame length \(length)")
        self.receiveHeader()
        return
      }
      connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payload, _, isComplete, error in
        if let error {
          GBearStreamLog.e("Payload read error: \(error.localizedDescription)")
          DispatchQueue.main.async { self.finishStream(reason: "payload read error") }
          return
        }
        if isComplete || payload == nil {
          DispatchQueue.main.async { self.finishStream(reason: "tcp closed mid-frame") }
          return
        }
        self.framesReceived += 1
        if self.framesReceived == 1 || self.framesReceived % 60 == 0 {
          GBearStreamLog.i(
            "Frame #\(self.framesReceived) keyframe=\(isKeyframe) bytes=\(payload!.count)"
          )
        }
        let frameData = payload!
        self.decodeQueue.async {
          guard !self.stopping else { return }
          self.decodeAnnexB(frameData, isKeyframe: isKeyframe)
          self.networkQueue.async {
            self.receiveHeader()
          }
        }
      }
    }
  }

  private func decodeAnnexB(_ annexB: Data, isKeyframe: Bool) {
    if Self.simulatorReceiveOnly {
      if framesReceived == 1 {
        GBearStreamLog.i("Simulator: first GBV1 frame \(annexB.count) bytes keyframe=\(isKeyframe)")
      }
      DispatchQueue.main.async {
        self.framesDisplayed = self.framesReceived
        if self.framesReceived == 1 || self.framesReceived % 30 == 0 {
          self.showStatus("Simulator: \(self.framesReceived) frames from Mac (no preview)")
        }
      }
      return
    }

    if isKeyframe || formatDescription == nil {
      if let newFormat = Self.formatDescription(from: annexB) {
        formatDescription = newFormat
        if let session = decompressionSession {
          VTDecompressionSessionInvalidate(session)
        }
        var session: VTDecompressionSession?
        let attrs: [NSString: Any] = [
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        let status = VTDecompressionSessionCreate(
          allocator: kCFAllocatorDefault,
          formatDescription: newFormat,
          decoderSpecification: nil,
          imageBufferAttributes: attrs as CFDictionary,
          outputCallback: nil,
          decompressionSessionOut: &session
        )
        if status != noErr {
          GBearStreamLog.e("VTDecompressionSessionCreate failed: \(status)")
        }
        decompressionSession = session
        DispatchQueue.main.async {
          if self.displayLayer.status == .failed {
            self.displayLayer.flush()
          }
        }
      } else if isKeyframe {
        GBearStreamLog.w("Keyframe missing SPS/PPS (\(annexB.count) bytes)")
      }
    }

    guard let formatDescription, let session = decompressionSession,
          let avcc = Self.annexBToAVCC(annexB) else { return }

    var blockBuffer: CMBlockBuffer?
    let allocStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: 0,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard allocStatus == kCMBlockBufferNoErr, let blockBuffer else { return }
    let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: avcc.count
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else { return }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: CMTime(value: presentationTicks, timescale: 600),
      decodeTimeStamp: .invalid
    )
    presentationTicks += 10

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return }

    var infoFlags = VTDecodeInfoFlags()
    VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [],
      infoFlagsOut: &infoFlags
    ) { [weak self] status, _, imageBuffer, _, _ in
      guard let self, let imageBuffer, status == noErr else { return }
      var timingInfo = CMSampleTimingInfo()
      var outSample: CMSampleBuffer?
      var outFormat: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &outFormat
      )
      guard let outFormat else { return }
      CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: outFormat,
        sampleTiming: &timingInfo,
        sampleBufferOut: &outSample
      )
      guard let outSample else { return }
      DispatchQueue.main.async {
        if self.displayLayer.status == .failed {
          self.displayLayer.flush()
        }
        if self.displayLayer.isReadyForMoreMediaData {
          self.displayLayer.enqueue(outSample)
          self.framesDisplayed += 1
          if self.framesDisplayed == 1 {
            GBearStreamLog.i("Rendered frame #1")
            self.hideStatus()
          }
        }
      }
    }
  }

  private static func formatDescription(from annexB: Data) -> CMFormatDescription? {
    let nalUnits = extractNALUnits(annexB)
    guard let sps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
          let pps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return nil }
    var description: CMFormatDescription?
    sps.withUnsafeBytes { spsRaw in
      pps.withUnsafeBytes { ppsRaw in
        guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
              let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let pointers = [spsBase, ppsBase]
        let sizes = [sps.count, pps.count]
        pointers.withUnsafeBufferPointer { ptr in
          sizes.withUnsafeBufferPointer { sizePtr in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
              allocator: kCFAllocatorDefault,
              parameterSetCount: 2,
              parameterSetPointers: ptr.baseAddress!,
              parameterSetSizes: sizePtr.baseAddress!,
              nalUnitHeaderLength: 4,
              formatDescriptionOut: &description
            )
          }
        }
      }
    }
    return description
  }

  /// VideoToolbox expects length-prefixed NALs (AVCC), not Annex-B start codes.
  private static func annexBToAVCC(_ annexB: Data) -> Data? {
    let nals = extractNALUnits(annexB)
    guard !nals.isEmpty else { return nil }
    var avcc = Data()
    for nal in nals {
      var len = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
      avcc.append(nal)
    }
    return avcc
  }

  private static func extractNALUnits(_ data: Data) -> [Data] {
    var units: [Data] = []
    var i = 0
    let bytes = [UInt8](data)
    func startIndex(_ from: Int) -> Int? {
      var j = from
      while j + 3 < bytes.count {
        if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 1 { return j + 3 }
        if j + 4 < bytes.count, bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 0, bytes[j + 3] == 1 {
          return j + 4
        }
        j += 1
      }
      return nil
    }
    while let start = startIndex(i) {
      var end = start
      while end < bytes.count {
        if end + 3 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 1 { break }
        if end + 4 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 0, bytes[end + 3] == 1 {
          break
        }
        end += 1
      }
      if end > start {
        units.append(Data(bytes[start..<end]))
      }
      i = max(end, start + 1)
    }
    return units
  }
}

enum GBearVideoFrameFormat {
  static let magic: UInt32 = 0x3156_4247 // "GBV1" little-endian
}
