import Foundation

/// What the watch sends the phone while a row is mirrored.
///
/// **Why this carries so little.** In Apple's mirroring, the phone already
/// receives heart rate and the session's own statistics through HealthKit —
/// that is what mirroring is for, and it arrives without this app doing
/// anything. What it cannot get from HealthKit is *the rower*: pace, stroke
/// rate, watts and the machine are this app's own, read off the PM5 over
/// Bluetooth by whichever device holds the radio. So these messages carry
/// exactly that, and nothing that HealthKit is already carrying.
///
/// **Why it is not `RowingLive`.** A wire format that is the domain model makes
/// every domain change a protocol change, between two devices that update at
/// different times — a watch app and a phone app, where the phone is the one
/// that gets updated when its owner feels like it. The mapping is a few lines,
/// and it lives in the initialisers below where it can be tested.
///
/// **On versioning.** Both ends ship together today, so there is none. The
/// moment the watch app can be updated independently of the phone — which on
/// watchOS is normal, since updates go through the Watch app on the phone and
/// can lag by days — this needs a version byte before the payload. Recorded
/// here rather than discovered later.
public enum MirrorMessage: Codable, Sendable, Equatable {
    /// While rowing. Sent on a throttle, not per notification.
    case metrics(Metrics)
    /// When the piece ends, so the phone can show a result before Health has
    /// caught up with it.
    case finished(Result)

    /// The live numbers, flattened to what a phone screen draws.
    public struct Metrics: Codable, Sendable, Equatable {
        public let elapsed: TimeInterval
        public let distance: Double
        public let pace: TimeInterval
        public let strokeRate: UInt8
        public let power: UInt16?
        public let isRowing: Bool

        public init(
            elapsed: TimeInterval,
            distance: Double,
            pace: TimeInterval,
            strokeRate: UInt8,
            power: UInt16?,
            isRowing: Bool
        ) {
            self.elapsed = elapsed
            self.distance = distance
            self.pace = pace
            self.strokeRate = strokeRate
            self.power = power
            self.isRowing = isRowing
        }
    }

    /// The finished row, as the watch is about to save it.
    public struct Result: Codable, Sendable, Equatable {
        public let duration: TimeInterval
        public let distance: Double
        public let averagePace: TimeInterval?
        public let averageStrokeRate: UInt8?
        public let averagePower: UInt16?
        /// The machine's name, not its enum: the phone only ever displays it,
        /// and a name survives the enum growing a case better than a raw byte
        /// does.
        public let machine: String?

        public init(
            duration: TimeInterval,
            distance: Double,
            averagePace: TimeInterval?,
            averageStrokeRate: UInt8?,
            averagePower: UInt16?,
            machine: String?
        ) {
            self.duration = duration
            self.distance = distance
            self.averagePace = averagePace
            self.averageStrokeRate = averageStrokeRate
            self.averagePower = averagePower
            self.machine = machine
        }
    }
}

extension MirrorMessage.Metrics {
    public init(_ live: RowingLive) {
        self.init(
            elapsed: live.elapsed,
            distance: live.distance,
            pace: live.pace,
            strokeRate: live.strokeRate,
            power: live.power,
            isRowing: live.isRowing
        )
    }
}

extension MirrorMessage.Result {
    public init(_ row: RowingWorkout) {
        self.init(
            duration: row.duration,
            distance: row.distance,
            averagePace: row.averagePace,
            averageStrokeRate: row.averageStrokeRate,
            averagePower: row.averagePower,
            machine: row.machine?.label
        )
    }
}
