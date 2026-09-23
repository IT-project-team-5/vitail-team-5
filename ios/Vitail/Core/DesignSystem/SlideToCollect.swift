import SwiftUI

struct SlideConfirmationState {
    var offset: CGFloat = 0
    private(set) var hasConfirmed = false

    mutating func finish(travel: CGFloat, isEnabled: Bool) -> Bool {
        guard isEnabled, !hasConfirmed, travel > 0, offset >= travel * 0.9 else {
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
                Capsule().fill(AppColors.surface)
                Text(isLoading ? "Confirming…" : "Slide to collect")
                    .font(.subheadline.weight(.medium)).foregroundStyle(AppColors.secondaryText)
                    .padding(.leading, 60).padding(.trailing, 12).frame(maxWidth: .infinity)
                ZStack {
                    Circle().fill(AppColors.brand)
                    if isLoading { ProgressView().tint(AppColors.brandForeground) }
                    else {
                        Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.brandForeground)
                    }
                }
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
        guard slide.finish(travel: travel, isEnabled: isEnabled) else { return }
        Task {
            await onConfirm()
            slide.reset()
        }
    }
}
