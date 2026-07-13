import AVFoundation
import UIKit

/// Хаптик-отклик UI. Генераторы переиспользуются и держатся готовыми
/// через prepare() — отклик сильнее и без задержки первого срабатывания.
/// Настройка «Haptic Feedback» выключает вибрацию во всём приложении.
enum UIHaptics {
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "touchHaptics") as? Bool) ?? true
    }

    /// Перемещение фокуса: карусель, строки меню и настроек
    static func move() {
        guard enabled else { return }
        medium.impactOccurred(intensity: 0.8)
        medium.prepare()
    }

    /// Действие: выбор пункта, тоггл, открытие меню, запуск игры
    static func action() {
        guard enabled else { return }
        heavy.impactOccurred(intensity: 0.9)
        heavy.prepare()
    }

    /// Отказ: выключенный пункт меню
    static func denied() {
        guard enabled else { return }
        rigid.impactOccurred(intensity: 0.7)
        rigid.prepare()
    }
}

/// Консольные UI-звуки меню. Категория .ambient — уважает беззвучный режим
/// и не глушит фоновую музыку пользователя.
final class UISound {

    static let shared = UISound()

    enum Sound: String, CaseIterable {
        case startup = "Startup" // запуск приложения
        case confirm = "Confirm" // выбор игры
        case click = "Click"     // перемещение по меню
    }

    private var players: [Sound: AVAudioPlayer] = [:]

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        for sound in Sound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[sound] = player
        }
    }

    static func play(_ sound: Sound) {
        guard let player = shared.players[sound] else { return }
        // Перезапуск с нуля: при быстром листании (key-repeat) звук не заикается
        player.currentTime = 0
        player.play()
    }
}
