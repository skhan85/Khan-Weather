import SwiftUI
import WeatherCore

/// Search for places by name, save them, rename, reorder and delete them.
struct PlacesView: View {
    @ObservedObject var store: SavedPlacesStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SavedPlace] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var renaming: SavedPlace?
    @State private var newName = ""

    private let search = PlaceSearch()

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("Search results") {
                        if searching {
                            ProgressView()
                        } else if let searchError {
                            Text(searchError).foregroundStyle(.secondary)
                        } else if results.isEmpty && query.count >= 2 {
                            Text("No places found").foregroundStyle(.secondary)
                        }
                        ForEach(results) { place in
                            Button {
                                store.add(place)
                                query = ""
                            } label: {
                                PlaceRow(place: place, systemImage: "plus.circle.fill")
                            }
                        }
                    }
                }
                Section {
                    Button {
                        store.selectedID = nil
                        dismiss()
                    } label: {
                        Label("Current location", systemImage: "location.fill")
                    }
                    ForEach(store.places) { place in
                        Button {
                            store.selectedID = place.id
                            dismiss()
                        } label: {
                            PlaceRow(place: place, systemImage: store.selectedID == place.id ? "checkmark.circle.fill" : "mappin.circle")
                        }
                        .swipeActions(edge: .leading) {
                            Button("Rename") {
                                newName = place.name
                                renaming = place
                            }
                            .tint(.orange)
                        }
                    }
                    .onDelete { store.remove(atOffsets: $0) }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Your places")
                } footer: {
                    Text("Swipe right to rename (e.g. \"Work\"), left to delete. Place search by Open-Meteo / GeoNames.")
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Add a city or town")
            .autocorrectionDisabled()
            .task(id: query) { await runSearch() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let renaming { store.rename(renaming.id, to: newName.trimmingCharacters(in: .whitespaces)) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func runSearch() async {
        let q = query
        searchError = nil
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; return }
        // Wait for typing to pause before asking the server.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await search.search(q)
            if !Task.isCancelled { results = found }
        } catch {
            if !Task.isCancelled { searchError = "Search failed. Check your connection." }
        }
    }
}

private struct PlaceRow: View {
    let place: SavedPlace
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(place.name).foregroundStyle(.primary)
                if let detail = place.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
