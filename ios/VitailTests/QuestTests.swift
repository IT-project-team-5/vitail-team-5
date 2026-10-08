import Combine
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class QuestTests: XCTestCase {
    private var goalSample: DogDailyGoalProgress {
        DogDailyGoalProgress(dogID: 7, dogName: "Milo", activeSeconds: 120, targetSeconds: 180,
            completed: false, currentStreak: 2, days: (19...25).map { day in
                GoalCalendarDay(date: "2026-09-\(day)", state: day == 25 ? "INCOMPLETE" : day >= 23 ? "COMPLETED" : day == 22 ? "MISSED" : "NOT_ELIGIBLE",
                    activeSeconds: day >= 23 && day < 25 ? 180 : day == 25 ? 120 : 0,
                    targetSeconds: day >= 22 ? 180 : nil)
            })
    }

    func testGoalCalendarLabelsAndUnconfiguredState() throws {
        XCTAssertEqual(goalSample.timeLabel, "2m 0s / 3m 0s")
        XCTAssertEqual(goalSample.days.last?.stateLabel, "Today, incomplete")
        XCTAssertEqual(goalSample.days.first?.stateLabel, "Not eligible")
        let unconfigured = DogDailyGoalProgress(dogID: 7, dogName: "Milo", activeSeconds: 0,
            targetSeconds: nil, completed: false, currentStreak: 0, days: [])
        XCTAssertEqual(unconfigured.timeLabel, "Daily target not configured")
        XCTAssertFalse(unconfigured.completed)
        let json = #"{"dog_id":7,"dog_name":"Milo","active_seconds":0,"target_seconds":null,"completed":false,"current_streak":0,"days":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(DogDailyGoalProgress.self, from: Data(json.utf8)), unconfigured)
    }

    func testGoalCalendarHidesAfterMelbourneMidnight() async {
        let session = await makeSession()
        let service = QuestFixture(serverTime: "2026-09-25T13:59:50Z")
        await service.setGoals([goalSample])
        var now = QuestCalendar.parse("2026-09-25T13:59:50Z")!
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { now })
        await store.refresh()
        XCTAssertEqual(store.dailyGoals?.count, 1)
        now = now.addingTimeInterval(20)
        XCTAssertNil(store.dailyGoals)
    }

    func testWalkCompletionFetchesAgainAfterAnInFlightRead() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let olderRead = Task { await store.refresh() }
        await service.waitForFetch()
        let committedWalk = Task { await store.walksDidChange() }
        await Task.yield()
        await service.releaseFetch()
        await olderRead.value
        await committedWalk.value
        let count = await service.fetchCount
        XCTAssertEqual(count, 2)
    }

    func testWalkAndDocumentChangesWithPollingNeverPublishTheOlderCalendar() async {
        let session = await makeSession()
        let service = QuestFixture()
        await service.setGoals([goalSample])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        var publishedSeconds: [Int] = []
        let subscription = store.$snapshot.sink { value in
            if let seconds = value?.dailyGoals?.first?.activeSeconds { publishedSeconds.append(seconds) }
        }
        defer { subscription.cancel() }
        await service.suspendFetch()
        let olderRead = Task { await store.refresh() }
        await service.waitForFetch()
        await service.setGoals([completedGoal])
        let firstWalk = Task { await store.walksDidChange() }
        let secondWalk = Task { await store.walksDidChange() }
        let documents = Task { await store.documentsDidChange() }
        let poll = Task { await store.refresh() }
        await Task.yield()
        await service.releaseFetch()
        await olderRead.value; await firstWalk.value; await secondWalk.value
        await documents.value; await poll.value
        XCTAssertEqual(store.dailyGoals?.first?.activeSeconds, 180)
        XCTAssertFalse(publishedSeconds.contains(120))
        XCTAssertFalse(store.isRefreshing)
        let concurrentRequests = await service.maxConcurrentFetches
        XCTAssertEqual(concurrentRequests, 1)
    }

    func testSlowInitialResponseCannotReviveYesterdaysCalendar() async {
        let session = await makeSession()
        let service = QuestFixture(serverTime: "2026-09-25T13:59:50Z")
        await service.setGoals([goalSample])
        var clock = Date(timeIntervalSince1970: 0)
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await service.suspendFetch()
        let read = Task { await store.refresh() }
        await service.waitForFetch()
        clock = clock.addingTimeInterval(20)
        await service.releaseFetch()
        await read.value
        XCTAssertNil(store.dailyGoals)
    }

    func testFailedWalkRefreshKeepsOnlyConfirmedProgressUntilRetry() async {
        let session = await makeSession()
        let service = QuestFixture()
        await service.setGoals([goalSample])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        var awardCount = 0
        store.onAward = { _ in awardCount += 1 }
        await store.refresh()
        await service.setGoals([completedGoal])
        await service.failNextFetch()
        await store.walksDidChange()
        XCTAssertEqual(store.dailyGoals?.first?.activeSeconds, 120)
        XCTAssertNotNil(store.errorMessage)
        await store.refresh()
        XCTAssertEqual(store.dailyGoals?.first?.completed, true)
        XCTAssertEqual(awardCount, 0)
    }

    func testOldAccountReadCannotPublishGoalsAfterSameAccountRelogin() async throws {
        let session = await makeSession()
        let service = QuestFixture()
        await service.setGoals([completedGoal])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let read = Task { await store.refresh() }
        await service.waitForFetch()
        let changed = Task { await store.walksDidChange() }
        await session.logout()
        try await session.login(email: "owner@example.com", password: "unused", expectedRole: .owner)
        await service.releaseFetch()
        await read.value; await changed.value
        XCTAssertNil(store.dailyGoals)
        XCTAssertNil(store.snapshot)
    }

    func testMalformedGoalCalendarNeverPublishesCompletion() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        let invalid = DogDailyGoalProgress(dogID: 7, dogName: "Milo", activeSeconds: 120,
            targetSeconds: 180, completed: true, currentStreak: 2, days: goalSample.days)
        for goals in [[invalid], [goalSample, goalSample]] {
            await service.setGoals(goals)
            await store.refresh()
            XCTAssertNil(store.dailyGoals)
            XCTAssertNotNil(store.errorMessage)
        }
        let invalidDays = [Array(goalSample.days.dropFirst()), Array(repeating: goalSample.days[0], count: 7),
            Array(goalSample.days.dropLast()) + [GoalCalendarDay(date: "2026-09-25", state: "COMPLETED", activeSeconds: -1, targetSeconds: 0)]]
        for days in invalidDays {
            XCTAssertFalse(DogDailyGoalProgress(dogID: 7, dogName: "Milo", activeSeconds: 120,
                targetSeconds: 180, completed: false, currentStreak: 2, days: days).isValid(on: "2026-09-25"))
        }
    }

    private var completedGoal: DogDailyGoalProgress {
        DogDailyGoalProgress(dogID: 7, dogName: goalSample.dogName, activeSeconds: 180, targetSeconds: 180,
            completed: true, currentStreak: 3, days: Array(goalSample.days.dropLast()) + [
                GoalCalendarDay(date: "2026-09-25", state: "COMPLETED", activeSeconds: 180, targetSeconds: 180)])
    }

    func testDailyGoalAppearanceSnapshots() async throws {
        let longName = DogDailyGoalProgress(dogID: 7, dogName: "Milo Alexander the Very Adventurous Walking Companion",
            activeSeconds: 0, targetSeconds: nil, completed: false, currentStreak: 0,
            days: Array(goalSample.days.dropLast()) + [GoalCalendarDay(date: "2026-09-25", state: "NOT_ELIGIBLE", activeSeconds: 0, targetSeconds: nil)])
        for dark in [false, true] {
            for width in [CGFloat(320), CGFloat(393), CGFloat(430)] {
                try await snapshot(DailyWalkingGoalCard(goal: goalSample), name: "Daily-Goal-\(width)-\(dark)", dark: dark, width: width)
                try await snapshot(ScrollView { DailyWalkingGoalCard(goal: longName) }.environment(\.dynamicTypeSize, .accessibility5),
                    name: "Daily-Goal-Large-Text-\(width)-\(dark)", dark: dark, width: width)
            }
        }
        try await snapshot(DailyWalkingGoalCard(goal: goalSample).environment(\.dynamicTypeSize, .accessibility3),
            name: "Daily-Goal-Large-Text", dark: false)
        let session = await makeSession()
        let service = QuestFixture(tasks: [])
        await service.setGoals([])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        for dark in [false, true] {
            try await snapshot(QuestView(store: store, checkIns: CheckInProgressStore(ownerID: 1))
                .environment(\.dynamicTypeSize, .accessibility3), name: "Daily-Goal-No-Dogs-\(dark)", dark: dark, width: 320)
        }
    }

    func testStreakProgressSupportsSevenThenThirtyDayMilestones() throws {
        for (current, target) in [(0, 7), (3, 7), (7, 7), (8, 30), (29, 30), (30, 30), (45, 60), (60, 60), (89, 90)] {
            let progress = try XCTUnwrap(StreakProgressValue(currentDays: current, targetDays: target))
            XCTAssertEqual(progress.label, "\(current) / \(target)")
            XCTAssertEqual(progress.fraction, Double(current) / Double(target), accuracy: 0.000_001)
            XCTAssertEqual(progress.accessibilityValue, "\(current) of \(target) days")
        }
    }

    func testStreakProgressClampsDaysAndRejectsInvalidMilestones() throws {
        let negative = try XCTUnwrap(StreakProgressValue(currentDays: Int.min, targetDays: 7))
        XCTAssertEqual(negative.label, "0 / 7")
        XCTAssertEqual(negative.fraction, 0)
        let ready = try XCTUnwrap(StreakProgressValue(currentDays: Int.max, targetDays: 60))
        XCTAssertEqual(ready.label, "60 / 60")
        XCTAssertEqual(ready.fraction, 1)
        let largeTarget = Int.max / 30 * 30
        let large = try XCTUnwrap(StreakProgressValue(currentDays: Int.max, targetDays: largeTarget))
        XCTAssertTrue(large.fraction.isFinite)
        XCTAssertEqual(large.fraction, 1)
        for invalid in [Int.min, -30, -7, 0, 1, 6, 8, 29, 31, 59, Int.max] {
            XCTAssertNil(StreakProgressValue(currentDays: 3, targetDays: invalid))
        }
    }

    func testStreakProgressAppearanceSnapshots() async throws {
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(streakSamples, name: "Quest-Streak-Progress-\(mode)", dark: dark)
        }
        try await snapshot(streakSamples.environment(\.dynamicTypeSize, .accessibility3),
            name: "Quest-Streak-Progress-Large-Text", dark: false)
    }

    func testStreakTaskDecodesExplicitDaysAndEnforcesMilestoneContract() throws {
        let task = try JSONDecoder().decode(QuestTask.self, from: Data(QuestFixture.streakTaskJSON.utf8))
        XCTAssertTrue(task.isSupported)
        XCTAssertEqual(task.currentDays, 8)
        XCTAssertEqual(task.milestoneDays, 7)
        XCTAssertEqual(task.runStartDate, "2026-09-01")
        XCTAssertEqual(task.streakProgress?.label, "7 / 7")
        XCTAssertTrue(QuestFixture.streak(current: 0, run: nil, status: .inProgress).isSupported)
        XCTAssertTrue(QuestFixture.streak(current: 29, milestone: 30, status: .inProgress).isSupported)
        for invalid in [QuestFixture.streak(current: -1), QuestFixture.streak(milestone: 10),
                        QuestFixture.streak(current: 6), QuestFixture.streak(run: "not-a-date"),
                        QuestFixture.streak(run: nil), QuestFixture.streak(current: 7, status: .inProgress),
                        QuestFixture.streak(points: 100)] {
            XCTAssertFalse(invalid.isSupported, "Accepted invalid streak \(invalid)")
        }
    }

    func testStreakProgressWaitsForNewDayRefreshWhileEarnedRewardRemainsVisible() async {
        let session = await makeSession()
        var clock = Date(timeIntervalSince1970: 0)
        let service = QuestFixture(tasks: [QuestFixture.streak(current: 3, status: .inProgress)],
                                   serverTime: "2026-09-25T13:59:00Z")
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await store.refresh()
        XCTAssertEqual(store.inProgressTasks.count, 1)
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        await service.setServerTime("2026-09-25T14:01:00Z")
        await service.setTasks([QuestFixture.streak(current: 0, run: nil, status: .inProgress)])
        await store.refresh()
        XCTAssertEqual(store.inProgressTasks.first?.streakProgress?.label, "0 / 7")
        await service.setTasks([QuestFixture.streak()])
        await store.refresh()
        clock = clock.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(store.readyTasks.count, 1)
    }

    func testStreakClaimKeepsOnlyFreshNextBarAndSheetFeedbackAfterRefreshFailure() async {
        let session = await makeSession()
        let selected = QuestFixture.streak()
        let service = QuestFixture(tasks: [selected])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.failNextFetch()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await store.collect(taskID: selected.id)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertEqual(store.detailTask(id: selected.id)?.status, .collected)
        XCTAssertTrue(store.collectedTodayTasks.isEmpty)
        XCTAssertEqual(awards.count, 1)
        XCTAssertNil(awards.first?.dogID)
        XCTAssertEqual(awards.first?.points, 20)
        XCTAssertNotNil(store.errorMessage)
        await store.refresh() // A stale READY response must not revive the old reward.
        XCTAssertTrue(store.visibleTasks.isEmpty)
        await store.collect(taskID: selected.id)
        XCTAssertEqual(awards.count, 1)
        await service.setTasks([QuestFixture.streak(current: 7, milestone: 30, status: .inProgress)])
        await store.refresh()
        XCTAssertEqual(store.visibleTasks.filter(\.isStreak).count, 1)
        XCTAssertEqual(store.inProgressTasks.first?.streakProgress?.label, "7 / 30")
        XCTAssertEqual(store.detailTask(id: selected.id)?.status, .collected)
    }

    func testStreakLostResponseRetriesTheSameRunAndMilestone() async {
        let session = await makeSession()
        let selected = QuestFixture.streak(current: 60, milestone: 60, run: "2026-06-01")
        let service = QuestFixture(tasks: [selected])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.failNextClaim()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await store.collect(taskID: selected.id)
        XCTAssertTrue(awards.isEmpty)
        XCTAssertTrue(store.canCollect(selected))
        await store.collect(taskID: selected.id)
        let calls = await service.calls
        XCTAssertEqual(calls, [selected.id, selected.id])
        XCTAssertEqual(awards.first?.points, 100)
        XCTAssertEqual(awards.first?.created, false)
        XCTAssertTrue(store.visibleTasks.isEmpty)
    }

    func testStreakCollectionSerializesWithOtherQuestsAndRejectsLateOwnerResponse() async throws {
        let session = await makeSession()
        let selected = QuestFixture.streak()
        let service = QuestFixture(tasks: [selected] + QuestFixture.tasks)
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        var callbacks = 0
        store.onAward = { _ in callbacks += 1 }
        let claim = Task { await store.collect(taskID: selected.id) }
        await service.waitForClaim()
        await store.collect(taskID: selected.id)
        await store.collect(taskID: "birthday:7:2026")
        await session.logout()
        try await session.login(email: "other@example.com", password: "unused", expectedRole: .owner)
        await service.releaseClaim()
        await claim.value
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.detailTask(id: selected.id))
        XCTAssertTrue(store.confirmedCollections.isEmpty)
        XCTAssertEqual(callbacks, 0)
        let calls = await service.calls
        XCTAssertEqual(calls, [selected.id])
    }

    func testInvalidStreakReceiptsNeverConfirmOrRefreshWallet() async {
        let cases: [(Int, String, String, Int, Int, Int, String)] = [
            (0, "STREAK", "2026-09-01", 7, 20, 120, QuestFixture.timestamp),
            (1, "BIRTHDAY", "2026-09-01", 7, 20, 120, QuestFixture.timestamp),
            (1, "STREAK", "2026-09-02", 7, 20, 120, QuestFixture.timestamp),
            (1, "STREAK", "2026-09-01", 30, 20, 120, QuestFixture.timestamp),
            (1, "STREAK", "2026-09-01", 7, 100, 120, QuestFixture.timestamp),
            (1, "STREAK", "2026-09-01", 7, 20, -1, QuestFixture.timestamp),
            (1, "STREAK", "2026-09-01", 7, 20, 120, "2026-09-05T00:00:00Z"),
            (1, "STREAK", "2026-09-01", 7, 20, 120, "invalid")
        ]
        for (id, kind, run, milestone, points, balance, date) in cases {
            let session = await makeSession()
            let selected = QuestFixture.streak()
            let service = QuestFixture(tasks: [selected])
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideStreak(StreakCollectResponse(award: StreakAward(id: id, kind: kind,
                runStartDate: run, milestoneDays: milestone, points: points, awardedAt: date), balance: balance, created: true))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: selected.id)
            XCTAssertEqual(callbacks, 0)
            XCTAssertTrue(store.confirmedCollections.isEmpty)
            XCTAssertTrue(store.canCollect(selected))
            XCTAssertNotNil(store.errorMessage)
            let fetchCount = await service.fetchCount
            XCTAssertEqual(fetchCount, 1)
        }
    }

    func testMultipleOrInvalidStreakRowsNeverReplaceValidSnapshot() async {
        let session = await makeSession()
        let selected = QuestFixture.streak()
        let service = QuestFixture(tasks: [selected])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        for invalid in [[selected, QuestFixture.streak(current: 14, milestone: 30, status: .inProgress)],
                        [QuestFixture.streak(milestone: 8)],
                        [QuestFixture.streak(run: "2027-01-01")],
                        [selected.collected(at: QuestFixture.timestamp)]] {
            await service.setTasks(invalid)
            await store.refresh()
            XCTAssertEqual(store.visibleTasks.filter(\.isStreak), [selected])
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testIntegratedStreakAppearanceSnapshots() async throws {
        let session = await makeSession()
        let selected = QuestFixture.streak(current: 8, run: "2026-09-18")
        let service = QuestFixture(tasks: [selected] + QuestFixture.tasks)
        let store = QuestStore(ownerID: 1, session: session, service: service)
        let checkIns = CheckInProgressStore(ownerID: 1)
        await store.refresh()
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(QuestView(store: store, checkIns: checkIns), name: "Quest-Streak-Integrated-\(mode)", dark: dark)
            try await snapshot(QuestDetailView(store: store, taskID: selected.id), name: "Quest-Streak-Detail-\(mode)", dark: dark)
        }
        await store.collect(taskID: selected.id)
        try await snapshot(QuestDetailView(store: store, taskID: selected.id), name: "Quest-Streak-Collected", dark: false)
        await service.setTasks([QuestFixture.streak(current: 8, milestone: 30, run: "2026-09-18", status: .inProgress)] + QuestFixture.tasks)
        await store.refresh()
        XCTAssertEqual(store.visibleTasks.filter(\.isStreak).count, 1)
        try await snapshot(QuestView(store: store, checkIns: checkIns), name: "Quest-Streak-In-Progress", dark: false)
    }

    private var streakSamples: some View {
        ScrollView {
            VStack(spacing: AppSpacing.small) {
                StreakProgressView(currentDays: 0, targetDays: 7)
                StreakProgressView(currentDays: 3, targetDays: 7)
                StreakProgressView(currentDays: 7, targetDays: 7)
                StreakProgressView(currentDays: 14, targetDays: 30)
                StreakProgressView(currentDays: 30, targetDays: 30)
                StreakProgressView(currentDays: 42, targetDays: 60)
                StreakProgressView(currentDays: 85, targetDays: 60)
            }.padding(AppSpacing.medium)
        }.background(AppColors.background)
    }

    func testTaskListDecodesWithoutLegacyDashboardProjectionsOrUnusedPresentationFields() throws {
        let data = Data(QuestFixture.json.utf8)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "next_reset_at")
        var tasks = try XCTUnwrap(payload["tasks"] as? [[String: Any]])
        for index in tasks.indices { tasks[index].removeValue(forKey: "subtitle") }
        payload["tasks"] = tasks
        let snapshot = try JSONDecoder().decode(QuestSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(snapshot.tasks.count, 4)
        XCTAssertEqual(snapshot.tasks.first?.subjectName, "Milo")
        XCTAssertEqual(snapshot.localDate, "2026-09-25")
    }

    func testCouncilTaskUsesExpiryAndUnknownExpiryRoutesToExistingEntitlement() throws {
        let ready = QuestFixture.council(expiry: "2027-06-15", status: .ready, entitlementID: 10)
        XCTAssertEqual(ready.validTo, "2027-06-15")
        XCTAssertEqual(ready.subjectLabel, "Milo")
        XCTAssertNotNil(ready.expiryLabel)
        XCTAssertTrue(ready.isSupported)
        XCTAssertFalse(QuestFixture.council(status: .ready, entitlementID: 10).isSupported)
        var unknown = QuestFixture.council(entitlementID: 10)
        unknown.needsExpiry = true
        XCTAssertTrue(unknown.isSupported)
        XCTAssertEqual(unknown.documentRoute?.expectedEntitlementID, 10)
        XCTAssertEqual(unknown.documentRoute?.needsExpiry, true)
    }

    func testCouncilExpiryHidesUnclaimedRewardAtMelbourneMidnight() async {
        let session = await makeSession()
        var clock = Date(timeIntervalSince1970: 0)
        let old = QuestFixture.council(expiry: "2027-06-15", status: .ready, entitlementID: 9)
        let service = QuestFixture(tasks: [old], serverTime: "2027-06-15T13:59:00Z")
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await store.refresh()
        XCTAssertEqual(store.readyTasks, [old])
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertFalse(store.canCollect(old))
        await service.setServerTime("2027-06-15T14:01:00Z")
        await service.setTasks([QuestFixture.council()])
        await store.refresh()
        XCTAssertEqual(store.inProgressTasks.map(\.id), ["council:7:new"])
        XCTAssertTrue(store.readyTasks.isEmpty)
    }

    func testExpiredOptimisticCollectionCannotHideRenewalForm() async {
        let session = await makeSession()
        var clock = Date(timeIntervalSince1970: 0)
        let selected = QuestFixture.council(expiry: "2027-06-15", status: .ready, entitlementID: 10)
        let timestamp = "2027-06-15T13:59:00Z"
        let service = QuestFixture(tasks: [selected], serverTime: timestamp)
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await store.refresh()
        await service.overrideDocument(DocumentCollectionReceipt(entitlementID: 10, kind: .council,
            dogID: 7, points: 300, balance: 420, collectedAt: timestamp, created: true, validTo: "2027-06-15"))
        await service.failNextFetch()
        await store.collect(taskID: selected.id)
        XCTAssertEqual(store.collectedTodayTasks.count, 1)
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        await service.setServerTime("2027-06-15T14:01:00Z")
        await service.setTasks([QuestFixture.council()])
        await store.refresh()
        XCTAssertEqual(store.visibleTasks, [QuestFixture.council()])
    }

    func testCouncilCollectionRequiresMatchingConfirmedExpiry() async {
        for receivedExpiry in ["2027-06-16", "2027-06-15", nil] as [String?] {
            let session = await makeSession()
            let selected = QuestFixture.council(expiry: "2027-06-15", status: .ready, entitlementID: 10)
            let service = QuestFixture(tasks: [selected])
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideDocument(DocumentCollectionReceipt(entitlementID: 10, kind: .council,
                dogID: 7, points: 300, balance: 420, collectedAt: QuestFixture.timestamp, created: true,
                validTo: receivedExpiry))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: selected.id)
            XCTAssertEqual(callbacks, receivedExpiry == selected.validTo ? 1 : 0)
            XCTAssertEqual(store.task(id: selected.id)?.status, receivedExpiry == selected.validTo ? .collected : .ready)
        }
    }

    func testCouncilQuestExpiryAppearanceSnapshot() async throws {
        let session = await makeSession()
        let service = QuestFixture(tasks: [QuestFixture.council(expiry: "2027-06-15", status: .ready, entitlementID: 10)])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        try await snapshot(QuestView(store: store, checkIns: CheckInProgressStore(ownerID: 1)),
                           name: "Quest-Council-Expiry", dark: false)
    }

    func testTaskDecodingPreservesUnknownStatusWithoutShowingUnavailableRows() async throws {
        let session = await makeSession()
        let unknown = try JSONDecoder().decode(QuestTaskStatus.self, from: Data(#""FUTURE_STATE""#.utf8))
        XCTAssertEqual(unknown, .unknown("FUTURE_STATE"))
        var tasks = QuestFixture.tasks
        tasks.append(QuestFixture.task(id: "unknown", kind: "DAILY_GOAL", status: .inProgress))
        tasks.append(QuestFixture.task(id: "disabled", status: unknown))
        tasks.append(QuestFixture.task(id: "old", status: .collected, collectedAt: "2026-09-24T01:00:00Z"))
        let store = QuestStore(ownerID: 1, session: session, service: QuestFixture(tasks: tasks))
        await store.refresh()
        XCTAssertEqual(store.visibleTasks.count, 4)
        XCTAssertEqual(store.readyTasks.map(\.id), ["birthday:7:2026", "document:10"])
        XCTAssertEqual(store.inProgressTasks.map(\.id), ["document:8:VET_CHECKUP"])
        XCTAssertEqual(store.collectedTodayTasks.map(\.id), ["document:11"])
        XCTAssertNil(store.inProgressTasks.first?.progressRatio)
    }

    func testDogTasksStayFlatAndPreserveVisibleTaskOrdering() async throws {
        let session = await makeSession()
        let tasks = [
            QuestFixture.task(id: "collected", status: .collected, collectedAt: QuestFixture.timestamp),
            QuestFixture.task(id: "progress"),
            QuestFixture.task(id: "ready", kind: "BIRTHDAY", status: .ready),
            QuestFixture.task(id: "same-name", dogID: 3),
            QuestFixture.streak()
        ]
        let store = QuestStore(ownerID: 1, session: session, service: QuestFixture(tasks: tasks))
        await store.refresh()

        // Both dogs are named Luna; each task remains one directly tappable row.
        XCTAssertEqual(store.dogTasks.map(\.id), ["ready", "progress", "same-name", "collected"])
        XCTAssertEqual(store.dogTasks.map(\.subjectName), ["Luna", "Luna", "Luna", "Luna"])
        XCTAssertEqual(store.accountTasks, [QuestFixture.streak()])
        let displayed = store.dogTasks + store.accountTasks
        XCTAssertEqual(displayed.count, tasks.count)
        XCTAssertEqual(Set(displayed.map(\.id)).count, displayed.count)
        XCTAssertEqual(Set(displayed.map(\.id)), Set(store.visibleTasks.map(\.id)))
    }

    func testDogTasksRefreshWithCurrentNameAndIdentity() async throws {
        let session = await makeSession()
        let service = QuestFixture(tasks: [QuestFixture.task(id: "before")])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        let originalID = try XCTUnwrap(store.dogTasks.first?.dogID)

        await service.setTasks([
            QuestFixture.task(id: "after", subjectName: "Renamed dog"),
            QuestFixture.task(id: "new-dog", kind: "BIRTHDAY", status: .ready, dogID: 9)
        ])
        await store.refresh()
        XCTAssertEqual(store.dogTasks.map(\.id), ["new-dog", "after"])
        XCTAssertEqual(store.dogTasks.last?.dogID, originalID)
        XCTAssertEqual(store.dogTasks.last?.subjectName, "Renamed dog")
        await service.failNextFetch()
        await store.refresh()
        XCTAssertEqual(store.dogTasks.map(\.id), ["new-dog", "after"])
    }

    func testFlatDogTasksKeepDocumentRoutesAndCollectionBehavior() async throws {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        let inProgress = try XCTUnwrap(store.dogTasks.first { $0.status == .inProgress })
        XCTAssertEqual(inProgress.documentRoute?.dogID, 8)
        XCTAssertEqual(inProgress.documentRoute?.kind, .vet)
        let ready = try XCTUnwrap(store.dogTasks.first { $0.id == "document:10" })
        XCTAssertTrue(store.canCollect(ready))
        await store.collect(taskID: ready.id)
        let collected = try XCTUnwrap(store.dogTasks.first { $0.id == ready.id })
        XCTAssertEqual(collected.status, .collected)
        XCTAssertFalse(store.canCollect(collected))
        XCTAssertEqual(store.dogTasks.filter { $0.id == ready.id }.count, 1)
        let calls = await service.calls
        XCTAssertEqual(calls, ["document:10"])
    }

    func testFlatDogTaskRowAppearanceSnapshots() async throws {
        let tasks = [
            QuestFixture.task(id: "ready", kind: "BIRTHDAY", status: .ready,
                              subjectName: "Luna the Very Adventurous Walking Companion"),
            QuestFixture.task(id: "progress"),
            QuestFixture.task(id: "collected", status: .collected, collectedAt: QuestFixture.timestamp)
        ]
        for dark in [false, true] {
            for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                try await snapshot(ScrollView {
                    VStack(spacing: AppSpacing.small) {
                        ForEach(tasks) { QuestTaskRow(task: $0) }
                    }
                    .padding(AppSpacing.medium)
                }.environment(\.dynamicTypeSize, size),
                    name: "Quest-Flat-Dog-Tasks-320-\(dark)-\(size)", dark: dark, width: 320)
            }
        }
    }

    func testCollectedRowsDisappearAtMelbourneMidnightWithoutBecomingReadyAgain() async {
        let session = await makeSession()
        var clock = Date(timeIntervalSince1970: 0)
        let service = QuestFixture(serverTime: "2026-09-25T13:59:00Z")
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await store.refresh()
        XCTAssertEqual(store.collectedTodayTasks.count, 1)
        await store.collect(taskID: "birthday:7:2026")
        XCTAssertEqual(store.collectedTodayTasks.count, 2)
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(store.collectedTodayTasks.isEmpty)
        XCTAssertFalse(store.visibleTasks.contains { $0.isBirthday })
        XCTAssertEqual(store.readyTasks.map(\.id), ["document:10"])
        // Even without a new-day response, an older refresh must not turn the display clock back.
        await store.refresh()
        XCTAssertTrue(store.collectedTodayTasks.isEmpty)
        XCTAssertFalse(store.visibleTasks.contains { $0.isBirthday })
    }

    func testOlderServerDayCannotResurrectBirthdayOrCollectedRows() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.setServerTime("2026-09-25T14:01:00Z")
        await service.setTasks([])
        await store.refresh()
        XCTAssertEqual(store.snapshot?.localDate, "2026-09-26")
        XCTAssertTrue(store.visibleTasks.isEmpty)
        await service.setServerTime(QuestFixture.timestamp)
        await service.setTasks(QuestFixture.tasks)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.localDate, "2026-09-26")
        XCTAssertTrue(store.visibleTasks.isEmpty)
    }

    func testBirthdayAndDocumentCollectSerializeAcrossRowsAndKeepSuccessWhenReloadFails() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        await service.failNextFetch()
        var balances: [Int] = []
        store.onAward = { balances.append($0.balance) }
        let first = Task { await store.collect(taskID: "birthday:7:2026") }
        await service.waitForClaim()
        await store.collect(taskID: "birthday:7:2026")
        await store.collect(taskID: "document:10")
        XCTAssertEqual(store.collectingTaskID, "birthday:7:2026")
        await service.releaseClaim()
        await first.value
        XCTAssertEqual(store.task(id: "birthday:7:2026")?.status, .collected)
        XCTAssertEqual(balances, [180])
        XCTAssertNotNil(store.errorMessage)
        let calls = await service.calls
        XCTAssertEqual(calls, ["birthday:7"])
        await store.collect(taskID: "birthday:7:2026")
        let laterCalls = await service.calls
        XCTAssertEqual(laterCalls, calls)
    }

    func testDocumentCorrectionInvalidatesOldRowsEvenWhenReloadFails() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await store.collect(taskID: "document:10")
        await service.setTasks([])
        await service.failNextFetch()
        await store.documentsDidChange()
        XCTAssertNil(store.task(id: "document:10"))
        XCTAssertNotNil(store.task(id: "birthday:7:2026"))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.confirmedCollections.values.allSatisfy { $0.documentKind != .council })
        await store.refresh()
        XCTAssertNil(store.task(id: "document:10"))
    }

    func testDocumentChangeWaitsForOlderRefreshThenFetchesAgain() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let older = Task { await store.refresh() }
        await service.waitForFetch()
        let changed = Task { await store.documentsDidChange() }
        await Task.yield()
        await service.setTasks([])
        await service.releaseFetch()
        await older.value; await changed.value
        let count = await service.fetchCount
        XCTAssertEqual(count, 2)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertFalse(store.isRefreshing)
    }

    func testDocumentSuccessSurvivesFailedReloadAndStaleReadyResponse() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.failNextFetch()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await store.collect(taskID: "document:10")
        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first?.points, 300)
        XCTAssertEqual(awards.first?.balance, 420)
        XCTAssertEqual(store.task(id: "document:10")?.status, .collected)
        await store.refresh()
        XCTAssertEqual(store.task(id: "document:10")?.status, .collected)
        await service.setTasks([])
        await store.refresh()
        XCTAssertEqual(store.collectedTodayTasks.map(\.id), ["document:10", "document:11"])
        await store.collect(taskID: "document:10")
        let calls = await service.calls
        XCTAssertEqual(calls, ["document:10"])
    }

    func testConfirmedEntitlementSuppressesStaleUploadRowWithoutSuppressingOtherReadyEntitlements() async {
        let session = await makeSession()
        let staleUpload = QuestTask(id: "document:7:COUNCIL_REGISTRATION", kind: "COUNCIL_REGISTRATION", status: .inProgress,
                                   title: "Council registration", subjectName: "Milo", photo: nil,
                                   icon: "doc.text", detail: "Add evidence", rewardPoints: 300, progress: nil,
                                   dogID: 7, entitlementID: nil, collectedAt: nil)
        let service = QuestFixture(tasks: QuestFixture.tasks + [staleUpload])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await store.collect(taskID: "document:10")
        XCTAssertFalse(store.inProgressTasks.contains { $0.id == staleUpload.id })
        XCTAssertEqual(store.readyTasks.map(\.id), ["birthday:7:2026"])
        XCTAssertEqual(store.collectedTodayTasks.count, 2)
    }

    func testLostResponseRetryUsesEntitlementWithoutInventingPoints() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await service.failNextClaim()
        await store.collect(taskID: "document:10")
        XCTAssertTrue(awards.isEmpty)
        XCTAssertNil(store.confirmedCollections["document:10"])
        XCTAssertEqual(store.task(id: "document:10")?.status, .ready)
        await store.collect(taskID: "document:10")
        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first?.created, false)
        XCTAssertEqual(awards.first?.balance, 420)
        let calls = await service.calls
        XCTAssertEqual(calls, ["document:10", "document:10"])
    }

    func testInvalidDocumentReceiptDoesNotConfirmOrRefreshWallet() async {
        let cases: [(Int, DocumentKind, Int, Int, Int, String)] = [
            (99, .council, 7, 300, 420, QuestFixture.timestamp),
            (10, .vet, 7, 300, 420, QuestFixture.timestamp),
            (10, .council, 8, 300, 420, QuestFixture.timestamp),
            (10, .council, 7, 0, 420, QuestFixture.timestamp),
            (10, .council, 7, 300, -1, QuestFixture.timestamp),
            (10, .council, 7, 300, 420, "invalid date")
        ]
        for (id, kind, dog, points, balance, collectedAt) in cases {
            let session = await makeSession()
            let service = QuestFixture()
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideDocument(DocumentCollectionReceipt(entitlementID: id, kind: kind, dogID: dog, points: points,
                                                                   balance: balance, collectedAt: collectedAt, created: true))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: "document:10")
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(store.confirmedCollections["document:10"])
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testInvalidBirthdayReceiptNeverConfirmsReward() async {
        for (dog, year, kind, points) in [(8, 2026, "BIRTHDAY", 60), (7, 2025, "BIRTHDAY", 60),
                                         (7, 2026, "STREAK", 60), (7, 2026, "BIRTHDAY", 61)] {
            let session = await makeSession()
            let service = QuestFixture()
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideBirthday(BirthdayCollectResponse(
                award: BirthdayAward(id: 4, kind: kind, dogID: dog, year: year, points: points, awardedAt: QuestFixture.timestamp),
                balance: 180, created: true))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: "birthday:7:2026")
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(store.confirmedCollections["birthday:7:2026"])
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testSessionSignOutRejectsLateCollectionWithoutViewCallback() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        var callbacks = 0
        store.onAward = { _ in callbacks += 1 }
        let claim = Task { await store.collect(taskID: "document:10") }
        await service.waitForClaim()
        await session.logout()
        await service.releaseClaim()
        await claim.value
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.confirmedCollections.isEmpty)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertEqual(callbacks, 0)
    }

    func testCoalescedRefreshAndTerminalStopRejectLateData() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let first = Task { await store.refresh() }
        await service.waitForFetch()
        let second = Task { await store.refresh() }
        await Task.yield()
        store.stop()
        await service.releaseFetch()
        await first.value; await second.value
        await store.refresh()
        XCTAssertNil(store.snapshot)
        let count = await service.fetchCount
        XCTAssertEqual(count, 1)
    }

    func testServicesUseSharedCredentialsAndCorrectCollectionAndCorrectionEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuestURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel(); QuestURLProtocol.handler = nil }
        let api = APIClient(baseURL: URL(string: "https://quests.example"), session: network)
        let authority = CredentialAuthority(apiClient: api, store: QuestTokenStore())
        try await authority.install(AuthTokens(access: "quest-token", refresh: "refresh-token"))
        let authenticated = AuthenticatedAPIClient(apiClient: api, credentials: authority)
        QuestURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer quest-token")
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path }
            switch path {
            case "/api/quests/":
                XCTAssertEqual(request.httpMethod, "GET"); return (200, QuestFixture.json)
            case "/api/quests/birthdays/7/collect/":
                XCTAssertEqual(request.httpMethod, "POST"); return (201, QuestFixture.awardJSON)
            case "/api/quests/documents/entitlements/10/collect/":
                XCTAssertEqual(request.httpMethod, "POST"); return (200, QuestFixture.documentJSON)
            case "/api/quests/documents/41/corrections":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try? questRequestBody(request)
                XCTAssertEqual(body?["registration_number"] as? String, "00042")
                XCTAssertNil(body?["corrects_submission_id"])
                return (201, #"{"submission":{"id":42,"request_id":"11111111-1111-1111-1111-111111111111","dog_id":7,"dog_name":"Coco","kind":"COUNCIL_REGISTRATION","status":"SELF_REPORTED","registration_number":"00042","filename":"","awarded_points":0,"submitted_at":"2026-09-29T00:00:00Z"},"balance":300,"awarded_points":0,"created":true,"corrects_submission_id":41}"#)
            case "/api/quests/streaks/collect/":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try? questRequestBody(request)
                XCTAssertEqual(body?["run_start_date"] as? String, "2026-09-01")
                XCTAssertEqual(body?["milestone_days"] as? Int, 7)
                XCTAssertEqual(body?.count, 2)
                return (201, QuestFixture.streakAwardJSON)
            default:
                XCTFail("Unexpected endpoint: \(request.url?.absoluteString ?? "missing")"); return (404, "{}")
            }
        }
        let service = QuestService(apiClient: authenticated)
        let dashboard = try await service.fetchQuests()
        let birthday = try await service.collectBirthday(dogID: 7)
        let document = try await service.collectDocument(entitlementID: 10)
        let streak = try await service.collectStreak(StreakCollectRequest(runStartDate: "2026-09-01", milestoneDays: 7))
        XCTAssertEqual(dashboard.tasks.count, 4)
        XCTAssertEqual(birthday.balance, 180)
        XCTAssertEqual(document.balance, 420)
        XCTAssertEqual(document.kind, .council)
        XCTAssertEqual(streak.award.kind, "STREAK")
        XCTAssertEqual(streak.award.points, 20)
        let draft = DocumentDraft(dogID: 7, kind: .council, registrationNumber: "00042", eventDate: nil,
            filename: nil, fileData: nil, correctsSubmissionID: 41)
        let corrected = try await DocumentService(apiClient: authenticated).submit(DocumentRequest(draft: draft, requestID: UUID()))
        XCTAssertEqual(corrected.correctsSubmissionID, 41)
        XCTAssertEqual(corrected.awardedPoints, 0)
    }

    func testCompactRowsAndDetailsAppearanceSnapshots() async throws {
        let session = await makeSession()
        let store = QuestStore(ownerID: 1, session: session, service: QuestFixture())
        let checkIns = CheckInProgressStore(ownerID: 1)
        await store.refresh()
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(QuestView(store: store, checkIns: checkIns), name: "Quest-Compact-\(mode)", dark: dark)
            try await snapshot(QuestDetailView(store: store, taskID: "document:10"), name: "Quest-Detail-Ready-\(mode)", dark: dark)
        }
        try await snapshot(QuestView(store: store, checkIns: checkIns).environment(\.dynamicTypeSize, .accessibility3),
                           name: "Quest-Compact-Large-Text", dark: false)
        try await snapshot(QuestDetailView(store: store, taskID: "document:8:VET_CHECKUP", onOpenDocuments: { _ in })
            .environment(\.dynamicTypeSize, .accessibility3), name: "Quest-Detail-Large-Text", dark: false)
        try await snapshot(QuestDetailView(store: store, taskID: "document:11"), name: "Quest-Detail-Collected", dark: false)
    }

    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: QuestAuthFixture())
        await session.restore()
        return session
    }
    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool, width: CGFloat = 393) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { content.navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline) }
            .vitailAppearance().preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private actor QuestAuthFixture: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    func restoreUser() async throws -> User? { User(id: 1, email: "owner@example.com", displayName: "Chien", role: .owner) }
    func login(email: String, password: String) async throws -> AuthResponse {
        AuthResponse(access: "unused", refresh: "unused", user: User(id: email == "other@example.com" ? 2 : 1,
            email: email, displayName: "Owner", role: .owner))
    }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
}

private actor QuestFixture: QuestServing {
    private(set) var fetchCount = 0
    private(set) var maxConcurrentFetches = 0
    private var concurrentFetches = 0
    private(set) var calls: [String] = []
    private var goalsValue: [DogDailyGoalProgress]?
    private var tasksValue: [QuestTask]
    private var serverTime: String
    private var failFetch = false, failClaim = false, pauseFetch = false, pauseClaim = false
    private var birthdayOverride: BirthdayCollectResponse?
    private var documentOverride: DocumentCollectionReceipt?
    private var streakOverride: StreakCollectResponse?
    private var fetchContinuation: CheckedContinuation<Void, Never>?, claimContinuation: CheckedContinuation<Void, Never>?
    private var fetchStarted: CheckedContinuation<Void, Never>?, claimStarted: CheckedContinuation<Void, Never>?
    init(tasks: [QuestTask] = QuestFixture.tasks, serverTime: String = QuestFixture.timestamp) {
        tasksValue = tasks; self.serverTime = serverTime
    }
    func fetchQuests() async throws -> QuestSnapshot {
        fetchCount += 1
        concurrentFetches += 1
        maxConcurrentFetches = max(maxConcurrentFetches, concurrentFetches)
        defer { concurrentFetches -= 1 }
        let captured = QuestSnapshot(serverTime: serverTime, timezone: "Australia/Melbourne", localDate: QuestCalendar.dateString(QuestCalendar.parse(serverTime)!),
                                     tasks: tasksValue, dailyGoals: goalsValue)
        if pauseFetch { await withCheckedContinuation { fetchContinuation = $0; fetchStarted?.resume(); fetchStarted = nil } }
        if failFetch { failFetch = false; throw APIError.network("Connection interrupted") }
        return captured
    }
    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse {
        calls.append("birthday:\(dogID)"); try await claimGate()
        if let birthdayOverride { return birthdayOverride }
        return BirthdayCollectResponse(award: BirthdayAward(id: 4, kind: "BIRTHDAY", dogID: dogID, year: 2026, points: 60, awardedAt: Self.timestamp),
                                       balance: 180, created: calls.count == 1)
    }
    func collectDocument(entitlementID: Int) async throws -> DocumentCollectionReceipt {
        calls.append("document:\(entitlementID)"); try await claimGate()
        if let documentOverride { return documentOverride }
        return DocumentCollectionReceipt(entitlementID: entitlementID, kind: .council, dogID: 7, points: 300,
                                       balance: 420, collectedAt: Self.timestamp, created: calls.count == 1, validTo: "2027-06-15")
    }
    func collectStreak(_ request: StreakCollectRequest) async throws -> StreakCollectResponse {
        calls.append("streak:\(request.runStartDate):\(request.milestoneDays)")
        try await claimGate()
        if let streakOverride { return streakOverride }
        return StreakCollectResponse(award: StreakAward(id: 5, kind: "STREAK", runStartDate: request.runStartDate,
            milestoneDays: request.milestoneDays, points: request.milestoneDays == 7 ? 20 : 100, awardedAt: Self.timestamp),
            balance: 120, created: calls.count == 1)
    }
    private func claimGate() async throws {
        if pauseClaim { await withCheckedContinuation { claimContinuation = $0; claimStarted?.resume(); claimStarted = nil } }
        if failClaim { failClaim = false; throw APIError.network("Response interrupted") }
    }
    func setGoals(_ goals: [DogDailyGoalProgress]) { goalsValue = goals }
    func setTasks(_ tasks: [QuestTask]) { tasksValue = tasks }
    func setServerTime(_ value: String) { serverTime = value }
    func failNextFetch() { failFetch = true }
    func failNextClaim() { failClaim = true }
    func overrideBirthday(_ value: BirthdayCollectResponse) { birthdayOverride = value }
    func overrideDocument(_ value: DocumentCollectionReceipt) { documentOverride = value }
    func overrideStreak(_ value: StreakCollectResponse) { streakOverride = value }
    func suspendFetch() { pauseFetch = true }
    func suspendClaim() { pauseClaim = true }
    func waitForFetch() async { if fetchContinuation != nil { return }; await withCheckedContinuation { fetchStarted = $0 } }
    func waitForClaim() async { if claimContinuation != nil { return }; await withCheckedContinuation { claimStarted = $0 } }
    func releaseFetch() { pauseFetch = false; fetchContinuation?.resume(); fetchContinuation = nil }
    func releaseClaim() { pauseClaim = false; claimContinuation?.resume(); claimContinuation = nil }
    nonisolated static let timestamp = "2026-09-25T01:00:00Z"
    nonisolated static func task(id: String, kind: String = "VET_CHECKUP", status: QuestTaskStatus = .inProgress,
                                collectedAt: String? = nil, dogID: Int = 8, subjectName: String = "Luna") -> QuestTask {
        QuestTask(id: id, kind: kind, status: status, title: kind == "BIRTHDAY" ? "Birthday treat" : "Vet check-up", subjectName: subjectName,
                  photo: nil, icon: "doc.text", detail: "Add a photo of the visit evidence.", rewardPoints: kind == "BIRTHDAY" ? 60 : 200, progress: nil,
                  dogID: dogID, entitlementID: nil, collectedAt: collectedAt)
    }
    nonisolated static func streak(current: Int = 7, milestone: Int = 7, run: String? = "2026-09-01",
                                   status: QuestTaskStatus = .ready, points: Int? = nil) -> QuestTask {
        QuestTask(id: "streak:\(run ?? "idle"):\(milestone)", kind: "STREAK", status: status,
            title: "Walking streak", subjectName: "Walking streak", photo: nil, icon: "flame.fill",
            detail: "Finish and upload a qualifying walk each day. Missing a day starts a new streak. Earn 20 points at 7 days and 100 at 30 days, then every 30 days. Collect each milestone to see the next one.",
            rewardPoints: points ?? (milestone == 7 ? 20 : 100), progress: nil, dogID: nil, entitlementID: nil,
            collectedAt: nil, currentDays: current, milestoneDays: milestone, runStartDate: run)
    }
    nonisolated static func council(expiry: String? = nil, status: QuestTaskStatus = .inProgress, entitlementID: Int? = nil) -> QuestTask {
        QuestTask(id: "council:7:" + (entitlementID.map { "entitlement:\($0)" } ?? "new"), kind: "COUNCIL_REGISTRATION", status: status,
            title: "Council registration", subjectName: "Milo", photo: nil, icon: "doc.text",
            detail: "Submit renewed proof after the expiry printed on your registration.",
            rewardPoints: 300, progress: nil, dogID: 7, entitlementID: entitlementID, collectedAt: nil,
            validTo: expiry)
    }
    nonisolated static var tasks: [QuestTask] { try! JSONDecoder().decode(QuestSnapshot.self, from: Data(json.utf8)).tasks }
    nonisolated static let awardJSON = #"{"award":{"id":4,"kind":"BIRTHDAY","dog_id":7,"year":2026,"points":60,"awarded_at":"2026-09-25T01:00:00Z"},"balance":180,"created":true}"#
    nonisolated static let documentJSON = #"{"entitlement_id":10,"kind":"COUNCIL_REGISTRATION","valid_to":"2027-06-15","dog_id":7,"points":300,"balance":420,"collected_at":"2026-09-25T01:00:00Z","created":true}"#
    nonisolated static let streakAwardJSON = #"{"award":{"id":5,"kind":"STREAK","run_start_date":"2026-09-01","milestone_days":7,"points":20,"awarded_at":"2026-09-25T01:00:00Z"},"balance":120,"created":true}"#
    nonisolated static let streakTaskJSON = #"{"id":"streak:2026-09-01:7","kind":"STREAK","status":"READY","title":"Walking streak","subject_name":"Walking streak","photo":null,"icon":"flame.fill","detail":"Finish and upload a qualifying walk each day.","reward_points":20,"progress":1,"dog_id":null,"entitlement_id":null,"collected_at":null,"current_days":8,"milestone_days":7,"run_start_date":"2026-09-01"}"#
    nonisolated static let json = #"""
    {"server_time":"2026-09-25T01:00:00Z","timezone":"Australia/Melbourne","local_date":"2026-09-25","next_reset_at":"2026-09-25T14:00:00Z","tasks":[
    {"id":"birthday:7:2026","kind":"BIRTHDAY","status":"READY","title":"Birthday treat","subtitle":"Ready to collect","subject_name":"Milo","photo":null,"icon":"birthday.cake","detail":"Celebrate Milo's birthday with 60 points. One birthday treat each year.","reward_points":60,"progress":1,"dog_id":7,"entitlement_id":null,"collected_at":null},
    {"id":"document:10","kind":"COUNCIL_REGISTRATION","valid_to":"2027-06-15","status":"READY","title":"Council registration","subtitle":"Ready to collect","subject_name":"Milo","photo":null,"icon":"doc.text","detail":"Your registration document is saved. Collect your 300 points. Renew after the actual registration expiry.","reward_points":300,"progress":1,"dog_id":7,"entitlement_id":10,"collected_at":null},
    {"id":"document:8:VET_CHECKUP","kind":"VET_CHECKUP","status":"IN_PROGRESS","title":"Vet check-up","subtitle":"Add a document","subject_name":"Luna","photo":null,"icon":"doc.text","detail":"Add a photo of Luna's vet check-up. Eligible visits earn 200 points, up to twice a year and at least 60 days apart.","reward_points":200,"progress":null,"dog_id":8,"entitlement_id":null,"collected_at":null},
    {"id":"document:11","kind":"MICROCHIP_REGISTRATION","status":"COLLECTED","title":"Microchip registration","subtitle":"Collected","subject_name":"Luna","photo":null,"icon":"doc.text","detail":"Your lifetime microchip registration reward was collected.","reward_points":300,"progress":1,"dog_id":8,"entitlement_id":11,"collected_at":"2026-09-25T00:00:00Z"}]}
    """#
}
private func questRequestBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private final class QuestTokenStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    func load() -> AuthTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ value: AuthTokens) { lock.lock(); defer { lock.unlock() }; tokens = value }
    func delete() { lock.lock(); defer { lock.unlock() }; tokens = nil }
}

private final class QuestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
