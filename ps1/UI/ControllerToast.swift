import SwiftUI

/// Всплывашка «геймпад подключён/отключён» с зарядом.
/// Наблюдает GamepadManager напрямую — достаточно бросить в ZStack экрана.
/// Каждое новое событие (по id) показывается ~2.8 с и само уезжает.
struct ControllerToastHost: View {
    @State private var gamepad = GamepadManager.shared
    @State private var shown: GamepadManager.ControllerEvent?

    var body: some View {
        VStack {
            if let shown {
                ControllerToastView(event: shown)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shown)
        .task(id: gamepad.controllerEvent?.id) {
            guard let event = gamepad.controllerEvent else { return }
            shown = event
            try? await Task.sleep(for: .seconds(2.8))
            shown = nil
        }
    }
}

private struct ControllerToastView: View {
    let event: GamepadManager.ControllerEvent

    private var accent: Color { event.connected ? .green : .orange }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent.opacity(0.9))

            Group {
                if event.connected {
                    Text(verbatim: event.name)
                } else {
                    Text("\(event.name) disconnected")
                }
            }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            if event.connected, let level = event.batteryLevel {
                battery(level: level, charging: event.charging)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.6)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func battery(level: Float, charging: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol(level: level, charging: charging))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(level <= 0.15 && !charging ? .red.opacity(0.9) : .white.opacity(0.7))
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.leading, 2)
    }

    private func batterySymbol(level: Float, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<0.1: return "battery.0"
        case ..<0.375: return "battery.25"
        case ..<0.625: return "battery.50"
        case ..<0.875: return "battery.75"
        default: return "battery.100"
        }
    }
}
