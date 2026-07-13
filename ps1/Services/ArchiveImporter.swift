import Foundation

/// Распаковка игровых архивов (.zip / .7z / .rar) через libarchive.
/// Из архива достаются только файлы образов; структура папок плющится —
/// .cue ссылается на .bin по имени, поэтому всё складывается в одну папку.
nonisolated enum ArchiveImporter {

    static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    /// Что забираем из архива: образы + сопутствующие файлы
    private static let gameExtensions: Set<String> = [
        "m3u", "chd", "cue", "pbp", "iso", "img", "bin", "sbi", "ccd", "sub",
    ]

    enum ImportError: LocalizedError {
        case cantOpen(String)
        case noGameFiles
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .cantOpen(let detail): "Can't open archive: \(detail)"
            case .noGameFiles: "No game files found in the archive"
            case .extractFailed(let detail): "Extraction failed: \(detail)"
            }
        }
    }

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// Распаковывает игровые файлы архива в directory (без подпапок).
    /// Возвращает имена извлечённых файлов.
    @discardableResult
    static func extract(_ archiveURL: URL, to directory: URL) throws -> [String] {
        guard let a = archive_read_new() else { throw ImportError.cantOpen("out of memory") }
        defer { archive_read_free(a) }

        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)

        guard archive_read_open_filename(a, archiveURL.path, 1 << 16) == ARCHIVE_OK else {
            throw ImportError.cantOpen(lastError(a))
        }

        var extracted: [String] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var entry: OpaquePointer?

        while archive_read_next_header(a, &entry) == ARCHIVE_OK {
            guard let entry else { continue }
            let rawName = archive_entry_pathname_utf8(entry).map { String(cString: $0) }
                ?? archive_entry_pathname(entry).map { String(cString: $0) }
            guard let path = rawName else {
                archive_read_data_skip(a)
                continue
            }

            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()

            // Только образы; мусор вроде __MACOSX и скрытых файлов — мимо
            guard !path.contains("__MACOSX"), !name.hasPrefix("."),
                  gameExtensions.contains(ext) else {
                archive_read_data_skip(a)
                continue
            }

            let dest = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: dest) else {
                throw ImportError.extractFailed("can't write \(name)")
            }
            defer { try? handle.close() }

            while true {
                let n = archive_read_data(a, &buffer, buffer.count)
                if n == 0 { break }
                guard n > 0 else {
                    // Битый или запароленный архив: подчищаем огрызок
                    try? handle.close()
                    try? FileManager.default.removeItem(at: dest)
                    throw ImportError.extractFailed(lastError(a))
                }
                handle.write(Data(bytes: buffer, count: n))
            }
            extracted.append(name)
        }

        guard !extracted.isEmpty else { throw ImportError.noGameFiles }
        return extracted
    }

    private static func lastError(_ a: OpaquePointer?) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
    }
}
