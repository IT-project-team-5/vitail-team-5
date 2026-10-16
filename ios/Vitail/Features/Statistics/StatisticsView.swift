import SwiftUI

struct StatisticsView: View {
    @StateObject private var viewModel = StatisticsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {

                Text("Statistics")
                    .font(.largeTitle.bold())

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)

                } else if let errorMessage = viewModel.errorMessage {
                    errorState(errorMessage)

                } else if let statistics = viewModel.statistics {
                    todayCard(statistics)
                    sevenDayCard(statistics)

                    if let leaderboard = viewModel.leaderboard {
                        leaderboardSection(leaderboard)
                    }
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .task {
            await viewModel.loadData()
        }
        .refreshable {
            await viewModel.loadData()
        }
    }

    // MARK: - Today's Activity

    private func todayCard(_ statistics: UserStatistics) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {

            Text("Today's Activity")
                .font(.title2.bold())

            HStack {
                VStack(alignment: .leading) {
                    Text("Walking")
                        .foregroundStyle(AppColors.secondaryText)

                    Text("\(statistics.todayWalkingMinutes) min")
                        .font(.title3.bold())
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("Distance")
                        .foregroundStyle(AppColors.secondaryText)

                    Text(
                        statistics.todayDistanceKm,
                        format: .number.precision(.fractionLength(1))
                    )
                    .font(.title3.bold())

                    Text("km")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            Divider()

            Text("Daily Goal")
                .font(.headline)

            ProgressView(value: statistics.goalProgress)

            Text(
                "\(statistics.todayWalkingMinutes) / \(statistics.dailyGoalMinutes) min"
            )
            .font(.subheadline)
            .foregroundStyle(AppColors.secondaryText)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: AppRadius.card)
        )
    }

    // MARK: - Seven Day Goals

    private func sevenDayCard(_ statistics: UserStatistics) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {

            Text("7-Day Goals")
                .font(.title2.bold())

            HStack {
                ForEach(statistics.sevenDayGoals) { day in
                    VStack(spacing: 6) {
                        Image(
                            systemName: day.completed
                                ? "checkmark.circle.fill"
                                : "circle"
                        )

                        Text(shortDay(from: day.date))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text(
                "\(statistics.completedGoals) of 7 goals completed"
            )
            .font(.subheadline)
            .foregroundStyle(AppColors.secondaryText)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: AppRadius.card)
        )
    }

    // MARK: - Leaderboard

    private func leaderboardSection(
        _ leaderboard: LeaderboardResponse
    ) -> some View {

        VStack(alignment: .leading, spacing: AppSpacing.medium) {

            Text("Friends Leaderboard")
                .font(.title2.bold())

            if leaderboard.entries.isEmpty {

                Text("No friends on your leaderboard yet.")
                    .foregroundStyle(AppColors.secondaryText)

            } else {

                ForEach(leaderboard.entries) { entry in
                    HStack {
                        Text("#\(entry.rank)")
                            .font(.headline)
                            .frame(width: 40)

                        Text(
                            entry.isCurrentUser
                                ? "\(entry.displayName) (You)"
                                : entry.displayName
                        )

                        Spacer()

                        Text(formatLeaderboardValue(entry.value))
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 6)
                }

                if let myRank = leaderboard.myRank {
                    Divider()

                    Text("Your position: #\(myRank)")
                        .font(.subheadline.bold())
                }
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: AppRadius.card)
        )
    }

    // MARK: - Error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: AppSpacing.medium) {

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))

            Text("Unable to load statistics")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func shortDay(from date: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let parsedDate = formatter.date(from: date) else {
            return "-"
        }

        formatter.dateFormat = "E"
        return String(formatter.string(from: parsedDate).prefix(1))
    }

    private func formatLeaderboardValue(_ value: Double) -> String {
        "\(Int(value))"
    }
}