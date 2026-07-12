import Foundation
import CoreGraphics

/// Потокобезопасный буфер последнего видеокадра (RGB565).
/// Ядро пишет с эмуляционного потока, Metal-рендерер читает с рендер-потока.
nonisolated final class VideoFrameBuffer: @unchecked Sendable {

    static let maxWidth = 1024
    static let maxHeight = 512

    private let lock = NSLock()
    private var buffer: UnsafeMutablePointer<UInt16>
    private(set) var width = 320
    private(set) var height = 240
    private var dirty = false
    /// Счётчик кадров — для отображения FPS и определения простоя
    private(set) var frameCount: UInt64 = 0

    init() {
        buffer = .allocate(capacity: Self.maxWidth * Self.maxHeight)
        buffer.initialize(repeating: 0, count: Self.maxWidth * Self.maxHeight)
    }

    deinit {
        buffer.deallocate()
    }

    /// Вызывается из video refresh колбэка ядра. pitch — в байтах.
    func store(pixels: UnsafeRawPointer, width: Int, height: Int, pitch: Int) {
        let w = min(width, Self.maxWidth)
        let h = min(height, Self.maxHeight)

        lock.lock()
        self.width = w
        self.height = h
        var src = pixels
        var dst = buffer
        for _ in 0..<h {
            memcpy(dst, src, w * 2)
            src += pitch
            dst += Self.maxWidth
        }
        dirty = true
        frameCount &+= 1
        lock.unlock()
    }

    /// Отдаёт кадр рендереру, если с прошлого вызова появился новый.
    /// body получает указатель на пиксели с row stride = maxWidth (в пикселях).
    func withNewFrame(_ body: (UnsafePointer<UInt16>, _ width: Int, _ height: Int, _ rowStride: Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return }
        dirty = false
        body(buffer, width, height, Self.maxWidth)
    }

    /// Снимок текущего кадра (RGB565 → RGBA8) — для обложек в библиотеке.
    func makeCGImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard frameCount > 0 else { return nil }

        let w = width, h = height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = buffer[y * Self.maxWidth + x]
                let i = (y * w + x) * 4
                rgba[i]     = UInt8((p >> 11) & 0x1F) << 3 // R
                rgba[i + 1] = UInt8((p >> 5) & 0x3F) << 2  // G
                rgba[i + 2] = UInt8(p & 0x1F) << 3         // B
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        return context.makeImage()
    }
}
