import Foundation
import AVFoundation

/// Аудиовыход: кольцевой буфер int16-стерео, который наполняет ядро,
/// а AVAudioSourceNode вычитывает на рендер-потоке CoreAudio.
nonisolated final class EmulatorAudio: @unchecked Sendable {

    private let lock = NSLock()
    private var ring: [Int16]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0 // в сэмплах (кадр = 2 сэмпла)

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    init() {
        // ~250 мс на 44.1 кГц стерео
        ring = [Int16](repeating: 0, count: 44100 / 2)
    }

    func start(sampleRate: Double) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()

        self.engine = engine
        self.sourceNode = node
    }

    func stop() {
        engine?.stop()
        engine = nil
        sourceNode = nil
    }

    /// Вызывается ядром с эмуляционного потока. frames — число стереокадров.
    func push(samples: UnsafePointer<Int16>, frames: Int) {
        let count = frames * 2
        lock.lock()
        let capacity = ring.count
        if available + count > capacity {
            // Переполнение: выбрасываем самые старые сэмплы
            let drop = available + count - capacity
            readIndex = (readIndex + drop) % capacity
            available -= drop
        }
        for i in 0..<count {
            ring[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available += count
        lock.unlock()
    }

    private func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        let capacity = ring.count
        for i in 0..<frames {
            if available >= 2 {
                left[i] = Float(ring[readIndex]) / 32768.0
                readIndex = (readIndex + 1) % capacity
                right[i] = Float(ring[readIndex]) / 32768.0
                readIndex = (readIndex + 1) % capacity
                available -= 2
            } else {
                left[i] = 0
                right[i] = 0
            }
        }
        lock.unlock()
    }
}
