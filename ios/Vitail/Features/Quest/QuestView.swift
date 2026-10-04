import SwiftUI

/// The compact progress row stays passive; its parent opens the milestone details.
struct StreakProgressView: View {
    let currentDays: Int
    let targetDays: Int
    var isReady = false

    var body: some View {
        if let progress = StreakProgressValue(currentDays: currentDays, targetDays: targetDays) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(progress.label)
                    .font(.headline)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(AppColors.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.medium)
            .foregroundStyle(AppColors.primaryText)
            .background(isReady ? AppColors.brand.opacity(0.12) : AppColors.surface,
                        in: RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay {
                if isReady { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.brand.opacity(0.5), lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Streak progress")
            .accessibilityValue(progress.accessibilityValue)
        }
    }
}

struct QuestView: View {
    @ObservedObject var store: QuestStore
    @ObservedObject var checkIns: CheckInProgressStore
    var onOpenDocuments: ((DocumentQuestRoute) -> Void)?
    @State private var selectedTask: QuestTask?
    @State private var pendingDocument: DocumentQuestRoute?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ScrollView {
                VStack(spacing: AppSpacing.small) {
                    if let goals = store.dailyGoals {
                        if goals.isEmpty {
                            Text("Add a dog to start configuring daily walking goals.")
                                .font(.subheadline).padding(AppSpacing.medium)
                        }
                        ForEach(goals) { goal in DailyWalkingGoalCard(goal: goal) }
                        if !goals.isEmpty {
                            Text("Goal rewards await confirmation of the multi-dog rules. Progress uses Melbourne calendar days.")
                                .font(.caption).foregroundStyle(AppColors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if store.snapshot?.dailyGoals != nil {
                        Text("Refresh to see today's walking goals.").font(.subheadline)
                    }
                    taskRows(store.readyTasks)
                    checkInRows(checkIns.activeItems.filter { $0.status == .ready })
                    taskRows(store.inProgressTasks)
                    checkInRows(checkIns.activeItems.filter { $0.status == .inProgress })
                    taskRows(store.collectedTodayTasks)
                    checkInRows(checkIns.collectedTodayItems)
                    if store.snapshot == nil && store.isRefreshing {
                        ProgressView().frame(maxWidth: .infinity).padding(AppSpacing.large)
                    }
                    if let error = store.errorMessage ?? checkIns.errorMessage {
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            Text(error).font(.subheadline).foregroundStyle(AppColors.error)
                            Button("Try again") { Task { await refresh() } }
                                .disabled(store.isRefreshing || store.collectingTaskID != nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.medium)
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
        .sheet(item: $selectedTask, onDismiss: {
            guard let route = pendingDocument else { return }
            pendingDocument = nil
            onOpenDocuments?(route)
        }) { task in
            NavigationStack {
                QuestDetailView(store: store, taskID: task.id, onOpenDocuments: onOpenDocuments == nil ? nil : { route in
                    pendingDocument = route
                    selectedTask = nil
                })
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func taskRows(_ tasks: [QuestTask]) -> some View {
        ForEach(tasks) { task in
            Button {
                if task.status == .inProgress, let route = task.documentRoute, let onOpenDocuments {
                    onOpenDocuments(route)
                } else {
                    selectedTask = task
                }
            } label: {
                if task.isStreak, let progress = task.streakProgress {
                    StreakProgressView(currentDays: progress.currentDays, targetDays: progress.targetDays,
                                       isReady: task.status == .ready)
                } else {
                    QuestTaskRow(task: task)
                }
            }
                .buttonStyle(.plain)
                .accessibilityHint("Opens task details")
        }
    }
    private func checkInRows(_ items: [VenueCheckInProgress]) -> some View {
        ForEach(items) { item in CheckInProgressCard(store: checkIns, checkInID: item.id) }
    }
    private func refresh() async {
        async let quests: Void = store.refresh()
        async let venues: Void = checkIns.refresh()
        _ = await (quests, venues)
    }
}

struct QuestTaskRow: View {
    let task: QuestTask
    private var ready: Bool { task.status == .ready }
    private var collected: Bool { task.status == .collected }

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            AvatarView(url: task.photo, name: task.subjectName, systemImage: task.dogID == nil ? task.icon : "dog.fill", size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(task.subjectLabel).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if collected {
                    Label("Collected", systemImage: "checkmark.circle.fill").font(.caption)
                } else if ready {
                    Text("Ready to collect").font(.caption.weight(.semibold)).foregroundStyle(AppColors.brand)
                } else if let progress = task.progressRatio {
                    ProgressView(value: progress).tint(AppColors.brand)
                        .accessibilityLabel("Task progress")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    Label("In progress", systemImage: "clock").font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
        }
        .padding(AppSpacing.medium)
        .foregroundStyle(collected ? AppColors.secondaryText : AppColors.primaryText)
        .background(ready ? AppColors.brand.opacity(0.12) : AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            if ready { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.brand.opacity(0.5), lineWidth: 1) }
        }
        .opacity(collected ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .accessibilityElement(children: .combine)
    }
}

struct QuestDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: QuestStore
    let taskID: String
    var onOpenDocuments: ((DocumentQuestRoute) -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    if let task = store.detailTask(id: taskID) {
                        if !task.isStreak {
                            HStack(spacing: AppSpacing.medium) {
                                AvatarView(url: task.photo, name: task.subjectName, systemImage: "dog.fill", size: 64)
                                Text(task.subjectName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(task.title).font(.title2.bold())
                        if let period = task.expiryLabel {
                            Text(period).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        }
                        if task.isStreak, let progress = task.streakProgress {
                            StreakProgressView(currentDays: progress.currentDays, targetDays: progress.targetDays,
                                               isReady: task.status == .ready)
                        }
                        Text(task.detail).foregroundStyle(AppColors.secondaryText)
                        if task.status == .collected {
                            Label("Collected · \(task.rewardPoints) points", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AppColors.success)
                        } else {
                            if task.rewardPoints > 0 { Text("\(task.rewardPoints) points").font(.headline) }
                            if task.status == .ready {
                                PrimaryButton(title: "Collect", isLoading: store.collectingTaskID == taskID,
                                              isDisabled: !store.canCollect(task)) {
                                    Task { await store.collect(taskID: taskID) }
                                }
                            } else if let route = task.documentRoute, let onOpenDocuments {
                                PrimaryButton(title: task.needsExpiry == true ? "Update document" : "Add document") { onOpenDocuments(route) }
                            }
                        }
                        if let error = store.errorMessage {
                            Text(error).font(.subheadline).foregroundStyle(AppColors.error)
                        }
                    } else {
                        Text("This task is no longer available.").foregroundStyle(AppColors.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.large)
            }
            .background(AppColors.background)
        }
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct DailyWalkingGoalCard: View {
    let goal: DogDailyGoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("\(goal.dogName)'s daily walk").font(.headline)
            if let target = goal.targetSeconds, target > 0 {
                Text(goal.timeLabel).font(.subheadline.monospacedDigit())
                ProgressView(value: min(Double(goal.activeSeconds) / Double(target), 1))
                    .tint(AppColors.brand)
                    .accessibilityLabel("\(goal.dogName)'s walking goal")
                    .accessibilityValue("\(goal.activeSeconds) of \(target) seconds. \(goal.completed ? "Completed" : "Incomplete")")
                Label(goal.completed ? "Goal completed" : "Keep walking", systemImage: goal.completed ? "checkmark.circle.fill" : "figure.walk")
                    .font(.subheadline).foregroundStyle(goal.completed ? AppColors.success : AppColors.secondaryText)
            } else {
                Text("Daily target not configured").font(.subheadline)
                Text("An approved walking target is needed before progress can count toward a goal.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Text("Goal streak: \(goal.currentStreak) \(goal.currentStreak == 1 ? "day" : "days")")
                .font(.subheadline.weight(.semibold))
            // Horizontal scrolling preserves readable dates at accessibility sizes.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.small) {
                    ForEach(goal.days) { day in
                        VStack(spacing: 6) {
                            Text(day.shortDateLabel).font(.caption.monospacedDigit())
                            Image(systemName: day.symbol)
                                .foregroundStyle(day.state == "COMPLETED" ? AppColors.success : AppColors.secondaryText)
                        }
                        .frame(minWidth: 42, minHeight: 44)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date): \(day.stateLabel)")
                        .accessibilityValue(day.targetSeconds.map { "\(day.activeSeconds) of \($0) seconds" } ?? "No target")
                    }
                }
            }
            Text("✓ Completed · × Missed · ◌ Today incomplete · − Not eligible")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
