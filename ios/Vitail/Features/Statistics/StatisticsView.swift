import SwiftUI

struct StatisticsView: View {
    @StateObject private var viewModel: StatisticsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var accessibleDayWidth: CGFloat = 44

    // This destination owns one account's model for its lifetime. Account changes
    // invalidate the model immediately, including requests already in flight.
    init(ownerID: Int, session: SessionStore, service: any StatisticsServing = StatisticsService()) {
        _viewModel = StateObject(wrappedValue: StatisticsViewModel(ownerID: ownerID, session: session, service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                if let statistics = viewModel.statistics {
                    todayCard(statistics)
                    sevenDayCard(statistics)
                } else if viewModel.isLoadingStatistics {
                    ProgressView("Loading your activity…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.large)
                }
                if let message = viewModel.statisticsError {
                    retryMessage(message) { await viewModel.loadStatistics() }
                }
                leaderboardCard
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            if scenePhase == .active { await viewModel.loadData() }
        }
        .refreshable { await viewModel.loadData() }
        .onDisappear { viewModel.cancelReads() }
    }

    private func todayCard(_ statistics: UserStatistics) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Today's activity").font(.title2.bold())
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Walking").foregroundStyle(AppColors.secondaryText)
                    Text("\(statistics.todayWalkingMinutes) min").font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Distance").foregroundStyle(AppColors.secondaryText)
                    Text("\(statistics.todayDistanceKm, format: .number.precision(.fractionLength(1))) km")
                        .font(.title3.bold())
                }
            }
            Divider()
            Text("Daily goals").font(.headline)
            if statistics.dailyGoalTargetSeconds > 0 {
                ProgressView(value: statistics.goalProgress)
                    .accessibilityLabel("Your dogs' daily goal progress")
                    .accessibilityValue(statistics.goalProgress.formatted(.percent.precision(.fractionLength(0))))
                Text("\(Double(statistics.dailyGoalActiveSeconds) / 60, format: .number.precision(.fractionLength(1))) / \(Double(statistics.dailyGoalTargetSeconds) / 60, format: .number.precision(.fractionLength(1))) min across your dogs")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                Text("No daily goals available yet. Add your dog's details in Account.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .statisticsCard()
    }

    private func sevenDayCard(_ statistics: UserStatistics) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("7-day goals").font(.title2.bold())
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    goalDays(statistics.sevenDayGoals, minimumWidth: accessibleDayWidth)
                }
            } else {
                goalDays(statistics.sevenDayGoals)
            }
            Text("\(statistics.completedGoals) of \(statistics.sevenDayGoals.count) days completed")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            Text("Days follow Melbourne time.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .statisticsCard()
    }

    private func goalDays(_ days: [DailyGoalResult], minimumWidth: CGFloat? = nil) -> some View {
        HStack(alignment: .top) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Image(systemName: day.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(day.completed ? AppColors.brand : AppColors.secondaryText)
                    Text(day.dateLabel(template: "EEEEE")).font(.caption)
                }
                .frame(minWidth: minimumWidth, maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.dateLabel(template: "EEEE d MMMM"))
                .accessibilityValue(day.completed ? "Goals completed" : "Goals not completed")
            }
        }
    }

    private var leaderboardCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Friends leaderboard").font(.title2.bold())
            Toggle("Share my activity with friends", isOn: Binding(
                get: { viewModel.leaderboardVisible },
                set: { visible in Task { await viewModel.setLeaderboardVisible(visible) } }
            ))
            .disabled(!viewModel.canChangeVisibility)
            .accessibilityHint("Controls whether friends can see your walking minutes on their leaderboard.")
            Text("Only friends who choose to share appear. Your own activity is always visible to you.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
            if viewModel.isSavingVisibility { ProgressView("Saving preference…") }
            if let message = viewModel.visibilityError {
                retryMessage(message) { await viewModel.retryVisibility() }
            }
            if viewModel.isLoadingLeaderboard {
                ProgressView("Loading leaderboard…")
            } else if let message = viewModel.leaderboardError {
                retryMessage(message) { await viewModel.loadLeaderboard() }
            } else if let leaderboard = viewModel.leaderboard {
                Text("\(leaderboard.metric) · \(leaderboard.period)")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                if leaderboard.entries.isEmpty {
                    Text("No activity to show yet.").foregroundStyle(AppColors.secondaryText)
                } else {
                    ForEach(leaderboard.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                            Text("#\(entry.rank)").font(.headline)
                            Text(entry.isCurrentUser ? "\(entry.name) (You)" : entry.name)
                            Spacer(minLength: AppSpacing.small)
                            Text("\(entry.value, format: .number.precision(.fractionLength(1...2))) min")
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                    if !leaderboard.entries.contains(where: { !$0.isCurrentUser }) {
                        Text("Friends who share their activity will appear here.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if let rank = leaderboard.myRank {
                        Text("Your position: #\(rank)").font(.subheadline.bold())
                    }
                }
            }
        }
        .statisticsCard()
    }

    private func retryMessage(_ message: String, action: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(message).font(.subheadline).foregroundStyle(AppColors.secondaryText)
            Button("Retry") { Task { await action() } }
                .buttonStyle(.bordered)
        }
    }
}

private extension View {
    func statisticsCard() -> some View {
        padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vitailCardBackground()
    }
}
