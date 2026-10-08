import SwiftUI

struct StreakProgressView: View {
    let currentDays: Int
    let targetDays: Int
    var isReady = false

    var body: some View {
        if let progress = StreakProgressValue(currentDays: currentDays, targetDays: targetDays) {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        streakTitle(progress)
                        Spacer(minLength: AppSpacing.small)
                        milestone(progress)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        streakTitle(progress)
                        milestone(progress)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    markerRow(progress, diameter: 32, spacing: 8)
                    markerRow(progress, diameter: 27, spacing: 5)
                }
                if progress.targetDays > 7 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(AppColors.brand)
                        .accessibilityHidden(true)
                }
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

    private func streakTitle(_ progress: StreakProgressValue) -> some View {
        Label {
            Text("\(progress.currentDays) day streak")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
        } icon: {
            Image(systemName: "flame.fill").foregroundStyle(AppColors.brand)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func milestone(_ progress: StreakProgressValue) -> some View {
        Text(isReady ? "Reward ready" : "\(progress.label) days")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isReady ? AppColors.brand : AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func markerRow(_ progress: StreakProgressValue, diameter: CGFloat, spacing: CGFloat) -> some View {
        let completed = min(progress.currentDays, 7)
        let markers = (1...7).map { StreakDayMarker(day: $0, completed: $0 <= completed) }
        return HStack(spacing: spacing) {
            ForEach(markers) { marker in
                ZStack {
                    Circle()
                        .fill(marker.completed ? AppColors.brand : AppColors.background)
                    Circle()
                        .stroke(marker.completed ? AppColors.brand : AppColors.border, lineWidth: 1.5)
                    if marker.completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: diameter * 0.38, weight: .bold))
                            .foregroundStyle(AppColors.brandForeground)
                    }
                }
                .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StreakDayMarker: Identifiable {
    let day: Int
    let completed: Bool
    var id: Int { day }
}

private struct QuestHeader: View {
    let points: Int?
    let isPulsing: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AppColors.brand)
                    .accessibilityHidden(true)
                Text(points.map { $0.formatted() } ?? "—")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("pts").font(.caption.weight(.semibold)).foregroundStyle(AppColors.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(AppColors.surface, in: Capsule())
            .overlay { Capsule().stroke(AppColors.border.opacity(0.8), lineWidth: 1) }
            .scaleEffect(isPulsing ? 1.08 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Points")
            .accessibilityValue(points.map(String.init) ?? "Unavailable")
        }
    }
}

private struct QuestAwardToast: View {
    let points: Int

    var body: some View {
        Label("+\(points) points", systemImage: "checkmark.circle.fill")
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(AppColors.brandForeground)
            .padding(.horizontal, AppSpacing.medium)
            .frame(minHeight: 44)
            .background(AppColors.brand, in: Capsule())
            .shadow(color: AppColors.primaryText.opacity(0.16), radius: 12, y: 6)
            .accessibilityLabel("Collected \(points) points")
    }
}

struct QuestView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: QuestStore
    @ObservedObject var checkIns: CheckInProgressStore
    var points: Int? = nil
    var onOpenDocuments: ((DocumentQuestRoute) -> Void)?
    var onResetAll: (() async -> Void)? = nil
    @State private var selectedTask: QuestTask?
    @State private var pendingDocument: DocumentQuestRoute?
    @State private var expandedDogIDs: Set<Int> = []
    @State private var presentedAward: QuestAwardEvent?
    @State private var isAwardVisible = false
    @State private var isPointsPulsing = false
    @State private var isConfirmingReset = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ScrollView {
                VStack(spacing: AppSpacing.small) {
                    QuestHeader(points: store.confirmedBalance ?? points, isPulsing: isPointsPulsing)
                        .padding(.bottom, AppSpacing.small)
                    if let goals = store.dailyGoals {
                        if goals.isEmpty {
                            Text("Add a dog to start configuring daily walking goals.")
                                .font(.subheadline).padding(AppSpacing.medium)
                        }
                        ForEach(goals) { goal in DailyWalkingGoalCard(goal: goal) }
                    } else if store.snapshot?.dailyGoals != nil {
                        Text("Refresh to see today's walking goals.").font(.subheadline)
                    }
                    ForEach(store.dogTaskGroups) { group in
                        DogQuestGroupCard(group: group, isExpanded: Binding(
                            get: { expandedDogIDs.contains(group.id) },
                            set: { expanded in
                                if expanded { expandedDogIDs.insert(group.id) }
                                else { expandedDogIDs.remove(group.id) }
                            }
                        ), onOpenTask: openTask)
                    }
                    if !store.accountTasks.isEmpty {
                        taskRows(store.accountTasks)
                    }
                    checkInRows(checkIns.activeItems.filter { $0.status == .ready })
                    checkInRows(checkIns.activeItems.filter { $0.status == .inProgress })
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
                    #if DEBUG
                    if store.isResetAvailable {
                        resetControl
                    }
                    #endif
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
        .overlay(alignment: .topTrailing) {
            if isAwardVisible, let presentedAward {
                QuestAwardToast(points: presentedAward.receipt.points)
                    .padding(.top, AppSpacing.small)
                    .padding(.trailing, AppSpacing.medium)
                    .transition(.scale(scale: 0.82, anchor: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: store.lastAwardEvent?.id) { _, _ in
            guard let event = store.lastAwardEvent else { return }
            present(event)
        }
        .confirmationDialog("Reset all quests?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset all quests", role: .destructive) {
                Task { await resetAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This testing action clears quest, document and check-in progress. Your point balance is preserved.")
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
                openTask(task)
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
    private func openTask(_ task: QuestTask) {
        if task.status == .inProgress, let route = task.documentRoute, let onOpenDocuments {
            onOpenDocuments(route)
        } else {
            selectedTask = task
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

    #if DEBUG
    private var resetControl: some View {
        VStack(spacing: AppSpacing.small) {
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                HStack(spacing: AppSpacing.small) {
                    if store.isResetting { ProgressView().tint(AppColors.error) }
                    Image(systemName: "arrow.counterclockwise")
                    Text(store.isResetting ? "Resetting…" : "Reset all quests")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.field))
                .overlay { RoundedRectangle(cornerRadius: AppRadius.field).stroke(AppColors.error.opacity(0.45), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.error)
            .disabled(store.isResetting || store.isRefreshing || store.collectingTaskID != nil)
            Text("Testing only · clears quest progress and refreshes every Quest surface")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, AppSpacing.large)
    }
    #endif

    private func resetAll() async {
        guard await store.resetAllForTesting() != nil else { return }
        await onResetAll?()
    }

    private func present(_ event: QuestAwardEvent) {
        presentedAward = event
        if reduceMotion {
            isAwardVisible = true
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                isAwardVisible = true
                isPointsPulsing = true
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            if reduceMotion {
                isAwardVisible = false
                isPointsPulsing = false
            } else {
                withAnimation(.easeOut(duration: 0.24)) {
                    isAwardVisible = false
                    isPointsPulsing = false
                }
            }
        }
    }
}

struct DogQuestGroupCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let group: DogQuestGroup
    @Binding var isExpanded: Bool
    let onOpenTask: (QuestTask) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                            labels
                            chevron
                        }
                    } else {
                        HStack(spacing: AppSpacing.medium) {
                            AvatarView(url: group.photo, name: group.name, systemImage: "dog.fill", size: 44)
                                .accessibilityHidden(true)
                            labels
                            chevron
                        }
                    }
                }
                .padding(AppSpacing.medium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.name), \(group.summary)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse tasks" : "Expand tasks")

            if isExpanded {
                ForEach(group.tasks) { task in
                    Divider().padding(.horizontal, AppSpacing.medium)
                    Button { onOpenTask(task) } label: {
                        QuestTaskRow(task: task, isNested: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(task.status == .inProgress && task.documentRoute != nil
                                       ? "Opens document or task details" : "Opens task details")
                }
            }
        }
        .foregroundStyle(AppColors.primaryText)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                .truncationMode(.tail)
            Text(group.summary)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityHidden(true)
    }
}

struct QuestTaskRow: View {
    let task: QuestTask
    var isNested = false
    private var ready: Bool { task.status == .ready }
    private var collected: Bool { task.status == .collected }

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            if !isNested {
                AvatarView(url: task.photo, name: task.subjectName, systemImage: task.dogID == nil ? task.icon : "dog.fill", size: 44)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !isNested {
                    Text(task.subjectLabel).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if collected {
                    Label("Collected", systemImage: "checkmark.circle.fill").font(.caption)
                } else if ready {
                    Text("Ready to collect").font(.caption.weight(.semibold)).foregroundStyle(AppColors.brand)
                } else {
                    Label("In progress", systemImage: "clock").font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                if !ready && !collected, let progress = task.progressRatio {
                    ProgressView(value: progress).tint(AppColors.brand)
                        .accessibilityLabel("Task progress")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                }
                if isNested && task.rewardPoints > 0 {
                    Text("\(task.rewardPoints) points").font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
        }
        .padding(AppSpacing.medium)
        .foregroundStyle(collected ? AppColors.secondaryText : AppColors.primaryText)
        .background(isNested ? Color.clear : ready ? AppColors.brand.opacity(0.12) : AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            if ready && !isNested { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.brand.opacity(0.5), lineWidth: 1) }
        }
        .opacity(collected ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct QuestDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                                .font(.headline)
                                .foregroundStyle(AppColors.success)
                                .padding(AppSpacing.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppColors.success.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.field))
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
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
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.75),
                       value: store.detailTask(id: taskID)?.status)
        }
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct DailyWalkingGoalCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let goal: DogDailyGoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            if let target = goal.targetSeconds, target > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                        title
                        Spacer(minLength: AppSpacing.small)
                        progressLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        progressLabel
                    }
                }
                ProgressView(value: min(Double(goal.activeSeconds) / Double(target), 1))
                    .tint(AppColors.brand)
                    .scaleEffect(x: 1, y: 1.8, anchor: .center)
                    .accessibilityLabel("\(goal.dogName)'s walking goal")
                    .accessibilityValue("\(goal.activeSeconds) of \(target) seconds. \(goal.completed ? "Completed" : "Incomplete")")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    title
                    Spacer(minLength: AppSpacing.small)
                    Text("Set a daily goal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                }
                ProgressView(value: 0)
                    .tint(AppColors.border)
                    .scaleEffect(x: 1, y: 1.8, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.medium)
        .foregroundStyle(AppColors.primaryText)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: goal.completed ? "checkmark.circle.fill" : "figure.walk")
                .foregroundStyle(goal.completed ? AppColors.success : AppColors.brand)
                .accessibilityHidden(true)
            Text("\(goal.dogName)'s daily goal")
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var progressLabel: some View {
        Text(goal.timeLabel)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(goal.completed ? AppColors.success : AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
