import SwiftUI

/// Полноэкранный игровой экран: видео + контролы + меню.
struct GameScreenView: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var gamepadManager = GamepadManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView()
                .ignoresSafeArea()

            if !gamepadManager.isControllerConnected {
                TouchControlsView()
            }

            VStack {
                HStack {
                    if gamepadManager.isFastForwarding {
                        HStack(spacing: 5) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text("×2")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(.leading, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    Spacer()
                    menu
                }
                Spacer()
            }
            .padding(.trailing, 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: gamepadManager.isFastForwarding)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Не отдаём нижний край системному жесту «домой» — иначе iOS
        // придерживает первые касания по нижнему ряду кнопок
        .defersSystemGestures(on: .bottom)
        .onAppear {
            GamepadManager.shared.mode = .game
            EmulatorCore.shared.start(gamePath: game.url.path)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            EmulatorCore.shared.stop()
            GamepadManager.shared.mode = .menu
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                EmulatorCore.shared.resume()
            default:
                // Запоминаем точку продолжения и замираем
                EmulatorCore.shared.saveAutoState()
                EmulatorCore.shared.pause()
            }
        }
    }

    private var menu: some View {
        Menu {
            Button {
                _ = EmulatorCore.shared.saveState(to: game.saveStateURL)
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }

            Button {
                _ = EmulatorCore.shared.loadState(from: game.saveStateURL)
            } label: {
                Label("Загрузить", systemImage: "square.and.arrow.up")
            }
            .disabled(!FileManager.default.fileExists(atPath: game.saveStateURL.path))

            Button {
                EmulatorCore.shared.reset()
            } label: {
                Label("Начать заново", systemImage: "arrow.counterclockwise")
            }

            let disks = EmulatorCore.shared.diskInfo()
            if disks.count > 1 {
                Menu {
                    ForEach(0..<disks.count, id: \.self) { index in
                        Button {
                            EmulatorCore.shared.switchDisk(to: index)
                        } label: {
                            if index == disks.current {
                                Label("Диск \(index + 1)", systemImage: "checkmark")
                            } else {
                                Text("Диск \(index + 1)")
                            }
                        }
                        .disabled(index == disks.current)
                    }
                } label: {
                    Label("Сменить диск", systemImage: "opticaldisc")
                }
            }

            Divider()

            Button(role: .destructive) {
                dismiss()
            } label: {
                Label("Выйти из игры", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }
}
