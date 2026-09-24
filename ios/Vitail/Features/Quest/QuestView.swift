import SwiftUI

struct QuestView: View {
    @ObservedObject var store: QuestStore
    @ObservedObject var checkIns: CheckInProgressStore
    var onManageDogs: () -> Void = {}
    var onOpenWalk: () -> Void = {}
    var onOpenDocuments: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                Text("Quests").font(.largeTitle.bold())
                if let snapshot = store.snapshot {
                    dailyGoal(snapshot.dailyGoal)
                    checkInSection
                    streak(snapshot.streak)
                    birthdays(snapshot.birthdays)
                    documentSection
                } else if store.isRefreshing {
                    ProgressView("Loading quests…").frame(maxWidth: .infinity).padding(.vertical, AppSpacing.large)
                } else if store.errorMessage == nil {
                    Text("Your quests will appear here.").foregroundStyle(AppColors.secondaryText)
                }
                if let error = store.errorMessage {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(error).foregroundStyle(AppColors.error)
                        Button("Try again") { Task { await refresh() } }
                            .disabled(store.isRefreshing || store.collectingBirthdayID != nil)
                    }
                    .font(.subheadline)
                }
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .refreshable { await refresh() }
    }

    private func refresh() async {
        async let quests: Void = store.refresh()
        async let venues: Void = checkIns.refresh()
        _ = await (quests, venues)
    }

    private func dailyGoal(_ goal: DailyGoalQuest) -> some View {
        QuestCard(title: "Daily goal", icon: "figure.walk") {
            if goal.dogs.isEmpty {
                Text("Add your dog to see their daily goal.").foregroundStyle(AppColors.secondaryText)
                Button("Add a dog", action: onManageDogs)
            } else {
                ForEach(goal.dogs) { dog in
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        dogHeading(name: dog.name, photo: dog.photo)
                        if goal.status == .available, let progress = dog.progressRatio {
                            ProgressView(value: progress).tint(AppColors.brand)
                                .accessibilityLabel("\(dog.name)'s daily goal")
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        Text("\(QuestFormatting.distance(dog.distanceMetres)) today")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                }
                if goal.status != .available || goal.dogs.contains(where: { $0.progressRatio == nil }) {
                    Text("Daily targets are not set yet.")
                        .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    private var checkInSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            if checkIns.visibleItems.isEmpty {
                QuestCard(title: "Venue check-in", icon: "mappin.and.ellipse") {
                    if checkIns.isRefreshing {
                        ProgressView("Loading check-ins…")
                    } else if checkIns.isAvailable {
                        Text("Check in at a venue from the map. Your progress and reward will appear here.")
                            .foregroundStyle(AppColors.secondaryText)
                        Button("Open map", action: onOpenWalk)
                    } else {
                        Text("Venue check-ins will be available here.").foregroundStyle(AppColors.secondaryText)
                    }
                    if let error = checkIns.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(AppColors.error)
                        Button("Try again") { Task { await checkIns.refresh() } }
                    }
                }
            } else {
                Text("Venue check-in").font(.title3.bold()).padding(.horizontal, AppSpacing.small)
                ForEach(checkIns.visibleItems) { item in
                    CheckInProgressCard(store: checkIns, checkInID: item.id)
                }
            }
        }
    }

    private func streak(_ streak: StreakQuest) -> some View {
        QuestCard(title: "Streak", icon: "flame") {
            if streak.status == .available {
                Text("\(streak.currentDays) \(streak.currentDays == 1 ? "day" : "days")")
                    .font(.largeTitle.bold()).monospacedDigit()
                Text(streak.activeToday ? "You've walked today." : "Take a walk today to keep your streak going.")
                    .foregroundStyle(AppColors.secondaryText)
                Text("Longest streak · \(streak.longestDays) days").font(.subheadline)
                if let next = streak.nextMilestone {
                    Text("Next milestone · \(next.days) days").font(.subheadline)
                }
                if streak.awardStatus == "NOT_ENABLED" {
                    Text("Streak rewards are coming later.").font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
            } else {
                Text("Streaks are currently unavailable.").foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private func birthdays(_ quest: BirthdayQuest) -> some View {
        QuestCard(title: "Birthday treats", icon: "birthday.cake") {
            if let points = quest.rewardPoints, quest.status == .available {
                Text("\(points) points for each dog's birthday, once a year.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
            if quest.dogs.isEmpty {
                Text("Add your dog and their birthday to celebrate together.").foregroundStyle(AppColors.secondaryText)
                Button("Add a dog", action: onManageDogs)
            }
            ForEach(quest.dogs) { dog in
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    dogHeading(name: dog.name, photo: dog.photo)
                    if store.birthdayWasCollected(dog) {
                        Label("Birthday treat collected", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(AppColors.success)
                    } else if quest.status != .available {
                        Text("Birthday treats are currently unavailable.").foregroundStyle(AppColors.secondaryText)
                    } else if dog.status == .missingBirthday {
                        Button("Add birthday", action: onManageDogs)
                    } else if dog.status == .invalidBirthday {
                        Text("Please check this birthday.").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        Button("Edit birthday", action: onManageDogs)
                    } else if dog.status == .available, dog.isBirthdayToday {
                        Text("Happy birthday, \(dog.name)!").font(.subheadline)
                        PrimaryButton(
                            title: quest.rewardPoints.map { "Collect \($0) points" } ?? "Collect",
                            isLoading: store.collectingBirthdayID == dog.dogID,
                            isDisabled: !store.canCollectBirthday(dog)
                        ) { Task { await store.collectBirthday(dogID: dog.dogID) } }
                    } else if dog.status == .upcoming, let date = dog.nextBirthday {
                        Text("Next birthday · \(QuestFormatting.calendarDate(date))")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    } else {
                        Text("No birthday treat available today.").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                }
                .padding(.top, AppSpacing.small)
            }
        }
    }

    private var documentSection: some View {
        QuestCard(title: "Care documents", icon: "doc.text") {
            if store.snapshot?.documents.status == .available, let onOpenDocuments {
                Text("Keep your dog's care documents together and collect eligible rewards.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("View documents", action: onOpenDocuments)
            } else {
                Text("Document rewards will be available here.").foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private func dogHeading(name: String, photo: String?) -> some View {
        HStack(spacing: AppSpacing.small) {
            AvatarView(url: photo, name: name, systemImage: "dog.fill", size: 44)
            Text(name).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct QuestCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Label(title, systemImage: icon).font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.large)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

enum QuestFormatting {
    static func distance(_ metres: Double) -> String {
        let kilometres = max(0, metres) / 1_000
        return kilometres.formatted(.number.precision(.fractionLength(1))) + " km"
    }

    static func calendarDate(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}
