import Foundation
import HealthKit
import Observation
import RowingKit

/// The watch's workout: one `HKWorkoutSession` from the tap on Row to the end
/// of the piece, saved to Health — which is what puts it in Fitness on the
/// phone, with no phone app involved.
///
/// **Why the session starts before the rower connects.** A running workout
/// session is what lets a watch app keep running with the wrist down
/// (`workout-processing` in `WKBackgroundModes`), and the Bluetooth link to the
/// PM5 lives only as long as the app does. So the session comes first, and
/// the radio rides inside it.
///
/// **What the watch measures and what the rower does.** Heart rate and active
/// energy come from the watch, collected by `HKLiveWorkoutDataSource` the way
/// every Apple Watch workout collects them. Distance comes from the PM5, as
/// one `distanceRowing` sample over the row, because the watch has no idea how
/// far a stationary rower has gone. The PM5's calories are deliberately *not*
/// added: the watch already writes active energy for the same minutes, and
/// two sources for one quantity would count the row twice on the Move ring.
@MainActor
@Observable
final class RowSession: NSObject {
    enum Phase: Equatable {
        case idle
        /// Asking Health, starting the session.
        case starting
        case running
        case saving
        /// Saved to Health, with the row it recorded.
        case saved(RowingWorkout?)
        /// Ended without anything worth saving — no row was rowed.
        case discarded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The watch's latest heart rate, in beats per minute.
    private(set) var heartRate: Double?
    /// When the session began, for the elapsed clock before the PM5 has one.
    private(set) var startedAt: Date?

    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    // `nonisolated` because the builder delegate, which is not on the main
    // actor, reads it too — and a constant type identifier is safe anywhere.
    nonisolated private static let heartRateType = HKQuantityType(.heartRate)

    /// What the watch writes: the workout, its energy, and the rower's
    /// distance. What it reads: heart rate and energy, which the live builder
    /// needs in order to show them. Heart rate is not in the share set — the
    /// data source's own samples are the system's to write, as in Apple's
    /// workout samples, and asking to *write* heart rate is a more alarming
    /// prompt for nothing.
    private static let shareTypes: Set<HKSampleType> = [
        HKWorkoutType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceRowing),
    ]
    private static let readTypes: Set<HKObjectType> = [
        heartRateType,
        HKQuantityType(.activeEnergyBurned),
    ]

    /// Start a workout. Asks for Health permission the first time.
    ///
    /// ! The usage strings in the watch app's Info.plist are not optional: a
    /// missing one raises inside `requestAuthorization`, and an Objective-C
    /// exception is not something `try` can catch.
    func start() async {
        guard phase == .idle || isOver else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .failed("Health isn't available on this watch")
            return
        }
        phase = .starting
        heartRate = nil
        do {
            try await health.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .rowing
            // A Concept2 in a room — "outdoor" would have the watch reaching for GPS.
            configuration.locationType = .indoor

            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: health,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            startedAt = now
            phase = .running
        } catch {
            session = nil
            builder = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// End the workout and save it with the row, or throw it away if there
    /// was no row.
    ///
    /// A session that never saw a row — the rower would not connect, or the
    /// person changed their mind — is discarded rather than saved: an empty
    /// "Rowing" in Fitness is worse than nothing.
    func finish(with row: RowingWorkout?) async {
        guard phase == .running, let session, let builder else { return }
        phase = .saving
        let end = Date()
        session.end()
        do {
            try await builder.endCollection(at: end)
            guard let row else {
                builder.discardWorkout()
                phase = .discarded
                clear()
                return
            }
            // The row's own interval, clamped inside the session's: the PM5's
            // clock and the watch's are not the same clock.
            let start = max(row.startedAt, startedAt ?? row.startedAt)
            let stop = min(max(row.endedAt, start), end)
            if row.distance > 0 {
                try await builder.addSamples([
                    HKQuantitySample(
                        type: HKQuantityType(.distanceRowing),
                        quantity: HKQuantity(unit: .meter(), doubleValue: row.distance),
                        start: start,
                        end: stop
                    ),
                ])
            }
            try await builder.addMetadata(Self.metadata(for: row))
            _ = try await builder.finishWorkout()
            phase = .saved(row)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        clear()
    }

    /// Back to the start screen after a finished or failed workout.
    func dismiss() {
        guard isOver else { return }
        phase = .idle
        heartRate = nil
        startedAt = nil
    }

    private var isOver: Bool {
        switch phase {
        case .saved, .discarded, .failed: true
        case .idle, .starting, .running, .saving: false
        }
    }

    private func clear() {
        session = nil
        builder = nil
    }

    /// HealthKit's shape for what `RowingWorkout.metadata` decided to keep.
    ///
    /// The decision — which fields are worth recording, and that a field the
    /// PM5 never sent is left out rather than written as zero — lives in
    /// `RowingKit`, where it is tested. This only converts.
    static func metadata(for row: RowingWorkout) -> [String: Any] {
        var metadata: [String: Any] = [HKMetadataKeyIndoorWorkout: NSNumber(value: true)]
        for (key, value) in row.metadata {
            switch value {
            case .text(let text): metadata[key.rawValue] = text
            case .number(let number): metadata[key.rawValue] = NSNumber(value: number)
            }
        }
        return metadata
    }

    // MARK: Delegate callbacks, on the main actor

    fileprivate func sessionFailed(_ message: String) {
        // The session died under us — the system ended it, or it could not
        // start. Whatever the builder holds is not coming back.
        if phase == .running || phase == .starting {
            phase = .failed(message)
            clear()
        }
    }

    fileprivate func collected(heartRate bpm: Double?) {
        if let bpm { heartRate = bpm }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension RowSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // Nothing to do: every transition this app cares about is one it asked
        // for, and `finish` awaits the builder rather than watching states.
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.sessionFailed(message) }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension RowSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard collectedTypes.contains(Self.heartRateType) else { return }
        // Only the number crosses to the main actor, and a Double is Sendable.
        let bpm = workoutBuilder.statistics(for: Self.heartRateType)?
            .mostRecentQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in self.collected(heartRate: bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
