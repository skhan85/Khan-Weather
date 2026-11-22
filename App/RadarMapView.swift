import MapKit
import SwiftUI
import WeatherCore

/// What the map shows: the radar loop, or one of Environment Canada's HRDPS model maps (2.5 km).
enum MapLayer: String, CaseIterable, Identifiable {
    case radar, temperature, wind, clouds
    var id: String { rawValue }

    var label: String {
        switch self {
        case .radar: return "Rain/snow"
        case .temperature: return "Temp"
        case .wind: return "Wind"
        case .clouds: return "Clouds"
        }
    }

    /// GeoMet WMS layer name.
    var wmsLayers: String {
        switch self {
        case .radar: return "RADAR_1KM_RRAI,RADAR_1KM_RSNO"
        case .temperature: return "HRDPS.CONTINENTAL_TT"
        case .wind: return "HRDPS.CONTINENTAL_UU"
        case .clouds: return "HRDPS.CONTINENTAL_NT"
        }
    }

    var credit: String {
        switch self {
        case .radar: return ""
        case .temperature: return "Temperature at 2 m"
        case .wind: return "Wind speed at 10 m"
        case .clouds: return "Cloud cover"
        }
    }

    /// GeoMet's colour key for the layer.
    var legendURL: URL? {
        guard self != .radar else { return nil }
        var c = URLComponents(string: "https://geo.weather.gc.ca/geomet")!
        c.queryItems = [
            URLQueryItem(name: "service", value: "WMS"), URLQueryItem(name: "version", value: "1.3.0"),
            URLQueryItem(name: "request", value: "GetLegendGraphic"), URLQueryItem(name: "layer", value: wmsLayers),
            URLQueryItem(name: "format", value: "image/png"), URLQueryItem(name: "sld_version", value: "1.1.0"),
        ]
        return c.url
    }
}

/// Extra layers drawn over the radar loop (Environment Canada GeoMet, Canada and the US).
enum RadarExtra: String, CaseIterable, Identifiable {
    case lightning, warnings
    var id: String { rawValue }

    var label: String { self == .lightning ? "Lightning" : "Warnings" }
    var systemImage: String { self == .lightning ? "bolt.fill" : "exclamationmark.triangle.fill" }

    /// GeoMet layer: lightning flashes in the last 10 minutes (2.5 km grid), and the areas
    /// under Environment Canada warnings, watches and advisories right now.
    var wmsLayers: String { self == .lightning ? "Lightning_2.5km_Density" : "Current-Alerts" }
    var opacity: CGFloat { self == .lightning ? 0.95 : 0.4 }
}

/// How far back the loop goes. GeoMet keeps three hours of radar.
enum RadarSpan: Int, CaseIterable, Identifiable {
    case oneHour = 1, threeHours = 3
    var id: Int { rawValue }
    var label: String { "\(rawValue) h" }
}

/// Environment Canada's 1 km radar (rain and snow) over a zoomable map, looping the last one or
/// three hours plus RainViewer's short forecast, with lightning, warnings and distance rings.
/// Or the current temperature, wind or cloud map from Environment Canada's HRDPS model.
/// Outside Canada and the US, RainViewer's worldwide radar loop instead.
struct RadarMapView: View {
    let center: Coordinate
    var timeZone: TimeZone = .current

    @State private var layer: MapLayer = .radar
    @State private var radarFrames: [RadarFrame]
    @State private var index = 0
    @State private var playing = true
    @State private var hold = 0
    @State private var loading = false
    @State private var recenter = 0
    @AppStorage("radarHours") private var hours = RadarSpan.oneHour.rawValue
    @AppStorage("radarLightning") private var lightning = true
    @AppStorage("radarWarnings") private var warnings = false
    @AppStorage("radarRings") private var rings = true
    private let timer = Timer.publish(every: RadarLoop.tick, on: .main, in: .common).autoconnect()

    init(center: Coordinate, timeZone: TimeZone = .current) {
        self.center = center
        self.timeZone = timeZone
        _radarFrames = State(initialValue: RadarFrames.initial(for: center,
            hours: UserDefaults.standard.object(forKey: "radarHours") as? Int ?? 1))
    }

    private var covered: Bool { ECCCRadarProvider.covers(center) }
    private var hasForecast: Bool { radarFrames.contains(where: \.isForecast) }
    private var span: RadarSpan { RadarSpan(rawValue: hours) ?? .oneHour }

    /// The radar loop, or a single model map (GeoMet's latest model hour when no time is sent).
    private var frames: [RadarFrame] {
        layer == .radar ? radarFrames : [RadarFrame(time: .distantPast, wmsLayers: layer.wmsLayers)]
    }
    private var shownIndex: Int { max(0, min(index, frames.count - 1)) }
    /// The newest frame that is radar, not forecast: the loop's "now".
    private var latestPast: Int { radarFrames.lastIndex(where: { !$0.isForecast }) ?? max(0, radarFrames.count - 1) }

    private var extras: [RadarExtra] {
        guard covered, layer == .radar else { return [] }
        return (warnings ? [.warnings] : []) + (lightning ? [.lightning] : [])
    }

    private func load() async {
        loading = true
        radarFrames = await RadarFrames.load(for: center, hours: span.rawValue)
        index = latestPast
        loading = false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RadarMap(center: center, frames: frames, index: shownIndex,
                     opacity: layer == .radar ? 0.75 : 0.6, extras: extras, rings: rings,
                     recenter: recenter)
                .ignoresSafeArea(edges: .bottom)
            if layer != .radar {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(layer.credit), Environment Canada HRDPS model, latest hour.")
                        .font(.caption)
                    if let url = layer.legendURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 520, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if radarFrames.isEmpty {
                Text(loading ? "Loading radar…" : "No radar for this area right now.")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
            } else {
                VStack(spacing: 10) {
                    options
                    RadarKey(lightning: extras.contains(.lightning))
                    HStack(spacing: 16) {
                        Button {
                            playing.toggle()
                        } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel(playing ? "Pause" : "Play")
                        Slider(value: Binding(get: { Double(shownIndex) },
                                              set: { index = Int($0.rounded()); playing = false }),
                               in: 0...Double(max(frames.count - 1, 1)), step: 1)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(TimeText.time(frames[shownIndex].time, timeZone))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text(RadarLoop.relative(frames[shownIndex], latest: radarFrames[latestPast].time))
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(frames[shownIndex].isForecast ? Color.orange : Color.secondary)
                        }
                        .frame(minWidth: 72, alignment: .trailing)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 560)
                .padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                recenter += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Back to my location")
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        .navigationTitle("Radar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { index = latestPast }
        .onChange(of: layer) { _, new in if new == .radar { index = latestPast } }
        .onChange(of: hours) { _, _ in Task { await load() } }
        .task { await load() }
        .onReceive(timer) { _ in
            guard playing, layer == .radar, !frames.isEmpty else { return }
            RadarLoop.advance(&index, hold: &hold, count: frames.count, latest: latestPast)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 4) {
                if covered {
                    Picker("Map", selection: $layer) {
                        ForEach(MapLayer.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 560)
                    .padding(.horizontal)
                }
                Text(layer != .radar
                     ? "Maps: Environment and Climate Change Canada. Pinch to zoom."
                     : !covered
                     ? "Radar: RainViewer, from national weather services. Pinch to zoom."
                     : hasForecast
                     ? "Radar, lightning and warnings: Environment and Climate Change Canada. Forecast frames: RainViewer."
                     : "Radar, lightning and warnings: Environment and Climate Change Canada. Covers Canada and the northern US.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal)
            }
        }
        .tint(.blue)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    /// Loop length and the overlays, as small chips.
    private var options: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if covered {
                    ForEach(RadarSpan.allCases) { s in
                        RadarChip(title: s.label, systemImage: nil, on: span == s) { hours = s.rawValue }
                    }
                    RadarChip(title: RadarExtra.lightning.label, systemImage: RadarExtra.lightning.systemImage,
                              on: lightning) { lightning.toggle() }
                    RadarChip(title: RadarExtra.warnings.label, systemImage: RadarExtra.warnings.systemImage,
                              on: warnings) { warnings.toggle() }
                }
                RadarChip(title: "Rings", systemImage: "scope", on: rings) { rings.toggle() }
            }
        }
    }
}

/// A small on/off pill for the radar's options.
private struct RadarChip: View {
    let title: String
    let systemImage: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(on ? Color.black : Color.primary)
            .background(Capsule().fill(on ? Brand.gold : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A small looping radar map for the main screen, with a storm heads-up line when one is
/// coming. Tapping it opens the full radar.
struct RadarPreviewCard: View {
    let center: Coordinate
    let timeZone: TimeZone
    /// Changes when the forecast reloads, to refresh the loop and the storm check.
    let refreshKey: Date

    @State private var frames: [RadarFrame] = []
    @State private var index = 0
    @State private var hold = 0
    @State private var storm: StormHeadsUp?
    @State private var loaded = false
    private let timer = Timer.publish(every: RadarLoop.tick, on: .main, in: .common).autoconnect()

    private var latestPast: Int { frames.lastIndex(where: { !$0.isForecast }) ?? max(0, frames.count - 1) }

    var body: some View {
        Group {
            if !frames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RadarMap(center: center, frames: frames, index: min(index, frames.count - 1),
                             span: 160_000, interactive: false, rings: true)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            // Top corner: the bottom one holds the Maps logo and Legal link.
                            let frame = frames[min(index, frames.count - 1)]
                            HStack(spacing: 4) {
                                if frame.isForecast { Image(systemName: "clock.arrow.circlepath") }
                                Text("\(TimeText.time(frame.time, timeZone)) · \(RadarLoop.relative(frame, latest: frames[latestPast].time))")
                            }
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(frame.isForecast ? Color.orange.opacity(0.85) : .black.opacity(0.55)))
                            .padding(8)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                        .accessibilityHidden(true)
                    if let storm {
                        Label {
                            Text(storm.shortText(timeZone: timeZone, distance: { WeatherFormat.distance($0) ?? "\(Int($0)) km" }))
                                .font(.subheadline.weight(.bold))
                        } icon: {
                            Image(systemName: storm.kind == .snowSquall ? "cloud.snow.fill" : storm.kind == .thunderstorm ? "cloud.bolt.rain.fill" : "cloud.heavyrain.fill")
                                .foregroundStyle(Brand.gold)
                        }
                    }
                    Text(ECCCRadarProvider.covers(center)
                         ? "Rain and snow, last hour\(frames.contains(where: \.isForecast) ? " and next half hour" : ""). Tap for the full map."
                         : "Rain and snow, last 2 hours. Tap for the full map.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.vertical, 4)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Label("Radar, temperature, wind and cloud maps", systemImage: "dot.radiowaves.left.and.right")
                    .font(.body.weight(.medium))
            }
        }
        .task(id: refreshKey) {
            frames = await RadarFrames.load(for: center)
            index = latestPast
            loaded = true
            storm = await StormWatchProvider().check(at: center)
        }
        .onReceive(timer) { _ in
            guard !frames.isEmpty else { return }
            RadarLoop.advance(&index, hold: &hold, count: frames.count, latest: latestPast)
        }
    }
}

/// Environment Canada's rain colours, light to heavy, as a thin strip, and the lightning colour
/// when that layer is on.
private struct RadarKey: View {
    var lightning = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Light").font(.caption2.weight(.semibold))
            LinearGradient(colors: [Color(red: 0.6, green: 0.8, blue: 1), Color(red: 0.0, green: 0.55, blue: 1),
                                    Color(red: 0.1, green: 0.75, blue: 0.2), Color(red: 1, green: 0.9, blue: 0),
                                    Color(red: 1, green: 0.5, blue: 0), Color(red: 0.9, green: 0, blue: 0),
                                    Color(red: 0.8, green: 0, blue: 0.8)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
            Text("Heavy").font(.caption2.weight(.semibold))
            if lightning {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text("Lightning, last 10 min").font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colours run from light rain in pale blue to heavy rain in red and purple")
    }
}

/// How the loop plays: a frame every half second, pausing on the latest radar frame before
/// going on to the forecast frames and starting over.
enum RadarLoop {
    static let tick: TimeInterval = 0.5
    /// Ticks to linger on the latest radar frame and on the last frame of the loop.
    static let holdTicks = 3

    static func advance(_ index: inout Int, hold: inout Int, count: Int, latest: Int) {
        guard count > 1 else { index = 0; return }
        if (index == latest || index >= count - 1), hold < holdTicks {
            hold += 1
            return
        }
        hold = 0
        index = index >= count - 1 ? 0 : index + 1
    }

    /// "40 min ago", "Now", "in 20 min".
    static func relative(_ frame: RadarFrame, latest: Date) -> String {
        let minutes = Int((frame.time.timeIntervalSince(latest) / 60).rounded())
        if minutes == 0 { return "Now" }
        return minutes < 0 ? "\(-minutes) min ago" : "in \(minutes) min"
    }
}

/// One frame of the loop: an Environment Canada radar image, or a RainViewer image (its worldwide
/// radar, or where the rain is expected to be in the next half hour or so).
struct RadarFrame: Equatable {
    let time: Date
    /// GeoMet layers; the radar's rain and snow unless set. Model maps send no time, so GeoMet
    /// picks its current hour.
    var wmsLayers: String? = nil
    /// RainViewer tile template with {z}/{x}/{y}; nil for Environment Canada.
    var tileTemplate: String? = nil
    var isForecast = false
}

enum RadarFrames {
    /// GeoMet publishes a frame every 6 minutes, a few minutes after the fact, and keeps three
    /// hours. The last hour is every frame; three hours is every second frame, so the loop
    /// stays a few seconds long and loads quickly.
    static func recent(hours: Int = 1, now: Date = Date()) -> [RadarFrame] {
        let six: TimeInterval = 6 * 60
        let latest = ((now.timeIntervalSince1970 - 9 * 60) / six).rounded(.down) * six
        let step = hours > 1 ? 2 * six : six
        // Stay a frame inside GeoMet's window so the oldest one is never already gone.
        let count = hours > 1 ? Int((Double(hours) * 3600 - six) / step) + 1 : 10
        return (0..<count).reversed().map { RadarFrame(time: Date(timeIntervalSince1970: latest - Double($0) * step)) }
    }

    /// What to show before anything loads: Environment Canada's frames where it has radar.
    static func initial(for c: Coordinate, hours: Int = 1) -> [RadarFrame] {
        ECCCRadarProvider.covers(c) ? recent(hours: hours) : []
    }

    /// The loop for a place: Environment Canada's last hour plus RainViewer's nowcast where it has
    /// radar, otherwise RainViewer's worldwide radar for the last two hours.
    static func load(for c: Coordinate, hours: Int = 1) async -> [RadarFrame] {
        let rv = await rainViewer()
        guard ECCCRadarProvider.covers(c) else { return rv.past + rv.nowcast }
        let past = recent(hours: hours)
        let latest = past.last?.time ?? .distantPast
        return past + rv.nowcast.filter { $0.time > latest }
    }

    /// RainViewer's free frames, past and (if it still publishes them) nowcast. Empty on any failure.
    static func rainViewer() async -> (past: [RadarFrame], nowcast: [RadarFrame]) {
        struct Maps: Decodable {
            struct Frame: Decodable { let time: Double; let path: String }
            struct Radar: Decodable { let past: [Frame]?; let nowcast: [Frame]? }
            let host: String
            let radar: Radar
        }
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let maps = try? JSONDecoder().decode(Maps.self, from: data) else { return ([], []) }
        func frames(_ list: [Maps.Frame]?, forecast: Bool) -> [RadarFrame] {
            (list ?? []).map {
                RadarFrame(time: Date(timeIntervalSince1970: $0.time),
                           tileTemplate: "\(maps.host)\($0.path)/256/{z}/{x}/{y}/2/1_1.png", isForecast: forecast)
            }
        }
        return (frames(maps.radar.past, forecast: false), frames(maps.radar.nowcast, forecast: true))
    }
}

/// One radar frame as WMS tiles in web-mercator.
final class RadarTileOverlay: MKTileOverlay {
    let time: Date?
    let layers: String

    init(time: Date?, layers: String) {
        self.time = time
        self.layers = layers
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 12
    }

    static func make(_ frame: RadarFrame) -> MKTileOverlay {
        guard let template = frame.tileTemplate else {
            return RadarTileOverlay(time: frame.wmsLayers == nil ? frame.time : nil,
                                    layers: frame.wmsLayers ?? MapLayer.radar.wmsLayers)
        }
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
            URLQueryItem(name: "layers", value: layers),
            URLQueryItem(name: "styles", value: ""),
            URLQueryItem(name: "crs", value: "EPSG:3857"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "width", value: "256"),
            URLQueryItem(name: "height", value: "256"),
            URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "true"),
        ]
        if let time { comps.queryItems?.append(URLQueryItem(name: "time", value: Self.iso.string(from: time))) }
        return comps.url!
    }
}


/// Distances for the rings around your spot, in the unit chosen in Settings.
enum RadarRings {
    /// Ring radii in km, and their labels: 10, 25 and 50 km, or 5, 15 and 30 miles.
    static func radii(miles: Bool = UnitSettings.current.distance == .mi) -> [(km: Double, label: String)] {
        miles
            ? [5, 15, 30].map { (Double($0) * 1.609344, "\($0) mi") }
            : [10, 25, 50].map { (Double($0), "\($0) km") }
    }
}

/// Where a ring's label sits: on the ring, straight north of your spot.
private final class RingLabel: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    init(_ coordinate: CLLocationCoordinate2D, _ title: String) {
        self.coordinate = coordinate
        self.title = title
    }
}

private struct RadarMap: UIViewRepresentable {
    let center: Coordinate
    let frames: [RadarFrame]
    let index: Int
    var opacity: CGFloat = 0.75
    /// Metres across. RainViewer's free tiles stop at zoom 7, so outside Environment Canada's
    /// radar the map starts wider.
    var span: CLLocationDistance = 300_000
    /// False for the main screen's preview, so a tap goes to the full map instead.
    var interactive = true
    /// Lightning and warnings, drawn over every frame.
    var extras: [RadarExtra] = []
    /// Distance rings around your spot.
    var rings = false
    /// Bumped to fly back to your spot.
    var recenter = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var meters: CLLocationDistance { ECCCRadarProvider.covers(center) ? span : max(span, 500_000) }
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters), animated: false)
        map.isUserInteractionEnabled = interactive
        if !interactive {
            map.showsCompass = false
            map.showsScale = false
        } else {
            map.showsScale = true
        }
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        map.addAnnotation(pin)
        context.coordinator.recenter = recenter
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.frames != frames {
            map.removeOverlays(coordinator.overlays)
            coordinator.frames = frames
            coordinator.overlays = frames.map { RadarTileOverlay.make($0) }
            coordinator.renderers = [:]
            map.addOverlays(coordinator.overlays, level: .aboveRoads)
            // Keep lightning, warnings and rings above the newly added radar frames.
            coordinator.extrasShown = nil
            coordinator.ringsShown = nil
        }
        if coordinator.extrasShown != extras {
            map.removeOverlays(coordinator.extraOverlays)
            coordinator.extraOverlays = extras.map { extra in
                let o = RadarTileOverlay(time: nil, layers: extra.wmsLayers)
                coordinator.extraOpacity[ObjectIdentifier(o)] = extra.opacity
                return o
            }
            map.addOverlays(coordinator.extraOverlays, level: .aboveRoads)
            coordinator.extrasShown = extras
            coordinator.ringsShown = nil
        }
        let ringKey = rings ? RadarRings.radii().map(\.label).joined(separator: ",") : ""
        if coordinator.ringsShown != ringKey {
            map.removeOverlays(coordinator.ringOverlays)
            map.removeAnnotations(coordinator.ringLabels)
            let radii = rings ? RadarRings.radii() : []
            coordinator.ringOverlays = radii.map { MKCircle(center: coordinate, radius: $0.km * 1000) }
            coordinator.ringLabels = radii.map { r in
                // One degree of latitude is about 111 km.
                RingLabel(CLLocationCoordinate2D(latitude: center.latitude + r.km / 111.0, longitude: center.longitude), r.label)
            }
            map.addOverlays(coordinator.ringOverlays, level: .aboveLabels)
            map.addAnnotations(coordinator.ringLabels)
            coordinator.ringCenter = coordinate
            coordinator.ringsShown = ringKey
        }
        if coordinator.opacity != opacity {
            coordinator.opacity = opacity
            coordinator.refresh()
        }
        if coordinator.recenter != recenter {
            coordinator.recenter = recenter
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters), animated: true)
        }
        coordinator.show(index)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var frames: [RadarFrame] = []
        var overlays: [MKTileOverlay] = []
        var renderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]
        var opacity: CGFloat = 0.75
        var extrasShown: [RadarExtra]?
        var extraOverlays: [MKTileOverlay] = []
        var extraOpacity: [ObjectIdentifier: CGFloat] = [:]
        var ringsShown: String?
        var ringOverlays: [MKCircle] = []
        fileprivate var ringLabels: [RingLabel] = []
        var ringCenter = CLLocationCoordinate2D()
        var recenter = 0

        /// Hides ring labels that would sit on top of each other (or of your spot) at this zoom.
        func spaceRingLabels(_ map: MKMapView) {
            let middle = map.convert(ringCenter, toPointTo: map)
            var lastShown: CGFloat = 0
            for label in ringLabels {
                guard let view = map.view(for: label) else { continue }
                let up = middle.y - map.convert(label.coordinate, toPointTo: map).y
                let show = up >= 22 && up - lastShown >= 22
                view.isHidden = !show
                if show { lastShown = up }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            spaceRingLabels(mapView)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            spaceRingLabels(mapView)
        }
        private var current = -1

        func show(_ index: Int) {
            guard index != current else { return }
            current = index
            refresh()
        }

        func refresh() {
            for (i, overlay) in overlays.enumerated() {
                renderers[ObjectIdentifier(overlay)]?.alpha = i == current ? opacity : 0
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.white.withAlphaComponent(0.85)
                r.lineWidth = 1.5
                r.lineDashPattern = [6, 5]
                return r
            }
            guard let tiles = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKTileOverlayRenderer(tileOverlay: tiles)
            if let extra = extraOpacity[ObjectIdentifier(tiles)] {
                r.alpha = extra
                return r
            }
            r.alpha = overlays.firstIndex(of: tiles) == current ? opacity : 0
            renderers[ObjectIdentifier(tiles)] = r
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ring = annotation as? RingLabel else { return nil }
            let id = "ring"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: ring, reuseIdentifier: id)
            view.annotation = ring
            view.subviews.forEach { $0.removeFromSuperview() }
            let label = UILabel()
            label.text = " \(ring.title ?? "") "
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.sizeToFit()
            label.frame.size.height += 4
            view.frame = label.bounds
            view.addSubview(label)
            view.canShowCallout = false
            view.isEnabled = false
            view.displayPriority = .required
            return view
        }
    }
}
