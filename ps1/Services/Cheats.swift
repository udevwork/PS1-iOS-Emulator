import Foundation

/// Один чит: GameShark/Action Replay-код с именем и переключателем.
/// nonisolated + Sendable — уезжает в EmulatorCore на эмуляционный поток.
nonisolated struct Cheat: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var code: String
    var enabled: Bool
}

/// Хранение читов рядом с сейвами: `<игра>.cheats.json`.
nonisolated enum CheatStore {
    static func load(for game: Game) -> [Cheat] {
        guard let data = try? Data(contentsOf: game.cheatsURL),
              let cheats = try? JSONDecoder().decode([Cheat].self, from: data) else { return [] }
        return cheats
    }

    static func save(_ cheats: [Cheat], for game: Game) {
        if cheats.isEmpty {
            try? FileManager.default.removeItem(at: game.cheatsURL)
            return
        }
        guard let data = try? JSONEncoder().encode(cheats) else { return }
        try? data.write(to: game.cheatsURL)
    }
}
