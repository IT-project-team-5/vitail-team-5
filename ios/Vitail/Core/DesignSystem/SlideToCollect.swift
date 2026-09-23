import SwiftUI

struct SlideConfirmationState {
    var offset: CGFloat = 0
    private(set) var hasConfirmed = false

    func progress(travel: CGFloat) -> CGFloat {
        guard travel > 0, travel.isFinite, offset.isFinite else { return 0 }
        return min(1, max(0, offset / travel))
    }

    mutating func finish(travel: CGFloat, isEnabled: Bool) -> Bool {
        guard !hasConfirmed else { return false }
        guard isEnabled, travel > 0, offset >= travel * 0.9 else {
            offset = 0
            return false
        }
        offset = travel
        hasConfirmed = true
        return true
    }

    mutating func reset() { offset = 0; hasConfirmed = false }
}

struct SlideToCollect: View {
    let isLoading: Bool
    let isDisabled: Bool
    let onConfirm: () async -> Void
    @State private var slide = SlideConfirmationState()
    private var isEnabled: Bool { !isLoading && !isDisabled && !slide.hasConfirmed }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - 64)
            ZStack(alignment: .leading) {
                CollectionSlideBackground(progress: slide.progress(travel: travel), isLoading: isLoading)
                ZStack {
                    Circle().fill(AppColors.brand)
                    if isLoading { ProgressView().tint(AppColors.brandForeground) }
                    else {
                        Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.brandForeground)
                    }
                }
                .overlay { Circle().stroke(AppColors.brandForeground.opacity(0.6), lineWidth: 1) }
                .frame(width: 52, height: 52).padding(6).offset(x: min(slide.offset, travel))
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard isEnabled else { return }
                        slide.offset = min(travel, max(0, value.translation.width))
                    }
                    .onEnded { _ in
                        confirm(travel: travel)
                    })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Slide to collect")
            .accessibilityValue(isLoading ? "Confirming" : "Not collected")
            .accessibilityHint("Swipe up to confirm after receiving your item.")
            .accessibilityAdjustableAction { direction in
                guard direction == .increment, isEnabled else { return }
                slide.offset = travel
                confirm(travel: travel)
            }
        }
        .frame(height: 64)
    }

    private func confirm(travel: CGFloat) {
        let confirmed = withAnimation(.easeOut(duration: 0.2)) {
            slide.finish(travel: travel, isEnabled: isEnabled)
        }
        guard confirmed else { return }
        Task {
            await onConfirm()
            withAnimation(.easeOut(duration: 0.2)) { slide.reset() }
        }
    }
}

/// The filled part follows the thumb and keeps its text readable in either theme.
struct CollectionSlideBackground: View {
    let progress: CGFloat
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            let filledWidth = geometry.size.width * min(1, max(0, progress))
            ZStack(alignment: .leading) {
                AppColors.surface
                AppColors.brand.frame(width: filledWidth)
                label.foregroundStyle(AppColors.secondaryText)
                label.foregroundStyle(AppColors.brandForeground)
                    .mask(alignment: .leading) { Rectangle().frame(width: filledWidth) }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text(isLoading ? "Confirming…" : "Slide to collect")
            .font(.subheadline.weight(.medium))
            .padding(.leading, 60).padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
