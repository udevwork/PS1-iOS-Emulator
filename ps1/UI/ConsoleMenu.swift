import SwiftUI
import UIKit

/// Общий консольный оверлей-меню: используется и как пауза-меню в игре,
/// и как меню запуска в библиотеке. Чёрный градиент въезжает слева,
/// пункты — вертикальная карусель с фокусом, справа — превью слота.
struct ConsoleMenuEntry: Identifiable {
    let icon: String
    let title: String
    let subtitle: String?
    let enabled: Bool
    var image: UIImage? = nil
    var isDestructive = false
    let perform: () -> Void

    var id: String { title }

    /// Выполнить пункт; выключенный отвечает жёсткой хаптикой
    func activate() {
        guard enabled else {
            UIHaptics.denied()
            return
        }
        UIHaptics.action()
        perform()
    }

    /// Дата сейв-файла для подзаголовков слотов; nil — слота нет
    static func saveDate(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Живёт в иерархии постоянно; появление/уход управляются `visible`.
struct ConsoleMenuOverlay: View {
    let visible: Bool
    let title: String
    let entries: [ConsoleMenuEntry]
    let focusIndex: Int
    let showHints: Bool
    let onActivate: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Затемнение: тьма наползает слева, справа фон остаётся виден
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.95), location: 0),
                    .init(color: .black.opacity(0.88), location: 0.5),
                    .init(color: .black.opacity(0.45), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .offset(x: visible ? 0 : -geo.size.width * 1.6)
                .animation(.spring(response: 0.45, dampingFraction: 0.95), value: visible)

                menuColumn(geo: geo)
                slotPreview(geo: geo)
            }
        }
    }

    /// Квадратик-скриншот слота справа: появляется у пунктов с картинкой
    /// и мягко кроссфейдится при переходе между ними.
    private func slotPreview(geo: GeometryProxy) -> some View {
        let side = min(geo.size.height * 0.55, 280)
        let focused = entries.indices.contains(focusIndex) ? entries[focusIndex] : nil

        return ZStack {
            if visible, let focused, let image = focused.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .id(focused.id) // смена пункта = кроссфейд картинок
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: focusIndex)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 36)
        .allowsHitTesting(false)
    }

    private func menuColumn(geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .reveal(visible, index: 0)

            // Прокрутка следует за фокусом: выбранная строка всегда на экране
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ConsoleMenuRow(entry: entry, focusDistance: abs(index - focusIndex))
                                .id(index)
                                .onTapGesture { onActivate(index) }
                                .reveal(visible, index: index + 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.1),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .onChange(of: focusIndex) { _, newIndex in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            if showHints {
                HStack(spacing: 18) {
                    hint(symbol: "xmark", circleColor: .blue, text: "Select")
                    hint(symbol: "circle", circleColor: .red, text: "Back")
                }
                .padding(.horizontal, 8)
                .reveal(visible, index: entries.count + 1)
            }
        }
        .frame(width: min(geo.size.width * 0.48, 400), alignment: .leading)
        .padding(.leading, 24)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func hint(symbol: String, circleColor: Color, text: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(.white.opacity(0.1))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(circleColor.opacity(0.9))
            }
            .frame(width: 24, height: 24)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private extension View {
    /// Каскадное появление пунктов вслед за градиентом
    func reveal(_ visible: Bool, index: Int) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(x: visible ? 0 : -36)
            .animation(
                .spring(response: 0.38, dampingFraction: 0.85)
                    .delay(visible ? 0.04 + Double(index) * 0.04 : 0),
                value: visible)
    }
}

// MARK: - Строка меню

private struct ConsoleMenuRow: View {
    let entry: ConsoleMenuEntry
    /// 0 — строка в фокусе; чем дальше от фокуса, тем прозрачнее
    let focusDistance: Int

    private var isFocused: Bool { focusDistance == 0 }

    private var distanceOpacity: Double {
        switch focusDistance {
        case 0: 1.0
        case 1: 0.65
        case 2: 0.45
        default: 0.32
        }
    }

    private var titleColor: Color {
        if !entry.enabled { return .white.opacity(0.4) }
        return entry.isDestructive ? .red.opacity(0.9) : .white.opacity(0.92)
    }

    private var iconColor: Color {
        if !entry.enabled { return .white.opacity(0.3) }
        return entry.isDestructive ? .red.opacity(0.7) : .white.opacity(0.6)
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: entry.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(entry.enabled ? 0.42 : 0.25))
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(isFocused ? 0.1 : 0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(
                    isFocused ? .white.opacity(0.9) : .white.opacity(0.08),
                    lineWidth: isFocused ? 2 : 1)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .opacity(distanceOpacity)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focusDistance)
        .contentShape(Rectangle())
    }
}
