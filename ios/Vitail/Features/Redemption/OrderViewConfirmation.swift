import SwiftUI

struct OrderConfirmationView: View {
    let order: RedemptionOrder
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(AppColors.brand)

            Text("Order Confirmed")
                .font(.title2)
                .fontWeight(.bold)

            VStack(spacing: AppSpacing.small) {
                Text(order.venueName)
                    .font(.headline)

                Text("Reference Number")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                Text(order.referenceNumber)
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ForEach(order.items) { item in
                    HStack {
                        Text("\(item.quantity) × \(item.itemNameSnapshot)")

                        Spacer()

                        Text("\(item.pointPriceSnapshot * item.quantity) pts")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }

                Divider()

                HStack {
                    Text("Total")
                        .fontWeight(.semibold)

                    Spacer()

                    Text("\(order.totalPoints) pts")
                        .fontWeight(.semibold)
                }
            }
            .padding(AppSpacing.medium)
            .background(AppColors.surface)
            .clipShape(
                RoundedRectangle(cornerRadius: AppRadius.card)
            )

            Text("Your points have been deducted. Show your reference number when collecting your order.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()

            PrimaryButton(
                title: "Done",
                isLoading: false,
                isDisabled: false
            ) {
                onDone()
            }
        }
        .padding(AppSpacing.large)
        .background(AppColors.background)
    }
}