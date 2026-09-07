import MapKit
import SwiftUI

struct WalkHistorySection: View {
    @ObservedObject var store: WalkHistoryStore
    @State private var selectedWalk: WalkRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Label("Walk History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer(minLength: AppSpacing.small)
                Text("\(store.records.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }

            Text("Saved on this device only.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)

            if let message = store.errorMessage {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Label("Walk history needs attention", systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Button("Retry") { store.retry() }
                        .fontWeight(.semibold)
                }
                .historyCard()
            }

            if store.records.isEmpty && store.errorMessage == nil {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Label("No walks yet", systemImage: "figure.walk")
                        .font(.headline)
                    Text("Finish a walk to see it here, with your dogs, distance and route.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .historyCard()
            } else if !store.records.isEmpty {
                LazyVStack(spacing: AppSpacing.small) {
                    ForEach(store.records) { walk in
                        Button {
                            selectedWalk = walk
                        } label: {
                            WalkHistoryCard(walk: walk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows walk details and the recorded route on a map.")
                    }
                }
            }
        }
        .tint(AppColors.brand)
        .sheet(item: $selectedWalk) { walk in
            WalkHistoryDetailView(walk: walk)
        }
    }
}

struct WalkHistoryCard: View {
    let walk: WalkRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(walk.startedAt, format: .dateTime.day().month(.abbreviated).year())
                        .font(.headline)
                    Text(walk.startedAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer(minLength: AppSpacing.small)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
            }

            Label(walk.dogs.map(\.name).joined(separator: ", "), systemImage: "dog.fill")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            WalkHistoryStats(walk: walk)

            if walk.routeSegments.contains(where: { !$0.isEmpty }) {
                WalkRouteThumbnail(segments: walk.routeSegments)
                    .frame(height: 88)
                    .accessibilityHidden(true)
                HStack {
                    Text("Route preview")
                        .foregroundStyle(AppColors.secondaryText)
                    Spacer()
                    Label("View route", systemImage: "map")
                        .foregroundStyle(AppColors.brand)
                }
                .font(.caption)
            } else {
                Label("No route was recorded", systemImage: "map")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .historyCard()
        .foregroundStyle(AppColors.primaryText)
    }
}

struct WalkHistoryDetailView: View {
    let walk: WalkRecord
    @Environment(\.dismiss) private var dismiss

    private var points: [WalkRoutePoint] { walk.routeSegments.flatMap { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(walk.startedAt, format: .dateTime.day().month(.wide).year())
                            .font(.title2.bold())
                        Label(walk.dogs.map(\.name).joined(separator: ", "), systemImage: "dog.fill")
                            .font(.subheadline)
                        WalkHistoryStats(walk: walk)
                        Divider()
                        LabeledContent("Started") {
                            Text(walk.startedAt, format: .dateTime.hour().minute())
                        }
                        LabeledContent("Finished") {
                            Text(walk.endedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                        }
                        Text("Walking time excludes pauses.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .historyCard()

                    Text("Recorded route")
                        .font(.headline)

                    if let first = points.first, let last = points.last {
                        routeMap(first: first, last: last)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                        Text(points.count == 1
                             ? "Only one location was recorded for this walk."
                             : "The line shows recorded locations. Paused parts are not joined.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        Label("No route was recorded for this walk.", systemImage: "map")
                            .foregroundStyle(AppColors.secondaryText)
                            .historyCard()
                    }

                    Text("Saved on this device only.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
            .navigationTitle("Walk Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(AppColors.brand)
        }
    }

    private func routeMap(first: WalkRoutePoint, last: WalkRoutePoint) -> some View {
        Map(initialPosition: .rect(WalkRouteBounds.mapRect(for: points))) {
            ForEach(Array(walk.routeSegments.enumerated()), id: \.offset) { _, segment in
                if segment.count >= 2 {
                    MapPolyline(coordinates: segment.map(\.coordinate))
                        .stroke(AppColors.brand, lineWidth: 5)
                } else if let point = segment.first {
                    Annotation("Recorded location", coordinate: point.coordinate) {
                        Circle()
                            .fill(AppColors.brand)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                    }
                }
            }
            if points.count == 1 {
                Marker("Recorded location", systemImage: "location.fill", coordinate: first.coordinate)
                    .tint(AppColors.brand)
            } else if abs(first.latitude - last.latitude) < 0.000001
                        && abs(first.longitude - last.longitude) < 0.000001 {
                Marker("Start / Finish", systemImage: "flag.fill", coordinate: first.coordinate)
                    .tint(AppColors.brand)
            } else {
                Marker("Start", systemImage: "play.fill", coordinate: first.coordinate)
                    .tint(AppColors.brand)
                Marker("Finish", systemImage: "flag.fill", coordinate: last.coordinate)
                    .tint(.orange)
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .accessibilityLabel("Map of the recorded walk route")
    }
}

private struct WalkHistoryStats: View {
    let walk: WalkRecord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.large) {
                distance.fixedSize()
                duration.fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                distance
                duration
            }
        }
    }

    private var distance: some View {
        Label {
            Text("\(walk.distanceKilometres, specifier: "%.2f") km")
                .monospacedDigit()
        } icon: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityLabel("Distance, \(walk.distanceKilometres, specifier: "%.2f") kilometres")
    }

    private var duration: some View {
        Label(walkDurationText(walk.activeDuration), systemImage: "stopwatch")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .accessibilityLabel("Walking time, \(walkDurationText(walk.activeDuration))")
    }

    private func walkDurationText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval < Double(Int.max) else { return "Unknown" }
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds)s"
    }
}

/// A lightweight sketch, not another live map for every history entry.
/// Each recorded segment is drawn separately so a pause never creates a connector.
struct WalkRouteThumbnail: View {
    let segments: [[WalkRoutePoint]]

    var body: some View {
        Canvas { context, size in
            let mapSegments = WalkRouteBounds.projectedSegments(segments)
            let allPoints = mapSegments.flatMap { $0 }
            guard let first = allPoints.first, let last = allPoints.last else { return }
            let minX = allPoints.map(\.x).min() ?? first.x
            let maxX = allPoints.map(\.x).max() ?? first.x
            let minY = allPoints.map(\.y).min() ?? first.y
            let maxY = allPoints.map(\.y).max() ?? first.y
            let availableWidth = max(1, size.width - 36)
            let availableHeight = max(1, size.height - 28)
            let scale = min(availableWidth / max(maxX - minX, 1),
                            availableHeight / max(maxY - minY, 1))

            func position(_ point: MKMapPoint) -> CGPoint {
                CGPoint(x: size.width / 2 + (point.x - (minX + maxX) / 2) * scale,
                        y: size.height / 2 + (point.y - (minY + maxY) / 2) * scale)
            }

            for segment in mapSegments where segment.count >= 2 {
                var path = Path()
                path.addLines(segment.map(position))
                context.stroke(path, with: .color(AppColors.brand),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            // Isolated recorded points remain visible, including very short walks.
            for segment in mapSegments where segment.count == 1 {
                if let point = segment.first {
                    let centre = position(point)
                    let dot = CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(AppColors.brand))
                }
            }

            let start = position(first)
            let end = position(last)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)),
                         with: .color(AppColors.brand))
            context.stroke(Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)),
                           with: .color(.orange), lineWidth: 3)
        }
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
    }
}

enum WalkRouteBounds {
    /// Unwrap longitude around the first point to keep a route crossing the date line compact.
    static func projectedSegments(_ segments: [[WalkRoutePoint]]) -> [[MKMapPoint]] {
        guard let first = segments.lazy.compactMap(\.first).first else { return [] }
        let anchor = MKMapPoint(first.coordinate)
        let worldWidth = MKMapRect.world.size.width
        return segments.map { segment in
            segment.map { point in
                var projected = MKMapPoint(point.coordinate)
                if projected.x - anchor.x > worldWidth / 2 { projected.x -= worldWidth }
                if projected.x - anchor.x < -worldWidth / 2 { projected.x += worldWidth }
                return projected
            }
        }
    }

    static func mapRect(for points: [WalkRoutePoint]) -> MKMapRect {
        guard let first = points.first else { return .world }
        let projected = projectedSegments([points]).flatMap { $0 }
        let minX = projected.map(\.x).min() ?? 0
        let maxX = projected.map(\.x).max() ?? minX
        let minY = projected.map(\.y).min() ?? 0
        let maxY = projected.map(\.y).max() ?? minY
        // A single point or a very short walk should still show useful street context.
        // MapKit's Mercator scale is undefined near the poles even for valid GPS coordinates.
        let scaleLatitude = min(85, max(-85, first.latitude))
        let minimumSpan = max(1, MKMapPointsPerMeterAtLatitude(scaleLatitude)) * 350
        let width = max(maxX - minX, minimumSpan) * 1.4
        let height = max(maxY - minY, minimumSpan) * 1.4
        return MKMapRect(x: (minX + maxX - width) / 2,
                         y: (minY + maxY - height) / 2,
                         width: width, height: height)
    }
}

private extension View {
    func historyCard() -> some View {
        padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
