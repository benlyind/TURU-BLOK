import Foundation

/// Persistent toggle state untuk alternating-skip:
/// - Trigger ke-1: skippable
/// - Trigger ke-2: forced (ga bisa skip)
/// - Trigger ke-3: skippable
/// - ... dan seterusnya.
struct SkipState: Codable {
    var nextSkippable: Bool
}

enum SkipStateStore {
    static let url: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/turublok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skip_state.json")
    }()

    static func load() -> SkipState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SkipState.self, from: data)
        else {
            return SkipState(nextSkippable: true)  // default: trigger pertama boleh skip
        }
        return state
    }

    static func toggle() {
        var state = load()
        state.nextSkippable.toggle()
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
        Log.info("skip state toggled → nextSkippable=\(state.nextSkippable)")
    }
}
