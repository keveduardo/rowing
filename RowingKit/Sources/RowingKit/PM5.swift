import Foundation

// ! WHY THIS FILE EXISTS IN HubCore AND NOT IN THE Hub TARGET.
//
// Everything here is `Data` in, struct out. There is no CoreBluetooth, no
// HealthKit, no SwiftUI — so the whole protocol is exercised by `swift test` on
// kevg10, against byte arrays, with no rower in the room. Only the radio is
// Apple-only, and only the radio is untestable here.
//
// That split is the reason this is worth writing on a box with no device
// attached, and it is the same argument `Package.swift:18` already makes for
// putting the Hub's logic in HubCore.
//
// Source: Concept2's *Performance Monitor Bluetooth Smart Communications
// Interface Definition*, Revision 1.30 (2022-03-02). Every layout below cites
// the byte count the spec gives, and each parser rejects a payload of any other
// length rather than reading past it.
//
// ⚠️ THE MULTIPLEXED CHARACTERISTIC (0x0080) IS NOT IMPLEMENTED, ON PURPOSE.
// Its payloads are *not* the same layouts as the standalone characteristics,
// despite echoing their IDs: multiplexed 0x0032 is 19 bytes where standalone
// 0x0032 is 17 (it adds Average Power), multiplexed 0x0033 is 18 where
// standalone is 20 (it drops Average Power), and multiplexed 0x0035 is 18 where
// standalone is 20 (it drops Work Per Stroke). The same ID means two different
// byte layouts depending on which characteristic carried it.
//
// Multiplexing exists for one reason, stated in the spec: Android 4.3 allowed 4
// notifications and Android 4.4 allowed 7, so several characteristics had to
// share one. iOS has no such limit, and the spec is explicit that a multiplexed
// ID is only sent "as long as the respective characteristic notification of the
// same ID is NOT enabled" — so subscribing to the standalone characteristics
// means 0x0080 stays silent. Read the standalone ones and never mix the two.

/// Concept2 PM5 — the rowing monitor's own Bluetooth profile.
///
/// The PM5 is the peripheral; the phone is the central. Everything here is
/// little-endian, which is what the spec's `Lo, Mid, Hi` ordering means.
public enum PM5 {}

// MARK: - Identity

extension PM5 {
    /// `CE06XXXX-43E5-11E4-916C-0800200C9A66` — the base every C2 UUID is built
    /// from, and what the PM5 advertises in its scan response, which is how a
    /// scan filters for rowers without connecting to everything nearby.
    public static let baseUUID = "CE06XXXX-43E5-11E4-916C-0800200C9A66"

    /// The services and characteristics this client uses, as 128-bit strings.
    ///
    /// Strings rather than `CBUUID` because `CBUUID` is CoreBluetooth and this
    /// file has to compile on Linux. The view target wraps these.
    public enum Characteristic: String, Sendable, CaseIterable {
        /// Start of the C2 Rowing Service.
        case rowingService = "CE060030-43E5-11E4-916C-0800200C9A66"
        /// Start of the C2 Control Service (CSAFE commands). Not used yet.
        case controlService = "CE060020-43E5-11E4-916C-0800200C9A66"
        /// Start of the C2 Device Information Service.
        case deviceInfoService = "CE060010-43E5-11E4-916C-0800200C9A66"

        /// 19 bytes. Time, distance, and the four state enums.
        case generalStatus = "CE060031-43E5-11E4-916C-0800200C9A66"
        /// 17 bytes. Speed, stroke rate, heart rate, pace.
        case additionalStatus = "CE060032-43E5-11E4-916C-0800200C9A66"
        /// 20 bytes. Interval count, power, calories, last split.
        case additionalStatus2 = "CE060033-43E5-11E4-916C-0800200C9A66"
        /// 1 byte, **writable**. How often the PM5 notifies. See `SampleRate`.
        case sampleRate = "CE060034-43E5-11E4-916C-0800200C9A66"
        /// 20 bytes. One stroke: drive length, drive time, force, work.
        case strokeData = "CE060035-43E5-11E4-916C-0800200C9A66"
        /// 15 bytes. Stroke power, stroke calories, projected finish.
        case additionalStrokeData = "CE060036-43E5-11E4-916C-0800200C9A66"
        /// 18 bytes. The current split or interval.
        case splitIntervalData = "CE060037-43E5-11E4-916C-0800200C9A66"
        /// 19 bytes. The split's averages.
        case additionalSplitIntervalData = "CE060038-43E5-11E4-916C-0800200C9A66"
        /// 20 bytes. The finished workout's totals — what gets saved to Health.
        case endOfWorkoutSummary = "CE060039-43E5-11E4-916C-0800200C9A66"
        /// 19 bytes. Calories, watts, rest totals for the finished workout.
        case endOfWorkoutAdditionalSummary = "CE06003A-43E5-11E4-916C-0800200C9A66"
        /// 6 bytes. Which heart-rate belt the PM5 is paired to.
        case heartRateBeltInfo = "CE06003B-43E5-11E4-916C-0800200C9A66"
        /// 2–288 bytes. Per-stroke force curve. `PM5v1` does not support it.
        case forceCurve = "CE06003D-43E5-11E4-916C-0800200C9A66"
    }

    /// `0x0034`, the one characteristic worth writing.
    ///
    /// The PM5 notifies at 500 ms unless told otherwise, and a tile that wants a
    /// steadier number can ask for 1 s. Write the raw value.
    public enum SampleRate: UInt8, Sendable, CaseIterable {
        case oneSecond = 0
        case halfSecond = 1
        case quarterSecond = 2
        case tenthSecond = 3
    }
}

// MARK: - Enumerated values (Appendix A)

extension PM5 {
    /// Appendix A, `Erg Machine Type`.
    ///
    /// The raw values have gaps (there is no 4, 6, or 9–15) because this is
    /// CSAFE's numbering, not Concept2's. Anything unrecognised is `.other`
    /// rather than a discarded byte — a MultiErg row is 224 and a BikeErg is
    /// 192, and an app that quietly mapped those to Model D would report the
    /// wrong machine with full confidence.
    public enum ErgMachineType: Sendable, Equatable {
        case staticD, staticC, staticA, staticB, staticE
        case staticSimulator, staticDynamic, staticDyno
        case slidesA, slidesB, slidesC, slidesD, slidesE, slidesDynamic
        case staticSki, staticSkiSimulator
        case bike, bikeArms, bikeNoArms, bikeSimulator
        case multiErgRow, multiErgSki, multiErgBike
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .staticD
            case 1: .staticC
            case 2: .staticA
            case 3: .staticB
            case 5: .staticE
            case 7: .staticSimulator
            case 8: .staticDynamic
            case 16: .slidesA
            case 17: .slidesB
            case 18: .slidesC
            case 19: .slidesD
            case 20: .slidesE
            case 32: .slidesDynamic
            case 64: .staticDyno
            case 128: .staticSki
            case 143: .staticSkiSimulator
            case 192: .bike
            case 193: .bikeArms
            case 194: .bikeNoArms
            case 207: .bikeSimulator
            case 224: .multiErgRow
            case 225: .multiErgSki
            case 226: .multiErgBike
            default: .other(raw)
            }
        }

        /// What to call the machine on screen. The stale PM5 device-info
        /// characteristic reports the Model D family as "PM5" regardless, so
        /// this is the only place the actual machine type is known.
        public var label: String {
            switch self {
            case .staticD: "Model D"
            case .staticC: "Model C"
            case .staticA: "Model A"
            case .staticB: "Model B"
            case .staticE: "Model E"
            case .staticSimulator: "Simulator"
            case .staticDynamic: "Dynamic"
            case .slidesA: "Slides A"
            case .slidesB: "Slides B"
            case .slidesC: "Slides C"
            case .slidesD: "Slides D"
            case .slidesE: "Slides E"
            case .slidesDynamic: "Slides Dynamic"
            case .staticDyno: "Static Dyno"
            case .staticSki: "SkiErg"
            case .staticSkiSimulator: "SkiErg Simulator"
            case .bike: "BikeErg"
            case .bikeArms: "BikeErg (arms)"
            case .bikeNoArms: "BikeErg (no arms)"
            case .bikeSimulator: "BikeErg Simulator"
            case .multiErgRow: "RowErg (MultiErg)"
            case .multiErgSki: "SkiErg (MultiErg)"
            case .multiErgBike: "BikeErg (MultiErg)"
            case .other(let raw): "Unknown machine (\(raw))"
            }
        }
    }

    /// Appendix A, `Workout Type`. Decides whether an interval is measured in
    /// time or distance — the spec says so twice, because the interval-type
    /// byte alone cannot tell you.
    public enum WorkoutType: Sendable, Equatable {
        case justRowNoSplits, justRowSplits
        case fixedDistanceNoSplits, fixedDistanceSplits
        case fixedTimeNoSplits, fixedTimeSplits
        case fixedTimeInterval, fixedDistanceInterval
        case variableInterval, variableUndefinedRestInterval
        case fixedCalorie, fixedWattMinutes, fixedCaloriesInterval
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .justRowNoSplits
            case 1: .justRowSplits
            case 2: .fixedDistanceNoSplits
            case 3: .fixedDistanceSplits
            case 4: .fixedTimeNoSplits
            case 5: .fixedTimeSplits
            case 6: .fixedTimeInterval
            case 7: .fixedDistanceInterval
            case 8: .variableInterval
            case 9: .variableUndefinedRestInterval
            case 10: .fixedCalorie
            case 11: .fixedWattMinutes
            case 12: .fixedCaloriesInterval
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .justRowNoSplits: "Just Row"
            case .justRowSplits: "Just Row, splits"
            case .fixedDistanceNoSplits: "Fixed distance"
            case .fixedDistanceSplits: "Fixed distance, splits"
            case .fixedTimeNoSplits: "Fixed time"
            case .fixedTimeSplits: "Fixed time, splits"
            case .fixedTimeInterval: "Time intervals"
            case .fixedDistanceInterval: "Distance intervals"
            case .variableInterval: "Variable intervals"
            case .variableUndefinedRestInterval: "Variable intervals, open rest"
            case .fixedCalorie: "Fixed calories"
            case .fixedWattMinutes: "Fixed watt-minutes"
            case .fixedCaloriesInterval: "Calorie intervals"
            case .other(let raw): "Unknown workout (\(raw))"
            }
        }
    }

    /// Appendix A, `Interval Type`. 255 is a real value, not a terminator.
    public enum IntervalType: Sendable, Equatable {
        case time, distance, rest, timeRestUndefined, distanceRestUndefined
        case restUndefined, calorie, calorieRestUndefined
        case wattMinute, wattMinuteRestUndefined, none
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .time
            case 1: .distance
            case 2: .rest
            case 3: .timeRestUndefined
            case 4: .distanceRestUndefined
            case 5: .restUndefined
            case 6: .calorie
            case 7: .calorieRestUndefined
            case 8: .wattMinute
            case 9: .wattMinuteRestUndefined
            case 255: .none
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .time: "Time"
            case .distance: "Distance"
            case .rest: "Rest"
            case .timeRestUndefined: "Time, open rest"
            case .distanceRestUndefined: "Distance, open rest"
            case .restUndefined: "Rest, open"
            case .calorie: "Calories"
            case .calorieRestUndefined: "Calories, open rest"
            case .wattMinute: "Watt-minutes"
            case .wattMinuteRestUndefined: "Watt-minutes, open rest"
            case .none: "None"
            case .other(let raw): "Unknown interval (\(raw))"
            }
        }
    }

    /// Appendix A, `Workout State`. The spec numbers these explicitly.
    ///
    /// This is the byte that says whether the rower is actually being used:
    /// `.workoutRow` for a Just Row, and the interval states while a programmed
    /// piece runs. `WaitToBegin` and `WorkoutEnd` bracket a session.
    public enum WorkoutState: Sendable, Equatable {
        case waitToBegin, workoutRow, countdownPause
        case intervalRest, intervalWorkTime, intervalWorkDistance
        case intervalRestEndToWorkTime, intervalRestEndToWorkDistance
        case intervalWorkTimeToRest, intervalWorkDistanceToRest
        case workoutEnd, terminate, workoutLogged, rearm
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .waitToBegin
            case 1: .workoutRow
            case 2: .countdownPause
            case 3: .intervalRest
            case 4: .intervalWorkTime
            case 5: .intervalWorkDistance
            case 6: .intervalRestEndToWorkTime
            case 7: .intervalRestEndToWorkDistance
            case 8: .intervalWorkTimeToRest
            case 9: .intervalWorkDistanceToRest
            case 10: .workoutEnd
            case 11: .terminate
            case 12: .workoutLogged
            case 13: .rearm
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .waitToBegin: "Ready"
            case .workoutRow: "Rowing"
            case .countdownPause: "Countdown"
            case .intervalRest: "Rest"
            case .intervalWorkTime: "Interval (time)"
            case .intervalWorkDistance: "Interval (distance)"
            case .intervalRestEndToWorkTime: "Rest ending, time interval next"
            case .intervalRestEndToWorkDistance: "Rest ending, distance interval next"
            case .intervalWorkTimeToRest: "Time interval ending, rest next"
            case .intervalWorkDistanceToRest: "Distance interval ending, rest next"
            case .workoutEnd: "Finished"
            case .terminate: "Terminated"
            case .workoutLogged: "Logged"
            case .rearm: "Rearmed"
            case .other(let raw): "Unknown state (\(raw))"
            }
        }
    }

    /// Appendix A, `Rowing State`. Two values: is the flywheel moving.
    public enum RowingState: Sendable, Equatable {
        case inactive, active
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .inactive
            case 1: .active
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .inactive: "Inactive"
            case .active: "Rowing"
            case .other(let raw): "Unknown rowing state (\(raw))"
            }
        }
    }

    /// Appendix A, `Stroke State`: where in the stroke the flywheel is.
    public enum StrokeState: Sendable, Equatable {
        case waitingForWheelToReachMinSpeed
        case waitingForWheelToAccelerate
        case driving
        case dwellingAfterDrive
        case recovery
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0: .waitingForWheelToReachMinSpeed
            case 1: .waitingForWheelToAccelerate
            case 2: .driving
            case 3: .dwellingAfterDrive
            case 4: .recovery
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .waitingForWheelToReachMinSpeed: "Waiting for wheel"
            case .waitingForWheelToAccelerate: "Accelerating"
            case .driving: "Drive"
            case .dwellingAfterDrive: "Dwell"
            case .recovery: "Recovery"
            case .other(let raw): "Unknown stroke state (\(raw))"
            }
        }
    }

    /// Appendix A, `Workout Duration Type`. Not 0…3 — it is 0, 0x40, 0x80,
    /// 0xC0, so a plain `switch` on small integers would be wrong.
    public enum DurationType: Sendable, Equatable {
        case time, calories, distance, watts
        case other(UInt8)

        public init(_ raw: UInt8) {
            self = switch raw {
            case 0x00: .time
            case 0x40: .calories
            case 0x80: .distance
            case 0xC0: .watts
            default: .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .time: "Time"
            case .calories: "Calories"
            case .distance: "Distance"
            case .watts: "Watts"
            case .other(let raw): "Unknown duration type (\(raw))"
            }
        }
    }
}

// MARK: - Reading bytes

/// A bounds-checked cursor over one notification's payload.
///
/// Every accessor returns `nil` past the end, so a short or malformed
/// notification produces a `nil` parse rather than a crash or a silent zero.
/// The PM5 sends fixed lengths and the spec's byte counts are asserted in each
/// parser's guard, but the reader is what makes that safe rather than hopeful.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// `Lo, Hi` — little-endian, which is what the spec's ordering means.
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// `Lo, Mid, Hi`.
    mutating func u24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
    }
}

/// The PM5 reports a missing heart rate as 255, not as absent.
///
/// Named `validHeartRate` and not `heartRate` on purpose: several of the
/// payloads below have a `heartRate` property, and a free function of the same
/// name inside their initialisers is the kind of thing that compiles until it
/// does not.
private func validHeartRate(_ raw: UInt8?) -> UInt8? {
    guard let raw, raw != 255, raw != 0 else { return nil }
    return raw
}

// MARK: - Characteristic payloads

extension PM5 {
    /// `0x0031`, 19 bytes. The four state enums and the two running totals live
    /// here; nothing else needs subscribing to just to know whether the rower
    /// is moving.
    public struct GeneralStatus: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let distance: Double
        public let workoutType: WorkoutType
        public let intervalType: IntervalType
        public let workoutState: WorkoutState
        public let rowingState: RowingState
        public let strokeState: StrokeState
        public let totalWorkDistance: UInt32
        /// The target's magnitude, in whatever unit `durationType` names:
        /// seconds when that is `.time`, and raw metres, calories or watts
        /// otherwise.
        ///
        /// ! **Not always a time**, despite the name the spec gives it. The
        /// spec's line reads "Workout Duration Lo (if time, 0.01 sec lsb)" and
        /// the qualifier is load-bearing: a captured `0x0031` from a 100 m
        /// distance piece carries `durationType` 0x80 with a raw 100 — that is
        /// 100 metres, and scaling it unconditionally renders a distance
        /// target as a hundredth of itself. `workoutDurationSeconds` is the
        /// safe reading when a time is what you want.
        public let workoutDuration: Double
        public let durationType: DurationType
        public let dragFactor: UInt8

        /// The duration as a time, or nil when the PM5 is counting something
        /// else — metres, calories, watt-minutes.
        public var workoutDurationSeconds: TimeInterval? {
            durationType == .time ? workoutDuration : nil
        }

        public init?(bytes: Data) {
            guard bytes.count == 19 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let dist = r.u24(),
                  let workoutType = r.u8(),
                  let intervalType = r.u8(),
                  let workoutState = r.u8(),
                  let rowingState = r.u8(),
                  let strokeState = r.u8(),
                  let totalWork = r.u24(),
                  let duration = r.u24(),
                  let durationType = r.u8(),
                  let drag = r.u8()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            distance = Double(dist) * 0.1
            self.workoutType = WorkoutType(workoutType)
            self.intervalType = IntervalType(intervalType)
            self.workoutState = WorkoutState(workoutState)
            self.rowingState = RowingState(rowingState)
            self.strokeState = StrokeState(strokeState)
            totalWorkDistance = totalWork
            // ! The 0.01 applies only when the target is a time. See the property.
            let target = DurationType(durationType)
            workoutDuration = target == .time ? Double(duration) * 0.01 : Double(duration)
            self.durationType = target
            dragFactor = drag
        }
    }

    /// `0x0032`, 17 bytes. The live numbers a rower actually watches.
    ///
    /// ! 17 bytes, not the 19 the multiplexed 0x0080 carries for the same ID —
    /// see the note at the top of this file. `ergMachineType` is the last byte
    /// here and would land mid-field under the multiplexed layout.
    public struct AdditionalStatus: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        /// Metres per second.
        public let speed: Double
        /// Strokes per minute.
        public let strokeRate: UInt8
        /// Nil when the PM5 has no belt paired; it sends 255 for "invalid".
        public let heartRate: UInt8?
        /// Seconds per 500 m, as the PM5 displays it.
        public let currentPace: TimeInterval
        public let averagePace: TimeInterval
        public let restDistance: UInt16
        public let restTime: TimeInterval
        public let ergMachineType: ErgMachineType

        public init?(bytes: Data) {
            guard bytes.count == 17 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let speed = r.u16(),
                  let strokeRate = r.u8(),
                  let hr = r.u8(),
                  let pace = r.u16(),
                  let avgPace = r.u16(),
                  let restDist = r.u16(),
                  let restTime = r.u24(),
                  let machine = r.u8()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            self.speed = Double(speed) * 0.001
            self.strokeRate = strokeRate
            heartRate = validHeartRate(hr)
            currentPace = Double(pace) * 0.01
            averagePace = Double(avgPace) * 0.01
            restDistance = restDist
            self.restTime = Double(restTime) * 0.01
            ergMachineType = ErgMachineType(machine)
        }
    }

    /// `0x0033`, 20 bytes. Interval progress, power, calories, and the split
    /// just completed.
    public struct AdditionalStatus2: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let intervalCount: UInt8
        public let averagePower: UInt16
        public let totalCalories: UInt16
        public let splitAveragePace: TimeInterval
        public let splitAveragePower: UInt16
        public let splitAverageCalories: UInt16
        /// ! **Hundredths of a second — the spec is wrong.**
        ///
        /// The spec's own table says "0.1 sec lsb" for this field, and that is
        /// a documented defect rather than an ambiguity. A capture from a real
        /// PM5 shows it plainly: at one instant during one split, this
        /// characteristic carried a raw 2492 while `0x0037` carried 249 for the
        /// same split at the same 100 m mark — a ratio of exactly ten, with
        /// 249 × 0.1 = 24.9 s matching 2492 × 0.01 = 24.92 s against an elapsed
        /// time of 24.89 s. Reading it as tenths reports a split ten times
        /// longer than the workout that contains it.
        ///
        /// The trap inside the trap: `splitAveragePace`, three fields earlier
        /// in this very payload, *is* hundredths and *is* labelled correctly.
        /// Trusting the column labels field by field is how this gets in.
        public let lastSplitTime: TimeInterval
        public let lastSplitDistance: UInt32

        public init?(bytes: Data) {
            guard bytes.count == 20 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let intervalCount = r.u8(),
                  let avgPower = r.u16(),
                  let calories = r.u16(),
                  let splitPace = r.u16(),
                  let splitPower = r.u16(),
                  let splitCalories = r.u16(),
                  let lastTime = r.u24(),
                  let lastDistance = r.u24()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            self.intervalCount = intervalCount
            averagePower = avgPower
            totalCalories = calories
            splitAveragePace = Double(splitPace) * 0.01
            splitAveragePower = splitPower
            splitAverageCalories = splitCalories
            // ! Hundredths, whatever the spec's table says. See the property.
            lastSplitTime = Double(lastTime) * 0.01
            lastSplitDistance = lastDistance
        }
    }

    /// `0x0035`, 20 bytes. One stroke, with the force numbers.
    ///
    /// This is the characteristic that makes an app better than the PM5's own
    /// screen — drive length and work per stroke are not on the monitor.
    public struct StrokeData: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let distance: Double
        /// Metres. The PM5 caps this at 2.55 m, which is what fits in a byte.
        public let driveLength: Double
        /// Seconds. Capped at 2.55 s.
        public let driveTime: TimeInterval
        public let strokeRecoveryTime: TimeInterval
        public let strokeDistance: Double
        /// Pounds of force, to a tenth.
        public let peakDriveForce: Double
        public let averageDriveForce: Double
        /// Joules, to a tenth.
        public let workPerStroke: Double
        public let strokeCount: UInt16

        public init?(bytes: Data) {
            guard bytes.count == 20 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let dist = r.u24(),
                  let driveLength = r.u8(),
                  let driveTime = r.u8(),
                  let recovery = r.u16(),
                  let strokeDist = r.u16(),
                  let peakForce = r.u16(),
                  let avgForce = r.u16(),
                  let work = r.u16(),
                  let count = r.u16()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            distance = Double(dist) * 0.1
            self.driveLength = Double(driveLength) * 0.01
            self.driveTime = Double(driveTime) * 0.01
            strokeRecoveryTime = Double(recovery) * 0.01
            strokeDistance = Double(strokeDist) * 0.01
            peakDriveForce = Double(peakForce) * 0.1
            averageDriveForce = Double(avgForce) * 0.1
            workPerStroke = Double(work) * 0.1
            strokeCount = count
        }
    }

    /// `0x0036`, 15 bytes. Stroke power and the projected finish.
    public struct AdditionalStrokeData: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let strokePower: UInt16
        /// Calories per hour, not a total.
        public let strokeCalories: UInt16
        public let strokeCount: UInt16
        /// Seconds.
        public let projectedWorkTime: UInt32
        /// Metres.
        public let projectedWorkDistance: UInt32

        public init?(bytes: Data) {
            guard bytes.count == 15 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let power = r.u16(),
                  let calories = r.u16(),
                  let count = r.u16(),
                  let projTime = r.u24(),
                  let projDistance = r.u24()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            strokePower = power
            strokeCalories = calories
            strokeCount = count
            projectedWorkTime = projTime
            projectedWorkDistance = projDistance
        }
    }

    /// `0x0037`, 18 bytes. The split or interval in progress.
    public struct SplitIntervalData: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let distance: Double
        /// ! Tenths of a second.
        public let splitIntervalTime: TimeInterval
        /// Whole metres.
        public let splitIntervalDistance: UInt32
        /// Whole seconds.
        public let intervalRestTime: UInt16
        /// Whole metres.
        public let intervalRestDistance: UInt16
        public let splitIntervalType: IntervalType
        public let splitIntervalNumber: UInt8

        public init?(bytes: Data) {
            guard bytes.count == 18 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let dist = r.u24(),
                  let splitTime = r.u24(),
                  let splitDist = r.u24(),
                  let restTime = r.u16(),
                  let restDist = r.u16(),
                  let type = r.u8(),
                  let number = r.u8()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            distance = Double(dist) * 0.1
            splitIntervalTime = Double(splitTime) * 0.1
            splitIntervalDistance = splitDist
            intervalRestTime = restTime
            intervalRestDistance = restDist
            splitIntervalType = IntervalType(type)
            splitIntervalNumber = number
        }
    }

    /// `0x0038`, 19 bytes. The split's averages, including both heart rates.
    ///
    /// `workHeartRate` and `restHeartRate` are separate because a rest interval
    /// is when the HR tells you the most — and this is the only place the PM5
    /// puts heart rate into a *split*, as opposed to the live value in `0x0032`.
    public struct AdditionalSplitIntervalData: Sendable, Equatable {
        public let elapsedTime: TimeInterval
        public let averageStrokeRate: UInt8
        public let workHeartRate: UInt8?
        public let restHeartRate: UInt8?
        /// ! Tenths of a second, where the live pace in `0x0032` is hundredths.
        public let averagePace: TimeInterval
        public let totalCalories: UInt16
        /// Calories per hour.
        public let averageCalories: UInt16
        public let speed: Double
        public let power: UInt16
        public let averageDragFactor: UInt8
        public let splitIntervalNumber: UInt8
        public let ergMachineType: ErgMachineType

        public init?(bytes: Data) {
            guard bytes.count == 19 else { return nil }
            var r = ByteReader(bytes)
            guard let elapsed = r.u24(),
                  let strokeRate = r.u8(),
                  let workHR = r.u8(),
                  let restHR = r.u8(),
                  let pace = r.u16(),
                  let calories = r.u16(),
                  let avgCalories = r.u16(),
                  let speed = r.u16(),
                  let power = r.u16(),
                  let drag = r.u8(),
                  let number = r.u8(),
                  let machine = r.u8()
            else { return nil }

            elapsedTime = Double(elapsed) * 0.01
            averageStrokeRate = strokeRate
            workHeartRate = validHeartRate(workHR)
            restHeartRate = validHeartRate(restHR)
            averagePace = Double(pace) * 0.1
            totalCalories = calories
            self.averageCalories = avgCalories
            self.speed = Double(speed) * 0.001
            self.power = power
            averageDragFactor = drag
            splitIntervalNumber = number
            ergMachineType = ErgMachineType(machine)
        }
    }

    /// `0x0039`, 20 bytes. The finished workout — **the payload that becomes the
    /// Health workout**, and the reason this characteristic matters more than
    /// the live ones.
    ///
    /// The PM5 sends it after the workout ends, and *again* about a minute later
    /// with `recoveryHeartRate` filled in, unless the monitor was turned off or
    /// a new workout started. So a client should expect this twice and treat the
    /// second as an update, not a duplicate.
    public struct WorkoutSummary: Sendable, Equatable {
        /// CSAFE's packed date, not a Unix time — see `AdditionalSummary` for
        /// why these two are kept raw.
        public let logEntryDate: UInt16
        public let logEntryTime: UInt16
        public let elapsedTime: TimeInterval
        public let distance: Double
        public let averageStrokeRate: UInt8
        public let endingHeartRate: UInt8?
        public let averageHeartRate: UInt8?
        public let minHeartRate: UInt8?
        public let maxHeartRate: UInt8?
        public let averageDragFactor: UInt8
        /// ! Zero means "not valid data", not a heart rate of zero — the spec
        /// says so, and it arrives zero on the first send of this payload.
        public let recoveryHeartRate: UInt8?
        public let workoutType: WorkoutType
        /// ! Tenths of a second.
        public let averagePace: TimeInterval

        public init?(bytes: Data) {
            guard bytes.count == 20 else { return nil }
            var r = ByteReader(bytes)
            guard let date = r.u16(),
                  let time = r.u16(),
                  let elapsed = r.u24(),
                  let dist = r.u24(),
                  let strokeRate = r.u8(),
                  let endingHR = r.u8(),
                  let avgHR = r.u8(),
                  let minHR = r.u8(),
                  let maxHR = r.u8(),
                  let drag = r.u8(),
                  let recoveryHR = r.u8(),
                  let workoutType = r.u8(),
                  let pace = r.u16()
            else { return nil }

            logEntryDate = date
            logEntryTime = time
            elapsedTime = Double(elapsed) * 0.01
            distance = Double(dist) * 0.1
            averageStrokeRate = strokeRate
            endingHeartRate = validHeartRate(endingHR)
            averageHeartRate = validHeartRate(avgHR)
            minHeartRate = validHeartRate(minHR)
            maxHeartRate = validHeartRate(maxHR)
            averageDragFactor = drag
            // ! Zero, unlike the 255 the live characteristic uses.
            recoveryHeartRate = (recoveryHR == 0) ? nil : recoveryHR
            self.workoutType = WorkoutType(workoutType)
            averagePace = Double(pace) * 0.1
        }
    }

    /// `0x003A`, 19 bytes. What the summary does not carry: watts, total rest,
    /// and the split configuration.
    public struct AdditionalSummary: Sendable, Equatable {
        public let logEntryDate: UInt16
        public let logEntryTime: UInt16
        public let splitIntervalType: IntervalType
        /// Metres or seconds, depending on `splitIntervalType`.
        public let splitIntervalSize: UInt16
        public let splitIntervalCount: UInt8
        public let totalCalories: UInt16
        public let watts: UInt16
        /// Whole metres.
        public let totalRestDistance: UInt32
        /// Whole seconds.
        public let intervalRestTime: UInt16
        /// Calories per hour.
        public let averageCalories: UInt16

        public init?(bytes: Data) {
            guard bytes.count == 19 else { return nil }
            var r = ByteReader(bytes)
            guard let date = r.u16(),
                  let time = r.u16(),
                  let type = r.u8(),
                  let size = r.u16(),
                  let count = r.u8(),
                  let calories = r.u16(),
                  let watts = r.u16(),
                  let restDistance = r.u24(),
                  let restTime = r.u16(),
                  let avgCalories = r.u16()
            else { return nil }

            logEntryDate = date
            logEntryTime = time
            splitIntervalType = IntervalType(type)
            splitIntervalSize = size
            splitIntervalCount = count
            totalCalories = calories
            self.watts = watts
            totalRestDistance = restDistance
            intervalRestTime = restTime
            averageCalories = avgCalories
        }
    }

    /// `0x003B`, 6 bytes. Which belt the PM5 is paired to.
    ///
    /// Worth having because heart rate in `0x0032` is a number with no
    /// provenance, and when it reads 255 this is what says whether no belt is
    /// paired at all or one is paired and quiet.
    public struct HeartRateBeltInfo: Sendable, Equatable {
        public let manufacturerID: UInt8
        public let deviceType: UInt8
        /// 32-bit, which is why it takes four bytes for a Bluetooth address.
        public let beltID: UInt32

        public init?(bytes: Data) {
            guard bytes.count == 6 else { return nil }
            var r = ByteReader(bytes)
            guard let manufacturer = r.u8(),
                  let deviceType = r.u8(),
                  let lo = r.u8(),
                  let midLo = r.u8(),
                  let midHi = r.u8(),
                  let hi = r.u8()
            else { return nil }

            manufacturerID = manufacturer
            self.deviceType = deviceType
            beltID = UInt32(lo) | UInt32(midLo) << 8 | UInt32(midHi) << 16 | UInt32(hi) << 24
        }
    }
}

// MARK: - The seam the radio uses

extension PM5 {
    /// One notification, decoded. This is the only thing the CoreBluetooth
    /// layer in the `Hub` target has to know about: hand it the characteristic's
    /// UUID string and the bytes, get back a typed value or nothing.
    ///
    /// Returning `nil` for an unknown characteristic or a wrong-length payload
    /// is deliberate — a rowing session must not die because the PM5 sent
    /// something this client does not model, and the states it does model are
    /// enough to display a workout.
    public enum Event: Sendable, Equatable {
        case generalStatus(GeneralStatus)
        case additionalStatus(AdditionalStatus)
        case additionalStatus2(AdditionalStatus2)
        case strokeData(StrokeData)
        case additionalStrokeData(AdditionalStrokeData)
        case splitInterval(SplitIntervalData)
        case additionalSplitInterval(AdditionalSplitIntervalData)
        case workoutSummary(WorkoutSummary)
        case additionalSummary(AdditionalSummary)
        case heartRateBelt(HeartRateBeltInfo)
    }

    /// Decode one notification.
    ///
    /// - Parameters:
    ///   - uuid: the characteristic UUID as an uppercase 128-bit string, which
    ///     is what `CBUUID.uuidString` gives on the standalone characteristics.
    ///     Compared case-insensitively, because CoreBluetooth's casing is not
    ///     contractual.
    ///   - bytes: the notification payload.
    public static func decode(uuid: String, bytes: Data) -> Event? {
        guard let characteristic = Characteristic(rawValue: uuid.uppercased()) else { return nil }
        return switch characteristic {
        case .generalStatus: GeneralStatus(bytes: bytes).map(Event.generalStatus)
        case .additionalStatus: AdditionalStatus(bytes: bytes).map(Event.additionalStatus)
        case .additionalStatus2: AdditionalStatus2(bytes: bytes).map(Event.additionalStatus2)
        case .strokeData: StrokeData(bytes: bytes).map(Event.strokeData)
        case .additionalStrokeData: AdditionalStrokeData(bytes: bytes).map(Event.additionalStrokeData)
        case .splitIntervalData: SplitIntervalData(bytes: bytes).map(Event.splitInterval)
        case .additionalSplitIntervalData: AdditionalSplitIntervalData(bytes: bytes)
            .map(Event.additionalSplitInterval)
        case .endOfWorkoutSummary: WorkoutSummary(bytes: bytes).map(Event.workoutSummary)
        case .endOfWorkoutAdditionalSummary: AdditionalSummary(bytes: bytes)
            .map(Event.additionalSummary)
        case .heartRateBeltInfo: HeartRateBeltInfo(bytes: bytes).map(Event.heartRateBelt)
        // Services, the write-only sample rate, and the force curve have no
        // payload to decode here. The force curve is deliberately unparsed: it
        // arrives as 2–288 bytes across several notifications, and Phase 1 has
        // nowhere to put a 288-sample series anyway.
        case .rowingService, .controlService, .deviceInfoService,
             .sampleRate, .forceCurve:
            nil
        }
    }
}

// MARK: - Formatting the PM5's own units

extension PM5 {
    /// The PM5 counts time in hundredths of a second and shows pace as
    /// minutes and tenths per 500 m. A tile wants both as something a person
    /// reads, and neither is a `DateComponentsFormatter` job because the
    /// tenths matter at rowing pace.
    public enum Format {
        /// `1:23.4` — the split format rowers read. Empty for no time.
        public static func pace(_ seconds: TimeInterval) -> String {
            guard seconds > 0, seconds.isFinite else { return "—" }
            let minutes = Int(seconds) / 60
            let remainder = seconds - Double(minutes * 60)
            return String(format: "%d:%04.1f", minutes, remainder)
        }

        /// `12:34` or `1:02:03` — elapsed time, no tenths.
        public static func elapsed(_ seconds: TimeInterval) -> String {
            guard seconds >= 0, seconds.isFinite else { return "—" }
            let total = Int(seconds.rounded())
            let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                : String(format: "%d:%02d", minutes, secs)
        }
    }
}
