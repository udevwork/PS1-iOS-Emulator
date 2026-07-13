import Foundation
import GameController
import Observation

/// Подключение физических геймпадов (DualShock, DualSense, Xbox, MFi).
/// В режиме .game ввод летит в ядро, в режиме .menu — в навигацию по UI.
@Observable
final class GamepadManager {

    static let shared = GamepadManager()

    enum Mode { case menu, game }

    enum MenuEvent {
        case left, right, up, down
        case primary   // ✕ — выбрать/запустить/переключить
        case secondary // △ — добавить игру
        case cancel    // ○ — назад/закрыть меню
    }

    private(set) var isControllerConnected = false
    /// Курок ×2 зажат — для индикатора на игровом экране
    private(set) var isFastForwarding = false

    var mode: Mode = .menu {
        didSet {
            EmulatorCore.shared.input.releaseAll()
            EmulatorCore.shared.fastForward = false
            isFastForwarding = false
            cancelAllRepeats()
            menuHeld.removeAll()
            l3Held = false
        }
    }
    var menuHandler: ((MenuEvent) -> Void)?
    /// Нажатие левого стика (L3) в игре — вызов пауза-меню
    var pauseHandler: (() -> Void)?
    private var l3Held = false

    // Для edge-детекции и автоповтора в режиме меню
    private var menuHeld: Set<String> = []
    private var repeatTimers: [String: Timer] = [:]

    /// Задержка перед автоповтором и его период (консольный key-repeat)
    private static let repeatDelay: TimeInterval = 0.35
    private static let repeatInterval: TimeInterval = 0.1

    private init() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let controller = note.object as? GCController else { return }
                self?.configure(controller)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isControllerConnected = !GCController.controllers().isEmpty
                EmulatorCore.shared.input.releaseAll()
                self.cancelAllRepeats()
                self.menuHeld.removeAll()
            }
        }
        GCController.controllers().forEach(configure)
    }

    private func configure(_ controller: GCController) {
        isControllerConnected = true
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            guard let self else { return }
            switch self.mode {
            case .game: self.feedEmulator(from: gamepad)
            case .menu: self.feedMenu(from: gamepad)
            }
        }
    }

    // MARK: - Режим игры

    private func feedEmulator(from gamepad: GCExtendedGamepad) {
        let input = EmulatorCore.shared.input

        input.set(.cross, pressed: gamepad.buttonA.isPressed)
        input.set(.circle, pressed: gamepad.buttonB.isPressed)
        input.set(.square, pressed: gamepad.buttonX.isPressed)
        input.set(.triangle, pressed: gamepad.buttonY.isPressed)

        // Левый стик дублирует крестовину: многие PS1-игры цифровые
        // и аналог не читают. Настоящий аналог при этом тоже передаётся
        let stickX = gamepad.leftThumbstick.xAxis.value
        let stickY = gamepad.leftThumbstick.yAxis.value
        input.set(.up, pressed: gamepad.dpad.up.isPressed || stickY > 0.5)
        input.set(.down, pressed: gamepad.dpad.down.isPressed || stickY < -0.5)
        input.set(.left, pressed: gamepad.dpad.left.isPressed || stickX < -0.5)
        input.set(.right, pressed: gamepad.dpad.right.isPressed || stickX > 0.5)

        input.set(.l1, pressed: gamepad.leftShoulder.isPressed)
        input.set(.r1, pressed: gamepad.rightShoulder.isPressed)
        input.set(.l2, pressed: gamepad.leftTrigger.isPressed)
        input.set(.r2, pressed: gamepad.rightTrigger.isPressed)

        // L3 забираем под пауза-меню (PS1-игры его почти не использовали),
        // в ядро он не передаётся; R3 остаётся игре
        let l3 = gamepad.leftThumbstickButton?.isPressed ?? false
        if l3 && !l3Held {
            pauseHandler?()
        }
        l3Held = l3
        input.set(.r3, pressed: gamepad.rightThumbstickButton?.isPressed ?? false)

        input.set(.select, pressed: gamepad.buttonOptions?.isPressed ?? false)
        input.set(.start, pressed: gamepad.buttonMenu.isPressed)

        // Ось Y у libretro инвертирована относительно GameController
        input.setAnalog(
            leftX: gamepad.leftThumbstick.xAxis.value,
            leftY: -gamepad.leftThumbstick.yAxis.value,
            rightX: gamepad.rightThumbstick.xAxis.value,
            rightY: -gamepad.rightThumbstick.yAxis.value)

        // Глубоко зажатый правый курок — ускорение ×2 (Pro).
        // R2 при этом продолжает работать в игре как обычная кнопка
        let fastForward = FeatureGate.sessionIsPro && gamepad.rightTrigger.value > 0.6
        EmulatorCore.shared.fastForward = fastForward
        if isFastForwarding != fastForward {
            isFastForwarding = fastForward
        }
    }

    // MARK: - Режим меню

    private func feedMenu(from gamepad: GCExtendedGamepad) {
        let stickX = gamepad.leftThumbstick.xAxis.value
        let stickY = gamepad.leftThumbstick.yAxis.value
        // Направления повторяются при удержании, кнопки действия — нет
        emitOnEdge("left", pressed: gamepad.dpad.left.isPressed || stickX < -0.5, event: .left, repeats: true)
        emitOnEdge("right", pressed: gamepad.dpad.right.isPressed || stickX > 0.5, event: .right, repeats: true)
        emitOnEdge("up", pressed: gamepad.dpad.up.isPressed || stickY > 0.5, event: .up, repeats: true)
        emitOnEdge("down", pressed: gamepad.dpad.down.isPressed || stickY < -0.5, event: .down, repeats: true)
        emitOnEdge("primary", pressed: gamepad.buttonA.isPressed, event: .primary)
        emitOnEdge("secondary", pressed: gamepad.buttonY.isPressed, event: .secondary)
        emitOnEdge("cancel", pressed: gamepad.buttonB.isPressed, event: .cancel)
    }

    private func emitOnEdge(_ key: String, pressed: Bool, event: MenuEvent, repeats: Bool = false) {
        if pressed && !menuHeld.contains(key) {
            menuHeld.insert(key)
            menuHandler?(event)
            if repeats {
                scheduleRepeat(key: key, event: event)
            }
        } else if !pressed && menuHeld.contains(key) {
            menuHeld.remove(key)
            repeatTimers[key]?.invalidate()
            repeatTimers[key] = nil
        }
    }

    // MARK: - Автоповтор при удержании

    private func scheduleRepeat(key: String, event: MenuEvent) {
        repeatTimers[key]?.invalidate()
        let delayTimer = Timer(timeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startRepeating(key: key, event: event)
            }
        }
        RunLoop.main.add(delayTimer, forMode: .common)
        repeatTimers[key] = delayTimer
    }

    private func startRepeating(key: String, event: MenuEvent) {
        guard menuHeld.contains(key) else { return }
        let repeatTimer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuHeld.contains(key), self.mode == .menu else { return }
                self.menuHandler?(event)
            }
        }
        RunLoop.main.add(repeatTimer, forMode: .common)
        repeatTimers[key] = repeatTimer
    }

    private func cancelAllRepeats() {
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
    }
}
