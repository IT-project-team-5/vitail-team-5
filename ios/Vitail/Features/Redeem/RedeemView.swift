import Foundation
import MapKit
import SwiftUI
import UIKit

enum RedemptionOrderStatus: Equatable {
    case pending
    case collected
    case expired
    case cancelled

    var title: String {
        switch self {
        case .pending:
            return "Ready to pick up"
        case .collected:
            return "Collected"
        case .expired:
            return "Expired"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct RewardProduct: Identifiable, Equatable {
    let id: UUID
    let name: String
    let details: String
    let pointPrice: Int
    let icon: String
}

struct RedemptionMerchant: Identifiable {
    let id: UUID
    let name: String
    let address: String
    let distanceKilometres: Double
    let coordinate: CLLocationCoordinate2D
    let products: [RewardProduct]

    static let demoMerchants: [RedemptionMerchant] = [
        RedemptionMerchant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Paws & Beans Carlton",
            address: "248 Lygon Street, Carlton",
            distanceKilometres: 0.4,
            coordinate: CLLocationCoordinate2D(latitude: -37.8002, longitude: 144.9671),
            products: [
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                    name: "Pup Cup & Coffee",
                    details: "One regular coffee and one dog-friendly pup cup.",
                    pointPrice: 120,
                    icon: "cup.and.saucer.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    name: "Dog Treat Bag",
                    details: "A small bag of baked dog treats.",
                    pointPrice: 80,
                    icon: "pawprint.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
                    name: "Brunch Voucher",
                    details: "$10 off one brunch order.",
                    pointPrice: 220,
                    icon: "fork.knife"
                )
            ]
        ),
        RedemptionMerchant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Happy Tails Pet Store",
            address: "86 Queensberry Street, Carlton",
            distanceKilometres: 0.8,
            coordinate: CLLocationCoordinate2D(latitude: -37.8048, longitude: 144.9591),
            products: [
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                    name: "Dog Wash Token",
                    details: "One self-service dog wash session.",
                    pointPrice: 180,
                    icon: "drop.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000005")!,
                    name: "Dental Chew Pack",
                    details: "A pack of three dental chews.",
                    pointPrice: 150,
                    icon: "cross.case.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000006")!,
                    name: "Walk Essentials Pack",
                    details: "Waste bags, treats and a travel water bowl.",
                    pointPrice: 260,
                    icon: "bag.fill"
                )
            ]
        ),
        RedemptionMerchant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: "Barkery Lane Fitzroy",
            address: "121 Gertrude Street, Fitzroy",
            distanceKilometres: 1.2,
            coordinate: CLLocationCoordinate2D(latitude: -37.8058, longitude: 144.9748),
            products: [
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000007")!,
                    name: "Fresh Treat Box",
                    details: "A mixed box of fresh dog biscuits.",
                    pointPrice: 140,
                    icon: "shippingbox.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000008")!,
                    name: "Vitail Bandana",
                    details: "A green Vitail bandana in your chosen size.",
                    pointPrice: 200,
                    icon: "tshirt.fill"
                ),
                RewardProduct(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000009")!,
                    name: "Birthday Pup Cake",
                    details: "A small dog-friendly celebration cake.",
                    pointPrice: 320,
                    icon: "birthday.cake.fill"
                )
            ]
        )
    ]
}

struct RedemptionOrderItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let quantity: Int
    let pointPrice: Int
}

struct RedemptionOrder: Identifiable, Equatable {
    let id: UUID
    let referenceNumber: String
    let venueName: String
    let venueAddress: String
    let items: [RedemptionOrderItem]
    let totalPoints: Int
    let createdAt: Date
    let expiresAt: Date
    var status: RedemptionOrderStatus
    var collectedAt: Date?

    static func demoReadyOrders(now: Date = .now) -> [RedemptionOrder] {
        [
            RedemptionOrder(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                referenceNumber: "VT-DEMO-101",
                venueName: "Paws & Beans Carlton",
                venueAddress: "248 Lygon Street, Carlton",
                items: [
                    RedemptionOrderItem(
                        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                        name: "Pup Cup & Coffee",
                        quantity: 1,
                        pointPrice: 120
                    )
                ],
                totalPoints: 120,
                createdAt: now.addingTimeInterval(-20 * 60),
                expiresAt: pickupDeadline(from: now),
                status: .pending,
                collectedAt: nil
            ),
            RedemptionOrder(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                referenceNumber: "VT-DEMO-102",
                venueName: "Happy Tails Pet Store",
                venueAddress: "86 Queensberry Street, Carlton",
                items: [
                    RedemptionOrderItem(
                        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                        name: "Dental Chew Pack",
                        quantity: 1,
                        pointPrice: 150
                    )
                ],
                totalPoints: 150,
                createdAt: now.addingTimeInterval(-8 * 60),
                expiresAt: pickupDeadline(from: now),
                status: .pending,
                collectedAt: nil
            )
        ]
    }

    static func demoHistoryOrders(now: Date = .now) -> [RedemptionOrder] {
        let oneDayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let fourDaysAgo = now.addingTimeInterval(-4 * 24 * 60 * 60)
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)

        return [
            historyOrder(
                id: "10000000-0000-0000-0000-000000000091",
                itemID: "20000000-0000-0000-0000-000000000091",
                reference: "VT-DEMO-091",
                venue: "Barkery Lane Fitzroy",
                address: "121 Gertrude Street, Fitzroy",
                item: "Fresh Treat Box",
                points: 140,
                createdAt: oneDayAgo.addingTimeInterval(-35 * 60),
                status: .collected,
                collectedAt: oneDayAgo
            ),
            historyOrder(
                id: "10000000-0000-0000-0000-000000000092",
                itemID: "20000000-0000-0000-0000-000000000092",
                reference: "VT-DEMO-092",
                venue: "Paws & Beans Carlton",
                address: "248 Lygon Street, Carlton",
                item: "Dog Treat Bag",
                points: 80,
                createdAt: fourDaysAgo.addingTimeInterval(-20 * 60),
                status: .collected,
                collectedAt: fourDaysAgo
            ),
            historyOrder(
                id: "10000000-0000-0000-0000-000000000093",
                itemID: "20000000-0000-0000-0000-000000000093",
                reference: "VT-DEMO-093",
                venue: "Happy Tails Pet Store",
                address: "86 Queensberry Street, Carlton",
                item: "Dog Wash Token",
                points: 180,
                createdAt: eightDaysAgo.addingTimeInterval(-2 * 60 * 60),
                status: .expired,
                collectedAt: nil
            )
        ]
    }

    private static func historyOrder(
        id: String,
        itemID: String,
        reference: String,
        venue: String,
        address: String,
        item: String,
        points: Int,
        createdAt: Date,
        status: RedemptionOrderStatus,
        collectedAt: Date?
    ) -> RedemptionOrder {
        RedemptionOrder(
            id: UUID(uuidString: id)!,
            referenceNumber: reference,
            venueName: venue,
            venueAddress: address,
            items: [
                RedemptionOrderItem(
                    id: UUID(uuidString: itemID)!,
                    name: item,
                    quantity: 1,
                    pointPrice: points
                )
            ],
            totalPoints: points,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(4 * 60 * 60),
            status: status,
            collectedAt: collectedAt
        )
    }

    private static func pickupDeadline(from date: Date) -> Date {
        let calendar = Calendar.current
        guard let todayAtSeven = calendar.date(
            bySettingHour: 19,
            minute: 0,
            second: 0,
            of: date
        ) else {
            return date.addingTimeInterval(4 * 60 * 60)
        }

        if todayAtSeven > date {
            return todayAtSeven
        }

        return calendar.date(byAdding: .day, value: 1, to: todayAtSeven)
            ?? date.addingTimeInterval(4 * 60 * 60)
    }
}

@MainActor
final class RedemptionStore: ObservableObject {
    @Published private(set) var pointsBalance: Int
    @Published private(set) var readyOrders: [RedemptionOrder]
    @Published private(set) var historyOrders: [RedemptionOrder]

    let merchants: [RedemptionMerchant]

    private var nextReferenceSequence: Int

    init(
        pointsBalance: Int = 760,
        merchants: [RedemptionMerchant] = RedemptionMerchant.demoMerchants,
        readyOrders: [RedemptionOrder] = RedemptionOrder.demoReadyOrders(),
        historyOrders: [RedemptionOrder] = RedemptionOrder.demoHistoryOrders(),
        nextReferenceSequence: Int = 200
    ) {
        self.pointsBalance = pointsBalance
        self.merchants = merchants
        self.readyOrders = readyOrders
        self.historyOrders = historyOrders
        self.nextReferenceSequence = nextReferenceSequence
    }

    func canOrder(_ product: RewardProduct) -> Bool {
        pointsBalance >= product.pointPrice
    }

    @discardableResult
    func placeOrder(
        merchantID: UUID,
        productID: UUID,
        at createdAt: Date = .now
    ) -> RedemptionOrder? {
        guard let merchant = merchants.first(where: { $0.id == merchantID }),
              let product = merchant.products.first(where: { $0.id == productID }),
              canOrder(product) else {
            return nil
        }

        let order = RedemptionOrder(
            id: UUID(),
            referenceNumber: String(format: "VT-DEMO-%03d", nextReferenceSequence),
            venueName: merchant.name,
            venueAddress: merchant.address,
            items: [
                RedemptionOrderItem(
                    id: UUID(),
                    name: product.name,
                    quantity: 1,
                    pointPrice: product.pointPrice
                )
            ],
            totalPoints: product.pointPrice,
            createdAt: createdAt,
            expiresAt: Calendar.current.date(byAdding: .hour, value: 4, to: createdAt)
                ?? createdAt,
            status: .pending,
            collectedAt: nil
        )

        nextReferenceSequence += 1
        pointsBalance -= product.pointPrice
        readyOrders.insert(order, at: 0)
        return order
    }

    @discardableResult
    func collect(orderID: UUID, at collectedAt: Date = .now) -> Bool {
        guard let index = readyOrders.firstIndex(where: { $0.id == orderID }),
              readyOrders[index].status == .pending else {
            return false
        }

        var order = readyOrders.remove(at: index)
        order.status = .collected
        order.collectedAt = collectedAt
        historyOrders.insert(order, at: 0)
        return true
    }
}

struct OrderView: View {
    @ObservedObject var store: RedemptionStore
    let onBrowseRewards: () -> Void

    @State private var selectedOrder: RedemptionOrder?

    var body: some View {
        ScrollView {
            readyOrdersSection
                .padding(AppSpacing.medium)
        }
        .background(AppColors.background)
        .fullScreenCover(item: $selectedOrder) { order in
            PickupOrderView(order: order) {
                store.collect(orderID: order.id)
                selectedOrder = nil
            }
        }
    }

    private var readyOrdersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to pick up")
                        .font(.title3.bold())
                    Text("Open an order when you arrive.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Spacer()

                Text("\(store.readyOrders.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppColors.brandForeground)
                    .frame(minWidth: 30, minHeight: 30)
                    .background(AppColors.brand)
                    .clipShape(Circle())
            }

            if store.readyOrders.isEmpty {
                emptyReadyState
            } else {
                ForEach(store.readyOrders) { order in
                    Button {
                        selectedOrder = order
                    } label: {
                        ReadyOrderCard(order: order)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens pickup confirmation")
                }
            }
        }
    }

    private var emptyReadyState: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(AppColors.brand)
            Text("Nothing to pick up")
                .font(.headline)
            Text("Browse Rewards to place a new order, or open Order History.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
            Button("Browse rewards", action: onBrowseRewards)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brand)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

struct RewardsView: View {
    @ObservedObject var store: RedemptionStore
    let onOpenOrder: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.large) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nearby rewards")
                        .font(.title3.bold())
                    Text("Choose a local business and use your demo points.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }

                RewardsMapCard(merchants: store.merchants)
                    .frame(height: 230)

                VStack(spacing: AppSpacing.medium) {
                    ForEach(store.merchants) { merchant in
                        MerchantCard(
                            merchant: merchant,
                            store: store,
                            onOpenOrder: onOpenOrder
                        )
                    }
                }
            }
            .padding(AppSpacing.medium)
        }
        .background(AppColors.background)
    }
}

private struct RewardsMapCard: View {
    let merchants: [RedemptionMerchant]

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -37.8036, longitude: 144.9665),
            span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
        )
    )

    private let demoUserCoordinate = CLLocationCoordinate2D(
        latitude: -37.7983,
        longitude: 144.9610
    )

    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            Annotation("You", coordinate: demoUserCoordinate) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.22))
                        .frame(width: 34, height: 34)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 15, height: 15)
                        .overlay {
                            Circle().stroke(Color.white, lineWidth: 3)
                        }
                }
            }

            ForEach(merchants) { merchant in
                Annotation(merchant.name, coordinate: merchant.coordinate) {
                    Image(systemName: "gift.fill")
                        .font(.caption.bold())
                        .foregroundStyle(AppColors.brandForeground)
                        .frame(width: 34, height: 34)
                        .background(AppColors.brand)
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(Color.white, lineWidth: 3)
                        }
                        .shadow(radius: 3, y: 1)
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topLeading) {
            Label("Demo locations", systemImage: "map.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .padding(AppSpacing.small)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

private struct MerchantCard: View {
    let merchant: RedemptionMerchant
    @ObservedObject var store: RedemptionStore
    let onOpenOrder: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: "storefront.fill")
                .font(.title3)
                .foregroundStyle(AppColors.brand)
                .frame(width: 46, height: 46)
                .background(AppColors.brand.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(merchant.name)
                    .font(.headline)
                Text(merchant.address)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1)
                Text(String(format: "%.1f km away", merchant.distanceKilometres))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.brand)
            }

            Spacer(minLength: AppSpacing.small)

            NavigationLink {
                MerchantProductsView(
                    merchant: merchant,
                    store: store,
                    onOpenOrder: onOpenOrder
                )
            } label: {
                Text("Order")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.brandForeground)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(AppColors.brand)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

private struct MerchantProductsView: View {
    let merchant: RedemptionMerchant
    @ObservedObject var store: RedemptionStore
    let onOpenOrder: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alert: ProductOrderAlert?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.large) {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Label(merchant.address, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("\(store.pointsBalance) pts available")
                        .font(.headline)
                        .foregroundStyle(AppColors.brand)
                }
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                ForEach(merchant.products) { product in
                    ProductCard(
                        product: product,
                        canOrder: store.canOrder(product)
                    ) {
                        order(product)
                    }
                }
            }
            .padding(AppSpacing.medium)
        }
        .background(AppColors.background)
        .navigationTitle(merchant.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $alert) { alert in
            switch alert {
            case let .success(productName, referenceNumber):
                Alert(
                    title: Text("Order ready to pick up"),
                    message: Text("\(productName) was added to Ready to Pick Up. Reference: \(referenceNumber)"),
                    primaryButton: .default(Text("View order")) {
                        dismiss()
                        DispatchQueue.main.async {
                            onOpenOrder()
                        }
                    },
                    secondaryButton: .cancel(Text("Keep browsing"))
                )
            case .notEnoughPoints:
                Alert(
                    title: Text("Not enough points"),
                    message: Text("Complete more walks before ordering this reward."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func order(_ product: RewardProduct) {
        guard let order = store.placeOrder(
            merchantID: merchant.id,
            productID: product.id
        ) else {
            alert = .notEnoughPoints
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        alert = .success(
            productName: product.name,
            referenceNumber: order.referenceNumber
        )
    }
}

private enum ProductOrderAlert: Identifiable {
    case success(productName: String, referenceNumber: String)
    case notEnoughPoints

    var id: String {
        switch self {
        case let .success(_, referenceNumber):
            return referenceNumber
        case .notEnoughPoints:
            return "not-enough-points"
        }
    }
}

private struct ProductCard: View {
    let product: RewardProduct
    let canOrder: Bool
    let order: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: product.icon)
                .font(.title2)
                .foregroundStyle(AppColors.brand)
                .frame(width: 52, height: 52)
                .background(AppColors.brand.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.headline)
                Text(product.details)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(product.pointPrice) pts")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColors.brand)
            }

            Spacer(minLength: AppSpacing.small)

            Button("Order", action: order)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brand)
                .disabled(!canOrder)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

private struct ReadyOrderCard: View {
    let order: RedemptionOrder

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .top) {
                Label("ORDER READY TO PICK UP", systemImage: "bag.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.brand)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(order.venueName)
                    .font(.title3.bold())
                Text(order.items.map { "\($0.quantity) × \($0.name)" }.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reference")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text(order.referenceNumber)
                        .font(.subheadline.monospaced().weight(.semibold))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Pick up by")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text(order.expiresAt, style: .time)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(AppColors.brand.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

private struct PickupOrderView: View {
    let order: RedemptionOrder
    let onCollected: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    VStack(spacing: AppSpacing.small) {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(AppColors.brand)
                        Text("Ready to pick up")
                            .font(.title2.bold())
                        Text(order.referenceNumber)
                            .font(.headline.monospaced())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity)

                    detailCard
                    pickupNotice
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
            .navigationTitle("Pick Up Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: AppSpacing.small) {
                    Text("Swipe only after you receive your order.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                    SwipeToCollectControl {
                        onCollected()
                        dismiss()
                    }
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, AppSpacing.medium)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(order.venueName)
                    .font(.title3.bold())
                Text(order.venueAddress)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }

            Divider()

            ForEach(order.items) { item in
                HStack(alignment: .top) {
                    Text("\(item.quantity) ×")
                        .fontWeight(.semibold)
                    Text(item.name)
                    Spacer()
                    Text("\(item.pointPrice * item.quantity) pts")
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            Divider()

            HStack {
                Text("Points paid")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(order.totalPoints) pts")
                    .fontWeight(.bold)
                    .foregroundStyle(AppColors.brand)
            }

            HStack {
                Text("Pick up by")
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(order.expiresAt, style: .time)
                    .fontWeight(.semibold)
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var pickupNotice: some View {
        HStack(alignment: .top, spacing: AppSpacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Confirm with the venue")
                    .font(.headline)
                Text("Show this screen to staff. After you swipe, the order is marked as collected and moves to Order History.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(AppSpacing.medium)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

struct OrderHistoryView: View {
    @ObservedObject var store: RedemptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.historyOrders.isEmpty {
                    VStack(spacing: AppSpacing.medium) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 42))
                            .foregroundStyle(AppColors.secondaryText)
                        Text("No order history")
                            .font(.headline)
                        Text("Orders appear here after pickup.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
                } else {
                    ScrollView {
                        LazyVStack(spacing: AppSpacing.medium) {
                            ForEach(store.historyOrders) { order in
                                HistoryOrderCard(order: order)
                            }
                        }
                        .padding(AppSpacing.medium)
                    }
                    .background(AppColors.background)
                }
            }
            .navigationTitle("Order History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct HistoryOrderCard: View {
    let order: RedemptionOrder

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack {
                Label(order.status.title, systemImage: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColour)
                Spacer()
                Text(order.referenceNumber)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppColors.secondaryText)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(order.venueName)
                    .font(.headline)
                Text(order.items.map { "\($0.quantity) × \($0.name)" }.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }

            HStack {
                Text(historyDate, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text("\(order.totalPoints) pts")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var historyDate: Date {
        order.collectedAt ?? order.expiresAt
    }

    private var statusIcon: String {
        switch order.status {
        case .collected:
            return "checkmark.circle.fill"
        case .expired:
            return "clock.badge.exclamationmark.fill"
        case .cancelled:
            return "xmark.circle.fill"
        case .pending:
            return "bag.fill"
        }
    }

    private var statusColour: Color {
        switch order.status {
        case .collected:
            return AppColors.brand
        case .expired:
            return .orange
        case .cancelled:
            return AppColors.error
        case .pending:
            return AppColors.brand
        }
    }
}

private struct SwipeToCollectControl: View {
    let onComplete: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isCompleted = false

    var body: some View {
        GeometryReader { geometry in
            let thumbSize: CGFloat = 56
            let edgeInset: CGFloat = 4
            let maximumOffset = max(0, geometry.size.width - thumbSize - edgeInset * 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isCompleted ? AppColors.brand : AppColors.brand.opacity(0.16))

                HStack(spacing: 4) {
                    Spacer()
                    Text(isCompleted ? "Order collected" : "Swipe to confirm pickup")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCompleted ? AppColors.brandForeground : AppColors.brand)
                    if !isCompleted {
                        Image(systemName: "chevron.right.2")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppColors.brand.opacity(0.65))
                    }
                    Spacer()
                }
                .padding(.leading, thumbSize)

                Circle()
                    .fill(isCompleted ? Color.white : AppColors.brand)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay {
                        Image(systemName: isCompleted ? "checkmark" : "bag.fill")
                            .font(.headline)
                            .foregroundStyle(isCompleted ? AppColors.brand : AppColors.brandForeground)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .padding(.leading, edgeInset)
                    .offset(x: dragOffset)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isCompleted else { return }
                        dragOffset = min(max(value.translation.width, 0), maximumOffset)
                    }
                    .onEnded { _ in
                        guard !isCompleted else { return }

                        if dragOffset >= maximumOffset * 0.8 {
                            complete(maximumOffset: maximumOffset)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Confirm order pickup")
            .accessibilityHint("Swipe right, or use the accessibility action, after receiving the order")
            .accessibilityAction {
                complete(maximumOffset: maximumOffset)
            }
        }
        .frame(height: 64)
    }

    private func complete(maximumOffset: CGFloat) {
        guard !isCompleted else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = maximumOffset
            isCompleted = true
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onComplete()
        }
    }
}
