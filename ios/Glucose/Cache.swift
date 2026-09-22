import Foundation

/// Tiny JSON-file cache in the app's Documents directory. Keeps the last
/// 48 h of server data on the phone so the app remains usable offline
/// (read-only: logging and recommendations still need the server).
enum Cache {
    struct Entry<T: Codable>: Codable {
        let savedAt: Date
        let value: T
    }

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func save<T: Codable>(_ value: T, as name: String) {
        let entry = Entry(savedAt: Date(), value: value)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func load<T: Codable>(_ type: T.Type, from name: String) -> (value: T, savedAt: Date)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")),
              let entry = try? JSONDecoder().decode(Entry<T>.self, from: data)
        else { return nil }
        return (entry.value, entry.savedAt)
    }
}
