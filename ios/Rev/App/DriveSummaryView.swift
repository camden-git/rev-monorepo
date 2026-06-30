import CoreImage
import LinkPresentation
import MapKit
import RevKit
import SwiftUI
import UIKit

/// post-drive recap sheet (REF: docs/game-design.md §Claiming, §Trails & Enclosure)
///
/// reads the provisional `DriveSummary` built locally at finalize
///
/// future: once the drive uploads, the backend returns the authoritative tally and this recap
/// would be reconciled against it (docs/tech-stack.md §Sync Model)
struct DriveSummaryView: View {
    let summary: DriveSummary
    let store: TerritoryStore
    /// personal records set by this drive
    var newRecords: [DrivePRKind] = []
    /// the player's current streak
    var streak: DriveStreak? = nil
    /// when this drive happened
    var driveDate: Date = .now
    /// the whole driven route
    var drivePath: [CLLocationCoordinate2D] = []
    var onDone: () -> Void = {}

    @State private var showExplainer = false
    @State private var isPreparingShare = false
    @State private var shareItem: ShareImageItem?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if !newRecords.isEmpty {
                    Section("New Records 🏆") {
                        ForEach(newRecords, id: \.self) { record in
                            HStack(spacing: 12) {
                                Image(systemName: record.systemImage)
                                    .foregroundStyle(.orange)
                                    .frame(width: 24)
                                Text(record.title)
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: "trophy.fill")
                                    .foregroundStyle(.yellow)
                            }
                            .listRowBackground(Color.yellow.opacity(0.12))
                        }
                    }
                }

                Section("This Drive") {
                    if summary.tilesClaimed > 0 {
                        tallyRow(icon: "flag.fill", tint: .blue,
                                 label: "New tiles claimed", value: summary.tilesClaimed)
                    }
                    ForEach(capturedRows) { row in
                        tallyRow(icon: "bolt.fill", tint: row.color,
                                 label: "Captured from \(row.name)", value: row.count)
                    }
                    if summary.tilesEnclosed > 0 {
                        tallyRow(icon: "lasso", tint: .orange,
                                 label: "Enclosed", value: summary.tilesEnclosed)
                            .listRowBackground(Color.orange.opacity(0.12))
                    }
                    if summary.tilesReinforced > 0 {
                        tallyRow(icon: "arrow.clockwise", tint: .secondary,
                                 label: "Tiles reinforced", value: summary.tilesReinforced)
                    }
                    if summary.totalGained == 0 && summary.tilesReinforced == 0 {
                        Text("No tiles changed hands this drive.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    metricsRow
                } footer: {
                    Button {
                        showExplainer = true
                    } label: {
                        Label("How tiles are scored", systemImage: "questionmark.circle")
                            .font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
            .sheet(isPresented: $showExplainer) {
                ScoringExplainerView(onDone: { showExplainer = false })
                    .presentationDetents([.large])
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        prepareShare()
                    } label: {
                        Group {
                            if isPreparingShare {
                                ProgressView()
                            } else {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .glassButton()
                    .disabled(isPreparingShare)

                    Button(action: onDone) {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .glassProminentButton()
                }
                .padding()
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [ShareCardItemSource(fileURL: item.url, image: item.image)])
            }
        }
    }

    /// render the recap card off the main loop (it does async map snapshotting) then present share
    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            let image = await makeShareUIImage()
            isPreparingShare = false
            guard let image else { return }
            shareItem = ShareImageItem(image: image, url: Self.writeSharePNG(image))
        }
    }

    /// write the rendered card to a named temp PNG so the share sheet shares a concrete
    /// file rather than an in-memory image promise
    private static func writeSharePNG(_ image: UIImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rev Drive.png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Drive complete")
                .font(.title3.weight(.semibold))
            Text("\(summary.tilesDriven) tiles")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.blue)
                .contentTransition(.numericText())
            if let streak, streak.current >= 1 {
                Text("🔥 \(streak.current) day streak")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: share card

    /// fixed render size for the share card
    private static let cardSize = CGSize(width: 380, height: 620)

    /// build the captured-territory recap card
    @MainActor
    private func makeShareUIImage() async -> UIImage? {
        await Self.renderShareImage(summary: summary, store: store, date: driveDate, scale: displayScale, drivePath: drivePath)
    }

    @MainActor
    static func renderShareImage(summary: DriveSummary, store: TerritoryStore, date: Date, scale: CGFloat, drivePath: [CLLocationCoordinate2D] = []) async -> UIImage? {
        let size = cardSize
        let renderScale = scale > 0 ? scale : 3

        var streetImage: UIImage?
        var hexPolygons: [[CGPoint]] = []

        // frame the map to the whole driven route when we have it, otherwise fall
        // back to the bounds of the gained tiles
        let region = drivePath.isEmpty
            ? H3Grid.region(covering: summary.gainedCells)
            : H3Grid.region(coveringCoordinates: drivePath)
        if let region {
            let snapshot = await streetSnapshot(region: region, size: size, scale: renderScale)
            if let snapshot {
                streetImage = cropAttribution(monochrome(snapshot.image))
                hexPolygons = summary.gainedCells.map { cell in
                    H3Grid.boundary(of: cell).map { snapshot.point(for: $0) }
                }
            } else {
                // no street layer
                hexPolygons = projectHexes(cells: summary.gainedCells, region: region, size: size)
            }
        }

        let card = DriveShareCard(
            summary: summary,
            store: store,
            date: date,
            streetImage: streetImage,
            hexPolygons: hexPolygons
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = renderScale
        return renderer.uiImage
    }

    private static let ciContext = CIContext(options: nil)

    /// crop to remove apple maps logo
    static let mapLogoStripPoints: CGFloat = 30

    private static func cropAttribution(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let cropPx = mapLogoStripPoints * image.scale
        let rect = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: max(CGFloat(cgImage.height) - cropPx, 0))
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// grayscale
    private static func monochrome(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage,
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func streetSnapshot(region: MKCoordinateRegion, size: CGSize, scale: CGFloat) async -> MKMapSnapshotter.Snapshot? {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale > 0 ? scale : 3

        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        options.preferredConfiguration = config
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshotter = MKMapSnapshotter(options: options)
        return try? await snapshotter.start()
    }

    private static func projectHexes(cells: [UInt64], region: MKCoordinateRegion, size: CGSize) -> [[CGPoint]] {
        let centerLat = region.center.latitude
        let centerLng = region.center.longitude
        let latSpan = region.span.latitudeDelta
        let lngSpan = region.span.longitudeDelta
        guard latSpan > 0, lngSpan > 0 else { return [] }
        let lngScale = cos(centerLat * .pi / 180)

        func point(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let x = ((coord.longitude - centerLng) * lngScale / (lngSpan * lngScale) + 0.5) * size.width
            let y = (0.5 - (coord.latitude - centerLat) / latSpan) * size.height
            return CGPoint(x: x, y: y)
        }
        return cells.map { H3Grid.boundary(of: $0).map(point) }
    }

    private func tallyRow(icon: String, tint: Color, label: String, value: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
    }

    private var metricsRow: some View {
        HStack {
            metric(value: distanceText, label: "distance")
            Divider().frame(height: 32)
            metric(value: durationText, label: "moving")
            Divider().frame(height: 32)
            metric(value: String(format: "%.0f", summary.averageScore), label: "avg mph")
            Divider().frame(height: 32)
            metric(value: String(format: "%.0f", summary.peakScore), label: "peak mph")
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: derived

    private struct CapturedRow: Identifiable {
        let id: String
        let name: String
        let color: Color
        let count: Int
    }

    private var capturedRows: [CapturedRow] {
        summary.capturedByOpponent
            .sorted { $0.value > $1.value }
            .map { ownerId, count in
                let player = store.player(id: ownerId)
                return CapturedRow(
                    id: ownerId,
                    name: player?.displayName ?? "rival",
                    color: player.map { Color(hex: $0.colorHex) } ?? .red,
                    count: count
                )
            }
    }

    private var distanceText: String {
        let miles = summary.distanceMeters / 1609.344
        return String(format: "%.1f mi", miles)
    }

    private var durationText: String {
        let total = Int(summary.movingTime.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// a wrapper so the rendered share image can drive `.sheet(item:)`
private struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    /// concrete temp PNG to share; nil only if the file write failed
    let url: URL?
}

/// presents the system share sheet for the rendered recap image
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class ShareCardItemSource: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let fileURL: URL?
    private let title = "My Rev drive"

    init(fileURL: URL?, image: UIImage) {
        self.fileURL = fileURL
        self.image = image
    }

    private var item: Any { fileURL ?? image }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        item
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        item
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) {
            metadata.imageProvider = provider
        } else {
            metadata.imageProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}

//rev wordmark
private struct RevWordmark: Shape {
    static let viewBox = CGSize(width: 48.62, height: 17.71)

    static let commands: [String] = [
        "M0,17.5V0h8.9c.72,0,1.38.06,1.97.19.59.13,1.12.32,1.6.58.47.26.87.58,1.2.96.33.38.58.83.76,1.34.18.51.26,1.09.26,1.73,0,1.09-.29,2-.86,2.75-.58.74-1.36,1.25-2.35,1.52v.14c.67.11,1.22.32,1.64.61.42.3.73.67.92,1.13.19.46.29,1.01.29,1.67v2.88c0,.32.01.65.04.98.02.34.11.67.25,1.01h-3.77c-.1-.21-.16-.49-.2-.84-.04-.35-.06-.74-.06-1.15v-2.23c0-.5-.08-.91-.23-1.25s-.42-.6-.8-.78-.94-.28-1.66-.28H3.41v-2.95h4.63c1.01,0,1.73-.24,2.16-.72.43-.48.65-1.08.65-1.8,0-.45-.07-.82-.2-1.12-.14-.3-.33-.54-.59-.73-.26-.19-.55-.33-.89-.42-.34-.09-.71-.13-1.13-.13H3.74v14.4H0Z",
        "M23.66,17.71c-1.33,0-2.46-.27-3.41-.82-.94-.54-1.67-1.31-2.17-2.29-.5-.98-.76-2.13-.76-3.44,0-1.39.25-2.59.76-3.6.5-1.01,1.22-1.78,2.16-2.33.94-.54,2.04-.82,3.3-.82,1.46,0,2.65.32,3.59.96.94.64,1.61,1.52,2.02,2.63.41,1.11.55,2.39.42,3.83h-8.76c0,.72.12,1.32.35,1.8.23.48.56.84,1,1.08s.94.36,1.51.36c.67,0,1.21-.14,1.62-.41s.69-.63.85-1.08h3.31c-.11.85-.43,1.58-.96,2.2-.53.62-1.2,1.09-2.03,1.43s-1.76.5-2.8.5ZM20.81,9.98l-.31-.34h5.93l-.31.34c.03-.66-.06-1.2-.28-1.64-.22-.44-.52-.77-.91-.98-.39-.22-.86-.32-1.4-.32s-1.02.12-1.42.35c-.4.23-.71.57-.94,1.02-.22.45-.34.98-.36,1.58Z",
        "M35.64,17.5l-4.39-12.86h3.79l1.99,7.37.72,2.81h.14l.72-2.81,1.99-7.37h3.82l-4.39,12.86h-4.39Z",
        "M46.8,17.69c-.54,0-.98-.16-1.32-.47-.34-.31-.5-.72-.5-1.24s.17-.95.5-1.26c.34-.31.78-.47,1.32-.47s.98.16,1.32.47c.34.31.5.73.5,1.26s-.17.92-.5,1.24c-.34.31-.78.47-1.32.47Z",
    ]

    func path(in rect: CGRect) -> Path {
        let logo = SVGPathParser.path(commands: Self.commands)
        let box = Self.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.minX + (rect.width - box.width * scale) / 2
        let dy = rect.minY + (rect.height - box.height * scale) / 2
        return logo.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}

/// minimal svg-parser
private enum SVGPathParser {
    static func path(commands: [String]) -> Path {
        let cg = CGMutablePath()
        for d in commands { append(d, to: cg) }
        return Path(cg)
    }

    private static let tokenizer = try! NSRegularExpression(
        pattern: "[MmLlHhVvCcSsQqTtAaZz]|[+-]?(?:\\d*\\.\\d+|\\d+\\.?\\d*)(?:[eE][+-]?\\d+)?"
    )

    private static func tokens(_ d: String) -> [String] {
        let ns = d as NSString
        return tokenizer
            .matches(in: d, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func append(_ d: String, to path: CGMutablePath) {
        let toks = tokens(d)
        var i = 0
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var prevCmd: Character = " "
        var prevControl2: CGPoint?

        func num() -> CGFloat {
            defer { i += 1 }
            return CGFloat(Double(toks[i]) ?? 0)
        }

        while i < toks.count {
            let cmd: Character
            if let c = toks[i].first, toks[i].count == 1, c.isLetter {
                cmd = c; i += 1
            } else {
                switch prevCmd {
                case "M": cmd = "L"
                case "m": cmd = "l"
                default: cmd = prevCmd
                }
            }

            switch cmd {
            case "M", "m":
                var x = num(); var y = num()
                if cmd == "m" { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y); start = cur
                path.move(to: cur); prevControl2 = nil
            case "L", "l":
                var x = num(); var y = num()
                if cmd == "l" { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y); path.addLine(to: cur); prevControl2 = nil
            case "H", "h":
                var x = num(); if cmd == "h" { x += cur.x }
                cur.x = x; path.addLine(to: cur); prevControl2 = nil
            case "V", "v":
                var y = num(); if cmd == "v" { y += cur.y }
                cur.y = y; path.addLine(to: cur); prevControl2 = nil
            case "C", "c":
                var x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num()
                if cmd == "c" { x1 += cur.x; y1 += cur.y; x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
                let c2 = CGPoint(x: x2, y: y2)
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: c2)
                prevControl2 = c2; cur = CGPoint(x: x, y: y)
            case "S", "s":
                var x2 = num(), y2 = num(), x = num(), y = num()
                if cmd == "s" { x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
                var c1 = cur
                if let pc2 = prevControl2, "CcSs".contains(prevCmd) {
                    c1 = CGPoint(x: 2 * cur.x - pc2.x, y: 2 * cur.y - pc2.y)
                }
                let c2 = CGPoint(x: x2, y: y2)
                path.addCurve(to: CGPoint(x: x, y: y), control1: c1, control2: c2)
                prevControl2 = c2; cur = CGPoint(x: x, y: y)
            case "Z", "z":
                path.closeSubpath(); cur = start; prevControl2 = nil
            default:
                break
            }
            prevCmd = cmd
        }
    }
}

private struct DriveShareCard: View {
    let summary: DriveSummary
    let store: TerritoryStore
    let date: Date

    var streetImage: UIImage? = nil

    var hexPolygons: [[CGPoint]] = []

    private var accent: Color { Color(hex: store.localPlayer.colorHex) }

    var body: some View {
        ZStack {
            // profile-color glow base
            background

            // faint street wireframe
            if let streetImage {
                Image(uiImage: streetImage)
                    .resizable()
                    .frame(width: streetImage.size.width, height: streetImage.size.height)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.80),
                                .init(color: .clear, location: 0.97),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 380, height: 620, alignment: .top)
                    .blendMode(.screen)
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }

            // the gained hexes
            hexLayer

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            stats
        }
        .frame(width: 380, height: 620)
        .clipped()
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.55), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
        }
    }

    private var hexLayer: some View {
        Canvas { context, _ in
            for polygon in hexPolygons where polygon.count >= 3 {
                var path = Path()
                path.move(to: polygon[0])
                for point in polygon.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                context.fill(path, with: .color(.white.opacity(0.22)))
                context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RevWordmark()
                    .fill(.white)
                    .frame(width: 76, height: 76 * RevWordmark.viewBox.height / RevWordmark.viewBox.width)
                Spacer()
                Text(date, format: .dateTime.month().day().year())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary.tilesDriven)")
                        .font(.system(size: 84, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("tiles driven")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }

                VStack(spacing: 8) {
                    ForEach(breakdownRows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(row.value)
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .font(.headline)

                HStack {
                    metricColumn(distanceText, "distance")
                    Spacer()
                    metricColumn(durationText, "moving time")
                }

                Text("driverev.app")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(28)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    private func metricColumn(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var breakdownRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if summary.tilesClaimed > 0 { rows.append(("Claimed", "\(summary.tilesClaimed)")) }
        if summary.totalCaptured > 0 { rows.append(("Captured", "\(summary.totalCaptured)")) }
        if summary.tilesEnclosed > 0 { rows.append(("Enclosed", "\(summary.tilesEnclosed)")) }
        if summary.tilesReinforced > 0 { rows.append(("Reinforced", "\(summary.tilesReinforced)")) }
        return rows
    }

    private var distanceText: String {
        String(format: "%.1f mi", summary.distanceMeters / 1609.344)
    }

    private var durationText: String {
        let total = Int(summary.movingTime.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension View {
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(.blue)
        } else {
            buttonStyle(.borderedProminent).tint(.blue)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
