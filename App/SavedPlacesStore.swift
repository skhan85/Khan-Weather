import Foundation
import WeatherCore

/// The user's saved places and which one is showing, kept in UserDefaults on this device.
@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published private(set) var places: [SavedPlace] = []
    /// nil means the current location.
    @Published var selectedID: UUID? {
        didSet { defaults.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }

    private let defaults: UserDefaults
    private static let placesKey = "savedPlaces"
    private static let selectedKey = "selectedPlaceID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.placesKey),
           let saved = try? JSONDecoder().decode([SavedPlace].self, from: data) {
            places = saved
        }
        let id = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        selectedID = places.contains { $0.id == id } ? id : nil
    }

    var selected: SavedPlace? { places.first { $0.id == selectedID } }

    func add(_ place: SavedPlace) {
        places.append(place)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = places.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        places[i].name = name
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        let removed = offsets.map { places[$0].id }
        places.remove(atOffsets: offsets)
        if let selectedID, removed.contains(selectedID) { self.selectedID = nil }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        places.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
    }
}
