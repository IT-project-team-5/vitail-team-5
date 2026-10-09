import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

@MainActor
final class WalkSessionTracker: ObservableObject {
    enum Status: Equatable {
        case idle
        case walking
        case paused
        case finished
    }

    static let maximumAcceptedAccuracy: CLLocationAccuracy = 30
    static let maximumRouteGap: TimeInterval = 60

    @Published private(set) var status: Status = .idle
    @Published private(set) var distanceMetres: CLLocationDistance = 0
    @Published private(set) var participatingDogs: [Dog] = []
    @Published private(set) var routeSegments: [[WalkRoutePoint]] = []
    @Published private(set) var completedWalk: WalkRecord?
    @Published private(set) var trackingNotice: String?

    // These callbacks run with the location delegate, not with a SwiftUI render.
    var onChange: (() -> Void)?
    var onFinish: (WalkRecord) -> Void
    var hasVenueActivity: ((Date) -> Bool)?

    private var lastTrackedLocation: CLLocation?
    private var lastRouteTimestamp: Date?
    private var startsNewSegment = true
    private var startedAt: Date?
    private var sessionID: UUID?
    private var activeIntervalStartedAt: Date?
    private var activeDuration: TimeInterval = 0
    private let now: () -> Date
    var enforcesRewardLimits = false
    private var lastMovementAt: Date?
    private var pausedAt: Date?
    var pointCount: Int { routeSegments.reduce(0) { $0 + $1.count } }

    func checkInactivity() {
        checkInactivity(at: now())
    }

    private func checkInactivity(at date: Date) {
        if status == .walking && hasVenueActivity?(date) == true {
            lastMovementAt = date
            return
        }
        guard enforcesRewardLimits, isInProgress,
              let last = [pausedAt, lastMovementAt].compactMap({ $0 }).min(),
              date.timeIntervalSince(last) >= 300 else { return }
        finish()
        trackingNotice = "Walk ended after 5 minutes without activity. Review the summary and choose the dogs who came along."
    }

    init(now: @escaping () -> Date = Date.init, onFinish: @escaping (WalkRecord) -> Void = { _ in }) {
        self.now = now
        self.onFinish = onFinish
    }

    func elapsedActiveDuration(at date: Date) -> TimeInterval {
        activeDuration + (activeIntervalStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    var distanceKilometres: Double {
        distanceMetres / 1_000
    }

    var canStart: Bool {
        status == .idle || status == .finished
    }

    var isInProgress: Bool {
        status == .walking || status == .paused
    }

    var canFinish: Bool {
        status == .walking || status == .paused
    }

    static func canUse(_ location: CLLocation?) -> Bool {
        guard let location else { return false }
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.timestamp.timeIntervalSince1970.isFinite
            && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maximumAcceptedAccuracy
    }

    static func isFresh(_ location: CLLocation?, at date: Date = Date()) -> Bool {
        guard let location, canUse(location) else { return false }
        let age = date.timeIntervalSince(location.timestamp)
        return age.isFinite && age >= -5 && age <= 15
    }

    func start(from location: CLLocation?, dogs: [Dog]) {
        guard canStart, let location, Self.canUse(location) else { return }

        let startTime = now()
        lastMovementAt = startTime
        pausedAt = nil
        var seenDogIDs: Set<Int> = []
        participatingDogs = dogs.filter { seenDogIDs.insert($0.id).inserted }
        distanceMetres = 0
        routeSegments = []
        completedWalk = nil
        trackingNotice = nil
        sessionID = UUID()
        lastRouteTimestamp = nil
        startsNewSegment = true
        startedAt = startTime
        activeIntervalStartedAt = startTime
        activeDuration = 0
        // A fresh map fix can still predate the Start tap. Do not count that
        // movement; the first fix in the active interval becomes the anchor.
        lastTrackedLocation = nil
        if location.timestamp >= startTime {
            lastTrackedLocation = location
            appendRoutePoint(location)
        }
        status = .walking
        onChange?()
    }

    func pause() {
        guard status == .walking else { return }
        pausedAt = now()
        finishActiveInterval(at: now())
        lastTrackedLocation = nil
        startsNewSegment = true
        status = .paused
        onChange?()
    }

    func resume(from location: CLLocation?) {
        checkInactivity()
        guard status == .paused else { return }
        pausedAt = nil
        lastTrackedLocation = nil
        startsNewSegment = true
        let resumeTime = now()
        activeIntervalStartedAt = resumeTime
        trackingNotice = nil
        if let location, Self.canUse(location), location.timestamp >= resumeTime,
           isNewRouteTimestamp(location.timestamp) {
            lastTrackedLocation = location
            appendRoutePoint(location)
        }
        status = .walking
        onChange?()
    }

    func finish() {
        guard canFinish, let startedAt, let sessionID else { return }
        let endTime = max(now(), startedAt)
        finishActiveInterval(at: endTime)
        lastTrackedLocation = nil
        let record = WalkRecord(
            id: sessionID, startedAt: startedAt, endedAt: endTime,
            activeDuration: activeDuration, distanceMetres: distanceMetres,
            dogs: participatingDogs.map { WalkDogSnapshot(id: $0.id, name: $0.name) },
            routeSegments: routeSegments
        )
        completedWalk = record
        status = .finished
        trackingNotice = nil
        onFinish(record)
        onChange?()
    }

    func record(_ location: CLLocation) {
        if recordLocation(location) { onChange?() }
    }

    func recordBatch(_ locations: [CLLocation]) {
        guard status == .walking, let activeIntervalStartedAt else { return }
        let latestAllowedTime = now().addingTimeInterval(5)
        var changed = false
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            // Delayed batches are valid; samples from before Start/Resume are not.
            guard location.timestamp >= activeIntervalStartedAt,
                  location.timestamp <= latestAllowedTime else { continue }
            if recordLocation(location) { changed = true }
        }
        if changed { onChange?() }
        checkInactivity()
    }

    func interruptRoute(message: String) {
        guard status == .walking else { return }
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = message
        onChange?()
    }

    func pauseForInterruption(message: String) {
        guard status == .walking else { return }
        pausedAt = now()
        finishActiveInterval(at: now())
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = message
        status = .paused
        onChange?()
    }

    func makeDraft() -> WalkDraft? {
        guard isInProgress, let sessionID, let startedAt else { return nil }
        let checkpoint = max(now(), startedAt)
        let elapsed = activeIntervalStartedAt.map { max(0, checkpoint.timeIntervalSince($0)) } ?? 0
        return WalkDraft(
            id: sessionID, startedAt: startedAt, checkpointAt: checkpoint,
            activeDuration: activeDuration + elapsed, distanceMetres: distanceMetres,
            dogs: participatingDogs, routeSegments: routeSegments
        )
    }

    @discardableResult
    func restore(_ draft: WalkDraft) -> Bool {
        guard canStart, draft.isValid, draft.finishedRecord == nil else { return false }
        sessionID = draft.id
        startedAt = draft.startedAt
        activeDuration = draft.activeDuration
        activeIntervalStartedAt = nil
        participatingDogs = draft.dogs
        distanceMetres = draft.distanceMetres
        routeSegments = draft.routeSegments
        completedWalk = nil
        lastRouteTimestamp = draft.routeSegments.last?.last?.timestamp
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = "Previous walk recovered. Tap Resume when ready. Time while the app was closed is not counted."
        // Recovery is another segment boundary, not a reset of the inactivity
        // window. Reconstruct accepted movement without bridging saved segments.
        lastMovementAt = draft.routeSegments.first?.first?.timestamp ?? draft.startedAt
        savedSegments: for segment in draft.routeSegments {
            if let first = segment.first, let lastMovementAt,
               first.timestamp.timeIntervalSince(lastMovementAt) >= 300 { break }
            for (previous, point) in zip(segment, segment.dropFirst()) {
                if let lastMovementAt,
                   point.timestamp.timeIntervalSince(lastMovementAt) >= 300 { break savedSegments }
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    .distance(from: CLLocation(latitude: previous.latitude, longitude: previous.longitude))
                if seconds > 0, seconds <= Self.maximumRouteGap,
                   distance >= 1, distance / seconds <= 3 {
                    lastMovementAt = point.timestamp
                }
            }
        }
        pausedAt = draft.checkpointAt
        status = .paused
        onChange?()
        return true
    }

    private func recordLocation(_ location: CLLocation) -> Bool {
        guard status == .walking, isNewRouteTimestamp(location.timestamp) else { return false }
        if enforcesRewardLimits && pointCount >= 5000 { return false }
        // Use sample time here so a delayed batch can first establish movement
        // before the cutoff. A later sample must never revive an expired walk.
        checkInactivity(at: location.timestamp)
        guard status == .walking else { return false }
        if enforcesRewardLimits && !Self.canUse(location) {
            lastTrackedLocation = nil
            startsNewSegment = true
            return false
        }
        guard Self.canUse(location) else { return false }

        if let previous = lastTrackedLocation,
           location.timestamp.timeIntervalSince(previous.timestamp) > Self.maximumRouteGap {
            lastTrackedLocation = nil
            startsNewSegment = true
        }

        guard let previousLocation = lastTrackedLocation else {
            if lastMovementAt == nil { lastMovementAt = location.timestamp }
            lastTrackedLocation = location
            appendRoutePoint(location)
            trackingNotice = nil
            return true
        }

        guard location.timestamp > previousLocation.timestamp else { return false }

        let segmentDistance = location.distance(from: previousLocation)
        guard segmentDistance.isFinite, segmentDistance >= 0 else { return false }

        if enforcesRewardLimits && segmentDistance / location.timestamp.timeIntervalSince(previousLocation.timestamp) > 3 {
            // Keep both measured points for server validation, but never draw/credit a jump.
            startsNewSegment = true
            lastTrackedLocation = location
            appendRoutePoint(location)
            return true
        }
        if segmentDistance >= 1 { lastMovementAt = location.timestamp }

        distanceMetres += segmentDistance
        lastTrackedLocation = location
        appendRoutePoint(location)
        trackingNotice = nil
        return true
    }

    private func isNewRouteTimestamp(_ timestamp: Date) -> Bool {
        guard let lastRouteTimestamp else { return true }
        return timestamp > lastRouteTimestamp
    }

    private func appendRoutePoint(_ location: CLLocation) {
        let point = WalkRoutePoint(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            accuracyM: location.horizontalAccuracy,
            isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false
        )
        if startsNewSegment || routeSegments.isEmpty {
            routeSegments.append([point])
            startsNewSegment = false
        } else {
            routeSegments[routeSegments.count - 1].append(point)
        }
        lastRouteTimestamp = location.timestamp
    }

    private func finishActiveInterval(at endTime: Date) {
        guard let activeIntervalStartedAt else { return }
        activeDuration += max(0, endTime.timeIntervalSince(activeIntervalStartedAt))
        self.activeIntervalStartedAt = nil
    }
}

enum WalkDrawerDetent: Equatable {
    case collapsed
    case expanded
}

/// The content keeps one expanded layout while its visible top edge follows the
/// finger. Resizing never pins controls above an independently scrolling history.
struct WalkDrawerGeometry: Equatable {
    static let handleHeight: CGFloat = 44
    let collapsedHeight: CGFloat
    let expandedHeight: CGFloat
    let controlsOverflowCollapsed: Bool

    init(availableHeight: CGFloat, controlsHeight: CGFloat, accessibilitySize: Bool) {
        let available = max(0, availableHeight)
        let naturalHeight = Self.handleHeight + max(0, controlsHeight)
        collapsedHeight = min(available * 0.65, max(Self.handleHeight + 88, naturalHeight))
        expandedHeight = min(available * 0.94, max(
            available * (accessibilitySize ? 0.72 : 0.52), collapsedHeight + 96
        ))
        controlsOverflowCollapsed = naturalHeight > collapsedHeight + 1
    }

    func height(at detent: WalkDrawerDetent, translation: CGFloat = 0) -> CGFloat {
        let restingHeight = detent == .collapsed ? collapsedHeight : expandedHeight
        return min(expandedHeight, max(collapsedHeight, restingHeight - translation))
    }

    func snap(from detent: WalkDrawerDetent, predictedTranslation: CGFloat) -> WalkDrawerDetent {
        height(at: detent, translation: predictedTranslation) >= (collapsedHeight + expandedHeight) / 2
            ? .expanded : .collapsed
    }

    func allowsContentScrolling(at detent: WalkDrawerDetent) -> Bool {
        // A short screen or large text must never make Finish unreachable.
        detent == .expanded || controlsOverflowCollapsed
    }
}

private struct WalkDrawerControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct WalkMapView: View {
    let isActive: Bool

    @ObservedObject private var coordinator: WalkSessionCoordinator
    @ObservedObject private var locationManager: WalkLocationManager
    @ObservedObject private var walkTracker: WalkSessionTracker
    @ObservedObject private var dogSelection: WalkDogSelectionViewModel
    @ObservedObject private var walkHistory: WalkHistoryStore
    @ObservedObject private var checkIns: CheckInProgressStore
    @ObservedObject private var venueCheckIns: WalkVenueCheckInStore
    @ObservedObject private var friends: FriendsStore
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var hasCentredOnUser = false
    @State private var drawerDetent: WalkDrawerDetent
    @State private var controlsHeight: CGFloat = 240
    @State private var selectedPeer: SocialMapPeer?
    @State private var selectedVenueID: Int?
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var panelDrag: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    init(
        coordinator: WalkSessionCoordinator, isActive: Bool,
        initialDrawerDetent: WalkDrawerDetent = .collapsed,
        checkIns: CheckInProgressStore? = nil,
        friends: FriendsStore
    ) {
        _drawerDetent = State(initialValue: initialDrawerDetent)
        self.isActive = isActive
        self.coordinator = coordinator
        locationManager = coordinator.locationManager
        walkTracker = coordinator.tracker
        dogSelection = coordinator.dogSelection
        walkHistory = coordinator.history
        self.checkIns = checkIns ?? CheckInProgressStore(ownerID: 0)
        venueCheckIns = coordinator.venueCheckIns
        self.friends = friends
    }

    var body: some View {
        GeometryReader { geometry in
            let drawer = WalkDrawerGeometry(
                availableHeight: geometry.size.height, controlsHeight: controlsHeight,
                accessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            ZStack(alignment: .bottom) {
                mapCard
                bottomPanel(geometry: drawer)
            }
            .contentShape(Rectangle())
            .clipped()
        }
        .sheet(isPresented: Binding(
            get: { isActive && coordinator.isFinishPresented },
            set: { if isActive { coordinator.isFinishPresented = $0 } }
        )) {
            WalkFinishSummaryView(coordinator: coordinator)
        }
        .sheet(item: $selectedPeer) { peer in
            SocialPeerSheet(peer: peer, store: friends)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { venueCheckIns.venues.first { $0.id == selectedVenueID } },
            set: { selectedVenueID = $0?.id }
        )) { venue in
            WalkVenueDetailSheet(store: venueCheckIns, venue: venue)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            coordinator.setWalkPageVisible(isActive)
            if isActive { reloadDogs() }
        }
        .task { await venueCheckIns.load() }
        .onDisappear {
            coordinator.setWalkPageVisible(false)
        }
        .onChange(of: isActive) { _, active in
            coordinator.setWalkPageVisible(active)
            if active { reloadDogs() }
        }
        .onChange(of: walkTracker.status) { _, status in
            if status == .finished { reloadDogs() }
        }
        .onChange(of: locationManager.location?.timestamp) { _, _ in
            guard !hasCentredOnUser, locationManager.location != nil else { return }
            centreOnCurrentLocation()
            hasCentredOnUser = true
        }
        .onChange(of: socialPeers.map(\.id)) { _, visiblePeerIDs in
            if let selectedPeer, !visiblePeerIDs.contains(selectedPeer.id) {
                self.selectedPeer = nil
            }
        }
    }

    private func bottomPanel(geometry: WalkDrawerGeometry) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) {
                        drawerDetent = drawerDetent == .collapsed ? .expanded : .collapsed
                    }
                } label: {
                    Capsule().fill(AppColors.secondaryText.opacity(0.35))
                        .frame(width: 36, height: 4)
                        .frame(maxWidth: .infinity)
                        .frame(height: WalkDrawerGeometry.handleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(drawerDetent == .expanded ? "Collapse walk menu" : "Expand walk menu")
                .accessibilityValue(drawerDetent == .expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Drag the handle to resize. Scroll the open menu for walk history.")
                .accessibilityAdjustableAction { direction in
                    withAnimation(.snappy) {
                        if direction == .increment { drawerDetent = .expanded }
                        else if direction == .decrement { drawerDetent = .collapsed }
                    }
                }
                .highPriorityGesture(drawerDrag(geometry: geometry))

                ScrollView {
                    VStack(spacing: 0) {
                        drawerControls
                            .id("walk-drawer-controls")
                            .background {
                                GeometryReader { controls in
                                    Color.clear.preference(
                                        key: WalkDrawerControlsHeightKey.self, value: controls.size.height
                                    )
                                }
                            }
                        drawerDetails
                            .accessibilityHidden(drawerDetent == .collapsed)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(!geometry.allowsContentScrolling(at: drawerDetent) || panelDrag != 0)
                // Only the closed summary delegates its vertical drag to the
                // drawer. The open content has native scrolling with no competing
                // sheet gesture; the handle always remains available to resize.
                .highPriorityGesture(
                    drawerDrag(geometry: geometry),
                    including: drawerDetent == .collapsed && !geometry.controlsOverflowCollapsed ? .all : .subviews
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.expandedHeight, alignment: .top)
            .background(AppColors.surface)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .frame(height: geometry.height(at: drawerDetent, translation: panelDrag), alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.08), radius: 12, y: -3)
            .onPreferenceChange(WalkDrawerControlsHeightKey.self) { height in
                if height > 0, abs(controlsHeight - height) > 0.5 { controlsHeight = height }
            }
            .onChange(of: drawerDetent) { _, detent in
                if detent == .collapsed {
                    // The next collapsed presentation must show the main action,
                    // even if history was scrolled far down before collapsing.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo("walk-drawer-controls", anchor: .top) }
                }
            }
        }
    }

    private func drawerDrag(geometry: WalkDrawerGeometry) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($panelDrag) { value, state, transaction in
                transaction.animation = nil
                state = value.translation.height
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    drawerDetent = geometry.snap(from: drawerDetent, predictedTranslation: value.predictedEndTranslation.height)
                }
            }
    }

    private var drawerControls: some View {
        VStack(spacing: 0) {
            WalkDogSelectionCard(
                selection: dogSelection, session: walkTracker, location: locationManager.location,
                canStartNewWalk: coordinator.canStartNewWalk,
                onReviewFinish: {
                    if coordinator.finishSummary != nil { coordinator.isFinishPresented = true }
                    else { coordinator.retryStorage(); drawerDetent = .expanded }
                }
            )
            if coordinator.storageErrorMessage != nil {
                Button("Your walk needs attention · Retry") { coordinator.retryStorage() }
                    .font(.caption).padding(.bottom, AppSpacing.small)
            }
            ForEach(checkIns.visibleItems.filter { $0.status != .collected && $0.walkRequestID == nil }) { item in
                CheckInProgressCard(store: checkIns, checkInID: item.id)
                    .padding(.horizontal, AppSpacing.medium)
                    .padding(.bottom, AppSpacing.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var drawerDetails: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            if let message = coordinator.storageErrorMessage {
                LocationStatusCard(
                    icon: "exclamationmark.triangle.fill", title: "Save your walk",
                    message: message, actionTitle: "Retry", action: coordinator.retryStorage
                )
            }
            if let notice = walkTracker.trackingNotice {
                Text(notice).font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
            netWalkPanel
            if let message = venueCheckIns.errorMessage {
                LocationStatusCard(icon: "wifi.exclamationmark", title: "Venue check-ins", message: message,
                    actionTitle: "Retry", action: { Task { await venueCheckIns.load() } })
            }
            WalkHistorySection(store: walkHistory)
            WalkSyncPanel(sync: coordinator.sync, history: walkHistory)
            Text("Walking continues with the screen locked. Pauses are excluded. After 5 minutes without activity, review your walk to finish.")
                .font(.footnote).foregroundStyle(AppColors.secondaryText)
        }
        .padding(.top, AppSpacing.medium)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.bottom, AppSpacing.large)
    }

    private func reloadDogs() {
        Task { await dogSelection.load() }
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            ForEach(venueCheckIns.venues) { venue in
                if venue.id == selectedVenueID {
                    MapCircle(center: venue.coordinate, radius: WalkVenueCheckInStore.radiusMetres)
                        .foregroundStyle(AppColors.brand.opacity(0.12))
                        .stroke(AppColors.brand.opacity(0.6), lineWidth: 1)
                }
                Annotation(venue.name, coordinate: venue.coordinate) {
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        WalkVenueMarker(venue: venue, presentation: venueCheckIns.presentation(for: venue, at: tick.date)) {
                            selectedVenueID = venue.id
                        }
                    }
                }
            }
            ForEach(socialPeers) { peer in
                Annotation(peerName(peer.user), coordinate: peer.coordinate) {
                    VStack(spacing: 2) {
                        Button { selectedPeer = peer } label: {
                            SocialAvatarView(user: peer.user, size: 36)
                                .overlay {
                                    Circle().stroke(peer.isNetPartner ? Color.orange : AppColors.brand, lineWidth: 3)
                                }
                                .shadow(radius: 2, y: 1)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(peerName(peer.user)), \(peer.isNetPartner ? "walking partner" : (peer.isApproximate ? "approximate nearby position" : "shared location"))")
                        Text(peer.isApproximate ? "\(peerName(peer.user)) · nearby" : peerName(peer.user))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial)
                            .clipShape(Capsule())
                            .accessibilityHidden(true)
                    }
                }
            }
            ForEach(Array(walkTracker.routeSegments.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment.map(\.coordinate))
                        .stroke(AppColors.brand, lineWidth: 5)
                }
            }
            if let location = locationManager.location {
                MapCircle(
                    center: location.coordinate,
                    radius: max(location.horizontalAccuracy, 1)
                )
                .foregroundStyle(Color.blue.opacity(0.12))

                Annotation("Current location", coordinate: location.coordinate) {
                    currentLocationMarker
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) {
            statusCard
                .padding(AppSpacing.medium)
        }
        .overlay(alignment: .topTrailing) {
            if locationManager.location != nil {
                Button {
                    centreOnCurrentLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.brand)
                        .frame(width: 46, height: 46)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 3, y: 1)
                }
                .accessibilityLabel("Centre map on my location")
                .padding(AppSpacing.medium)
                .padding(.top, 56)
            }
        }
    }

    private var currentLocationMarker: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .shadow(radius: 2)
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel("Your current location")
    }

    private var socialPeers: [SocialMapPeer] {
        friends.peers
    }

    @ViewBuilder
    private var netWalkPanel: some View {
        if let active = friends.invitations.active {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Label("Walking with \(peerName(active.user))", systemImage: "figure.walk.motion")
                    .font(.headline)
                if let distance = friends.currentSession?.sharedDistanceM {
                    Text("Together for \(distanceText(distance))")
                        .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                }
                Button("End Net-Walking", role: .destructive) {
                    Task { await friends.endInvitation(active) }
                }
                .disabled(friends.isWorking)
            }
        } else if let incoming = friends.invitations.incoming.first {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text("\(peerName(incoming.user)) wants to walk together").font(.headline)
                HStack {
                    Button("Accept") { Task { await friends.respondToInvitation(incoming, accept: true) } }
                        .buttonStyle(.borderedProminent).tint(AppColors.brand)
                        .disabled(friends.isWorking || !friends.canAcceptInvitation)
                    Button("Decline", role: .destructive) {
                        Task { await friends.respondToInvitation(incoming, accept: false) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(friends.isWorking)
                }
            }
        } else if let outgoing = friends.invitations.outgoing.first {
            HStack {
                Label("Waiting for \(peerName(outgoing.user))", systemImage: "clock")
                Spacer()
                Button("Cancel") { Task { await friends.endInvitation(outgoing) } }
                    .disabled(friends.isWorking)
            }
        } else if friends.netMatchingEnabled && friends.isCurrentlyWalking && !friends.mapSnapshot.nearby.isEmpty {
            Text("Tap a nearby person on the map to invite them to Net-Walk.")
                .font(.subheadline).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func peerName(_ user: SocialProfile) -> String {
        user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : user.displayName
    }

    private func distanceText(_ metres: Double) -> String {
        if metres < 1_000 {
            return metres.formatted(.number.precision(.fractionLength(0))) + " m"
        }
        return (metres / 1_000).formatted(.number.precision(.fractionLength(2))) + " km"
    }

    @ViewBuilder
    private var statusCard: some View {
        switch locationManager.state {
        case .idle, .ready:
            EmptyView()
        case .requestingPermission:
            LocationStatusCard(
                icon: "location.fill",
                title: "Location access needed",
                message: "Allow access to show your current position on the map."
            )
        case .locating:
            LocationStatusCard(
                icon: "location.magnifyingglass",
                title: "Finding your location",
                message: "This may take a few seconds."
            )
        case .denied:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location access is off",
                message: "Allow location access in Settings to use the walk map.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .restricted:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location is restricted",
                message: "This device does not allow Vitail to use location services."
            )
        case .servicesDisabled:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location Services are off",
                message: "Turn on Location Services in Settings to use the walk map.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .preciseLocationRequired:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Precise Location is off",
                message: "Enable Precise Location in Settings to track your walk accurately.",
                actionTitle: "Open Settings", action: openSettings
            )
        case let .failed(message):
            LocationStatusCard(
                icon: "exclamationmark.triangle.fill",
                title: "Could not find your location",
                message: message
            )
        }
    }

    private func centreOnCurrentLocation() {
        guard let location = locationManager.location else { return }

        cameraPosition = .region(
            MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }
}

private struct LocationStatusCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.medium) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppColors.brand)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.brand)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .shadow(radius: 4, y: 2)
    }
}

private struct SocialPeerSheet: View {
    let peer: SocialMapPeer
    @ObservedObject var store: FriendsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: AppSpacing.medium) {
                        SocialAvatarView(user: peer.user, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName).font(.title3.bold())
                            if peer.isNetPartner {
                                Label("Net-Walking with you", systemImage: "figure.walk.motion")
                                    .font(.subheadline).foregroundStyle(AppColors.brand)
                            } else if peer.isApproximate {
                                Text("Approximate nearby position")
                                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                            } else {
                                Text("Sharing their walk with friends")
                                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                    }
                    if let distance = peer.distanceM {
                        LabeledContent("Distance", value: distanceText(distance))
                    }
                }
                actionSection
                if let error = store.errorMessage {
                    Section { Text(error).foregroundStyle(AppColors.error) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle("Walker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("Net-Walking") {
            if let active = store.invitations.active, active.user.id == peer.user.id {
                if let distance = store.currentSession?.sharedDistanceM {
                    LabeledContent("Together", value: distanceText(distance))
                }
                Button("End Net-Walking", role: .destructive) {
                    Task {
                        await store.endInvitation(active)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking)
            } else if let incoming = store.invitations.incoming.first(where: { $0.user.id == peer.user.id }) {
                Button("Accept invitation") {
                    Task {
                        await store.respondToInvitation(incoming, accept: true)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking || !store.canAcceptInvitation)
                Button("Decline", role: .destructive) {
                    Task {
                        await store.respondToInvitation(incoming, accept: false)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking)
            } else if let outgoing = store.invitations.outgoing.first(where: { $0.user.id == peer.user.id }) {
                Text("Invitation sent").foregroundStyle(AppColors.secondaryText)
                Button("Cancel invitation", role: .destructive) {
                    Task {
                        await store.endInvitation(outgoing)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking)
            } else if isNearby {
                Button("Invite to Net-Walk") {
                    Task {
                        await store.invite(peer.user)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(store.isWorking || !store.canSendInvitation)
                Text("Both walkers must opt in. Either person can end the pairing at any time.")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
            } else {
                Text("This friend is sharing their walk, but is not currently available for Net-Walking.")
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var isNearby: Bool {
        store.mapSnapshot.nearby.contains { $0.user.id == peer.user.id }
    }
    private var displayName: String {
        peer.user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : peer.user.displayName
    }
    private func distanceText(_ metres: Double) -> String {
        if metres < 1_000 {
            return metres.formatted(.number.precision(.fractionLength(0))) + " m"
        }
        return (metres / 1_000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
}

struct WalkFinishSummaryView: View {
    @ObservedObject var coordinator: WalkSessionCoordinator
    @ObservedObject private var selection: WalkDogSelectionViewModel
    @ObservedObject private var history: WalkHistoryStore
    @ObservedObject private var sync: WalkSyncStore
    @Environment(\.dismiss) private var dismiss

    init(coordinator: WalkSessionCoordinator) {
        self.coordinator = coordinator
        selection = coordinator.dogSelection
        history = coordinator.history
        sync = coordinator.sync
    }

    private var record: WalkRecord? {
        guard let summary = coordinator.finishSummary else { return nil }
        return history.records.first { $0.id == summary.id } ?? summary
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    if let record {
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            HStack(spacing: AppSpacing.large) {
                                summaryMetric("Distance", value: String(format: "%.2f km", record.distanceKilometres))
                                summaryMetric("Walking time", value: WalkDogSelectionCard.durationText(record.activeDuration))
                            }
                        }
                        pointsSummary(record)
                        if let receipt = record.serverSummary {
                            WalkVenueAwardsSection(summary: receipt)
                        } else if !record.dogs.isEmpty || coordinator.needsFinishConfirmation {
                            VStack(alignment: .leading, spacing: AppSpacing.small) {
                                Text("Venue check-ins").font(.headline)
                                Text(coordinator.needsFinishConfirmation
                                    ? "Complete your walk to settle verified check-ins."
                                    : "Processing venue settlement. Rewards appear after the upload is confirmed.")
                                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        if coordinator.needsFinishConfirmation {
                            dogPicker
                            PrimaryButton(
                                title: selection.selectedDogs.isEmpty ? "Save without dogs · 0 pts" : "Complete walk",
                                isLoading: coordinator.isConfirmingFinish,
                                isDisabled: selection.isLoading
                            ) { Task { await coordinator.confirmFinishedWalk() } }
                        } else {
                            if !record.dogs.isEmpty {
                                Text(record.dogs.map(\.name).joined(separator: ", "))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            if let message = sync.errorMessage {
                                Text(message).font(.footnote).foregroundStyle(AppColors.secondaryText)
                                Button("Retry upload") { Task { await sync.refreshAndUpload() } }
                                    .disabled(sync.isSyncing)
                            }
                            PrimaryButton(title: "Done", isLoading: coordinator.isConfirmingFinish) { dismiss() }
                        }
                    }
                    if let message = coordinator.storageErrorMessage {
                        Text(message).font(.footnote).foregroundStyle(AppColors.error)
                        Button("Retry saving") { coordinator.retryStorage() }
                    }
                }
                .padding(AppSpacing.large)
            }
            .background(AppColors.background)
            .navigationTitle("Walk summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(coordinator.needsFinishConfirmation ? "Later" : "Close") { dismiss() }
                        .disabled(coordinator.isConfirmingFinish)
                }
            }
            .task {
                if coordinator.needsFinishConfirmation { await selection.load() }
            }
            .interactiveDismissDisabled(coordinator.isConfirmingFinish)
        }
        .vitailAppearance()
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(AppColors.secondaryText)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pointsSummary(_ record: WalkRecord) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            if let receipt = record.serverSummary {
                Text("+\(receipt.settledTotalPoints) points").font(.largeTitle.weight(.semibold))
                Text("Added to your wallet · \(receipt.distanceM / 1_000, specifier: "%.2f") km accepted")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
                Text("Walk \(receipt.pointsAwarded) · Venue \(receipt.checkInPointsAwarded) · Net-Walking \(receipt.netPointsAwarded)")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            } else if coordinator.needsFinishConfirmation {
                let estimate = coordinator.estimatedPoints(for: record, hasSelectedDogs: !selection.selectedDogs.isEmpty)
                Text("≈ \(estimate) points").font(.largeTitle.weight(.semibold))
                Text(selection.selectedDogs.isEmpty
                     ? "Choose who came along. Walks without a dog are saved on this device and earn no points."
                     : "Walk points estimated from your route, up to 40 per day. Venue rewards are confirmed at settlement; walking and check-ins share a 72-point daily limit.")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
            } else if record.dogs.isEmpty || record.uploadRequest == nil || record.uploadFailure != nil {
                Text("0 points").font(.largeTitle.weight(.semibold))
                Text(record.syncDescription).font(.footnote).foregroundStyle(AppColors.secondaryText)
            } else {
                Text("Points pending").font(.title2.weight(.semibold))
                Text("Your walk is saved. Your points will appear when the upload is confirmed.")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
                if sync.isSyncing { ProgressView() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dogPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Who came along?").font(.headline)
            if selection.isLoading {
                ProgressView("Loading your dogs…")
            } else if let message = selection.errorMessage {
                Text(message).font(.footnote).foregroundStyle(AppColors.secondaryText)
                Button("Retry loading dogs") { Task { await selection.load() } }
            } else if selection.dogs.isEmpty {
                Text("No dogs added yet. Add your dog in Account for your next walk.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(selection.dogs) { dog in
                    let selected = selection.selectedDogIDs.contains(dog.id)
                    Button { selection.toggleDog(id: dog.id) } label: {
                        HStack(spacing: AppSpacing.medium) {
                            AvatarView(url: dog.photo, name: dog.name, systemImage: "dog.fill", size: 44)
                            Text(dog.name).foregroundStyle(AppColors.primaryText)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AppColors.brand : AppColors.secondaryText)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isConfirmingFinish)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
