import Foundation

final class SetupStorage {
    private let key = "savedSetupsV1"

    func load() -> [SavedSetup] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedSetup].self, from: data)) ?? []
    }

    func save(_ setups: [SavedSetup]) {
        guard let data = try? JSONEncoder().encode(setups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
