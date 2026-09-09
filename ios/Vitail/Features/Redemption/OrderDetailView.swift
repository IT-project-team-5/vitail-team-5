import SwiftUI

struct OrderDetailView: View {
    let order: RedemptionOrder
    @ObservedObject var viewModel: RedemptionViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var isCollecting = false
    @State private var collected = false

    private let sliderWidth: CGFloat = 300
    private let knobSize: CGFloat = 54

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "bag.fill")
                            .foregroundStyle(AppColors.brand)

                        Text(collected ? "ORDER COLLECTED" : "ORDER READY TO PICK UP")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(AppColors.brand)
                    }

                    Text(order.venueName)
                        .font(.title2)
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        ForEach(order.items) { item in
                            HStack {
                                Text("\(item.quantity) × \(item.itemNameSnapshot)")
                                Spacer()
                                Text("\(item.pointPriceSnapshot * item.quantity) pts")
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                    }
                    .padding(AppSpacing.medium)
                    .background(AppColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text("Reference")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)

                        Text(order.referenceNumber)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)

                        Text("\(order.totalPoints) pts")
                            .font(.headline)
                    }
                }
                .padding(AppSpacing.large)
            }

            if collected {
                VStack(spacing: AppSpacing.medium) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(AppColors.brand)

                    Text("Order collected")
                        .font(.headline)

                    Text("Your order has been marked as collected.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)

                    PrimaryButton(
                        title: "Done",
                        isLoading: false,
                        isDisabled: false
                    ) {
                        dismiss()
                    }
                }
                .padding(AppSpacing.large)
            } else {
                swipeToCollect
                    .padding(.horizontal, AppSpacing.large)
                    .padding(.bottom, AppSpacing.large)
            }
        }
        .background(AppColors.background)
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var swipeToCollect: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 30)
                .fill(AppColors.surface)
                .frame(height: 60)

            Text(isCollecting ? "Collecting..." : "Swipe to collect")
                .font(.headline)
                .foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity)

            Circle()
                .fill(AppColors.brand)
                .frame(width: knobSize, height: knobSize)
                .overlay {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white)
                        .fontWeight(.bold)
                }
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let maxOffset = sliderWidth - knobSize
                            dragOffset = min(
                                max(value.translation.width, 0),
                                maxOffset
                            )
                        }
                        .onEnded { _ in
                            let maxOffset = sliderWidth - knobSize

                            if dragOffset > maxOffset * 0.75 {
                                collectOrder()
                            } else {
                                withAnimation {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
        .frame(width: sliderWidth, height: 60)
        .frame(maxWidth: .infinity)
        .disabled(isCollecting)
    }

    private func collectOrder() {
        isCollecting = true

        Task {
            await viewModel.collect(orderID: order.id)

            if viewModel.errorMessage == nil {
                collected = true
            }

            isCollecting = false
            dragOffset = 0
        }
    }
}
