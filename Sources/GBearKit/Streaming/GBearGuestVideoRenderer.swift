import AppKit
import CoreVideo
import Metal
import MetalFX
import QuartzCore

/// Draws decoded guest frames into a `CAMetalLayer`, fitted to the window without stretching.
/// When the picture is shown larger than it was sent, MetalFX's spatial upscaler enlarges it
/// (edge-aware, sharper than plain bilinear scaling); it costs about 2 ms of GPU time per frame on Apple silicon.
final class GBearGuestVideoRenderer: @unchecked Sendable {
    static let shared = GBearGuestVideoRenderer()

    static let upscaleDefaultsKey = "gbearGuestMetalFXUpscale"
    /// MetalFX spatial scaling is tuned for up to about 2×; anything beyond is finished bilinearly.
    private static let maxUpscale = 2.0

    private let lock = NSLock()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var linearSampler: MTLSamplerState?
    private let renderQueue = DispatchQueue(label: "GBearGuest.video.render", qos: .userInteractive)

    private var layer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var latestFrame: CVPixelBuffer?
    private var renderScheduled = false
    private var videoSize: CGSize = .zero

    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: [Int] = []
    private var scalerInput: MTLTexture?
    private var scalerOutput: MTLTexture?

    /// Called on the main actor when the stream's picture size changes.
    var onVideoSizeChange: (@MainActor (CGSize) -> Void)?

    var isUpscalerSupported: Bool {
        guard let device else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    private init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        guard let device else { return }
        UserDefaults.standard.register(defaults: [Self.upscaleDefaultsKey: true])
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "gbear_video_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "gbear_video_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[GBearGuestVideo] Metal pipeline failed: \(error.localizedDescription)")
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    // MARK: - Layer

    func makeLayer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    func attach(_ layer: CAMetalLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
        scheduleRender()
    }

    func detach(_ layer: CAMetalLayer) {
        lock.lock()
        if self.layer === layer { self.layer = nil }
        lock.unlock()
    }

    /// Pixel size of the view (points × backing scale).
    func setDrawableSize(_ size: CGSize) {
        lock.lock()
        let changed = drawableSize != size
        drawableSize = size
        layer?.drawableSize = size
        lock.unlock()
        if changed { scheduleRender() }
    }

    // MARK: - Frames

    /// Any thread. Only the newest frame is drawn if rendering falls behind.
    func display(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        lock.lock()
        latestFrame = pixelBuffer
        let sizeChanged = size != videoSize
        videoSize = size
        let callback = onVideoSizeChange
        lock.unlock()
        if sizeChanged, let callback {
            Task { @MainActor in callback(size) }
        }
        scheduleRender()
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        videoSize = .zero
        lock.unlock()
        scheduleRender()
    }

    private func scheduleRender() {
        lock.lock()
        if renderScheduled {
            lock.unlock()
            return
        }
        renderScheduled = true
        lock.unlock()
        renderQueue.async { [self] in
            lock.lock()
            renderScheduled = false
            let frame = latestFrame
            let layer = layer
            let target = drawableSize
            lock.unlock()
            guard let layer, target.width >= 1, target.height >= 1 else { return }
            render(frame, into: layer, drawableSize: target)
        }
    }

    // MARK: - Rendering (render queue only)

    private func render(_ frame: CVPixelBuffer?, into layer: CAMetalLayer, drawableSize: CGSize) {
        guard let commandQueue, let pipeline, let linearSampler,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var source: MTLTexture?
        var cvTexture: CVMetalTexture?
        if let frame, let textureCache {
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, frame, nil, .bgra8Unorm, width, height, 0, &cvTexture
            )
            source = cvTexture.flatMap(CVMetalTextureGetTexture)
        }

        var viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)
        var drawTexture = source
        if let source {
            let videoW = Double(source.width)
            let videoH = Double(source.height)
            let scale = min(drawableSize.width / videoW, drawableSize.height / videoH)
            let fitW = (videoW * scale).rounded(.down)
            let fitH = (videoH * scale).rounded(.down)
            viewport = MTLViewport(
                originX: ((drawableSize.width - fitW) / 2).rounded(.down),
                originY: ((drawableSize.height - fitH) / 2).rounded(.down),
                width: fitW, height: fitH, znear: 0, zfar: 1
            )
            if scale > 1.01, UserDefaults.standard.bool(forKey: Self.upscaleDefaultsKey),
               let upscaled = upscale(source, toWidth: Int(min(fitW, videoW * Self.maxUpscale)),
                                      height: Int(min(fitH, videoH * Self.maxUpscale)), commandBuffer: commandBuffer) {
                drawTexture = upscaled
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            if let drawTexture {
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(viewport)
                encoder.setFragmentTexture(drawTexture, index: 0)
                encoder.setFragmentSamplerState(linearSampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            // The decoded frame's texture must outlive the GPU work that reads it.
            _ = cvTexture
        }
        commandBuffer.commit()
    }

    private func upscale(_ source: MTLTexture, toWidth outW: Int, height outH: Int, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let device, isUpscalerSupported, outW > source.width, outH > source.height else { return nil }
        let key = [source.width, source.height, outW, outH]
        if key != scalerKey || scaler == nil {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = source.width
            descriptor.inputHeight = source.height
            descriptor.outputWidth = outW
            descriptor.outputHeight = outH
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
                scaler = nil
                scalerKey = []
                return nil
            }
            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false
            )
            inputDescriptor.storageMode = .private
            inputDescriptor.usage = newScaler.colorTextureUsage
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false
            )
            outputDescriptor.storageMode = .private
            outputDescriptor.usage = newScaler.outputTextureUsage.union(.shaderRead)
            scalerInput = device.makeTexture(descriptor: inputDescriptor)
            scalerOutput = device.makeTexture(descriptor: outputDescriptor)
            scaler = newScaler
            scalerKey = key
        }
        guard let scaler, let scalerInput, let scalerOutput,
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        // Decoder textures are not guaranteed to carry the usage MetalFX needs, so copy first.
        blit.copy(from: source, to: scalerInput)
        blit.endEncoding()
        scaler.colorTexture = scalerInput
        scaler.outputTexture = scalerOutput
        scaler.inputContentWidth = source.width
        scaler.inputContentHeight = source.height
        scaler.encode(commandBuffer: commandBuffer)
        return scalerOutput
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GBearVideoVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex GBearVideoVertexOut gbear_video_vertex(uint vid [[vertex_id]]) {
        const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        GBearVideoVertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 gbear_video_fragment(GBearVideoVertexOut in [[stage_in]],
                                         texture2d<float> frame [[texture(0)]],
                                         sampler linearSampler [[sampler(0)]]) {
        return frame.sample(linearSampler, in.uv);
    }
    """
}
