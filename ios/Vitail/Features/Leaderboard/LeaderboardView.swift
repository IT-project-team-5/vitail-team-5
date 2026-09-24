import SwiftUI

struct LeaderboardView: View {
    @ObservedObject var store: LeaderboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                Text("Leaderboard").font(.largeTitle.bold())
                Picker("Time period", selection: Binding(get: { store.period }, set: { period in
                    Task { await store.selectPeriod(period) }
                })) {
                    ForEach(LeaderboardPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                if let entry = store.currentEntry {
                    QuestCard(title: "Your walking", icon: "figure.walk") {
                        HStack(spacing: AppSpacing.medium) {
                            AvatarView(url: entry.photo, name: entry.displayName, size: 56)
                            Text(entry.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                        }
                        statistic("Distance", value: QuestFormatting.distance(entry.distanceMetres))
                        statistic("Walks", value: entry.walkCount.formatted())
                        statistic("Walking points", value: entry.walkingPoints.formatted())
                    }
                } else if store.isRefreshing {
                    ProgressView("Loading your walks…").frame(maxWidth: .infinity).padding(.vertical, AppSpacing.large)
                } else if store.errorMessage == nil {
                    QuestCard(title: "Your walking", icon: "figure.walk") {
                        Text("Your walking stats will appear here.").foregroundStyle(AppColors.secondaryText)
                    }
                }
                if let error = store.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(AppColors.error)
                    Button("Try again") { Task { await store.refresh() } }.disabled(store.isRefreshing)
                }
                QuestCard(title: "Friends", icon: "person.2") {
                    Text("A friends leaderboard is coming later. For now, you can see your own walking stats here.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .refreshable { await store.refresh() }
    }

    private func statistic(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(AppColors.secondaryText)
                Spacer(minLength: AppSpacing.medium)
                Text(value).fontWeight(.semibold).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(AppColors.secondaryText)
                Text(value).fontWeight(.semibold).monospacedDigit()
            }
        }
    }
}
