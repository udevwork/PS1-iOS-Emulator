import Foundation

/// Состояние виртуального геймпада PS1 (порт 0).
/// UI-поток и GameController пишут, эмуляционный поток читает.
nonisolated final class EmulatorInput: @unchecked Sendable {

    /// Кнопки PS1 в терминах libretro RETRO_DEVICE_ID_JOYPAD_*
    enum Button: Int32, CaseIterable, Sendable {
        case cross = 0      // B
        case square = 1     // Y
        case select = 2
        case start = 3
        case up = 4
        case down = 5
        case left = 6
        case right = 7
        case circle = 8     // A
        case triangle = 9   // X
        case l1 = 10
        case r1 = 11
        case l2 = 12
        case r2 = 13
        case l3 = 14
        case r3 = 15
    }

    private let lock = NSLock()
    private var buttonMask: UInt32 = 0
    // Аналоговые стики: [-32768, 32767], индексы: left/right, оси X/Y
    private var analog = [Int16](repeating: 0, count: 4)

    func set(_ button: Button, pressed: Bool) {
        lock.lock()
        if pressed {
            buttonMask |= 1 << UInt32(button.rawValue)
        } else {
            buttonMask &= ~(1 << UInt32(button.rawValue))
        }
        lock.unlock()
    }

    func setAnalog(leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        lock.lock()
        analog[0] = Int16(max(-1, min(1, leftX)) * 32767)
        analog[1] = Int16(max(-1, min(1, leftY)) * 32767)
        analog[2] = Int16(max(-1, min(1, rightX)) * 32767)
        analog[3] = Int16(max(-1, min(1, rightY)) * 32767)
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        buttonMask = 0
        analog = [0, 0, 0, 0]
        lock.unlock()
    }

    /// Ответ на retro_input_state с эмуляционного потока.
    func state(device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        lock.lock()
        defer { lock.unlock() }

        switch Int32(device) {
        case RETRO_DEVICE_JOYPAD:
            if id == RETRO_DEVICE_ID_JOYPAD_MASK {
                return Int16(truncatingIfNeeded: buttonMask)
            }
            guard id < 16 else { return 0 }
            return (buttonMask & (1 << id)) != 0 ? 1 : 0

        case RETRO_DEVICE_ANALOG:
            guard index < 2, id < 2 else { return 0 }
            return analog[Int(index * 2 + id)]

        default:
            return 0
        }
    }
}
