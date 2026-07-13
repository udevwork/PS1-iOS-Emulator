import SwiftUI
import MetalKit

/// SwiftUI-обёртка над MTKView, рисующим кадры эмулятора.
struct MetalVideoView: UIViewRepresentable {

    func makeCoordinator() -> Renderer {
        Renderer()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let linearSampler: MTLSamplerState
        private let nearestSampler: MTLSamplerState
        private let texture: MTLTexture
        private var frameWidth = 320
        private var frameHeight = 240
        private var viewSize = CGSize(width: 1, height: 1)

        override init() {
            device = MTLCreateSystemDefaultDevice()!
            commandQueue = device.makeCommandQueue()!

            let library = device.makeDefaultLibrary()!
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "screenQuadVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "screenQuadFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)!

            samplerDescriptor.minFilter = .nearest
            samplerDescriptor.magFilter = .nearest
            nearestSampler = device.makeSamplerState(descriptor: samplerDescriptor)!

            // Одна текстура на максимальный размер кадра PS1; каждый кадр
            // обновляется нужный регион, семплируется по фактическим размерам
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .b5g6r5Unorm,
                width: VideoFrameBuffer.maxWidth,
                height: VideoFrameBuffer.maxHeight,
                mipmapped: false)
            textureDescriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: textureDescriptor)!

            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewSize = size
        }

        func draw(in view: MTKView) {
            EmulatorCore.shared.videoBuffer.withNewFrame { pixels, width, height, rowStride in
                frameWidth = width
                frameHeight = height
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: pixels,
                    bytesPerRow: rowStride * 2)
            }

            guard let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

            // Настройка «На весь экран»: либо честные 4:3 (PS1 выводит
            // с неквадратными пикселями), либо натянуть на весь экран (Pro)
            let stretchFill = FeatureGate.sessionIsPro
                && (UserDefaults.standard.object(forKey: "stretchFill") as? Bool) ?? false
            var scale = SIMD2<Float>(1, 1)
            if !stretchFill {
                let targetAspect: Float = 4.0 / 3.0
                let viewAspect = Float(viewSize.width / max(viewSize.height, 1))
                if viewAspect > targetAspect {
                    scale.x = targetAspect / viewAspect
                } else {
                    scale.y = viewAspect / targetAspect
                }
            }

            // Текстурные координаты обрезаем до фактического размера кадра
            var texScale = SIMD2<Float>(
                Float(frameWidth) / Float(VideoFrameBuffer.maxWidth),
                Float(frameHeight) / Float(VideoFrameBuffer.maxHeight))

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setVertexBytes(&texScale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            // Настройка «Сглаживание картинки»: линейная фильтрация или честные пиксели (Pro)
            let smoothing = FeatureGate.sessionIsPro
                && (UserDefaults.standard.object(forKey: "videoSmoothing") as? Bool) ?? true
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(smoothing ? linearSampler : nearestSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
