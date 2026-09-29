import SwiftUI
import UIKit

/// Preview, choose what to include, then hand the image to the system share sheet.
/// Nothing is shared or saved until the owner taps Share; the share sheet offers Save Image,
/// Instagram and any other installed app.
struct ActivityShareView: View {
    let summary: ActivityShareSummary
    @State private var options = ActivityShareOptions()
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.medium) {
                    ActivityShareCard(summary: summary, options: options)
                        .scaleEffect(previewScale)
                        .frame(width: ActivityShareCard.size.width * previewScale,
                               height: ActivityShareCard.size.height * previewScale)
                        .accessibilityLabel("Preview of your activity card")

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text("Include on the card").font(.headline)
                        Toggle("Date", isOn: $options.showDate)
                        Toggle("Dog names", isOn: $options.showDogNames)
                            .disabled(summary.dogNames.isEmpty)
                        Toggle("Points earned", isOn: $options.showPoints)
                            .disabled(summary.pointsAwarded == nil)
                    }
                    .padding(AppSpacing.medium)
                    .background(AppColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

                    Label("Your route and location are never included.", systemImage: "location.slash")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)

                    if let image {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview("My Vitail walk", image: Image(uiImage: image))
                        ) {
                            Label("Share or save image", systemImage: "square.and.arrow.up")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .foregroundStyle(AppColors.brandForeground)
                                .background(AppColors.brand)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
                        }
                    } else {
                        ProgressView().frame(minHeight: 50)
                    }
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
            .navigationTitle("Share Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .tint(AppColors.brand)
            .task(id: options) { render() }
        }
    }

    private var previewScale: CGFloat { 0.85 }

    private func render() {
        let renderer = ImageRenderer(content: ActivityShareCard(summary: summary, options: options))
        renderer.scale = 3
        image = renderer.uiImage
    }
}
