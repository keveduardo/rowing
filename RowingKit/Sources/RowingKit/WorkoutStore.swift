import Foundation
import Observation

/// A finished row, in the terms HealthKit wants and the PM5's own units.
///
/// The radio hands over `PM5.Event`s; this is what they add up to. Saving it is
/// the Hub target's job — `HKWorkout` is Apple-only and this file is not — so
/// nothing here knows what HealthKit is.
public struct RowingWorkout: Sendable, Equatable {
    public let startedAt: Date
    public let endedAt: Date
    /// The PM5's own elapsed time for the piece, not the wall clock. A person
    /// who sits on the erg for two minutes before pulling has a workout that is
    /// shorter than the time the app was open, and the PM5 is right.
    public let duration: TimeInterval
    /// Metres.
    public let distance: Double
    /// Seconds per 500 m.
    public let averagePace: TimeInterval?
    public let averageStrokeRate: UInt8?
    /// Watts, from the summary's additional characteristic.
    public let averagePower: UInt16?
    /// Kilocalories. The PM5's "cals" — what HealthKit calls active energy.
    public let totalCalories: UInt16?
    public let averageHeartRate: UInt8?
    public let maxHeartRate: UInt8?
    /// Arrives about a minute after the row, on the PM5's second summary.
    /// Nil until it does, which is not the same as zero.
    public let recoveryHeartRate: UInt8?
    public let averageDragFactor: UInt8?
    public let machine: PM5.ErgMachineType?
    public let workoutType: PM5.WorkoutType?

    /// Whether the PM5 has sent its revised summary yet. A workout is
    /// saveable either way; this only says whether a later number is coming.
    public var isComplete: Bool { recoveryHeartRate != nil }
}

extension RowingWorkout {
    /// The keys a saved row carries into Health.
    ///
    /// Namespaced, because a workout's metadata dictionary is shared with every
    /// other app that has written to it.
    public enum MetadataKey: String, Sendable {
        case machine = "com.brisaloca.hub.ergMachine"
        case strokeRate = "com.brisaloca.hub.averageStrokeRate"
        case power = "com.brisaloca.hub.averagePower"
        case dragFactor = "com.brisaloca.hub.averageDragFactor"
        case workoutType = "com.brisaloca.hub.workoutType"
        case recoveryHeartRate = "com.brisaloca.hub.recoveryHeartRate"
        // Recorded so that reading history back needs no permission to read
        // heart rate itself. The numbers are already in hand when the row is
        // saved; asking Health for them again would mean a second, much more
        // alarming permission prompt for data this app already had.
        case averageHeartRate = "com.brisaloca.hub.averageHeartRate"
        case maxHeartRate = "com.brisaloca.hub.maxHeartRate"
    }

    /// HealthKit's metadata values must be `NSString`, `NSNumber` or `NSDate`.
    /// Which of the three is a HealthKit detail; *what* is worth keeping is not,
    /// so that decision is made here where it can be tested.
    public enum MetadataValue: Sendable, Equatable {
        case text(String)
        case number(Int)
    }

    /// What rides alongside the workout in Health.
    ///
    /// ! **A field the PM5 did not send is absent, never zero.** HealthKit has
    /// no predefined key for stroke rate, power or drag factor, and no way to
    /// create a custom quantity type, so they ride as custom metadata that only
    /// this app understands. But writing a zero for a heart rate the monitor
    /// never reported would be a claim about the row that nothing supports —
    /// and 0 bpm reads as a real, alarming measurement rather than a gap.
    public var metadata: [MetadataKey: MetadataValue] {
        var values: [MetadataKey: MetadataValue] = [:]
        if let machine { values[.machine] = .text(machine.label) }
        if let averageStrokeRate { values[.strokeRate] = .number(Int(averageStrokeRate)) }
        if let averagePower { values[.power] = .number(Int(averagePower)) }
        if let averageDragFactor { values[.dragFactor] = .number(Int(averageDragFactor)) }
        if let workoutType { values[.workoutType] = .text(workoutType.label) }
        if let recoveryHeartRate { values[.recoveryHeartRate] = .number(Int(recoveryHeartRate)) }
        if let averageHeartRate { values[.averageHeartRate] = .number(Int(averageHeartRate)) }
        if let maxHeartRate { values[.maxHeartRate] = .number(Int(maxHeartRate)) }
        return values
    }
}

/// The row in progress, in the shape a tile draws.
public struct RowingLive: Sendable, Equatable {
    public var elapsed: TimeInterval = 0
    public var distance: Double = 0
    /// Seconds per 500 m, as the PM5 displays it.
    public var pace: TimeInterval = 0
    public var strokeRate: UInt8 = 0
    public var power: UInt16?
    public var strokeCount: UInt16?
    public var heartRate: UInt8?
    /// Whether the flywheel is turning, which is not the same as being in a
    /// workout: you are in a workout during a rest interval and not rowing.
    public var isRowing = false
    public var machine: PM5.ErgMachineType?
}

/// Turns a stream of PM5 notifications into a workout worth saving.
///
/// **Where the numbers come from, when they disagree.** The PM5 sends live
/// notifications throughout a row and then, at the end, its own summary — and
/// the summary is authoritative, because it is the monitor's own arithmetic
/// over the whole piece rather than this app's over the notifications it
/// happened to receive. Notifications get dropped on a busy radio; the PM5's
/// totals do not. So the summary wins wherever it carries a field, and the
/// accumulated stream fills in only what the summary omits (power and calories,
/// which live in the *additional* summary) or covers the case where no summary
/// ever arrives at all.
///
/// **Why the two summary sends matter.** The spec is explicit that the PM5
/// sends the end-of-workout summary once when the piece ends and again about a
/// minute later with recovery heart rate filled in, "unless the monitor has
/// been turned off or a new workout started". So the second send is an update
/// to the same workout, not a second workout — and `isComplete` is what says
/// whether to expect it.
@MainActor
@Observable
public final class WorkoutStore {
    public enum Phase: Sendable, Equatable {
        /// No row in progress and none just finished.
        case waiting
        /// A row is being rowed.
        case rowing
        /// The row has ended and its result is ready to save.
        case finished
    }

    public private(set) var phase: Phase = .waiting
    public private(set) var live = RowingLive()
    /// The last finished row, kept after the phase moves on so a tile can show
    /// what was just saved.
    public private(set) var latest: RowingWorkout?

    /// Injected so a test can decide what "now" is, the same way the other
    /// stores here take their transport.
    private let now: @Sendable () -> Date
    private var startedAt: Date?
    /// The highest heart rate seen live. The summary's own max wins if it
    /// arrives; this is what makes a workout without one still worth saving.
    private var peakHeartRate: UInt8?
    private var additionalSummary: PM5.AdditionalSummary?
    /// Running sums rather than an array of samples: a long row produces
    /// thousands of notifications and an average does not need to keep them.
    private var strokeRateTotal = 0
    private var strokeRateCount = 0
    /// The furthest the row got, rather than the most recent thing said.
    ///
    /// The totals worth saving are the ones at the end, and the notification
    /// that ends a piece is not obliged to carry them — a status arriving with
    /// zeros, or out of order, would otherwise wipe a row that had been going
    /// for half an hour. So the store keeps a high-water mark and the last
    /// notification cannot take it away.
    private var furthestElapsed: TimeInterval = 0
    private var furthestDistance: Double = 0

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Reading

    /// Seconds per 500 m across a whole piece.
    ///
    /// Derived from the totals rather than averaged from the live stream.
    /// Averaging instantaneous paces weights a slow patch exactly as heavily as
    /// a fast one, which is not what a rower means by average split, and it is
    /// not what the PM5's own summary reports either.
    public static func pace(elapsed: TimeInterval, distance: Double) -> TimeInterval? {
        guard elapsed > 0, distance > 0 else { return nil }
        return elapsed / (distance / 500)
    }

    /// Metres per second — what HealthKit wants for a distance sample.
    public static func speed(elapsed: TimeInterval, distance: Double) -> Double? {
        guard elapsed > 0, distance > 0 else { return nil }
        return distance / elapsed
    }

    // MARK: Writing

    /// Feed one notification from the radio.
    public func apply(_ event: PM5.Event) {
        switch event {
        case .generalStatus(let status):
            live.elapsed = status.elapsedTime
            live.distance = status.distance
            live.isRowing = status.rowingState == .active
            // Recorded before `advance`, so the notification that ends the row
            // still contributes what it carries — and so the clearing that
            // `advance` does while the PM5 is idle wins over a stale total.
            furthestElapsed = max(furthestElapsed, status.elapsedTime)
            furthestDistance = max(furthestDistance, status.distance)
            advance(to: status.workoutState)

        case .additionalStatus(let status):
            live.pace = status.currentPace
            live.strokeRate = status.strokeRate
            live.heartRate = status.heartRate
            live.machine = status.ergMachineType
            // The live heart rate is the only continuously-available one, so it
            // is what a workout without a summary falls back to.
            if let heartRate = status.heartRate {
                peakHeartRate = max(peakHeartRate ?? 0, heartRate)
            }
            if status.strokeRate > 0 {
                strokeRateTotal += Int(status.strokeRate)
                strokeRateCount += 1
            }

        case .additionalStatus2(let status):
            live.power = status.averagePower

        case .strokeData(let stroke):
            live.strokeCount = stroke.strokeCount

        case .additionalStrokeData(let stroke):
            // More immediate than the running average in the other
            // characteristic, so it is what the tile shows while rowing.
            live.power = stroke.strokePower

        // The split characteristics carry the current interval's numbers,
        // which the live ones already cover. They are parsed and available on
        // the radio for a splits view, but nothing here needs them yet.
        case .splitInterval, .additionalSplitInterval, .heartRateBelt:
            break

        case .workoutSummary(let summary):
            finish(with: summary)

        case .additionalSummary(let summary):
            additionalSummary = summary
            // It arrives beside the summary, but ordering is the PM5's to
            // choose — if the summary came first, rebuild with the extras.
            if phase == .finished, let startedAt {
                latest = build(additional: summary, startedAt: startedAt, endedAt: now())
            }
        }
    }

    /// Drop everything. Called when the rower disconnects or the screen closes,
    /// so the next row starts clean rather than inheriting the last one's peak
    /// heart rate.
    public func reset() {
        phase = .waiting
        live = RowingLive()
        // `latest` goes too. A screen that reopens onto a row from an hour ago,
        // presented as though it were the one just finished, is worse than
        // showing nothing.
        latest = nil
        startedAt = nil
        peakHeartRate = nil
        additionalSummary = nil
        strokeRateTotal = 0
        strokeRateCount = 0
        furthestElapsed = 0
        furthestDistance = 0
    }

    // MARK: The state machine

    /// Whether this PM5 state means a row is under way.
    ///
    /// Written as "everything except the idle and terminal states" rather than
    /// listing the interval states, because there are nine of them and the
    /// spec has added more over time. A rest interval is inside the workout.
    private static func isInWorkout(_ state: PM5.WorkoutState) -> Bool {
        switch state {
        case .waitToBegin, .workoutEnd, .terminate, .workoutLogged, .rearm, .other:
            false
        default:
            true
        }
    }

    /// Whether the PM5 is saying the piece is over.
    private static func isFinished(_ state: PM5.WorkoutState) -> Bool {
        switch state {
        case .workoutEnd, .workoutLogged, .terminate:
            true
        default:
            false
        }
    }

    private func advance(to state: PM5.WorkoutState) {
        if Self.isFinished(state) {
            // The state says the piece is over, but the summary that carries
            // the totals has not necessarily arrived. Ending here means a row
            // still counts if the PM5 is switched off before it sends one.
            if phase == .rowing { finishWithoutSummary() }
            return
        }

        guard Self.isInWorkout(state) else {
            // `.waitToBegin` before a row, or a state this client does not know.
            // Neither starts anything nor ends anything — a PM5 that has
            // finished sends the terminal states, not this.
            //
            // ! The high-water marks are deliberately NOT cleared here, even
            // though this is where the previous piece's totals are still on
            // screen and easy to mistake for this row's. Clearing on "not in a
            // workout" would also clear them on an unrecognised state arriving
            // mid-row, which throws away a real row to defend against a stale
            // one. `begin()` resets the marks instead, so a new row starts
            // clean without any mid-row state being able to take the current
            // one's totals away.
            return
        }

        if phase != .rowing { begin() }
    }

    private func begin() {
        startedAt = now()
        peakHeartRate = nil
        additionalSummary = nil
        strokeRateTotal = 0
        strokeRateCount = 0
        // A new row starts from zero rather than inheriting whatever the
        // monitor was still displaying from the last one. Reaching zero costs
        // at most one notification interval: the PM5 resends the full elapsed
        // time every time it notifies, so the marks recover immediately.
        furthestElapsed = 0
        furthestDistance = 0
        phase = .rowing
    }

    private func finishWithoutSummary() {
        guard let startedAt else { return }
        latest = build(additional: additionalSummary, startedAt: startedAt, endedAt: now())
        phase = .finished
    }

    /// The PM5's own end-of-workout summary. This is the good path: its totals
    /// beat anything accumulated from notifications.
    private func finish(with summary: PM5.WorkoutSummary) {
        // If the live stream missed the start entirely — the app was opened
        // mid-row — the summary's own elapsed time still gives a start.
        let start = startedAt ?? now().addingTimeInterval(-summary.elapsedTime)
        let end = start.addingTimeInterval(summary.elapsedTime)

        latest = RowingWorkout(
            startedAt: start,
            endedAt: end,
            duration: summary.elapsedTime,
            distance: summary.distance,
            averagePace: summary.averagePace > 0
                ? summary.averagePace
                : Self.pace(elapsed: summary.elapsedTime, distance: summary.distance),
            averageStrokeRate: summary.averageStrokeRate > 0
                ? summary.averageStrokeRate
                : accumulatedStrokeRate(),
            averagePower: additionalSummary?.watts ?? live.power,
            totalCalories: additionalSummary?.totalCalories,
            averageHeartRate: summary.averageHeartRate,
            maxHeartRate: summary.maxHeartRate ?? peakHeartRate,
            recoveryHeartRate: summary.recoveryHeartRate,
            // ! Zero means the monitor never worked one out, not a drag factor
            // of zero — a real one is around 100–200. Recorded as absent rather
            // than as a number, for the same reason 255 heart rate is.
            averageDragFactor: summary.averageDragFactor > 0 ? summary.averageDragFactor : nil,
            machine: live.machine,
            workoutType: summary.workoutType
        )
        // Not `begin()`'s job: a finished workout is deliberately kept, so the
        // second summary can update it and a tile can show what was just rowed.
        startedAt = start
        phase = .finished
    }

    /// Build from what was accumulated, for when no summary arrives.
    private func build(
        additional: PM5.AdditionalSummary?,
        startedAt: Date,
        endedAt: Date
    ) -> RowingWorkout {
        RowingWorkout(
            startedAt: startedAt,
            endedAt: endedAt,
            // The high-water marks, not `live`: the row is measured by how far
            // it got, not by what the last notification happened to say.
            duration: furthestElapsed > 0
                ? furthestElapsed
                : endedAt.timeIntervalSince(startedAt),
            distance: furthestDistance,
            averagePace: Self.pace(elapsed: furthestElapsed, distance: furthestDistance),
            averageStrokeRate: accumulatedStrokeRate(),
            averagePower: additional?.watts ?? live.power,
            totalCalories: additional?.totalCalories,
            averageHeartRate: nil,
            maxHeartRate: peakHeartRate,
            recoveryHeartRate: nil,
            averageDragFactor: nil,
            machine: live.machine,
            workoutType: nil
        )
    }

    /// The mean of the stroke rates seen. The average of values that each fit
    /// in a byte fits in a byte, so this conversion cannot overflow.
    private func accumulatedStrokeRate() -> UInt8? {
        guard strokeRateCount > 0 else { return nil }
        return UInt8(strokeRateTotal / strokeRateCount)
    }
}
