import CoreLocation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class BrandAppearanceTests: XCTestCase {
    func testBrandArtworkAndPrimaryAppIconAreBundled() throws {
        let artwork = try XCTUnwrap(UIImage(named: "BrandMark"))
        XCTAssertGreaterThanOrEqual(artwork.size.width * artwork.scale, 1024)
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertFalse((primary["CFBundleIconFiles"] as? [String] ?? []).isEmpty)
    }

    func testTextAndButtonContrastInLightAndDarkMode() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for background in [AppColors.background, AppColors.surface] {
                for foreground in [AppColors.primaryText, AppColors.secondaryText, AppColors.brand,
                                   AppColors.warning, AppColors.success, AppColors.information] {
                    XCTAssertGreaterThanOrEqual(contrast(foreground, background, style: style), 4.5)
                }
            }
            XCTAssertGreaterThanOrEqual(contrast(AppColors.brandForeground, AppColors.brand, style: style), 4.5)
        }
    }

    func testBrandLayoutSnapshots() async throws {
        let session = SessionStore()
        for dark in [false, true] {
            try await snapshot(AuthView(session: session), name: dark ? "Brand-Login-Dark" : "Brand-Login-Light", dark: dark)
        }

        // Render real Walk components with deterministic local fixtures. No GPS,
        // server requests, account records or point awards are created here.
        let dog = Dog(id: 1, name: "Milo", photo: nil,
                      breed: Breed(id: 1, name: "Golden Retriever", energyLevel: .moderate,
                                   defaultSize: .medium, isBrachycephalic: false),
                      ageMonths: 24, size: .medium, isBrachycephalic: false, createdAt: "2026-09-15T00:00:00Z")
        let start = Date(timeIntervalSince1970: 1_789_430_400)
        var now = start
        let tracker = WalkSessionTracker(now: { now })
        let first = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -37.81, longitude: 144.96),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start)
        tracker.start(from: first, dogs: [dog])
        for step in 1...30 {
            now = start.addingTimeInterval(Double(step) * 30)
            tracker.record(CLLocation(coordinate: CLLocationCoordinate2D(latitude: -37.81 + Double(step) / 3000,
                                                                          longitude: 144.96),
                                      altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now))
        }
        XCTAssertGreaterThan(tracker.distanceMetres, 1000)
        tracker.pause()
        let selection = WalkDogSelectionViewModel(session: tracker)
        let route = [
            WalkRoutePoint(latitude: -37.81, longitude: 144.96, timestamp: start),
            WalkRoutePoint(latitude: -37.808, longitude: 144.961, timestamp: start.addingTimeInterval(300)),
            WalkRoutePoint(latitude: -37.804, longitude: 144.958, timestamp: start.addingTimeInterval(600)),
            WalkRoutePoint(latitude: -37.80, longitude: 144.96, timestamp: now)
        ]
        let history = WalkRecord(id: UUID(), startedAt: start, endedAt: now, activeDuration: 900,
                                 distanceMetres: 1250, dogs: [WalkDogSnapshot(id: 1, name: "Milo")],
                                 routeSegments: [route])
        for dark in [false, true] {
            let page = ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VitailBrandMark(size: 48)
                        Text("Walk").font(.title.bold())
                        Spacer()
                        Text("40 pts").foregroundStyle(AppColors.brand)
                    }
                    WalkDogSelectionCard(selection: selection, session: tracker, location: first, onManageDogs: {})
                    Text("Walk History").font(.headline)
                    WalkHistoryCard(walk: history)
                    PrimaryButton(title: "Continue") {}
                }
                .padding(20)
            }
            try await snapshot(page, name: dark ? "Brand-Walk-Dark" : "Brand-Walk-Light", dark: dark)
        }
        try await snapshot(AuthView(session: session).environment(\.dynamicTypeSize, .accessibility2),
                           name: "Brand-Login-Large-Text", dark: false)
    }

    private func contrast(_ first: Color, _ second: Color, style: UIUserInterfaceStyle) -> Double {
        func luminance(_ color: Color) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let page = content.vitailAppearance().preferredColorScheme(dark ? .dark : .light)
        let host = UIHostingController(rootView: page)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
