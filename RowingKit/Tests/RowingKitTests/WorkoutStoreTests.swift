import Foundation
import Testing
@testable import RowingKit

/// Turning notifications into a workout worth saving.
///
/// The two questions these answer are the ones the store exists for: when a row
/// began and ended, and which of two disagreeing sources to believe when the
/// PM5's own summary contradicts what the live stream added up to.
@Suite("workout store")
@MainActor
struct WorkoutStoreTests {
    /// A clock the test moves by hand, so "when did this row start" has an
    /// answer rather than a race. `@unchecked Sendable` because a `@Sendable`
    /// closure has to capture it; it is only ever touched from the main actor,
    /// which is where these tests run.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeStore() -> (WorkoutStore, Clock) {
        let clock = Clock()
        return (WorkoutStore(now: { clock.now }), clock)
    }

    // MARK: Starting and ending

    @Test("a row begins when the PM5 says it is rowing, not before")
    func beginsOnRow() throws {
        let (store, clock) = makeStore()
        #expect(store.phase == .waiting)

        // Sitting on the erg with the PM5 on is `.waitToBegin`, which is not a row.
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 0, rowingState: 0))
        #expect(store.phase == .waiting)

        clock.advance(30) // the person fiddles with the foot straps
        store.apply(try PM5Fixtures.generalStatusEvent(
            elapsed: 0, distance: 0, workoutState: 1, rowingState: 1
        ))
        #expect(store.phase == .rowing)
    }

    @Test("a rest interval is inside the workout, not the end of it")
    func restIsNotAnEnd() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        #expect(store.phase == .rowing)

        // 3 is INTERVALTYPE-rest's workout state; the row is still going on.
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 3, rowingState: 0))
        #expect(store.phase == .rowing)
    }

    @Test("the end state finishes the row, and `reset` puts it back")
    func endStateFinishes() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 10, rowingState: 0))
        #expect(store.phase == .finished)
        #expect(store.latest != nil)

        store.reset()
        #expect(store.phase == .waiting)
        #expect(store.latest == nil)
        #expect(store.live.distance == 0)
    }

    // MARK: Which source wins

    @Test("the PM5's own summary beats what the live stream added up to")
    func summaryWinsOverLive() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))

        // The live stream, which is missing the first few minutes.
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 60_000, distance: 2_000))
        store.apply(try PM5Fixtures.additionalStatusEvent(strokeRate: 20, heartRate: 140))

        // The monitor's own arithmetic over the whole piece: 30 minutes, 6 km.
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 180_000, distance: 60_000, strokeRate: 24,
            averageHeartRate: 145, maxHeartRate: 172, dragFactor: 128, averagePace: 15_000
        ))

        let row = try #require(store.latest)
        #expect(row.duration == 1_800)
        #expect(row.distance == 6_000)
        #expect(row.averageStrokeRate == 24)
        #expect(row.averageHeartRate == 145)
        #expect(row.maxHeartRate == 172)
        #expect(row.averageDragFactor == 128)
        // The summary's pace is tenths of a second: 15000 -> 1500 s.
        #expect(row.averagePace == 1_500)
    }

    @Test("with no summary, what was accumulated is still a workout")
    func fallsBackToAccumulated() throws {
        let (store, clock) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        clock.advance(600)
        // 600 s of elapsed, 2000 m — a 2:30 split.
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 60_000, distance: 20_000))
        store.apply(try PM5Fixtures.additionalStatusEvent(strokeRate: 22, heartRate: 150))

        // The PM5 is switched off before it sends a summary.
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 10, rowingState: 0))

        let row = try #require(store.latest)
        #expect(row.duration == 600)
        #expect(row.distance == 2_000)
        // ! Derived from the totals, not averaged from samples: 600 s over
        // 2000 m is 150 s per 500 m.
        #expect(row.averagePace == 150)
        #expect(row.maxHeartRate == 150)
        #expect(row.averageHeartRate == nil)
        #expect(row.recoveryHeartRate == nil)
        #expect(row.isComplete == false)
    }

    @Test("`finishNow` closes a row the monitor never ended, and nothing else")
    func finishNowClosesAnOpenRow() throws {
        let (store, clock) = makeStore()
        // Nothing under way: there is no row to close.
        store.finishNow()
        #expect(store.phase == .waiting)
        #expect(store.latest == nil)

        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        clock.advance(300)
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 30_000, distance: 10_000))
        // A "Just Row" piece: the person stands up, no end state ever arrives.
        store.finishNow()

        let row = try #require(store.latest)
        #expect(store.phase == .finished)
        #expect(row.duration == 300)
        #expect(row.distance == 1_000)

        // A second press, or a late summary-less close, changes nothing.
        clock.advance(60)
        store.finishNow()
        #expect(store.latest == row)
    }

    @Test("with no 0x0032, pace and rate come from the split and the stroke")
    func fallbacksWithoutAdditionalStatus() throws {
        // Kevin's PM5, 2026-09-29: distance, time and watts live; pace and
        // stroke rate "—" for twenty minutes, because 0x0032 never arrived.
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))

        // A split averaging 2:05.0 — hundredths on the wire.
        store.apply(try PM5Fixtures.additionalStatus2Event(averagePower: 106, splitPace: 12_500))
        #expect(store.live.pace == 125)

        // 0.9 s drive + 2.1 s recovery = a 3 s stroke = 20 spm.
        store.apply(try PM5Fixtures.strokeDataEvent(strokeCount: 1, driveTime: 90, recovery: 210))
        #expect(store.live.strokeRate == 20)
    }

    @Test("once 0x0032 arrives it wins, and the fallbacks stop")
    func additionalStatusWins() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(strokeRate: 24, heartRate: 150))
        let pace = store.live.pace

        store.apply(try PM5Fixtures.additionalStatus2Event(averagePower: 106, splitPace: 12_500))
        store.apply(try PM5Fixtures.strokeDataEvent(strokeCount: 2, driveTime: 90, recovery: 210))
        #expect(store.live.strokeRate == 24, "the PM5's own rate, not one worked out")
        #expect(store.live.pace == pace, "the PM5's current pace, not the split average")
    }

    @Test("a stroke with no timing, or an impossible one, gives no rate")
    func strokeRateBounds() throws {
        let none = try #require(PM5.StrokeData(bytes: PM5Fixtures.strokeData()))
        #expect(WorkoutStore.strokeRate(none) == nil)
        let tooFast = try #require(PM5.StrokeData(bytes: PM5Fixtures.strokeData(driveTime: 30, recovery: 40)))
        #expect(WorkoutStore.strokeRate(tooFast) == nil)
    }

    @Test("the notification that ends a row cannot wipe its totals")
    func endNotificationCannotWipeTotals() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 60_000, distance: 20_000))

        // The PM5 ends the piece with a zeroed status. It is not obliged to
        // carry the totals on the notification that ends the row, and a store
        // that trusted the last one it saw would save half an hour of rowing
        // as an empty workout.
        store.apply(try PM5Fixtures.generalStatusEvent(
            elapsed: 0, distance: 0, workoutState: 10
        ))

        let row = try #require(store.latest)
        #expect(row.duration == 600)
        #expect(row.distance == 2_000)
    }

    @Test("a previous piece's totals are not lent to the next row")
    func totalsDoNotLeakBetweenRows() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 180_000, distance: 60_000))
        store.apply(try PM5Fixtures.workoutSummaryEvent(elapsed: 180_000, distance: 60_000))
        #expect(try #require(store.latest).distance == 6_000)

        // The monitor sits idle showing that finished piece — which is what a
        // PM5 does — and then a second, much shorter row starts.
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 0, distance: 0, workoutState: 0))
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.generalStatusEvent(elapsed: 5_000, distance: 1_000))
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 10, rowingState: 0))

        let row = try #require(store.latest)
        #expect(row.duration == 50)
        #expect(row.distance == 100)
    }

    @Test("the second summary updates the same row rather than starting another")
    func secondSummaryIsAnUpdate() throws {
        let (store, clock) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        clock.advance(1_800)
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 180_000, distance: 60_000, recoveryHeartRate: 0
        ))

        let ended = try #require(store.latest)
        #expect(ended.isComplete == false)
        #expect(store.phase == .finished)

        // A minute later the PM5 revises it, adding recovery heart rate.
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 180_000, distance: 60_000, recoveryHeartRate: 88
        ))

        let revised = try #require(store.latest)
        #expect(revised.isComplete)
        #expect(revised.recoveryHeartRate == 88)
        #expect(revised.startedAt == ended.startedAt)
        #expect(revised.duration == ended.duration)
    }

    @Test("the additional summary's watts and calories land however the two arrive")
    func additionalSummaryOrdering() throws {
        // It arrives before the summary: the summary rebuilds and picks it up.
        let (first, _) = makeStore()
        first.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        first.apply(try PM5Fixtures.additionalSummaryEvent(totalCalories: 95, watts: 210))
        first.apply(try PM5Fixtures.workoutSummaryEvent(elapsed: 180_000, distance: 60_000))
        let before = try #require(first.latest)
        #expect(before.averagePower == 210)
        #expect(before.totalCalories == 95)

        // And after it: the summary builds, then the extra revises it.
        let (second, _) = makeStore()
        second.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        second.apply(try PM5Fixtures.workoutSummaryEvent(elapsed: 180_000, distance: 60_000))
        second.apply(try PM5Fixtures.additionalSummaryEvent(totalCalories: 95, watts: 210))
        let after = try #require(second.latest)
        #expect(after.averagePower == 210)
        #expect(after.totalCalories == 95)
    }

    // MARK: Heart rate

    @Test("the peak heart rate is the highest live reading, and 255 is not one")
    func peakHeartRate() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 150))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 168))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 141))
        // 255 is "no belt paired", and must not become the peak.
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 255))

        #expect(store.live.heartRate == nil)
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 10, rowingState: 0))
        #expect(try #require(store.latest).maxHeartRate == 168)
    }

    @Test("the summary's max wins, and its absence falls back to the live peak")
    func summaryMaxFallsBackToPeak() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 165))
        // The summary carries no valid max (255), so the live peak stands in.
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 60_000, distance: 20_000, maxHeartRate: 255
        ))
        #expect(try #require(store.latest).maxHeartRate == 165)
    }

    @Test("a new row does not inherit the last one's numbers")
    func newRowStartsClean() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 175))
        store.apply(try PM5Fixtures.workoutSummaryEvent(elapsed: 60_000, distance: 20_000))
        #expect(try #require(store.latest).maxHeartRate == 175)

        // A second row, with a lower peak than the first.
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 120))
        store.apply(try PM5Fixtures.workoutSummaryEvent(elapsed: 60_000, distance: 20_000))
        #expect(try #require(store.latest).maxHeartRate == 120)
    }

    // MARK: The live snapshot a tile draws

    @Test("the live numbers come from whichever characteristic carries them")
    func liveNumbers() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(
            elapsed: 12_345, distance: 2_000, workoutState: 1, rowingState: 1
        ))
        store.apply(try PM5Fixtures.additionalStatusEvent(
            strokeRate: 24, heartRate: 145, currentPace: 9_500, machine: 0
        ))
        store.apply(try PM5Fixtures.additionalStatus2Event(averagePower: 205))
        store.apply(try PM5Fixtures.strokeDataEvent(strokeCount: 37))

        #expect(store.live.elapsed == 123.45)
        #expect(store.live.distance == 200)
        #expect(store.live.isRowing)
        #expect(store.live.strokeRate == 24)
        #expect(store.live.heartRate == 145)
        #expect(store.live.pace == 95)
        #expect(store.live.power == 205)
        #expect(store.live.strokeCount == 37)
        #expect(store.live.machine == .staticD)
    }

    @Test("the stroke's own power is more immediate than the running average")
    func strokePowerSupersedesAverage() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.additionalStatus2Event(averagePower: 205))
        #expect(store.live.power == 205)
        store.apply(try PM5Fixtures.additionalStrokeDataEvent(strokePower: 232))
        #expect(store.live.power == 232)
    }

    // MARK: What gets recorded

    @Test("what a row records about itself")
    func metadataRecordsTheRow() throws {
        let (store, _) = makeStore()
        store.apply(try PM5Fixtures.generalStatusEvent(workoutState: 1, rowingState: 1))
        store.apply(try PM5Fixtures.additionalStatusEvent(heartRate: 150, machine: 0))
        store.apply(try PM5Fixtures.additionalSummaryEvent(totalCalories: 95, watts: 210))
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 180_000, distance: 60_000, strokeRate: 24,
            averageHeartRate: 145, maxHeartRate: 172, dragFactor: 128,
            recoveryHeartRate: 88
        ))

        let metadata = try #require(store.latest).metadata
        #expect(metadata[.machine] == .text("Model D"))
        #expect(metadata[.strokeRate] == .number(24))
        #expect(metadata[.power] == .number(210))
        #expect(metadata[.dragFactor] == .number(128))
        #expect(metadata[.workoutType] == .text("Just Row, splits"))
        #expect(metadata[.recoveryHeartRate] == .number(88))
    }

    @Test("a field the PM5 never sent is absent, not zero")
    func metadataOmitsWhatNeverArrived() throws {
        let (store, _) = makeStore()
        // Nothing was accumulated live — the app was opened after the row — and
        // the monitor is switched off before it sends its second summary.
        store.apply(try PM5Fixtures.workoutSummaryEvent(
            elapsed: 60_000, distance: 20_000,
            strokeRate: 0, dragFactor: 0, recoveryHeartRate: 0
        ))

        let metadata = try #require(store.latest).metadata
        // ! Each of these would otherwise be written as a confident zero: a
        // stroke rate of 0 spm, a drag factor of 0, a recovery heart rate of
        // 0 bpm. None of those is a measurement — they are gaps, and a saved
        // zero is indistinguishable from a real reading afterwards.
        #expect(metadata[.strokeRate] == nil)
        #expect(metadata[.dragFactor] == nil)
        #expect(metadata[.recoveryHeartRate] == nil)
        #expect(metadata[.power] == nil)
        #expect(metadata[.machine] == nil)
    }

    // MARK: Derived units

    @Test("pace and speed are derived from the totals, and refuse to divide by zero")
    func derivedUnits() throws {
        // 600 s over 2000 m is a 2:30 split, and 3.33 m/s.
        #expect(WorkoutStore.pace(elapsed: 600, distance: 2_000) == 150)
        #expect(WorkoutStore.speed(elapsed: 600, distance: 2_000) == 2_000.0 / 600.0)

        // A row that has not moved has no split, which is not a split of zero.
        #expect(WorkoutStore.pace(elapsed: 600, distance: 0) == nil)
        #expect(WorkoutStore.pace(elapsed: 0, distance: 2_000) == nil)
        #expect(WorkoutStore.speed(elapsed: 0, distance: 0) == nil)
    }
}
