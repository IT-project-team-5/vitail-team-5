import SwiftUI

/// The image people share. Fixed colours and size (1080 × 1350 px when rendered at 3×) so it
/// looks the same in light and dark mode and fits Instagram's portrait feed.
struct ActivityShareCard: View {
    static let size = CGSize(width: 360, height: 450)

    let summary: ActivityShareSummary
    let options: ActivityShareOptions

    private let ink = Color(red: 0.26, green: 0.18, blue: 0.11)
    private let paper = Color(red: 1.0, green: 0.97, blue: 0.92)
    private let honey = Color(red: 0.93, green: 0.72, blue: 0.36)
    private let sky = Color(red: 0.72, green: 0.87, blue: 0.95)

    var body: some View {
        ZStack {
            // Neo-retro hard shadow behind the card.
            RoundedRectangle(cornerRadius: 24).fill(ink).offset(x: 6, y: 6)
            RoundedRectangle(cornerRadius: 24).fill(paper)
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ink, lineWidth: 3))
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    VitailBrandMark(size: 40)
                    Text("Vitail").font(.system(size: 26, weight: .heavy, design: .rounded))
                    Spacer()
                    if options.showDate {
                        Text(summary.date, format: .dateTime.day().month(.abbreviated).year())
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(sky)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink, lineWidth: 3))
                    DogIllustration().padding(18)
                }
                .frame(height: 170)

                VStack(spacing: 2) {
                    Text(ActivityShareFormat.distance(summary.distanceKilometres))
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    if options.showDogNames, let dogs = ActivityShareFormat.dogs(summary.dogNames) {
                        Text("walked \(dogs)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.7).lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    stat(title: "Walking time", value: ActivityShareFormat.duration(summary.activeDuration))
                    if options.showPoints, let points = summary.pointsAwarded {
                        stat(title: "Points earned", value: "+\(points)")
                    }
                }
                Spacer(minLength: 0)
                Text("Dog walking rewards")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.2).textCase(.uppercase)
            }
            .padding(20)
        }
        .padding(.trailing, 6).padding(.bottom, 6)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(ink)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityShareFormat.accessibilityDescription(summary, options: options))
    }

    private func stat(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(honey.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink, lineWidth: 2))
    }
}
