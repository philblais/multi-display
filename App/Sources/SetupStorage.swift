import Foundation

final class SetupStorage {
    private let key = "savedSetupsV1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [SavedSetup] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedSetup].self, from: data)) ?? []
    }

    func save(_ setups: [SavedSetup]) {
        guard let data = try? JSONEncoder().encode(setups) else { return }
        defaults.set(data, forKey: key)
    }
}
