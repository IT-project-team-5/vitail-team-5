import SwiftUI

struct RedemptionView: View {
    @ObservedObject var viewModel: RedemptionViewModel
    var documentService: any DocumentServing = DocumentService()
    var session: SessionStore? = nil
    @State private var selectedCafe: CafeRewardGroup?
    @State private var isMenuPresented = false
    @State private var selectedOrder: Redemption?
    @State private var receiptAfterMenu: Redemption?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pointsCard
                PendingPurchaseNotice(viewModel: viewModel)
                RegistrationGate(viewModel: viewModel, documentService: documentService, session: session)
                if let message = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                        SecondaryButton(title: "Try again") { Task { await viewModel.refresh() } }
                            .disabled(viewModel.isLoading || viewModel.isMutating)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vitailInset()
                }
                if !viewModel.pendingRedemptions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RedeemSectionTitle(text: "Ready to collect")
                        ForEach(viewModel.pendingRedemptions) { order in orderCard(order) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    RedeemSectionTitle(text: "Cafés")
                    if viewModel.cafes.isEmpty && !viewModel.isLoading {
                        ContentUnavailableView {
                            Label("No rewards available", systemImage: "cup.and.saucer")
                                .font(AppFont.heading(20, .semibold, relativeTo: .title3))
                        } description: {
                            Text("Check back soon for local rewards.").font(AppFont.body(15))
                        }
                        .foregroundStyle(AppColors.primaryText)
                        .frame(maxWidth: .infinity)
                        .vitailInset()
                    }
                    ForEach(viewModel.cafes) { cafe in
                        Button {
                            isMenuPresented = true
                            selectedCafe = cafe
                        } label: {
                            cafeRow(cafe)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("View café and menu")
                        .padding(.trailing, AppStroke.shadow)
                    }
                }
                if !viewModel.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RedeemSectionTitle(text: "History")
                        ForEach(viewModel.history) { order in orderCard(order) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, AppSpacing.medium)
        }
        .background { VitailScreenBackground() }
        .refreshable { await viewModel.refresh() }
        .overlay {
            if viewModel.isLoading && viewModel.balance == nil { LoadingView(message: "Loading cafés…") }
        }
        .onChange(of: viewModel.purchasedReceipt) { _, receipt in
            guard let receipt else { return }
            viewModel.acknowledgePurchasedReceipt()
            if isMenuPresented {
                // Wait for the menu to dismiss before presenting another sheet.
                receiptAfterMenu = receipt
                selectedCafe = nil
            } else {
                selectedOrder = receipt
            }
        }
        .sheet(item: $selectedCafe, onDismiss: {
            isMenuPresented = false
            if let receipt = receiptAfterMenu {
                receiptAfterMenu = nil
                selectedOrder = receipt
            }
        }) { cafe in CafeMenuView(cafe: cafe, viewModel: viewModel, documentService: documentService, session: session) }
        .sheet(item: $selectedOrder) { order in RedemptionDetailView(order: order, viewModel: viewModel) }
    }

    /// Points balance card: small uppercase label, big Fredoka number and how
    /// many rewards the balance covers.
    private var pointsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            VitailSectionLabel(text: "Your points")
            Text(viewModel.balance.map { $0.formatted() } ?? "—")
                .font(AppFont.heading(52, .bold, relativeTo: .largeTitle))
                .foregroundStyle(AppColors.primaryText)
                .contentTransition(.numericText())
            if let hint = pointsHint {
                Label(hint, systemImage: "cup.and.saucer")
                    .font(AppFont.body(14, relativeTo: .subheadline))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vitailCard(padding: 20)
        .padding(.trailing, AppStroke.shadow)
        .accessibilityElement(children: .combine)
    }

    private var pointsHint: String? {
        guard let balance = viewModel.balance else { return nil }
        guard let cheapest = viewModel.rewards.map(\.pointCost).filter({ $0 > 0 }).min() else {
            return balance == 0 ? "Walk with your dog to earn points" : nil
        }
        let count = balance / cheapest
        switch count {
        case 0: return "\(cheapest - balance) pts to your first reward"
        case 1: return "Enough for 1 reward"
        default: return "Enough for about \(count) rewards"
        }
    }

    private func cafeRow(_ cafe: CafeRewardGroup) -> some View {
        HStack(spacing: 14) {
            CafeThumbnail(url: cafe.photo, name: cafe.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(cafe.name).font(AppFont.heading(17, .bold)).foregroundStyle(AppColors.primaryText)
                Text(cafe.openingHours.isEmpty ? "Opening hours not provided" : cafe.openingHours)
                    .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let cheapest = cafe.rewards.map(\.pointCost).min() {
                    VitailChip(text: "From \(cheapest) pts").padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
        }
        .padding(14)
        .vitailCardBackground()
        .contentShape(Rectangle())
    }

    private func orderCard(_ order: Redemption) -> some View {
        Button { selectedOrder = order } label: {
            HStack(spacing: 14) {
                CafeThumbnail(url: order.cafePhoto, name: order.cafeNameSnapshot ?? "Café")
                VStack(alignment: .leading, spacing: 3) {
                    Text(order.rewardNameSnapshot).font(AppFont.heading(16, .semibold))
                    Text(order.cafeNameSnapshot ?? "Café").font(AppFont.body(13, relativeTo: .subheadline))
                        .foregroundStyle(AppColors.secondaryText)
                    if order.status == .pending {
                        VitailChip(text: "\(order.pointCostSnapshot) pts · Ready to collect", fill: AppColors.honey)
                            .padding(.top, 4)
                    } else {
                        Text(order.status.rawValue.capitalized)
                            .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }
            .foregroundStyle(AppColors.primaryText).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vitailCardBackground(shadow: order.status == .pending)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityHint("View order details")
        .padding(.trailing, AppStroke.shadow)
    }
}

private struct RedeemSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(AppFont.heading(22, .bold, relativeTo: .title3))
            .foregroundStyle(AppColors.primaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 52 pt rounded square: the café photo, or a cup on an accent colour.
struct CafeThumbnail: View {
    let url: String?
    let name: String
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let url, !url.isEmpty {
                CafeCoverPhoto(url: url, name: name)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
                    }
            } else {
                VitailIconTile(systemImage: "cup.and.saucer", fill: AvatarView.accent(for: name), size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Large header on the café menu: the photo, or the accent card with a cup badge.
struct CafeHero: View {
    let url: String?
    let name: String
    var height: CGFloat = 190

    var body: some View {
        Group {
            if let url, !url.isEmpty {
                CafeCoverPhoto(url: url, name: name)
            } else {
                ZStack {
                    AvatarView.accent(for: name)
                    VitailBackdropPaws()
                    Image(systemName: "cup.and.saucer")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(AppColors.onAccent)
                        .frame(width: 76, height: 76)
                        .background(Color(vitailHex: 0xFFF8EA), in: Circle())
                        .overlay(Circle().strokeBorder(Color(vitailHex: 0x3B2A1A), lineWidth: AppStroke.width))
                }
                .accessibilityLabel("\(name)")
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card)
                .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
        }
    }
}

/// Three faint paws for accent panels.
private struct VitailBackdropPaws: View {
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<3, id: \.self) { index in
                Image("MotifPaw")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color(vitailHex: 0xFFF8EA).opacity(0.7))
                    .rotationEffect(.degrees(30))
                    .position(x: [34, 60, proxy.size.width - 46][index],
                              y: [30, 56, proxy.size.height - 30][index])
            }
        }
        .accessibilityHidden(true)
    }
}

struct CafeCoverPhoto: View {
    let url: String?
    let name: String
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        AppColors.inset
                        Image(systemName: "storefront").font(.system(size: 30, weight: .regular))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityLabel("\(name) photo")
    }
}

struct CafeMenuView: View {
    let cafe: CafeRewardGroup
    @ObservedObject var viewModel: RedemptionViewModel
    var documentService: any DocumentServing = DocumentService()
    var session: SessionStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var chosenRewardID: Int?
    @State private var confirmingReward: Reward?
    private var currentCafe: CafeRewardGroup { viewModel.cafes.first { $0.id == cafe.id } ?? cafe }
    private var menu: [Reward] { viewModel.cafes.first { $0.id == cafe.id }?.rewards ?? [] }
    private var chosenReward: Reward? {
        menu.first { $0.id == (chosenRewardID ?? viewModel.retryRewardID) } ?? menu.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CafeHero(url: currentCafe.photo, name: currentCafe.name)
                    details
                    if let message = viewModel.errorMessage {
                        Text(message).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                    }
                    PendingPurchaseNotice(viewModel: viewModel)
                    RegistrationGate(viewModel: viewModel, documentService: documentService, session: session)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Menu").font(AppFont.heading(22, .bold, relativeTo: .title3))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if let balance = viewModel.balance {
                            VitailChip(text: "You have \(balance.formatted()) pts", systemImage: "sparkle",
                                       fill: AppColors.surface)
                        }
                    }
                    if menu.isEmpty {
                        Text("No items available right now.")
                            .font(AppFont.body(15)).foregroundStyle(AppColors.secondaryText)
                    }
                    ForEach(menu) { reward in menuRow(reward) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, AppSpacing.medium)
            }
            .background(AppColors.background)
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationTitle(currentCafe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $confirmingReward) { reward in
                RedemptionConfirmSheet(reward: reward, viewModel: viewModel) {
                    confirmingReward = nil
                    Task { await viewModel.redeem(rewardID: reward.id) }
                } cancel: {
                    confirmingReward = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .vitailAppearance()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !currentCafe.openingHours.isEmpty || !currentCafe.address.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !currentCafe.openingHours.isEmpty {
                        Label(currentCafe.openingHours, systemImage: "clock")
                    }
                    if !currentCafe.address.isEmpty {
                        Label(currentCafe.address, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(AppFont.body(12, relativeTo: .caption))
                .foregroundStyle(AppColors.secondaryText)
            }
            if !currentCafe.description.isEmpty {
                Text(currentCafe.description).font(AppFont.body(14, relativeTo: .subheadline))
                    .foregroundStyle(AppColors.secondaryText)
            }
            if let url = mapsURL(currentCafe.googleMapsURL) {
                Link(destination: url) { Label("Google Maps", systemImage: "arrow.up.right") }
                    .font(AppFont.heading(14, .semibold))
                    .foregroundStyle(AppColors.brand)
            }
        }
    }

    private func menuRow(_ reward: Reward) -> some View {
        let isChosen = chosenReward?.id == reward.id
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { chosenRewardID = reward.id }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reward.name).font(AppFont.heading(16, .semibold)).foregroundStyle(AppColors.primaryText)
                    if !reward.description.isEmpty {
                        Text(reward.description).font(AppFont.body(12, relativeTo: .caption))
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(reward.pointCost) pts")
                    .font(AppFont.heading(15, .semibold))
                    .foregroundStyle(AppColors.primaryText)
                ZStack {
                    Circle().fill(isChosen ? AppColors.honey : Color.clear)
                    Circle().strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
                }
                .frame(width: 22, height: 22)
            }
            .padding(14)
            .vitailCardBackground(shadow: isChosen)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, AppStroke.shadow)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityHint("Select this item")
    }

    @ViewBuilder private var purchaseBar: some View {
        if let reward = chosenReward {
            let isRetry = viewModel.retryRewardID == reward.id
            VStack(spacing: 8) {
                if !isRetry, let reason = viewModel.purchaseBlockReason(rewardID: reward.id) {
                    Text(reason)
                        .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                PrimaryButton(
                    title: "\(isRetry ? "Retry purchase" : "Redeem \(reward.name)") · \(reward.pointCost) pts",
                    isLoading: viewModel.redeemingRewardID == reward.id,
                    isDisabled: isRetry ? (viewModel.isLoading || viewModel.isMutating)
                        : !viewModel.canPurchase(rewardID: reward.id)
                ) { confirmingReward = reward }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(AppColors.background)
            .overlay(alignment: .top) { Rectangle().fill(AppColors.outline).frame(height: AppStroke.width) }
        }
    }
}

/// Bottom sheet that replaces the old purchase alert: what you're buying,
/// what it costs and what is left afterwards.
private struct RedemptionConfirmSheet: View {
    let reward: Reward
    @ObservedObject var viewModel: RedemptionViewModel
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm redemption").vitailTitle(22)
                HStack(spacing: 12) {
                    VitailIconTile(systemImage: "cup.and.saucer", fill: AppColors.honey, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reward.name).font(AppFont.heading(16, .semibold))
                        Text(reward.cafeName).font(AppFont.body(12, relativeTo: .caption))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                    Text("\(reward.pointCost) pts").font(AppFont.heading(16, .semibold))
                }
                .padding(14)
                .vitailCardBackground(shadow: false)
                if let balance = viewModel.balance {
                    VStack(spacing: 10) {
                        row("Your balance", "\(balance) pts")
                        row("This order", "−\(reward.pointCost) pts", color: AppColors.brand)
                        VitailDashedDivider()
                        HStack {
                            Text("Left after").font(AppFont.heading(16, .semibold))
                            Spacer()
                            Text("\(max(0, balance - reward.pointCost)) pts").font(AppFont.heading(22, .bold))
                        }
                    }
                }
                Label {
                    Text("Points come off now. \(CollectionDeadline.purchaseText()).")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(AppFont.body(12, relativeTo: .caption))
                .foregroundStyle(AppColors.secondaryText)
                PrimaryButton(title: "Confirm · \(reward.pointCost) pts",
                              isDisabled: viewModel.retryRewardID != reward.id && !viewModel.canPurchase(rewardID: reward.id),
                              action: confirm)
                VitailTextButton(title: "Cancel", action: cancel)
            }
            .padding(20)
        }
        .background(AppColors.surface)
        .foregroundStyle(AppColors.primaryText)
    }

    private func row(_ title: String, _ value: String, color: Color = AppColors.primaryText) -> some View {
        HStack {
            Text(title).font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
            Spacer()
            Text(value).font(AppFont.heading(15, .semibold)).foregroundStyle(color)
        }
    }
}

private struct RegistrationGate: View {
    @ObservedObject var viewModel: RedemptionViewModel
    let documentService: any DocumentServing
    let session: SessionStore?

    var body: some View {
        if viewModel.eligibility == nil {
            Text(viewModel.isLoading ? "Checking redemption eligibility…" : "Unable to confirm microchip registration. Refresh to try again.")
                .font(AppFont.body(14, relativeTo: .subheadline)).foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vitailInset()
        } else if let eligibility = viewModel.eligibility, !eligibility.eligible {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.subheadline.weight(.bold))
                        .foregroundStyle(AppColors.brand)
                    Text("Microchip registration needed").font(AppFont.heading(18, .bold, relativeTo: .headline))
                }
                Text("Register each dog to redeem. The 300-point registration reward can be collected separately.")
                    .font(AppFont.body(14, relativeTo: .subheadline)).foregroundStyle(AppColors.secondaryText)
                ForEach(eligibility.incompleteDogs) { dog in
                    NavigationLink {
                        DocumentSubmissionView(service: documentService, session: session,
                            initialDogID: dog.id, initialKind: .microchip, manageRegistration: true,
                            onSubmitted: { await viewModel.refreshEligibility() },
                            onChanged: { await viewModel.refreshEligibility() })
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(AppColors.brand)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Register \(dog.name)'s microchip").font(AppFont.heading(15, .semibold))
                                    .foregroundStyle(AppColors.primaryText)
                                Text("Missing").font(AppFont.body(12, relativeTo: .caption))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vitailCard(padding: 18)
            .padding(.trailing, AppStroke.shadow)
        } else if viewModel.eligibility?.eligible == true, let rewardID = viewModel.registrationRewardID,
                  let reward = viewModel.rewards.first(where: { $0.id == rewardID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("All dogs registered. Continue with \(reward.name).").font(AppFont.body(14, .medium))
                if let reason = viewModel.purchaseBlockReason(rewardID: rewardID) {
                    Text(reason).font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                }
                PrimaryButton(title: "Purchase · \(reward.pointCost) pts", isDisabled: !viewModel.canPurchase(rewardID: rewardID)) {
                    Task { await viewModel.redeem(rewardID: rewardID) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vitailCard(padding: 18)
            .padding(.trailing, AppStroke.shadow)
        }
    }
}

struct RedemptionDetailView: View {
    let order: Redemption
    @ObservedObject var viewModel: RedemptionViewModel
    @Environment(\.dismiss) private var dismiss
    private var current: Redemption { viewModel.redemptions.first { $0.id == order.id } ?? order }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    ticket
                    if let message = viewModel.errorMessage {
                        Text(message).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                    }
                    if current.status == .pending {
                        VStack(spacing: 10) {
                            SlideToCollect(isLoading: viewModel.collectingRedemptionID == current.id,
                                           isDisabled: viewModel.isLoading || viewModel.isMutating) {
                                await viewModel.collect(redemptionID: current.id)
                            }
                            Text("Barista only. Slide after you receive your item. This can't be undone.")
                                .font(AppFont.body(12, relativeTo: .caption))
                                .foregroundStyle(AppColors.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    VitailTextButton(title: "Back to Redeem") { dismiss() }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, AppSpacing.large)
                .frame(maxWidth: .infinity)
            }
            .background { VitailScreenBackground() }
            .navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await viewModel.refresh() }
        }
        .vitailAppearance()
    }

    private var header: some View {
        VStack(spacing: 8) {
            switch current.status {
            case .pending:
                VitailSuccessBadge()
                Text("Order confirmed").vitailTitle(28)
                Text("Show this screen at the counter.")
                    .font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
            case .collected:
                VitailSuccessBadge()
                Text("Collected. Enjoy!").vitailTitle(28)
            default:
                VitailSuccessBadge(systemImage: "arrow.uturn.backward")
                Text("\(current.status.rawValue.capitalized)").vitailTitle(28)
                Text("Points refunded").font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, AppSpacing.small)
    }

    private var ticket: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                VitailSectionLabel(text: "Order code")
                Text(current.referenceNumber)
                    .font(AppFont.heading(40, .bold, relativeTo: .largeTitle))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if current.status == .pending, let expiry = current.expiresAt.flatMap(Self.date) {
                    Text(CollectionDeadline.receiptText(expiry))
                        .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            VitailDashedDivider()
            VStack(spacing: 10) {
                ticketRow("Item", current.rewardNameSnapshot)
                NavigationLink {
                    ReceiptCafeDetailsView(order: current)
                } label: {
                    HStack {
                        Text("Café").font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                        Spacer()
                        Text(current.cafeNameSnapshot ?? "Café").font(AppFont.heading(15, .semibold))
                            .foregroundStyle(AppColors.primaryText)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(current.cafeNameSnapshot ?? "café") details")
                ticketRow("Points spent", "−\(current.pointCostSnapshot) pts", color: AppColors.brand)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .vitailCardBackground()
        .padding(.trailing, AppStroke.shadow)
    }

    private func ticketRow(_ title: String, _ value: String, color: Color = AppColors.primaryText) -> some View {
        HStack {
            Text(title).font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
            Spacer()
            Text(value).font(AppFont.heading(15, .semibold)).foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Uses the receipt's own café fields so details remain available when its menu is no longer listed.
struct ReceiptCafeDetailsView: View {
    let order: Redemption

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CafeHero(url: order.cafePhoto, name: order.cafeNameSnapshot ?? "Café", height: 210)
                Text(order.cafeNameSnapshot ?? "Café").vitailTitle(26)
                if let address = order.cafeAddress, !address.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        VitailSectionLabel(text: "Address")
                        Text(address).font(AppFont.body(15))
                    }
                }
                if let hours = order.cafeOpeningHours, !hours.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        VitailSectionLabel(text: "Opening hours")
                        Text(hours).font(AppFont.body(15))
                    }
                }
                if let url = mapsURL(order.cafeGoogleMapsURL) {
                    Link(destination: url) { Label("Google Maps", systemImage: "arrow.up.right") }
                        .font(AppFont.heading(15, .semibold))
                        .foregroundStyle(AppColors.brand)
                }
                if (order.cafeAddress ?? "").isEmpty && (order.cafeOpeningHours ?? "").isEmpty
                    && mapsURL(order.cafeGoogleMapsURL) == nil {
                    Text("Contact details are not available for this receipt.")
                        .font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.background)
        .navigationTitle("Café details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func mapsURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

private struct PendingPurchaseNotice: View {
    @ObservedObject var viewModel: RedemptionViewModel

    var body: some View {
        if let rewardID = viewModel.retryRewardID {
            VStack(alignment: .leading, spacing: 10) {
                Text("Check your previous purchase before placing another order.")
                    .font(AppFont.body(14, relativeTo: .subheadline)).foregroundStyle(AppColors.secondaryText)
                if let reward = viewModel.retryReward {
                    Text("\(reward.name) · \(reward.cafeName)").font(AppFont.heading(15, .semibold))
                }
                PrimaryButton(
                    title: viewModel.retryReward.map { "Retry purchase · \($0.pointCost) pts" } ?? "Check purchase",
                    isLoading: viewModel.isMutating, isDisabled: viewModel.isLoading || viewModel.isMutating
                ) { Task { await viewModel.redeem(rewardID: rewardID) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vitailInset()
        }
    }
}
