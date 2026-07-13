import SwiftUI
import UniformTypeIdentifiers

struct Game: Identifiable, Hashable {
    let url: URL

    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }

    var saveStateURL: URL {
        EmulatorCore.saveDirectory
            .appendingPathComponent(url.lastPathComponent)
            .appendingPathExtension("state")
    }

    /// Скриншот из авто-сейва (пишет EmulatorCore.saveCover)
    var coverURL: URL {
        EmulatorCore.saveDirectory
            .appendingPathComponent(url.lastPathComponent)
            .appendingPathExtension("cover.png")
    }

    /// Бокс-арт из TheGamesDB (качает BoxartFetcher)
    var boxartURL: URL {
        EmulatorCore.saveDirectory
            .appendingPathComponent(url.lastPathComponent)
            .appendingPathExtension("boxart.jpg")
    }

    /// Что показывать на карточке: бокс-арт (Pro), иначе скриншот из сейва
    var displayCoverPath: String {
        if FeatureGate.isPro && FileManager.default.fileExists(atPath: boxartURL.path) {
            return boxartURL.path
        }
        return coverURL.path
    }

    /// Есть точка продолжения — на карточке показываем «Продолжить»
    var hasResumePoint: Bool {
        let autoState = EmulatorCore.saveDirectory
            .appendingPathComponent(url.lastPathComponent)
            .appendingPathExtension("auto.state")
        return FileManager.default.fileExists(atPath: autoState.path)
    }

    /// Имя для поиска в базе обложек: без региональных тегов «(USA) [!]» и т.п.
    var searchTitle: String {
        title
            .replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Библиотека в стиле консольного дашборда: горизонтальная карусель
/// со смещённым влево фокусом. Геймпад двигает ленту, не курсор.
struct GameLibraryView: View {
    @State private var games: [Game] = []
    @State private var selectedIndex = 0
    @State private var selectedGame: Game?
    @State private var showImporter = false
    @State private var importError: String?
    @State private var gamepadManager = GamepadManager.shared
    @State private var subscriptionManager = SubscriptionManager.shared
    @State private var showPaywall = false

    // Вертикальная «карусель» страниц: библиотека — верхний элемент, настройки — под ней
    private enum Page { case library, settings }
    @State private var page: Page = .library
    @State private var settingsIndex = 0

    @AppStorage("renderEnhanced") private var renderEnhanced = true
    @AppStorage("stretchFill") private var stretchFill = false
    @AppStorage("videoSmoothing") private var videoSmoothing = true
    @AppStorage("touchHaptics") private var touchHaptics = true
    @AppStorage("autoResume") private var autoResume = true

    static let gamesDirectory: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Расширения образов, которые запускаются (треки .bin с .cue не показываем)
    private static let playableExtensions: Set<String> = ["m3u", "chd", "cue", "pbp", "iso", "img", "bin"]

    /// «Game (Disc 2).chd» → база «Game», номер 2. Понимает Disc/Disk/CD
    private static let discRegex = /^(.+?)[\s._-]*[(\[]?(?:disc|disk|cd)[\s._-]*(\d+)[)\]]?/
        .ignoresCase()

    private var selectedCover: UIImage? {
        guard games.indices.contains(selectedIndex) else { return nil }
        return UIImage(contentsOfFile: games[selectedIndex].displayCoverPath)
    }

    var body: some View {
        GeometryReader { geo in
            let cardSize = Self.cardSize(for: geo)
            // Единый левый отступ («линейка») для хедера, карусели,
            // футера и настроек — всегда от края safe area
            let anchorX = Self.contentInset(for: geo)

            VStack(spacing: 0) {
                libraryPage(cardSize: cardSize, anchorX: anchorX, pageSize: geo.size)
                settingsPage(anchorX: anchorX)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .offset(y: page == .library ? 0 : -geo.size.height)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: page)
        }
        // Фон именно через .background: он получает размер контента и сам
        // на layout не влияет — картинка в ZStack раздувала весь экран
        .background(background)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .fullScreenCover(item: $selectedGame, onDismiss: {
            GamepadManager.shared.mode = .menu
            reloadGames()
        }) { game in
            GameScreenView(game: game)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .alert("Import Failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            installBundledGameIfNeeded()
            reloadGames()
            fetchBoxarts()
            GamepadManager.shared.mode = .menu
            GamepadManager.shared.menuHandler = { event in
                handleMenuEvent(event)
            }
        }
        // Ядро перечитывает свои опции между кадрами — даже посреди игры
        .onChange(of: renderEnhanced) {
            EmulatorCore.shared.setVariablesUpdated()
        }
        // «Открыть в ps1» из Files, Safari или share sheet
        .onOpenURL { url in
            importFile(from: url)
            reloadGames()
            fetchBoxarts()
        }
    }

    // MARK: - Фон

    private var background: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.09)

            if let cover = selectedCover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 70)
                    .opacity(0.35)
                    .transition(.opacity)
                    .id(selectedIndex) // форсируем кроссфейд при смене игры
            }

            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeOut(duration: 0.4), value: selectedIndex)
        .ignoresSafeArea()
    }

    // MARK: - Бюджет высоты
    //
    // Альбомная ориентация, всё считаем явно от высоты safe area:
    //   header (64) + карусель (остаток) + инфо-футер (86) = высота экрана.
    // Карточка выводится из остатка с запасом 1.16 — под увеличение
    // выбранной (×1.13) и тень, чтобы ничего не выталкивало соседей.

    private static let headerHeight: CGFloat = 64
    private static let infoHeight: CGFloat = 86
    private static let cardSpacing: CGFloat = 24

    private static func cardSize(for geo: GeometryProxy) -> CGFloat {
        let carouselArea = geo.size.height - headerHeight - infoHeight
        return min((carouselArea - 20) / 1.16, 240)
    }

    /// Левый отступ контента от safe area — одинаковый для всех страниц.
    /// GeometryReader уже работает внутри safe area, ничего доп. не прибавляем.
    private static func contentInset(for geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.1, 96)
    }

    // MARK: - Страница «Библиотека»

    private func libraryPage(cardSize: CGFloat, anchorX: CGFloat, pageSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, anchorX)
                .frame(height: Self.headerHeight)

            if games.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                carousel(cardSize: cardSize, spacing: Self.cardSpacing, anchorX: anchorX)
                    .frame(maxHeight: .infinity)

                selectedGameInfo
                    .padding(.horizontal, anchorX)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.infoHeight, alignment: .top)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    // MARK: - Страница «Настройки»

    private var settingsToggles: [(icon: String, title: String, subtitle: String, binding: Binding<Bool>, pro: Bool)] {
        [
            ("sparkles.tv", "Enhanced Resolution",
             "3D games render at double internal resolution (×2)", $renderEnhanced, true),
            ("arrow.up.left.and.arrow.down.right", "Full Screen",
             "Stretch the picture, sacrificing the 4:3 aspect", $stretchFill, true),
            ("wand.and.stars", "Picture Smoothing",
             "Soft filtering instead of raw pixels", $videoSmoothing, true),
            ("iphone.radiowaves.left.and.right", "Touch Button Haptics",
             "Vibration feedback for on-screen controls", $touchHaptics, false),
            ("memories", "Resume Where You Left Off",
             "Jump back in at the exact same spot", $autoResume, false),
        ]
    }

    /// Заперта ли Pro-строка: подписки нет и пробные 10 часов сожжены
    private func isRowLocked(_ pro: Bool) -> Bool {
        pro && !subscriptionManager.isSubscribed && FeatureGate.trialRemaining <= 0
    }

    private func settingsPage(anchorX: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                Text("Settings")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if gamepadManager.isControllerConnected {
                    hint(symbol: "xmark", circleColor: .blue, text: "Toggle")
                    hint(symbol: "chevron.up", circleColor: .gray, text: "Back")
                }
                Button {
                    page = .library
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }
            .frame(height: Self.headerHeight)

            // Прокрутка следует за фокусом: выбранная строка всегда на экране
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(settingsToggles.enumerated()), id: \.offset) { index, row in
                            SettingRow(
                                icon: row.icon,
                                title: row.title,
                                subtitle: row.subtitle,
                                isOn: row.binding,
                                focusDistance: abs(index - settingsIndex),
                                isLocked: isRowLocked(row.pro)
                            )
                            .id(index)
                            .onTapGesture {
                                settingsIndex = index
                                if isRowLocked(row.pro) {
                                    showPaywall = true
                                } else {
                                    row.binding.wrappedValue.toggle()
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.7)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: 576, alignment: .leading)
                // Строки не обрезаются рамкой скролла, а уезжают за экран,
                // растворяясь в градиентной маске по верхнему и нижнему краю
                .scrollClipDisabled()
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .onChange(of: settingsIndex) { _, newIndex in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, anchorX)
    }

    private var header: some View {
        HStack(spacing: 24) {
            Text("PS1")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text("\(games.count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 4)

            Spacer()

            if gamepadManager.isControllerConnected {
                hint(symbol: "xmark", circleColor: .blue, text: "Play")
                hint(symbol: "triangle", circleColor: .green, text: "Add")
            }

            if !subscriptionManager.isSubscribed {
                Button {
                    showPaywall = true
                } label: {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.yellow.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
            }

            Button {
                showImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
        }
    }

    private func carousel(cardSize: CGFloat, spacing: CGFloat, anchorX: CGFloat) -> some View {
        // Лента живёт в overlay и не участвует в layout: её полная ширина
        // (все карточки разом) шире экрана, и любой честный контейнер
        // от этого центрируется со сдвигом, утаскивая хедер и футер влево
        Color.clear
            .overlay(alignment: .leading) {
                HStack(spacing: spacing) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        GameCardView(game: game, isSelected: index == selectedIndex, size: cardSize)
                            .onTapGesture {
                                if index == selectedIndex {
                                    launchSelected()
                                } else {
                                    select(index)
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteGame(game)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .offset(x: anchorX - CGFloat(selectedIndex) * (cardSize + spacing))
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: selectedIndex)
            }
            .contentShape(Rectangle())
            .gesture(
            DragGesture()
                .onEnded { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        // Вертикальный свайп вверх открывает настройки
                        if value.translation.height < -50 {
                            openSettings()
                        }
                    } else {
                        // Горизонтальный двигает ленту так же, как геймпад
                        let threshold: CGFloat = 40
                        if value.translation.width < -threshold {
                            select(selectedIndex + 1)
                        } else if value.translation.width > threshold {
                            select(selectedIndex - 1)
                        }
                    }
                }
        )
    }

    private var selectedGameInfo: some View {
        Group {
            if games.indices.contains(selectedIndex) {
                let game = games[selectedIndex]
                VStack(alignment: .leading, spacing: 5) {
                    Spacer().frame(height: 16)
                    Text(game.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(game.url.pathExtension.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.1)))
                        if game.hasResumePoint {
                            Text("Continue")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: selectedIndex)
    }

    private func hint(symbol: String, circleColor: Color, text: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.1))
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

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.25))
            Text("No Games")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text("Add a disc image — .chd, .cue + .bin, or .pbp")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Button {
                showImporter = true
            } label: {
                Text("Add Game")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Действия

    private func handleMenuEvent(_ event: GamepadManager.MenuEvent) {
        // Пока пейвол открыт, геймпад не должен листать библиотеку под ним
        guard !showPaywall else { return }
        switch (page, event) {
        case (.library, .left): select(selectedIndex - 1)
        case (.library, .right): select(selectedIndex + 1)
        case (.library, .down): openSettings()
        case (.library, .primary): launchSelected()
        case (.library, .secondary): showImporter = true
        case (.library, .up): break

        case (.settings, .up):
            if settingsIndex == 0 {
                page = .library
            } else {
                settingsIndex -= 1
            }
            UISound.play(.click)
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        case (.settings, .down):
            guard settingsIndex < settingsToggles.count - 1 else { break }
            settingsIndex += 1
            UISound.play(.click)
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        case (.settings, .primary):
            if isRowLocked(settingsToggles[settingsIndex].pro) {
                showPaywall = true
            } else {
                settingsToggles[settingsIndex].binding.wrappedValue.toggle()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.7)
            }
        case (.settings, .left), (.settings, .right), (.settings, .secondary):
            break
        }
    }

    private func openSettings() {
        settingsIndex = 0
        page = .settings
        UISound.play(.click)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }

    private func select(_ index: Int) {
        let clamped = max(0, min(games.count - 1, index))
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        UISound.play(.click)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }

    private func launchSelected() {
        guard games.indices.contains(selectedIndex) else { return }
        UISound.play(.confirm)
        selectedGame = games[selectedIndex]
    }

    // MARK: - Импорт и файлы

    private func reloadGames() {
        var files = (try? FileManager.default.contentsOfDirectory(
            at: Self.gamesDirectory, includingPropertiesForKeys: nil)) ?? []

        // Многодисковые игры склеиваем в .m3u-плейлисты автоматически
        if generateMultiDiscPlaylists(files: files) {
            files = (try? FileManager.default.contentsOfDirectory(
                at: Self.gamesDirectory, includingPropertiesForKeys: nil)) ?? []
        }

        let cueBaseNames = Set(files.filter { $0.pathExtension.lowercased() == "cue" }
            .map { $0.deletingPathExtension().lastPathComponent })

        // Диски, входящие в плейлисты, отдельными карточками не показываем
        let insidePlaylists = filesReferencedByPlaylists(files: files)

        games = files
            .filter { Self.playableExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !insidePlaylists.contains($0.lastPathComponent) }
            .filter { url in
                // .bin/.img прячем, если рядом лежит их .cue
                let ext = url.pathExtension.lowercased()
                guard ext == "bin" || ext == "img" else { return true }
                return !cueBaseNames.contains(url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Game(url: $0) }

        selectedIndex = max(0, min(games.count - 1, selectedIndex))
    }

    /// Находит группы «(Disc 1) / (Disc 2)…» и пишет для них .m3u.
    /// Возвращает true, если что-то создалось или обновилось.
    @discardableResult
    private func generateMultiDiscPlaylists(files: [URL]) -> Bool {
        let discExtensions: Set<String> = ["cue", "chd", "pbp", "iso", "img"]
        var groups: [String: [(number: Int, url: URL)]] = [:]

        for url in files where discExtensions.contains(url.pathExtension.lowercased()) {
            let name = url.deletingPathExtension().lastPathComponent
            guard let match = try? Self.discRegex.firstMatch(in: name),
                  let number = Int(match.output.2) else { continue }
            let base = String(match.output.1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_.(["))
            guard !base.isEmpty else { continue }
            groups[base, default: []].append((number, url))
        }

        var changed = false
        for (base, discs) in groups where discs.count > 1 {
            let content = discs.sorted { $0.number < $1.number }
                .map(\.url.lastPathComponent)
                .joined(separator: "\n") + "\n"
            let playlistURL = Self.gamesDirectory
                .appendingPathComponent(base).appendingPathExtension("m3u")
            if (try? String(contentsOf: playlistURL, encoding: .utf8)) != content {
                try? content.write(to: playlistURL, atomically: true, encoding: .utf8)
                changed = true
            }
        }
        return changed
    }

    private func filesReferencedByPlaylists(files: [URL]) -> Set<String> {
        var referenced: Set<String> = []
        for url in files where url.pathExtension.lowercased() == "m3u" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: \.isNewline) {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !name.hasPrefix("#") {
                    referenced.insert(name)
                }
            }
        }
        return referenced
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            urls.forEach(importFile)
            reloadGames()
            fetchBoxarts()
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Предустановленная хоумбрю-игра (Loonies 8192, thp.io) — библиотека
    /// не пустая с первого запуска, и ревьюеру Apple есть что запустить.
    /// Ставится один раз: если пользователь удалил — не воскресает.
    private func installBundledGameIfNeeded() {
        let installedFlag = "bundledLooniesInstalled"
        guard !UserDefaults.standard.bool(forKey: installedFlag) else { return }
        UserDefaults.standard.set(true, forKey: installedFlag)

        guard let cue = Bundle.main.url(forResource: "Loonies 8192", withExtension: "cue"),
              let bin = Bundle.main.url(forResource: "Loonies 8192", withExtension: "bin") else { return }
        try? FileManager.default.copyItem(
            at: cue, to: Self.gamesDirectory.appendingPathComponent("Loonies 8192.cue"))
        try? FileManager.default.copyItem(
            at: bin, to: Self.gamesDirectory.appendingPathComponent("Loonies 8192.bin"))

        // Обложка от автора — предзасеваем как бокс-арт, чтобы карточка
        // была красивой сразу, без похода в TheGamesDB
        if let art = Bundle.main.url(forResource: "Loonies 8192 Cover", withExtension: "png") {
            let boxart = EmulatorCore.saveDirectory
                .appendingPathComponent("Loonies 8192.cue")
                .appendingPathExtension("boxart.jpg")
            try? FileManager.default.copyItem(at: art, to: boxart)
        }
    }

    /// Тихо докачивает недостающие бокс-арты и обновляет карусель
    private func fetchBoxarts() {
        let snapshot = games
        Task {
            if await BoxartFetcher.fetchMissing(for: snapshot) {
                reloadGames()
            }
        }
    }

    /// Копирует образ в песочницу приложения (Documents/Games).
    /// Оригинал после этого приложению не нужен.
    private func importFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let destination = Self.gamesDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func deleteGame(_ game: Game) {
        // Для плейлиста удаляем и все его диски (вместе с их .bin-треками)
        if game.url.pathExtension.lowercased() == "m3u",
           let content = try? String(contentsOf: game.url, encoding: .utf8) {
            let allFiles = (try? FileManager.default.contentsOfDirectory(
                at: Self.gamesDirectory, includingPropertiesForKeys: nil)) ?? []
            for line in content.split(whereSeparator: \.isNewline) {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let discURL = Self.gamesDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: discURL)
                // .bin-треки, принадлежащие удаляемому .cue
                let baseName = discURL.deletingPathExtension().lastPathComponent
                for file in allFiles where
                    file.deletingPathExtension().lastPathComponent == baseName &&
                    ["bin", "img"].contains(file.pathExtension.lowercased()) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        try? FileManager.default.removeItem(at: game.url)
        try? FileManager.default.removeItem(at: game.coverURL)
        try? FileManager.default.removeItem(at: game.boxartURL)
        try? FileManager.default.removeItem(at: game.saveStateURL)
        reloadGames()
    }
}

// MARK: - Строка настройки

private struct SettingRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    /// 0 — строка в фокусе; чем дальше от фокуса, тем прозрачнее
    let focusDistance: Int
    /// Pro-фича при истёкшем триале: вместо тумблера — замок, тап ведёт на пейвол
    let isLocked: Bool

    private var isFocused: Bool { focusDistance == 0 }

    private var distanceOpacity: Double {
        switch focusDistance {
        case 0: 1.0
        case 1: 0.6
        case 2: 0.42
        default: 0.3
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 20)

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.8))
                    .frame(width: 44, height: 26)
                    .background(Capsule().fill(.white.opacity(0.08)))
            } else {
                toggle
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(isFocused ? 0.1 : 0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isFocused ? .white.opacity(0.9) : .white.opacity(0.08),
                    lineWidth: isFocused ? 2 : 1)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .opacity(distanceOpacity)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focusDistance)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }

    private var toggle: some View {
        Capsule()
            .fill(isOn ? Color.blue.opacity(0.85) : .white.opacity(0.14))
            .frame(width: 44, height: 26)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
    }
}

// MARK: - Карточка игры

private struct GameCardView: View {
    let game: Game
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        let cover = UIImage(contentsOfFile: game.displayCoverPath)

        ZStack {
            // Свечение: заблюренный дубль арта позади карточки.
            // Сначала обрезаем в форму карточки, потом блюрим — ореол
            // получается симметричным независимо от пропорций обложки
            if isSelected, let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .blur(radius: 24)
                    .opacity(0.75)
                    .scaleEffect(1.07)
            }

            Group {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        isSelected ? .white.opacity(0.95) : .white.opacity(0.12),
                        lineWidth: isSelected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
        }
        .scaleEffect(isSelected ? 1.13 : 0.92)
        .opacity(isSelected ? 1 : 0.55)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isSelected)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.16, blue: 0.24), Color(red: 0.09, green: 0.09, blue: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.25))
                Text(game.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    GameLibraryView()
}
