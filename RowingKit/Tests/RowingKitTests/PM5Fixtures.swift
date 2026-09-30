import Foundation
import Testing
@testable import RowingKit

/// PM5 payloads, assembled to the spec's field order.
///
/// Shared so that the parser's tests and the store's tests build their bytes
/// the same way. Both need the real thing: the payload structs have no
/// memberwise initialiser, only `init?(bytes:)`, so every test in this target
/// goes through the parser whether it means to or not — which is the right
/// accident, because a store test that could construct a `GeneralStatus`
/// directly would be testing a struct nobody can construct.
///
/// The scale factors are the caller's business here, as they are in the spec:
/// `elapsed` is hundredths of a second, `distance` tenths of a metre. Callers
/// pass the raw integer the PM5 would send.
enum PM5Fixtures {
    // MARK: Little-endian assembly

    /// `Lo, Hi`.
    static func le16(_ value: Int) -> [Int] { [value & 0xFF, (value >> 8) & 0xFF] }

    /// `Lo, Mid, Hi` — the spec's three-byte fields.
    static func le24(_ value: Int) -> [Int] {
        [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
    }

    static func data(_ values: [Int]) -> Data { Data(values.map { UInt8($0 & 0xFF) }) }

    // MARK: 0x0031

    static func generalStatus(
        elapsed: Int = 0,
        distance: Int = 0,
        workoutType: Int = 1,
        intervalType: Int = 255,
        workoutState: Int = 0,
        rowingState: Int = 0,
        strokeState: Int = 0,
        totalWorkDistance: Int = 0,
        workoutDuration: Int = 0,
        durationType: Int = 0,
        dragFactor: Int = 0
    ) -> Data {
        data(
            le24(elapsed) + le24(distance)
                + [workoutType, intervalType, workoutState, rowingState, strokeState]
                + le24(totalWorkDistance) + le24(workoutDuration)
                + [durationType, dragFactor]
        )
    }

    static func generalStatusEvent(
        elapsed: Int = 0,
        distance: Int = 0,
        workoutState: Int = 0,
        rowingState: Int = 0
    ) throws -> PM5.Event {
        .generalStatus(try #require(PM5.GeneralStatus(bytes: generalStatus(
            elapsed: elapsed, distance: distance,
            workoutState: workoutState, rowingState: rowingState
        ))))
    }

    // MARK: 0x0032

    static func additionalStatus(
        elapsed: Int = 0,
        speed: Int = 0,
        strokeRate: Int = 0,
        heartRate: Int = 255,
        currentPace: Int = 0,
        averagePace: Int = 0,
        restDistance: Int = 0,
        restTime: Int = 0,
        machine: Int = 0
    ) -> Data {
        data(
            le24(elapsed) + le16(speed) + [strokeRate, heartRate]
                + le16(currentPace) + le16(averagePace)
                + le16(restDistance) + le24(restTime) + [machine]
        )
    }

    static func additionalStatusEvent(
        strokeRate: Int = 0,
        heartRate: Int = 255,
        currentPace: Int = 0,
        machine: Int = 0
    ) throws -> PM5.Event {
        .additionalStatus(try #require(PM5.AdditionalStatus(bytes: additionalStatus(
            strokeRate: strokeRate, heartRate: heartRate,
            currentPace: currentPace, machine: machine
        ))))
    }

    // MARK: 0x0033

    static func additionalStatus2(
        elapsed: Int = 0,
        intervalCount: Int = 0,
        averagePower: Int = 0,
        totalCalories: Int = 0,
        splitPace: Int = 0,
        splitPower: Int = 0,
        splitCalories: Int = 0,
        lastSplitTime: Int = 0,
        lastSplitDistance: Int = 0
    ) -> Data {
        data(
            le24(elapsed) + [intervalCount] + le16(averagePower) + le16(totalCalories)
                + le16(splitPace) + le16(splitPower) + le16(splitCalories)
                + le24(lastSplitTime) + le24(lastSplitDistance)
        )
    }

    static func additionalStatus2Event(averagePower: Int = 0) throws -> PM5.Event {
        .additionalStatus2(try #require(PM5.AdditionalStatus2(bytes: additionalStatus2(
            averagePower: averagePower
        ))))
    }

    // MARK: 0x0035 / 0x0036

    /// `driveTime` and `recovery` in hundredths of a second, as on the wire.
    static func strokeData(elapsed: Int = 0, strokeCount: Int = 0, driveTime: Int = 0, recovery: Int = 0) -> Data {
        data(
            le24(elapsed) + le24(0) + [0, driveTime]
                + le16(recovery) + le16(0) + le16(0) + le16(0) + le16(0) + le16(strokeCount)
        )
    }

    static func strokeDataEvent(strokeCount: Int = 0, driveTime: Int = 0, recovery: Int = 0) throws -> PM5.Event {
        .strokeData(try #require(PM5.StrokeData(bytes: strokeData(
            strokeCount: strokeCount, driveTime: driveTime, recovery: recovery
        ))))
    }

    static func additionalStatus2Event(averagePower: Int = 0, splitPace: Int) throws -> PM5.Event {
        .additionalStatus2(try #require(PM5.AdditionalStatus2(bytes: additionalStatus2(
            averagePower: averagePower, splitPace: splitPace
        ))))
    }

    static func additionalStrokeData(strokePower: Int = 0) -> Data {
        data(le24(0) + le16(strokePower) + le16(0) + le16(0) + le24(0) + le24(0))
    }

    static func additionalStrokeDataEvent(strokePower: Int = 0) throws -> PM5.Event {
        .additionalStrokeData(try #require(PM5.AdditionalStrokeData(
            bytes: additionalStrokeData(strokePower: strokePower)
        )))
    }

    // MARK: 0x0039

    static func workoutSummary(
        elapsed: Int = 0,
        distance: Int = 0,
        strokeRate: Int = 0,
        endingHeartRate: Int = 255,
        averageHeartRate: Int = 255,
        minHeartRate: Int = 255,
        maxHeartRate: Int = 255,
        dragFactor: Int = 0,
        recoveryHeartRate: Int = 0,
        workoutType: Int = 1,
        averagePace: Int = 0
    ) -> Data {
        data(
            le16(0) + le16(0)
                + le24(elapsed) + le24(distance)
                + [strokeRate, endingHeartRate, averageHeartRate, minHeartRate, maxHeartRate]
                + [dragFactor, recoveryHeartRate, workoutType]
                + le16(averagePace)
        )
    }

    static func workoutSummaryEvent(
        elapsed: Int = 0,
        distance: Int = 0,
        strokeRate: Int = 0,
        averageHeartRate: Int = 255,
        maxHeartRate: Int = 255,
        dragFactor: Int = 0,
        recoveryHeartRate: Int = 0,
        averagePace: Int = 0
    ) throws -> PM5.Event {
        .workoutSummary(try #require(PM5.WorkoutSummary(bytes: workoutSummary(
            elapsed: elapsed, distance: distance, strokeRate: strokeRate,
            averageHeartRate: averageHeartRate, maxHeartRate: maxHeartRate,
            dragFactor: dragFactor, recoveryHeartRate: recoveryHeartRate,
            averagePace: averagePace
        ))))
    }

    // MARK: 0x003A

    static func additionalSummary(
        totalCalories: Int = 0,
        watts: Int = 0,
        totalRestDistance: Int = 0,
        intervalRestTime: Int = 0,
        averageCalories: Int = 0
    ) -> Data {
        data(
            le16(0) + le16(0) + [0] + le16(0) + [0]
                + le16(totalCalories) + le16(watts)
                + le24(totalRestDistance) + le16(intervalRestTime) + le16(averageCalories)
        )
    }

    static func additionalSummaryEvent(totalCalories: Int = 0, watts: Int = 0) throws -> PM5.Event {
        .additionalSummary(try #require(PM5.AdditionalSummary(bytes: additionalSummary(
            totalCalories: totalCalories, watts: watts
        ))))
    }
}
