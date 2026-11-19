import MapKit
import SwiftUI
import WeatherCore

/// Environment Canada's 1 km radar (rain and snow) over a zoomable map, looping the last hour.
struct RadarMapView: View {
    let center: Coordinate

    @State private var frames: [RadarFrame] = RadarFrames.recent()
    @State private var index = 0
    @State private var playing = true
    private let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    private var hasForecast: Bool { frames.contains(where: \.isForecast) }

    /// Adds the next half hour or so after the latest radar frame, when RainViewer has it.
    private func loadForecast() async {
        let ahead = await RadarFrames.nowcast()
        guard !ahead.isEmpty else { return }
        let past = frames.filter { !$0.isForecast }
        let latest = past.last?.time ?? .distantPast
        frames = past + ahead.filter { $0.time > latest }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RadarMap(center: center, frames: frames, index: index)
                .ignoresSafeArea(edges: .bottom)
            HStack(spacing: 16) {
                Button {
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                Slider(value: Binding(get: { Double(index) },
                                      set: { index = Int($0.rounded()); playing = false }),
                       in: 0...Double(max(frames.count - 1, 1)), step: 1)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(TimeText.time(frames[index].time, .current))
                        .font(.subheadline.monospacedDigit())
                    if frames[index].isForecast {
                        Text("Forecast")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
        .navigationTitle("Radar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    frames = RadarFrames.recent()
                    index = frames.count - 1
                    Task { await loadForecast() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { index = frames.count - 1 }
        .task { await loadForecast() }
        .onReceive(timer) { _ in
            guard playing, !frames.isEmpty else { return }
            // Linger on the latest frame for a beat before starting over.
            index = index >= frames.count - 1 ? 0 : index + 1
        }
        .safeAreaInset(edge: .top) {
            Text(hasForecast
                 ? "Radar: Environment and Climate Change Canada. Forecast frames: RainViewer. Pinch to zoom."
                 : "Radar: Environment and Climate Change Canada. Covers Canada and the northern US. Pinch to zoom.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        }
        .tint(.blue)
        .toolbarColorScheme(.light, for: .navigationBar)
    }
}

/// One frame of the loop: an Environment Canada radar image, or a RainViewer nowcast image
/// (where the rain is expected to be in the next half hour or so).
struct RadarFrame: Equatable {
    let time: Date
    /// RainViewer tile template with {z}/{x}/{y}; nil for Environment Canada radar.
    var forecastTemplate: String? = nil
    var isForecast: Bool { forecastTemplate != nil }
}

enum RadarFrames {
    /// GeoMet publishes a frame every 6 minutes, a few minutes after the fact.
    static func recent(count: Int = 10, now: Date = Date()) -> [RadarFrame] {
        let step: TimeInterval = 6 * 60
        let latest = ((now.timeIntervalSince1970 - 9 * 60) / step).rounded(.down) * step
        return (0..<count).reversed().map { RadarFrame(time: Date(timeIntervalSince1970: latest - Double($0) * step)) }
    }

    /// RainViewer's free nowcast frames, if it publishes any. Empty on any failure.
    static func nowcast() async -> [RadarFrame] {
        struct Maps: Decodable {
            struct Frame: Decodable { let time: Double; let path: String }
            struct Radar: Decodable { let nowcast: [Frame]? }
            let host: String
            let radar: Radar
        }
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let maps = try? JSONDecoder().decode(Maps.self, from: data) else { return [] }
        return (maps.radar.nowcast ?? []).map {
            RadarFrame(time: Date(timeIntervalSince1970: $0.time),
                       forecastTemplate: "\(maps.host)\($0.path)/256/{z}/{x}/{y}/2/1_1.png")
        }
    }
}

/// One radar frame as WMS tiles in web-mercator.
final class RadarTileOverlay: MKTileOverlay {
    let time: Date

    init(time: Date) {
        self.time = time
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 12
    }

    static func make(_ frame: RadarFrame) -> MKTileOverlay {
        guard let template = frame.forecastTemplate else { return RadarTileOverlay(time: frame.time) }
        let tiles = MKTileOverlay(urlTemplate: template)
        tiles.canReplaceMapContent = false
        tiles.minimumZ = 3
        tiles.maximumZ = 7   // RainViewer's free tiles stop at zoom 7
        return tiles
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let world = 20_037_508.342789244
        let size = 2 * world / pow(2, Double(path.z))
        let minX = -world + Double(path.x) * size
        let maxY = world - Double(path.y) * size
        let bbox = [minX, maxY - size, minX + size, maxY].map { String(format: "%.2f", $0) }.joined(separator: ",")
        var comps = URLComponents(string: "https://geo.weather.gc.ca/geomet")!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "WMS"),
            URLQueryItem(name: "version", value: "1.3.0"),
            URLQueryItem(name: "request", value: "GetMap"),
            URLQueryItem(name: "layers", value: "RADAR_1KM_RRAI,RADAR_1KM_RSNO"),
            URLQueryItem(name: "styles", value: ""),
            URLQueryItem(name: "crs", value: "EPSG:3857"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "width", value: "256"),
            URLQueryItem(name: "height", value: "256"),
            URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "true"),
            URLQueryItem(name: "time", value: Self.iso.string(from: time)),
        ]
        return comps.url!
    }
}

private struct RadarMap: UIViewRepresentable {
    let center: Coordinate
    let frames: [RadarFrame]
    let index: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        let c = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 300_000, longitudinalMeters: 300_000), animated: false)
        let pin = MKPointAnnotation()
        pin.coordinate = c
        map.addAnnotation(pin)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.frames != frames {
            map.removeOverlays(map.overlays)
            coordinator.frames = frames
            coordinator.overlays = frames.map { RadarTileOverlay.make($0) }
            coordinator.renderers = [:]
            map.addOverlays(coordinator.overlays, level: .aboveRoads)
        }
        coordinator.show(index)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var frames: [RadarFrame] = []
        var overlays: [MKTileOverlay] = []
        var renderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]
        private var current = -1

        func show(_ index: Int) {
            guard index != current else { return }
            current = index
            for (i, overlay) in overlays.enumerated() {
                renderers[ObjectIdentifier(overlay)]?.alpha = i == index ? 0.75 : 0
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKTileOverlayRenderer(tileOverlay: tiles)
            r.alpha = overlays.firstIndex(of: tiles) == current ? 0.75 : 0
            renderers[ObjectIdentifier(tiles)] = r
            return r
        }
    }
}
