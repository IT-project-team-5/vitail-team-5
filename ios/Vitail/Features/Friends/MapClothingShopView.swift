import Combine
import Foundation
import SwiftUI

enum AvatarHat: String, Codable, Sendable {
    case none, baseballCap, beanie, sunHat
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

enum AvatarBandanaStyle: String, Codable, Sendable {
    case classic, striped, polkaDot
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .classic
    }
}

enum AvatarDecoration: String, Codable, Sendable {
    case none, roundGlasses, starBadge
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

struct DogAvatarOutfit: Codable, Equatable, Sendable {
    var hat: AvatarHat = .none
    var bandanaStyle: AvatarBandanaStyle = .classic
    var decoration: AvatarDecoration = .none
    static let plain = DogAvatarOutfit()

    init(hat: AvatarHat = .none, bandanaStyle: AvatarBandanaStyle = .classic,
         decoration: AvatarDecoration = .none) {
        self.hat = hat
        self.bandanaStyle = bandanaStyle
        self.decoration = decoration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hat = try values.decodeIfPresent(AvatarHat.self, forKey: .hat) ?? .none
        bandanaStyle = try values.decodeIfPresent(AvatarBandanaStyle.self, forKey: .bandanaStyle) ?? .classic
        decoration = try values.decodeIfPresent(AvatarDecoration.self, forKey: .decoration) ?? .none
    }

    enum CodingKeys: String, CodingKey {
        case hat, bandanaStyle = "bandana_style", decoration
    }
}

enum AvatarShopCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case hats, bandanas, extras
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var clearTitle: String {
        switch self {
        case .hats: return "No hat"
        case .bandanas: return "Classic pattern"
        case .extras: return "No extra"
        }
    }
}

struct AvatarShopProduct: Codable, Equatable, Identifiable, Sendable {
    let code: String
    let title: String
    let description: String
    let category: AvatarShopCategory
    let price: Int
    var id: String { code }

    func applying(to outfit: DogAvatarOutfit) -> DogAvatarOutfit {
        var result = outfit
        switch code {
        case "baseballCap": result.hat = .baseballCap
        case "beanie": result.hat = .beanie
        case "sunHat": result.hat = .sunHat
        case "stripedBandana": result.bandanaStyle = .striped
        case "polkaDotBandana": result.bandanaStyle = .polkaDot
        case "roundGlasses": result.decoration = .roundGlasses
        case "starBadge": result.decoration = .starBadge
        default: break
        }
        return result
    }

    func isEquipped(in outfit: DogAvatarOutfit) -> Bool {
        switch code {
        case "baseballCap": return outfit.hat == .baseballCap
        case "beanie": return outfit.hat == .beanie
        case "sunHat": return outfit.hat == .sunHat
        case "stripedBandana": return outfit.bandanaStyle == .striped
        case "polkaDotBandana": return outfit.bandanaStyle == .polkaDot
        case "roundGlasses": return outfit.decoration == .roundGlasses
        case "starBadge": return outfit.decoration == .starBadge
        default: return false
        }
    }
}

struct AvatarShopState: Codable, Equatable, Sendable {
    let balance: Int
    let products: [AvatarShopProduct]
    let owned: [String]
    let outfit: DogAvatarOutfit
}

struct AvatarShopPurchase: Encodable, Equatable, Sendable {
    let productCode: String
    let requestID: UUID
    enum CodingKeys: String, CodingKey {
        case productCode = "product_code", requestID = "request_id"
    }
}

struct AvatarShopOutfitUpdate: Encodable, Sendable {
    let category: AvatarShopCategory
    let productCode: String?
    enum CodingKeys: String, CodingKey { case category, productCode = "product_code" }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(category, forKey: .category)
        if let productCode { try values.encode(productCode, forKey: .productCode) }
        else { try values.encodeNil(forKey: .productCode) }
    }
}

protocol AvatarShopServing: Sendable {
    func load() async throws -> AvatarShopState
    func purchase(_ request: AvatarShopPurchase) async throws -> AvatarShopState
    func updateOutfit(_ update: AvatarShopOutfitUpdate) async throws -> AvatarShopState
}

actor AvatarShopService: AvatarShopServing {
    private let apiClient: AuthenticatedAPIClient
    private let path = "/api/social/avatar-shop"
    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) { self.apiClient = apiClient }
    func load() async throws -> AvatarShopState { try await apiClient.get(path) }
    func purchase(_ request: AvatarShopPurchase) async throws -> AvatarShopState {
        try await apiClient.post("\(path)/purchases", body: request)
    }
    func updateOutfit(_ update: AvatarShopOutfitUpdate) async throws -> AvatarShopState {
        try await apiClient.patch("\(path)/outfit", body: update)
    }
}

@MainActor
final class AvatarShopStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var snapshot: AvatarShopState?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var pendingPurchase: AvatarShopPurchase?
    var balance: Int? { snapshot?.balance }
    var products: [AvatarShopProduct] { snapshot?.products ?? [] }
    var owned: Set<String> { Set(snapshot?.owned ?? []) }
    var outfit: DogAvatarOutfit { snapshot?.outfit ?? .plain }

    private let service: any AvatarShopServing
    private weak var session: SessionStore?
    private let sessionRevision: Int?
    private let onOutfitChanged: @MainActor () async -> Void
    private var sessionSubscription: AnyCancellable?
    private var operationTask: Task<AvatarShopState, Error>?
    private var enabled = true
    private var generation = 0

    init(ownerID: Int, session: SessionStore? = nil,
         service: any AvatarShopServing = AvatarShopService(),
         onOutfitChanged: @escaping @MainActor () async -> Void = {}) {
        self.ownerID = ownerID
        self.session = session
        self.sessionRevision = session?.sessionRevision
        self.service = service
        self.onOutfitChanged = onOutfitChanged
        sessionSubscription = session?.$state.sink { [weak self] state in
            guard let self else { return }
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner,
               self.session?.sessionRevision == self.sessionRevision { return }
            self.stop()
        }
    }

    deinit { operationTask?.cancel() }

    func load() async {
        await run(notice: nil, notify: false) { try await self.service.load() }
    }

    func purchase(_ product: AvatarShopProduct) async {
        guard prepare(), !isWorking, snapshot != nil else { return }
        if owned.contains(product.code) { notice = "You already own \(product.title). Choose Wear to equip it."; return }
        if let pendingPurchase, pendingPurchase.productCode != product.code {
            errorMessage = "Resolve the pending purchase before buying another item."
            return
        }
        if pendingPurchase == nil {
            guard let current = products.first(where: { $0.code == product.code }), current.price > 0,
                  let balance, balance >= current.price else {
                errorMessage = "Not enough points for this item."
                return
            }
            pendingPurchase = AvatarShopPurchase(productCode: product.code, requestID: UUID())
        }
        await retryPendingPurchase()
    }

    func retryPendingPurchase() async {
        guard prepare(), !isWorking, let request = pendingPurchase else { return }
        await run(notice: "Purchased. Choose Wear to equip your new item.", notify: true, purchaseRequest: request) {
            let response = try await self.service.purchase(request)
            guard response.owned.contains(request.productCode) else {
                throw APIError.network("The purchase response did not confirm ownership. Check your wardrobe or retry this purchase.")
            }
            return response
        }
    }

    func wear(_ product: AvatarShopProduct) async {
        guard prepare(), !isWorking, owned.contains(product.code),
              products.contains(where: { $0.code == product.code && $0.category == product.category }) else { return }
        await run(notice: "\(product.title) equipped.", notify: true) {
            let response = try await self.service.updateOutfit(.init(category: product.category, productCode: product.code))
            guard product.isEquipped(in: response.outfit) else {
                throw APIError.network("The outfit change was not confirmed. Try again.")
            }
            return response
        }
    }

    func clear(_ category: AvatarShopCategory) async {
        guard prepare(), !isWorking, snapshot != nil else { return }
        await run(notice: "\(category.title) updated. Your owned items stay in your wardrobe.", notify: true) {
            let response = try await self.service.updateOutfit(.init(category: category, productCode: nil))
            switch category {
            case .hats: guard response.outfit.hat == .none else { throw APIError.invalidResponse }
            case .bandanas: guard response.outfit.bandanaStyle == .classic else { throw APIError.invalidResponse }
            case .extras: guard response.outfit.decoration == .none else { throw APIError.invalidResponse }
            }
            return response
        }
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        sessionSubscription = nil
        snapshot = nil
        pendingPurchase = nil
        isWorking = false
        errorMessage = nil
        notice = nil
    }

    private func prepare() -> Bool {
        guard enabled else { return false }
        if let sessionRevision {
            guard let session, session.sessionRevision == sessionRevision,
                  case let .signedIn(user) = session.state, user.id == ownerID, user.role == .owner else {
                stop()
                return false
            }
        }
        return true
    }

    private func run(notice successNotice: String?, notify: Bool,
                     purchaseRequest: AvatarShopPurchase? = nil,
                     operation: @escaping @MainActor () async throws -> AvatarShopState) async {
        guard prepare(), !isWorking else { return }
        let lifetime = generation
        isWorking = true
        errorMessage = nil
        notice = nil
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        operationTask = task
        defer {
            if enabled, lifetime == generation { isWorking = false; operationTask = nil }
        }
        do {
            let result = try await task.value
            guard prepare(), lifetime == generation else { return }
            snapshot = result
            let reconciledPurchase = pendingPurchase.map { result.owned.contains($0.productCode) } ?? false
            if reconciledPurchase { pendingPurchase = nil }
            notice = successNotice
            if notify || reconciledPurchase { await onOutfitChanged() }
        } catch {
            guard prepare(), lifetime == generation else { return }
            errorMessage = error.localizedDescription
            if let purchaseRequest, pendingPurchase == purchaseRequest,
               case let APIError.http(status, _) = error, [400, 403, 404, 409].contains(status) {
                pendingPurchase = nil
            }
            // A lost response may follow a completed debit. Keep this UUID until
            // the same request succeeds or an authoritative load confirms ownership.
        }
    }
}

struct MapClothingShopView: View {
    @ObservedObject var store: AvatarShopStore
    let profile: SocialProfile
    @State private var confirmingProduct: AvatarShopProduct?
    private var currentOutfit: DogAvatarOutfit { store.snapshot?.outfit ?? profile.avatarOutfit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                walletCard
                HStack(spacing: 18) {
                    DogMapAvatarView(breed: profile.dogAvatarBreed, bandanaColor: profile.bandanaColor, outfit: currentOutfit)
                        .frame(width: 104, height: 104)
                        .accessibilityIdentifier("clothing-shop-current-avatar")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.displayName).font(.headline)
                        Text("Your map appearance").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        Text("Buy an item, then choose Wear.").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                }
                if let error = store.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(AppColors.error)
                }
                if let pending = store.pendingPurchase {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This purchase is awaiting confirmation.").font(.footnote)
                        HStack {
                            Button("Retry purchase") { Task { await store.retryPendingPurchase() } }
                            Button("Check wardrobe") { Task { await store.load() } }
                        }
                    }
                    .disabled(store.isWorking)
                    .accessibilityIdentifier("clothing-shop-pending-\(pending.productCode)")
                } else if store.errorMessage != nil {
                    Button("Try Again") { Task { await store.load() } }.disabled(store.isWorking)
                }
                if let notice = store.notice {
                    Text(notice).font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
                if store.snapshot != nil {
                    ForEach(AvatarShopCategory.allCases) { category in categorySection(category) }
                } else if store.isWorking {
                    ProgressView("Loading clothing…")
                }
            }.padding(16)
        }
        .background(AppColors.background)
        .navigationTitle("Clothing shop")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
        .alert("Buy clothing with points", isPresented: Binding(
            get: { confirmingProduct != nil }, set: { if !$0 { confirmingProduct = nil } }
        ), presenting: confirmingProduct) { product in
            Button("Buy for \(product.price) pt") {
                confirmingProduct = nil
                Task { await store.purchase(product) }
            }
            Button("Cancel", role: .cancel) { confirmingProduct = nil }
        } message: { product in
            Text("Buy \(product.title) for \(product.price) pt from your points wallet? You can choose Wear after the purchase.")
        }
        .accessibilityIdentifier("map-clothing-shop")
    }

    private var walletCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Points wallet", systemImage: "wallet.pass").font(.subheadline.weight(.semibold))
            Text(store.balance.map { "\($0.formatted()) pt" } ?? "Loading balance…")
                .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(AppColors.brandForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppColors.brand, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .accessibilityIdentifier("clothing-shop-balance")
    }

    private func categorySection(_ category: AvatarShopCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.title).font(.title3.weight(.semibold))
                Spacer()
                Button(category.clearTitle) { Task { await store.clear(category) } }
                    .font(.caption.weight(.semibold)).frame(minHeight: 44)
                    .disabled(store.isWorking)
            }
            if category == .bandanas {
                Text("Bandana colors keep their meaning: red · reactive, yellow · please give space, green · friendly. Choose a color or no bandana in your map profile.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                if profile.bandanaColor == .none {
                    Text("Green appears only in these previews. Buying or wearing a pattern keeps your no-bandana choice.")
                        .font(.caption2).foregroundStyle(AppColors.secondaryText)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(store.products.filter { $0.category == category }) { product in productCard(product) }
            }
        }
    }

    private func productCard(_ product: AvatarShopProduct) -> some View {
        let isOwned = store.owned.contains(product.code)
        let isEquipped = product.isEquipped(in: store.outfit)
        let canAfford = product.price > 0 && (store.balance ?? 0) >= product.price
        return VStack(spacing: 9) {
            DogMapAvatarView(breed: profile.dogAvatarBreed,
                             bandanaColor: product.category == .bandanas && profile.bandanaColor == .none ? .green : profile.bandanaColor,
                             outfit: product.applying(to: store.outfit))
                .frame(width: 94, height: 94)
            Text(product.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            Text(product.description).font(.caption).foregroundStyle(AppColors.secondaryText).multilineTextAlignment(.center)
            Text(isOwned ? "Owned" : "\(product.price) pt").font(.caption.weight(.semibold))
            Button {
                if isOwned { Task { await store.wear(product) } }
                else { confirmingProduct = product }
            } label: {
                Text(isEquipped ? "Equipped" : isOwned ? "Wear" : canAfford ? "Buy" : "Not enough pt")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(AppColors.brand)
            .disabled(store.isWorking || isEquipped || (!isOwned && (!canAfford || store.pendingPurchase != nil)))
            .accessibilityIdentifier("clothing-shop-action-\(product.code)")
        }
        .frame(maxWidth: .infinity, alignment: .top).padding(12)
        .vitailCardBackground()
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(isEquipped ? AppColors.brand : AppColors.border) }
    }
}
