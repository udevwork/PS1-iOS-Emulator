import SwiftUI
import UIKit

/// Хаптика тач-кнопок с учётом настройки «Вибрация тач-кнопок»
enum TouchHaptics {
    static func tap(intensity: CGFloat) {
        let enabled = (UserDefaults.standard.object(forKey: "touchHaptics") as? Bool) ?? true
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: intensity)
    }
}

/// Экранные контролы. Ввод обрабатывает один UIKit-слой на голых touches* —
/// без жестов и распознавателей: касание = нажатие в тот же момент,
/// палец может скользить между кнопками, мультитач честный.
/// SwiftUI здесь только рисует.
struct TouchControlsView: View {
    @State private var pressedButtons: Set<EmulatorInput.Button> = []

    var body: some View {
        GeometryReader { geo in
            let layout = TouchLayout(size: geo.size)

            ZStack {
                // Слой ввода — под визуалами, на весь экран
                TouchCaptureView(layout: layout) { buttons in
                    applyTouches(buttons)
                }

                dpadVisual(layout)
                faceVisual(layout)
                shoulderVisuals(layout)
                pillVisuals(layout)
            }
        }
        .allowsHitTesting(true)
    }

    private func applyTouches(_ new: Set<EmulatorInput.Button>) {
        guard new != pressedButtons else { return }
        let input = EmulatorCore.shared.input
        let added = new.subtracting(pressedButtons)
        for button in pressedButtons.subtracting(new) { input.set(button, pressed: false) }
        for button in added { input.set(button, pressed: true) }
        if !added.isEmpty {
            TouchHaptics.tap(intensity: 0.7)
        }
        pressedButtons = new
    }

    // MARK: - Визуалы

    private func dpadVisual(_ layout: TouchLayout) -> some View {
        let anyDirection = !pressedButtons.isDisjoint(with: [.up, .down, .left, .right])
        return ZStack {
            Circle().fill(.white.opacity(anyDirection ? 0.12 : 0.06))
            Image(systemName: "dpad.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(anyDirection ? 0.55 : 0.35))
                .rotationEffect(.zero)
        }
        .frame(width: layout.dpadRect.width, height: layout.dpadRect.height)
        .position(x: layout.dpadRect.midX, y: layout.dpadRect.midY)
        .allowsHitTesting(false)
    }

    private func faceVisual(_ layout: TouchLayout) -> some View {
        ForEach(TouchLayout.faceButtons, id: \.button) { spec in
            let rect = layout.faceRect(spec.button)
            let pressed = pressedButtons.contains(spec.button)
            ZStack {
                Circle().fill(.white.opacity(pressed ? 0.28 : 0.08))
                Image(systemName: spec.symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(spec.color.opacity(0.85))
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }

    private func shoulderVisuals(_ layout: TouchLayout) -> some View {
        ForEach(TouchLayout.shoulderButtons, id: \.button) { spec in
            let rect = layout.shoulderRect(spec.button)
            let pressed = pressedButtons.contains(spec.button)
            Text(spec.label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: rect.width, height: rect.height)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(pressed ? 0.28 : 0.08)))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func pillVisuals(_ layout: TouchLayout) -> some View {
        ForEach(TouchLayout.pillButtons, id: \.button) { spec in
            let rect = layout.pillRect(spec.button)
            let pressed = pressedButtons.contains(spec.button)
            Text(spec.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: rect.width, height: rect.height)
                .background(Capsule().fill(.white.opacity(pressed ? 0.28 : 0.08)))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Геометрия контролов

/// Все прямоугольники кнопок считаются из размера экрана в одном месте:
/// и отрисовка, и хит-тест используют одни и те же рамки.
struct TouchLayout {
    let size: CGSize

    static let faceButtons: [(button: EmulatorInput.Button, symbol: String, color: Color)] = [
        (.triangle, "triangle", .green),
        (.circle, "circle", .red),
        (.cross, "xmark", .blue),
        (.square, "square", .pink),
    ]

    static let shoulderButtons: [(button: EmulatorInput.Button, label: String)] = [
        (.l2, "L2"), (.l1, "L1"), (.r1, "R1"), (.r2, "R2"),
    ]

    static let pillButtons: [(button: EmulatorInput.Button, label: String)] = [
        (.select, "SELECT"), (.start, "START"),
    ]

    // Крестовина: слева внизу
    var dpadRect: CGRect {
        CGRect(x: 20, y: size.height - 24 - 150, width: 150, height: 150)
    }

    // Кластер ✕○□△: справа внизу, крест на 160×160
    private var faceCenter: CGPoint {
        CGPoint(x: size.width - 20 - 80, y: size.height - 24 - 80)
    }

    func faceRect(_ button: EmulatorInput.Button) -> CGRect {
        let offset: CGPoint = switch button {
        case .triangle: CGPoint(x: 0, y: -52)
        case .cross: CGPoint(x: 0, y: 52)
        case .square: CGPoint(x: -52, y: 0)
        case .circle: CGPoint(x: 52, y: 0)
        default: .zero
        }
        return CGRect(
            x: faceCenter.x + offset.x - 29,
            y: faceCenter.y + offset.y - 29,
            width: 58, height: 58)
    }

    // Шифты: по верхним углам
    func shoulderRect(_ button: EmulatorInput.Button) -> CGRect {
        let y: CGFloat = 12
        return switch button {
        case .l2: CGRect(x: 24, y: y, width: 64, height: 34)
        case .l1: CGRect(x: 96, y: y, width: 64, height: 34)
        case .r1: CGRect(x: size.width - 96 - 64, y: y, width: 64, height: 34)
        case .r2: CGRect(x: size.width - 24 - 64, y: y, width: 64, height: 34)
        default: .zero
        }
    }

    // SELECT/START: над кластером ✕○□△
    func pillRect(_ button: EmulatorInput.Button) -> CGRect {
        let y = faceCenter.y - 80 - 14 - 26
        return switch button {
        case .select: CGRect(x: faceCenter.x - 12 - 74, y: y, width: 74, height: 26)
        case .start: CGRect(x: faceCenter.x + 12, y: y, width: 74, height: 26)
        default: .zero
        }
    }

    /// Какие кнопки зажаты касанием в точке p (зоны шире визуала на 12pt)
    func buttons(at p: CGPoint) -> Set<EmulatorInput.Button> {
        // Крестовина с запасом: направление от центра, 8 позиций
        if dpadRect.insetBy(dx: -16, dy: -16).contains(p) {
            return dpadDirections(at: p)
        }

        for spec in Self.faceButtons where faceRect(spec.button).insetBy(dx: -12, dy: -12).contains(p) {
            return [spec.button]
        }
        for spec in Self.shoulderButtons where shoulderRect(spec.button).insetBy(dx: -12, dy: -12).contains(p) {
            return [spec.button]
        }
        for spec in Self.pillButtons where pillRect(spec.button).insetBy(dx: -10, dy: -10).contains(p) {
            return [spec.button]
        }
        return []
    }

    private func dpadDirections(at p: CGPoint) -> Set<EmulatorInput.Button> {
        let dx = p.x - dpadRect.midX
        let dy = p.y - dpadRect.midY
        guard dx * dx + dy * dy > 100 else { return [] } // мёртвая зона в центре

        let angle = atan2(dy, dx)
        if angle > -.pi * 5 / 8 && angle < -.pi * 3 / 8 { return [.up] }
        if angle >= -.pi * 3 / 8 && angle <= -.pi / 8 { return [.up, .right] }
        if angle > -.pi / 8 && angle < .pi / 8 { return [.right] }
        if angle >= .pi / 8 && angle <= .pi * 3 / 8 { return [.down, .right] }
        if angle > .pi * 3 / 8 && angle < .pi * 5 / 8 { return [.down] }
        if angle >= .pi * 5 / 8 && angle <= .pi * 7 / 8 { return [.down, .left] }
        if angle > -.pi * 7 / 8 && angle < -.pi * 5 / 8 { return [.up, .left] }
        return [.left]
    }
}

// MARK: - UIKit-слой ввода

private struct TouchCaptureView: UIViewRepresentable {
    let layout: TouchLayout
    let onUpdate: (Set<EmulatorInput.Button>) -> Void

    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.layout = layout
        view.onUpdate = onUpdate
        return view
    }

    func updateUIView(_ uiView: TouchCaptureUIView, context: Context) {
        uiView.layout = layout
        uiView.onUpdate = onUpdate
    }
}

final class TouchCaptureUIView: UIView {
    var layout: TouchLayout?
    var onUpdate: ((Set<EmulatorInput.Button>) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute(event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute(event)
    }

    /// Пересобирает полный набор нажатых кнопок из всех активных касаний.
    private func recompute(_ event: UIEvent?) {
        guard let layout, let onUpdate else { return }
        var buttons: Set<EmulatorInput.Button> = []
        for touch in event?.allTouches ?? [] {
            switch touch.phase {
            case .began, .moved, .stationary:
                buttons.formUnion(layout.buttons(at: touch.location(in: self)))
            default:
                break
            }
        }
        onUpdate(buttons)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        TouchControlsView()
    }
}
