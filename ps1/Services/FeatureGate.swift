import Foundation

/// Триал 5 игровых часов → дальше Pro-фичи по подписке.
/// Читается из любых потоков (эмуляция, рендер), поэтому только UserDefaults
/// и никакой связи с @Observable-мирами.
enum FeatureGate {

    static let trialSeconds: Double = 5 * 3600

    private static let playtimeKey = "totalPlaySeconds"
    static let subscribedCacheKey = "isSubscribedCache"

    /// Живой статус: подписка активна или триал ещё не сожжён
    static var isPro: Bool {
        UserDefaults.standard.bool(forKey: subscribedCacheKey) || trialRemaining > 0
    }

    static var totalPlaySeconds: Double {
        UserDefaults.standard.double(forKey: playtimeKey)
    }

    static var trialRemaining: Double {
        max(0, trialSeconds - totalPlaySeconds)
    }

    /// Статус на текущую игровую сессию: фиксируется при старте игры,
    /// чтобы истёкший посреди сессии триал не переключал картинку на лету.
    nonisolated(unsafe) private(set) static var sessionIsPro = false

    static func beginSession() {
        sessionIsPro = isPro
    }

    /// Вызывается эмуляционным потоком (~раз в 5 секунд и при выходе из игры)
    static func addPlaytime(_ seconds: Double) {
        guard seconds > 0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.double(forKey: playtimeKey) + seconds, forKey: playtimeKey)
    }
}
