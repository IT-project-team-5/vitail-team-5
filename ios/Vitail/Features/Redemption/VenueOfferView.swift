import SwiftUI

/// Ordering screen for one venue: pick offers and quantities, then place the
/// order. Points are deducted at order creation, not at collection
/// (README.md, "Redeeming Points").
struct VenueOfferView: View {
    let venue: Venue
    @ObservedObject var viewModel: RedemptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var cart: [Int: Int] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                if viewModel.isLoadingVenueDetail {
                    LoadingView(message: "Loading offers…")
                } else if let detail = viewModel.selectedVenueDetail {
                    if detail.offers.isEmpty {
                        Text("No offers available right now.")
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        ForEach(detail.offers) { offer in
                            OfferRow(
                                offer: offer,
                                quantity: cart[offer.id] ?? 0,
                                onChange: { cart[offer.id] = $0 }
                            )
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                }

                PrimaryButton(
                    title: "Place order (\(totalPoints) pts)",
                    isLoading: viewModel.isPlacingOrder,
                    isDisabled: totalPoints == 0
                ) {
                    Task {
                        await viewModel.placeOrder(venueId: venue.id, cart: cart)
                        if viewModel.lastPlacedOrder != nil {
                            dismiss()
                        }
                    }
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .navigationTitle(venue.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadVenueDetail(id: venue.id)
        }
        .onDisappear {
            viewModel.clearSelectedVenue()
        }
    }

    private var totalPoints: Int {
        guard let offers = viewModel.selectedVenueDetail?.offers else { return 0 }
        return offers.reduce(0) { total, offer in
            total + offer.pointPrice * (cart[offer.id] ?? 0)
        }
    }
}

private struct OfferRow: View {
    let offer: VenueOffer
    let quantity: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name)
                    .fontWeight(.semibold)
                Text("\(offer.pointPrice) pts")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            HStack(spacing: AppSpacing.small) {
                Button {
                    onChange(max(0, quantity - 1))
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .disabled(quantity == 0)

                Text("\(quantity)")
                    .frame(minWidth: 20)

                Button {
                    onChange(quantity + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .foregroundStyle(AppColors.brand)
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
