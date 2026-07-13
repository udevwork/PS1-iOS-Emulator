import Foundation

/// Подгрузка бокс-артов из TheGamesDB.
/// Не заменяет скриншоты из авто-сейвов (EmulatorCore.saveCover) — бокс-арт
/// сохраняется отдельным файлом и имеет приоритет только при отрисовке.
enum BoxartFetcher {

    // Ключ бесплатного тарифа TheGamesDB (~3000 запросов/мес).
    // Репозиторий публичный — ключ тоже; при злоупотреблениях перевыпустить.
    private static let apiKey = "def9fc48ef16b21cb5634996451cbffa65cb7face1b98d53c095a60adb9b3330"
    private static let ps1PlatformID = 10 // «Sony Playstation»
    private static let attemptedKey = "boxartAttemptedGames"

    enum FetchError: LocalizedError {
        /// Сервер ответил не 200: код + начало тела (там причина от TheGamesDB)
        case http(Int, String?)
        /// Запрос прошёл, но игры/арта в базе нет
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                "TheGamesDB HTTP \(code)" + (body.map { "\n\($0)" } ?? "")
            case .notFound(let title):
                "No box art found for “\(title)”"
            }
        }
    }

    /// Забыть, что для этих файлов уже искали арт: файл переимпортировали
    /// или удалили — при следующем появлении ищем заново.
    static func forgetAttempts(_ ids: [String]) {
        var attempted = Set(UserDefaults.standard.stringArray(forKey: attemptedKey) ?? [])
        attempted.subtract(ids)
        UserDefaults.standard.set(Array(attempted), forKey: attemptedKey)
    }

    /// Догружает недостающие обложки (Pro). Возвращает true, если что-то скачалось.
    static func fetchMissing(for games: [Game]) async -> Bool {
        guard FeatureGate.isPro else { return false }
        var attempted = Set(UserDefaults.standard.stringArray(forKey: attemptedKey) ?? [])
        var downloadedAny = false

        for game in games {
            guard !FileManager.default.fileExists(atPath: game.boxartURL.path),
                  !attempted.contains(game.id) else { continue }
            do {
                if let imageData = try await searchBoxart(title: game.searchTitle) {
                    try imageData.write(to: game.boxartURL)
                    downloadedAny = true
                }
                // Нашли или игры нет в базе — в любом случае больше не спрашиваем
                attempted.insert(game.id)
                UserDefaults.standard.set(Array(attempted), forKey: attemptedKey)
            } catch {
                // Сеть недоступна — попробуем при следующем открытии библиотеки
            }
        }
        return downloadedAny
    }

    /// Принудительная загрузка обложки одной игры (из контекстного меню).
    /// Не молчит: любая причина неудачи вылетает ошибкой с подробностями.
    static func fetchNow(for game: Game) async throws {
        guard let imageData = try await searchBoxart(title: game.searchTitle) else {
            throw FetchError.notFound(game.searchTitle)
        }
        try imageData.write(to: game.boxartURL)
    }

    private static func searchBoxart(title: String) async throws -> Data? {
        var components = URLComponents(string: "https://api.thegamesdb.net/v1/Games/ByGameName")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "filter[platform]", value: String(ps1PlatformID)),
            URLQueryItem(name: "include", value: "boxart"),
        ]

        let (data, urlResponse) = try await URLSession.shared.data(from: components.url!)
        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(200), encoding: .utf8)
            throw FetchError.http(http.statusCode, body)
        }
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)

        // Первый результат поиска; у него — фронтальная сторона коробки
        guard let game = response.data.games.first,
              let arts = response.include?.boxart?.data?[String(game.id)],
              let art = arts.first(where: { $0.side == "front" }) ?? arts.first,
              let baseURL = response.include?.boxart?.baseURL?.best,
              let imageURL = URL(string: baseURL + art.filename) else { return nil }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        return imageData
    }

    // MARK: - Формат ответа TheGamesDB

    private struct SearchResponse: Decodable {
        let data: GamesData
        let include: Include?

        struct GamesData: Decodable {
            let games: [GameEntry]
        }
        struct GameEntry: Decodable {
            let id: Int
        }
        struct Include: Decodable {
            let boxart: Boxart?
        }
        struct Boxart: Decodable {
            let baseURL: BaseURL?
            let data: [String: [Art]]?

            enum CodingKeys: String, CodingKey {
                case baseURL = "base_url"
                case data
            }
        }
        struct BaseURL: Decodable {
            let large: String?
            let medium: String?
            let original: String?

            /// large хватает для карточек, original — избыточен по весу
            var best: String? { large ?? medium ?? original }
        }
        struct Art: Decodable {
            let side: String?
            let filename: String
        }
    }
}
