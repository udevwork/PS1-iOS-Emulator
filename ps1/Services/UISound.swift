import AVFoundation

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
