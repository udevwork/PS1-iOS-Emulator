import SwiftUI
import UIKit

/// Полноэкранный игровой экран: видео + контролы + пауза-меню.
struct GameScreenView: View {
    let game: Game
    /// Стейт, с которого стартуем (выбран в меню запуска); nil — чистый запуск
    var initialState: URL? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var gamepadManager = GamepadManager.shared

    // Пауза-меню
    @State private var menuVisible = false
    @State private var menuIndex = 0
    @State private var menuEntries: [ConsoleMenuEntry] = []
    @State private var previousMenuHandler: ((GamepadManager.MenuEvent) -> Void)?
    @State private var menuButtonPressed = false

    // Короткое подтверждение «Game Saved» поверх игры
    @State private var toast: Toast?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView()
                .ignoresSafeArea()

            if !gamepadManager.isControllerConnected {
                TouchControlsView()
                    .allowsHitTesting(!menuVisible)
            }

            hud

            ConsoleMenuOverlay(
                visible: menuVisible,
                title: game.displayTitle,
                entries: menuEntries,
                focusIndex: menuIndex,
                showHints: gamepadManager.isControllerConnected,
                onActivate: { index in
                    menuIndex = index
                    menuEntries[index].activate()
                },
                onClose: {
                    UISound.play(.click)
                    closeMenu()
                }
            )
            .allowsHitTesting(menuVisible)

            toastView
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Не отдаём нижний край системному жесту «домой» — иначе iOS
        // придерживает первые касания по нижнему ряду кнопок
        .defersSystemGestures(on: .bottom)
        .onAppear {
            GamepadManager.shared.mode = .game
            GamepadManager.shared.pauseHandler = { openMenu() }
            EmulatorCore.shared.start(gamePath: game.url.path, initialState: initialState)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            EmulatorCore.shared.stop()
            GamepadManager.shared.pauseHandler = nil
            GamepadManager.shared.mode = .menu
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Возвращение в приложение при открытом меню игру не запускает
                if !menuVisible { EmulatorCore.shared.resume() }
            default:
                // Запоминаем точку продолжения и замираем
                EmulatorCore.shared.saveAutoState()
                EmulatorCore.shared.pause()
            }
        }
    }

    // MARK: - HUD (индикатор ×2 + кнопка меню)

    private var hud: some View {
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
                menuButton
            }
            Spacer()
        }
        .padding(.trailing, 8)
        .opacity(menuVisible ? 0 : 1)
        .allowsHitTesting(!menuVisible)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: gamepadManager.isFastForwarding)
        .animation(.easeOut(duration: 0.15), value: menuVisible)
    }

    /// Кнопка паузы на том же голом UIKit-мультитаче, что и контролы:
    /// срабатывает в момент касания, без задержек жестов.
    private var menuButton: some View {
        ZStack {
            Circle().fill(.white.opacity(menuButtonPressed ? 0.28 : 0.08))
            Image(systemName: "pause.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(menuButtonPressed ? 0.95 : 0.5))
        }
        .frame(width: 40, height: 40)
        .scaleEffect(menuButtonPressed ? 0.92 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: menuButtonPressed)
        .frame(width: 52, height: 52)
        .overlay(
            InstantTouchView(
                onDown: { openMenu() },
                onPressChanged: { menuButtonPressed = $0 }
            )
        )
    }

    // MARK: - Тост-подтверждение

    private var toastView: some View {
        VStack {
            if let toast {
                Text(toast.text)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 10)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast)
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            toast = nil
        }
    }

    // MARK: - Пауза-меню: открытие/закрытие

    private func openMenu() {
        guard !menuVisible else { return }
        menuEntries = buildEntries()
        menuIndex = 0
        EmulatorCore.shared.pause()
        previousMenuHandler = GamepadManager.shared.menuHandler
        GamepadManager.shared.mode = .menu
        GamepadManager.shared.menuHandler = { event in
            handleMenuEvent(event)
        }
        UISound.play(.click)
        UIHaptics.action()
        menuVisible = true
    }

    private func closeMenu() {
        guard menuVisible else { return }
        menuVisible = false
        GamepadManager.shared.menuHandler = previousMenuHandler
        previousMenuHandler = nil
        GamepadManager.shared.mode = .game
        EmulatorCore.shared.resume()
    }

    private func handleMenuEvent(_ event: GamepadManager.MenuEvent) {
        guard menuVisible else { return }
        switch event {
        case .up: moveFocus(-1)
        case .down: moveFocus(1)
        case .primary:
            guard menuEntries.indices.contains(menuIndex) else { return }
            menuEntries[menuIndex].activate()
        case .cancel:
            UISound.play(.click)
            closeMenu()
        case .left, .right, .secondary:
            break
        }
    }

    private func moveFocus(_ delta: Int) {
        let target = max(0, min(menuEntries.count - 1, menuIndex + delta))
        guard target != menuIndex else { return }
        menuIndex = target
        UISound.play(.click)
        UIHaptics.move()
    }

    // MARK: - Пункты меню

    private func buildEntries() -> [ConsoleMenuEntry] {
        let manualDate = ConsoleMenuEntry.saveDate(game.saveStateURL)
        let autoDate = ConsoleMenuEntry.saveDate(game.autoStateURL)
        // Превью слотов: у ручного сейва свой скриншот, у автосейва — обложка
        let manualImage = UIImage(contentsOfFile: game.saveImageURL.path)
        let autoImage = UIImage(contentsOfFile: game.coverURL.path)

        var entries: [ConsoleMenuEntry] = [
            ConsoleMenuEntry(
                icon: "play.fill", title: "Continue",
                subtitle: nil, enabled: true
            ) {
                UISound.play(.click)
                closeMenu()
            },
            ConsoleMenuEntry(
                icon: "square.and.arrow.down", title: "Save",
                subtitle: manualDate.map { "Overwrites save · \($0)" } ?? "For the tough spots",
                enabled: true
            ) {
                UISound.play(.confirm)
                let ok = EmulatorCore.shared.saveState(to: game.saveStateURL)
                if ok { EmulatorCore.shared.saveScreenshot(to: game.saveImageURL) }
                closeMenu()
                toast = Toast(text: ok ? "Game Saved" : "Save Failed")
            },
            ConsoleMenuEntry(
                icon: "square.and.arrow.up", title: "Load",
                subtitle: manualDate ?? "No manual save yet",
                enabled: manualDate != nil, image: manualImage
            ) {
                UISound.play(.confirm)
                let ok = EmulatorCore.shared.loadState(from: game.saveStateURL)
                closeMenu()
                toast = Toast(text: ok ? "Save Loaded" : "Load Failed")
            },
            ConsoleMenuEntry(
                icon: "clock.arrow.circlepath", title: "Load Autosave",
                subtitle: autoDate.map { "Where you left off · \($0)" } ?? "No autosave yet",
                enabled: autoDate != nil, image: autoImage
            ) {
                UISound.play(.confirm)
                let ok = EmulatorCore.shared.loadState(from: game.autoStateURL)
                closeMenu()
                toast = Toast(text: ok ? "Autosave Loaded" : "Load Failed")
            },
        ]

        let disks = EmulatorCore.shared.diskInfo()
        if disks.count > 1 {
            entries.append(ConsoleMenuEntry(
                icon: "opticaldisc", title: "Change Disc",
                subtitle: "Disc \(disks.current + 1) of \(disks.count)", enabled: true
            ) {
                UISound.play(.confirm)
                EmulatorCore.shared.switchDisk(to: (disks.current + 1) % disks.count)
                closeMenu()
            })
        }

        entries.append(ConsoleMenuEntry(
            icon: "xmark.circle", title: "Quit Game",
            subtitle: nil, enabled: true, isDestructive: true
        ) {
            UISound.play(.click)
            GamepadManager.shared.menuHandler = previousMenuHandler
            previousMenuHandler = nil
            dismiss()
        })
        return entries
    }
}

private struct Toast: Equatable {
    let id = UUID()
    let text: String
}

// MARK: - Мгновенная UIKit-кнопка

/// Слой на голых touches*, как у TouchCaptureUIView:
/// onDown вызывается в touchesBegan — в тот же момент касания.
private struct InstantTouchView: UIViewRepresentable {
    let onDown: () -> Void
    let onPressChanged: (Bool) -> Void

    func makeUIView(context: Context) -> InstantTouchUIView {
        let view = InstantTouchUIView()
        view.backgroundColor = .clear
        view.onDown = onDown
        view.onPressChanged = onPressChanged
        return view
    }

    func updateUIView(_ uiView: InstantTouchUIView, context: Context) {
        uiView.onDown = onDown
        uiView.onPressChanged = onPressChanged
    }
}

final class InstantTouchUIView: UIView {
    var onDown: (() -> Void)?
    var onPressChanged: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(true)
        TouchHaptics.tap(intensity: 0.7)
        onDown?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(false)
    }
}
