import UIKit

/// Иконки приложения для выбора в настройках.
/// Наборы объявлены в ассетах (AppIcon + Crane/Fuji/Kanagawa/Sakura) и в
/// build settings (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES). Порядок
/// кейсов = порядок перелистывания в селекторе.
enum AppIcon: String, CaseIterable, Identifiable {
    case standard, crane, fuji, kanagawa, sakura

    var id: String { rawValue }

    /// Имя набора для `setAlternateIconName`; nil — основная иконка
    var alternateName: String? {
        self == .standard ? nil : rawValue.capitalized // "Crane", "Fuji"…
    }

    /// Обычный imageset с превью для селектора (не app-icon-набор)
    var previewAsset: String {
        "IconPreview" + rawValue.capitalized // "IconPreviewStandard"…
    }

    /// Подпись в селекторе. Японские названия — имена собственные, не переводим
    var title: String {
        switch self {
        case .standard: String(localized: "Classic")
        case .crane:    "Crane"
        case .fuji:     "Fuji"
        case .kanagawa: "Kanagawa"
        case .sakura:   "Sakura"
        }
    }
}

/// Смена иконки приложения на лету через alternate app icons (iOS 10.3+).
/// iOS при смене показывает свой системный алерт «You have changed the icon…»
/// — отключить его публичным API нельзя, это поведение платформы.
@MainActor
enum IconManager {
    /// Поддерживает ли устройство смену иконки (на iPad в Slide Over — нет)
    static var isSupported: Bool { UIApplication.shared.supportsAlternateIcons }

    /// Текущая иконка — источник истины сама система, переживает перезапуск
    static var current: AppIcon {
        let name = UIApplication.shared.alternateIconName
        return AppIcon.allCases.first { $0.alternateName == name } ?? .standard
    }

    /// Сменить иконку. No-op, если нужная уже стоит — иначе лишний системный алерт
    static func set(_ icon: AppIcon) {
        guard isSupported, current != icon else { return }
        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            if let error {
                print("setAlternateIconName(\(icon.alternateName ?? "nil")) failed: \(error.localizedDescription)")
            }
        }
    }
}
