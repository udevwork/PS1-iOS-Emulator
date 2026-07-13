import Foundation
import QuartzCore
import UIKit

/// Обёртка над libretro-ядром PCSX-ReARMed (статически слинковано).
/// Ядро однопоточное: все retro_* вызовы делаются только с эмуляционного потока.
nonisolated final class EmulatorCore: @unchecked Sendable {

    nonisolated(unsafe) static let shared = EmulatorCore()

    enum State { case stopped, running, paused }

    private(set) var state: State = .stopped
    private var thread: Thread?
    private let stateLock = NSLock()

    // Видеокадр, который забирает Metal-рендерер
    let videoBuffer = VideoFrameBuffer()
    let audio = EmulatorAudio()
    let input = EmulatorInput()

    private var gamePath: String?
    private var fps: Double = 60.0
    private var resumeFromAutoState = true
    private var _fastForward = false

    /// Ускорение ×2 (курок на геймпаде). Читается тактовщиком каждый кадр.
    var fastForward: Bool {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return _fastForward
        }
        set {
            stateLock.lock()
            _fastForward = newValue
            stateLock.unlock()
        }
    }

    // Работа, которую нужно выполнить на эмуляционном потоке между кадрами
    private let workLock = NSLock()
    private var pendingWork: [() -> Void] = []
    private var acceptingWork = false

    // C-строки для environment-колбэков — должны жить всё время работы ядра
    private var systemDirCString: UnsafeMutablePointer<CChar>?
    private var saveDirCString: UnsafeMutablePointer<CChar>?

    // Трансляция настроек приложения в core options (GET_VARIABLE)
    private let variablesLock = NSLock()
    private var variablesUpdated = false
    // Стабильные C-строки значений; читается только с эмуляционного потока
    private var cStringCache: [String: UnsafeMutablePointer<CChar>] = [:]

    // Смена дисков: колбэки ядра, зарегистрированные при загрузке игры.
    // Пишется и читается только на эмуляционном потоке (env callback / performSync)
    private var diskControl: retro_disk_control_ext_callback?

    static let systemDirectory: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("System", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let saveDirectory: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        systemDirCString = strdup(Self.systemDirectory.path)
        saveDirCString = strdup(Self.saveDirectory.path)
    }

    // MARK: - Управление

    func start(gamePath: String, resume: Bool = true) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard state == .stopped else { return }
        self.gamePath = gamePath
        // Pro-статус фиксируется на всю сессию: истёкший посреди игры триал
        // не должен переключать качество на лету
        FeatureGate.beginSession()
        // Настройка «Продолжать с места выхода» может отключить автовозобновление
        let autoResumeEnabled = (UserDefaults.standard.object(forKey: "autoResume") as? Bool) ?? true
        self.resumeFromAutoState = resume && autoResumeEnabled
        workLock.lock()
        acceptingWork = true
        workLock.unlock()
        state = .running

        let thread = Thread { [weak self] in self?.emulationLoop() }
        thread.name = "EmulationThread"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        stateLock.lock()
        guard state != .stopped else { stateLock.unlock(); return }
        state = .stopped
        stateLock.unlock()
        // Поток сам увидит state и завершится, сохранив карту памяти
    }

    func pause() {
        stateLock.lock(); defer { stateLock.unlock() }
        if state == .running { state = .paused }
    }

    func resume() {
        stateLock.lock(); defer { stateLock.unlock() }
        if state == .paused { state = .running }
    }

    // MARK: - Эмуляционный поток

    private func emulationLoop() {
        guard let gamePath else { return }

        retro_set_environment(environmentCallback)
        retro_set_video_refresh(videoRefreshCallback)
        retro_set_audio_sample(audioSampleCallback)
        retro_set_audio_sample_batch(audioSampleBatchCallback)
        retro_set_input_poll(inputPollCallback)
        retro_set_input_state(inputStateCallback)

        retro_init()

        var loaded = false
        gamePath.withCString { pathPtr in
            var info = retro_game_info(path: pathPtr, data: nil, size: 0, meta: nil)
            loaded = retro_load_game(&info)
        }

        guard loaded else {
            NSLog("EmulatorCore: retro_load_game failed for \(gamePath)")
            retro_deinit()
            stateLock.lock(); state = .stopped; stateLock.unlock()
            return
        }

        var avInfo = retro_system_av_info()
        retro_get_system_av_info(&avInfo)
        fps = avInfo.timing.fps > 0 ? avInfo.timing.fps : 60.0

        // DualShock: RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1) —
        // аналоговые стики + обратная совместимость с цифровыми играми
        retro_set_controller_port_device(0, UInt32((2 << 8) | RETRO_DEVICE_ANALOG))

        loadSaveRAM()

        // Продолжаем с того места, где закончили в прошлый раз
        if resumeFromAutoState, let autoURL = autoStateURL,
           FileManager.default.fileExists(atPath: autoURL.path) {
            _ = unserialize(from: autoURL)
        }

        audio.start(sampleRate: avInfo.timing.sample_rate)

        var nextFrame = CACurrentMediaTime()
        var framesSinceSave = 0
        var playtimeMark = CACurrentMediaTime()

        while true {
            stateLock.lock()
            let current = state
            let speedMultiplier = _fastForward ? 2.0 : 1.0
            stateLock.unlock()
            let period = 1.0 / (fps * speedMultiplier)

            if current == .stopped { break }

            drainWork()

            if current == .paused {
                Thread.sleep(forTimeInterval: 0.05)
                nextFrame = CACurrentMediaTime()
                playtimeMark = nextFrame // пауза в триал не засчитывается
                continue
            }

            retro_run()

            // Периодически скидываем карту памяти на диск (раз в ~5 секунд)
            framesSinceSave += 1
            if framesSinceSave >= Int(fps * 5) {
                framesSinceSave = 0
                persistSaveRAM()
                let now = CACurrentMediaTime()
                FeatureGate.addPlaytime(now - playtimeMark)
                playtimeMark = now
            }

            nextFrame += period
            let now = CACurrentMediaTime()
            if nextFrame > now {
                Thread.sleep(forTimeInterval: nextFrame - now)
            } else {
                nextFrame = now // отстали — не пытаемся догонять рывком
            }
        }

        // Больше не принимаем работу извне, добиваем уже вставшую в очередь
        workLock.lock()
        acceptingWork = false
        workLock.unlock()
        drainWork()

        // Автосохранение, чтобы в следующий раз продолжить с этого места
        if let autoURL = autoStateURL {
            _ = serialize(to: autoURL)
        }
        saveCover()
        persistSaveRAM()
        FeatureGate.addPlaytime(CACurrentMediaTime() - playtimeMark)
        audio.stop()
        diskControl = nil
        retro_unload_game()
        retro_deinit()
    }

    // MARK: - Очередь работы на эмуляционном потоке

    /// Выполняет work на эмуляционном потоке между кадрами и ждёт результат.
    /// Возвращает nil, если ядро остановлено.
    private func performSync<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        if Thread.current === thread {
            return work()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        workLock.lock()
        guard acceptingWork else {
            workLock.unlock()
            return nil
        }
        pendingWork.append {
            box.value = work()
            semaphore.signal()
        }
        workLock.unlock()

        semaphore.wait()
        return box.value
    }

    private func drainWork() {
        workLock.lock()
        let work = pendingWork
        pendingWork.removeAll()
        workLock.unlock()
        work.forEach { $0() }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: - Save states

    func saveState(to url: URL) -> Bool {
        performSync { Self.shared.serialize(to: url) } ?? false
    }

    func loadState(from url: URL) -> Bool {
        performSync { Self.shared.unserialize(from: url) } ?? false
    }

    /// Сброс консоли (начать игру заново); авто-сейв затирается.
    func reset() {
        if let autoURL = autoStateURL {
            try? FileManager.default.removeItem(at: autoURL)
        }
        _ = performSync { retro_reset(); return true }
    }

    // MARK: - Многодисковые игры

    /// Сколько дисков у игры и какой вставлен сейчас.
    func diskInfo() -> (count: Int, current: Int) {
        performSync { [self] in
            guard let dc = diskControl,
                  let numImages = dc.get_num_images,
                  let imageIndex = dc.get_image_index else { return (1, 0) }
            return (Int(numImages()), Int(imageIndex()))
        } ?? (1, 0)
    }

    /// Смена диска: «открываем лоток», меняем образ, через секунду «закрываем» —
    /// пауза нужна, чтобы игра успела заметить извлечение диска.
    func switchDisk(to index: Int) {
        _ = performSync { [self] in
            guard let dc = diskControl else { return false }
            _ = dc.set_eject_state?(true)
            _ = dc.set_image_index?(UInt32(index))
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            _ = self?.performSync {
                _ = self?.diskControl?.set_eject_state?(false)
                return true
            }
        }
    }

    /// Сохранить точку продолжения (при сворачивании приложения).
    func saveAutoState() {
        guard let autoURL = autoStateURL else { return }
        _ = saveState(to: autoURL)
        saveCover()
    }

    var autoStateURL: URL? {
        guard let gamePath else { return nil }
        let name = (gamePath as NSString).lastPathComponent
        return Self.saveDirectory.appendingPathComponent(name).appendingPathExtension("auto.state")
    }

    var coverURL: URL? {
        guard let gamePath else { return nil }
        let name = (gamePath as NSString).lastPathComponent
        return Self.saveDirectory.appendingPathComponent(name).appendingPathExtension("cover.png")
    }

    /// Скриншот текущего кадра как обложка игры в библиотеке.
    private func saveCover() {
        guard let coverURL, let cgImage = videoBuffer.makeCGImage() else { return }
        try? UIImage(cgImage: cgImage).pngData()?.write(to: coverURL)
    }

    // Только с эмуляционного потока
    private func serialize(to url: URL) -> Bool {
        let size = retro_serialize_size()
        guard size > 0 else { return false }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { retro_serialize($0.baseAddress, size) }
        guard ok else { return false }
        return (try? data.write(to: url)) != nil
    }

    // Только с эмуляционного потока
    private func unserialize(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.withUnsafeBytes { retro_unserialize($0.baseAddress, data.count) }
    }

    // MARK: - Карта памяти (SRAM)

    private var saveRAMURL: URL? {
        guard let gamePath else { return nil }
        let name = (gamePath as NSString).lastPathComponent
        return Self.saveDirectory.appendingPathComponent(name).appendingPathExtension("srm")
    }

    private func loadSaveRAM() {
        guard let url = saveRAMURL,
              let data = try? Data(contentsOf: url),
              let ptr = retro_get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return }
        let size = retro_get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        guard size > 0 else { return }
        data.withUnsafeBytes { src in
            memcpy(ptr, src.baseAddress, min(size, data.count))
        }
    }

    private func persistSaveRAM() {
        guard let url = saveRAMURL,
              let ptr = retro_get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return }
        let size = retro_get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        guard size > 0 else { return }
        let data = Data(bytes: ptr, count: size)
        try? data.write(to: url)
    }

    // MARK: - Environment

    fileprivate func handleEnvironment(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch Int32(bitPattern: cmd) {
        case RETRO_ENVIRONMENT_GET_CAN_DUPE: // 3
            data?.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: // 9
            guard let data, let dir = systemDirCString else { return false }
            data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(dir)
            return true

        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: // 31
            guard let data, let dir = saveDirCString else { return false }
            data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(dir)
            return true

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: // 10
            guard let data else { return false }
            let format = data.assumingMemoryBound(to: retro_pixel_format.self).pointee
            return format == RETRO_PIXEL_FORMAT_RGB565

        case RETRO_ENVIRONMENT_GET_VARIABLE: // 15
            guard let data else { return false }
            let variable = data.assumingMemoryBound(to: retro_variable.self)
            guard let keyPtr = variable.pointee.key,
                  let value = coreVariableValue(forKey: String(cString: keyPtr)) else {
                return false // неизвестный ключ — ядро возьмёт свой дефолт
            }
            variable.pointee.value = cachedCString(value)
            return true

        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: // 17
            variablesLock.lock()
            let updated = variablesUpdated
            variablesUpdated = false
            variablesLock.unlock()
            data?.assumingMemoryBound(to: Bool.self).pointee = updated
            return true

        case RETRO_ENVIRONMENT_SET_GEOMETRY: // 37 — размеры читаем из каждого кадра
            return true

        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION: // 57
            data?.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: // 58
            guard let data else { return false }
            diskControl = data.assumingMemoryBound(to: retro_disk_control_ext_callback.self).pointee
            return true

        default:
            return false
        }
    }

    // MARK: - Core options из настроек приложения

    /// Сообщить ядру, что настройки изменились — оно перечитает их между кадрами.
    func setVariablesUpdated() {
        variablesLock.lock()
        variablesUpdated = true
        variablesLock.unlock()
    }

    /// Значения core options, которыми мы управляем. Остальные ключи → nil,
    /// ядро использует свои дефолты.
    private func coreVariableValue(forKey key: String) -> String? {
        switch key {
        case "pcsx_rearmed_neon_enhancement_enable":
            let enhanced = (UserDefaults.standard.object(forKey: "renderEnhanced") as? Bool) ?? true
            return (enhanced && FeatureGate.sessionIsPro) ? "enabled" : "disabled"
        default:
            return nil
        }
    }

    private func cachedCString(_ value: String) -> UnsafePointer<CChar> {
        if let cached = cStringCache[value] {
            return UnsafePointer(cached)
        }
        let pointer = strdup(value)!
        cStringCache[value] = pointer
        return UnsafePointer(pointer)
    }
}

// MARK: - C-колбэки (не могут ничего захватывать)

private let environmentCallback: retro_environment_t = { cmd, data in
    EmulatorCore.shared.handleEnvironment(cmd, data)
}

private let videoRefreshCallback: retro_video_refresh_t = { data, width, height, pitch in
    guard let data else { return } // NULL — дубликат кадра, оставляем предыдущий
    EmulatorCore.shared.videoBuffer.store(
        pixels: data, width: Int(width), height: Int(height), pitch: pitch)
}

private let audioSampleCallback: retro_audio_sample_t = { left, right in
    var samples = [left, right]
    EmulatorCore.shared.audio.push(samples: &samples, frames: 1)
}

private let audioSampleBatchCallback: retro_audio_sample_batch_t = { data, frames in
    guard let data else { return 0 }
    EmulatorCore.shared.audio.push(samples: data, frames: frames)
    return frames
}

private let inputPollCallback: retro_input_poll_t = {
    // Состояние ввода обновляется асинхронно из UI/GameController — здесь ничего не нужно
}

private let inputStateCallback: retro_input_state_t = { port, device, index, id in
    guard port == 0 else { return 0 }
    return EmulatorCore.shared.input.state(device: device, index: index, id: id)
}
