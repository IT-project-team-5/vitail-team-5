import SwiftUI

struct QuestView: View {
    @ObservedObject var store: QuestStore
    @ObservedObject var checkIns: CheckInProgressStore
    var onOpenDocuments: ((Int, DocumentKind) -> Void)?
    @State private var selectedTask: QuestTask?
    @State private var pendingDocument: DocumentRoute?

    private struct DocumentRoute {
        let dogID: Int
        let kind: DocumentKind
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ScrollView {
                VStack(spacing: AppSpacing.small) {
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
            onOpenDocuments?(route.dogID, route.kind)
        }) { task in
            NavigationStack {
                QuestDetailView(store: store, taskID: task.id, onOpenDocuments: onOpenDocuments == nil ? nil : { dogID, kind in
                    pendingDocument = DocumentRoute(dogID: dogID, kind: kind)
                    selectedTask = nil
                })
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func taskRows(_ tasks: [QuestTask]) -> some View {
        ForEach(tasks) { task in
            Button { selectedTask = task } label: { QuestTaskRow(task: task) }
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
                Text(task.subjectName).font(.subheadline).foregroundStyle(AppColors.secondaryText)
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
    var onOpenDocuments: ((Int, DocumentKind) -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    if let task = store.task(id: taskID) {
                        HStack(spacing: AppSpacing.medium) {
                            AvatarView(url: task.photo, name: task.subjectName, systemImage: "dog.fill", size: 64)
                            Text(task.subjectName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(task.title).font(.title2.bold())
                        Text(task.detail).foregroundStyle(AppColors.secondaryText)
                        if task.status == .collected {
                            Label("Collected · \(task.rewardPoints) points", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AppColors.success)
                        } else {
                            Text("\(task.rewardPoints) points").font(.headline)
                            if task.status == .ready {
                                PrimaryButton(title: "Collect", isLoading: store.collectingTaskID == taskID,
                                              isDisabled: !store.canCollect(task)) {
                                    Task { await store.collect(taskID: taskID) }
                                }
                            } else if let kind = task.documentKind, let dogID = task.dogID, let onOpenDocuments {
                                PrimaryButton(title: "Add document") { onOpenDocuments(dogID, kind) }
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
