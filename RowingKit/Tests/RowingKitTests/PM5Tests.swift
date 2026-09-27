import Foundation
import Testing
@testable import RowingKit

/// The PM5's byte layouts.
///
/// These tests are the whole reason the parser lives in `HubCore`: there is no
/// rower attached to this box and there never will be, so the protocol is
/// either proven here against bytes or it is not proven at all. Every payload
/// below is assembled from the spec's own field order — `Lo, Mid, Hi`, which is
/// little-endian — and the byte count the spec gives for that characteristic is
/// asserted before the parse, so a test that drifts from the spec fails loudly
/// rather than testing a layout nobody ships.
@Suite("PM5 payloads")
struct PM5Tests {
    // MARK: Helpers

    // The assembly itself lives in `PM5Fixtures`, shared with the store's tests
    // so the two do not drift into separate dialects of the same payloads.
    private func le16(_ value: Int) -> [Int] { PM5Fixtures.le16(value) }
    private func le24(_ value: Int) -> [Int] { PM5Fixtures.le24(value) }
    private func data(_ values: [Int]) -> Data { PM5Fixtures.data(values) }

    /// Scale factors turn integers into hundredths and tenths, so equality on
    /// `Double` would be a coin flip. `1e-9` is far tighter than any PM5 unit
    /// and far looser than the float noise.
    private func near(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-9
    }

    // MARK: 0x0031 — general status

    @Test("0x0031: the four state enums and both running clocks")
    func generalStatus() throws {
        let payload = data(
            le24(12_345)            // elapsed, hundredths of a second
            + le24(2_000)           // distance, tenths of a metre
            + [1, 255, 1, 1, 2]     // workout, interval, workout state, rowing, stroke
            + le24(2_000)           // total work distance
            + le24(6_000)           // workout duration, hundredths
            + [0x80, 120]           // duration type, drag factor
        )
        #expect(payload.count == 19)

        let status = try #require(PM5.GeneralStatus(bytes: payload))
        #expect(near(status.elapsedTime, 123.45))
        #expect(near(status.distance, 200.0))
        #expect(status.workoutType == .justRowSplits)
        #expect(status.intervalType == .none)
        #expect(status.workoutState == .workoutRow)
        #expect(status.rowingState == .active)
        #expect(status.strokeState == .driving)
        #expect(status.totalWorkDistance == 2_000)
        // ! durationType is 0x80 — distance — so the raw 6000 is 6000 METRES,
        // not 60 seconds. The spec's own line is "Workout Duration Lo (if time,
        // 0.01 sec lsb)" and the qualifier is load-bearing.
        #expect(status.durationType == .distance)
        #expect(status.workoutDuration == 6_000)
        #expect(status.workoutDurationSeconds == nil)
        #expect(status.dragFactor == 120)
    }

    @Test("0x0031: the duration is a time only when the duration type says so")
    func durationDependsOnItsType() throws {
        func status(duration: Int, type: Int) -> PM5.GeneralStatus? {
            PM5.GeneralStatus(bytes: data(
                le24(0) + le24(0) + [0, 255, 0, 0, 0] + le24(0) + le24(duration) + [type, 0]
            ))
        }

        // A time target really is hundredths of a second.
        let timed = try #require(status(duration: 600_000, type: 0x00))
        #expect(timed.durationType == .time)
        #expect(near(timed.workoutDuration, 6_000))
        #expect(near(timed.workoutDurationSeconds, 6_000))

        // A distance target's u24 is metres, and must not be touched.
        let distanced = try #require(status(duration: 2_000, type: 0x80))
        #expect(distanced.workoutDuration == 2_000)
        #expect(distanced.workoutDurationSeconds == nil)

        // Neither is a calorie or a watt-minute target.
        #expect(try #require(status(duration: 500, type: 0x40)).workoutDurationSeconds == nil)
        #expect(try #require(status(duration: 250, type: 0xC0)).workoutDurationSeconds == nil)
    }

    @Test("0x0031: the third byte is a high byte, not padding")
    func threeByteFieldsUseTheirHighByte() throws {
        // 0x01_00_00 read Lo/Mid/Hi is 65536 hundredths — 655.36 s. Dropping
        // the high byte would read as zero, which is the failure mode this
        // catches: a row that has been going eleven minutes showing 0:00.
        let payload = data(
            le24(65_536) + le24(0) + [0, 255, 0, 0, 0] + le24(0) + le24(0) + [0, 0]
        )
        let status = try #require(PM5.GeneralStatus(bytes: payload))
        #expect(near(status.elapsedTime, 655.36))
    }

    // MARK: 0x0032 — additional status

    @Test("0x0032: pace, rate and heart rate, and 255 is not a heart rate")
    func additionalStatus() throws {
        let live = data(
            le24(10_000)            // elapsed
            + le16(4_500)           // speed, thousandths of a m/s
            + [24, 145]             // stroke rate, heart rate
            + le16(9_500)           // current pace, hundredths of a second
            + le16(9_600)           // average pace
            + le16(0)               // rest distance
            + le24(0)               // rest time
            + [0]                   // erg machine type
        )
        #expect(live.count == 17)

        let status = try #require(PM5.AdditionalStatus(bytes: live))
        #expect(near(status.elapsedTime, 100.0))
        #expect(near(status.speed, 4.5))
        #expect(status.strokeRate == 24)
        #expect(status.heartRate == 145)
        #expect(near(status.currentPace, 95.0))
        #expect(near(status.averagePace, 96.0))
        #expect(status.ergMachineType == .staticD)

        let noBelt = data(
            le24(0) + le16(0) + [0, 255] + le16(0) + le16(0) + le16(0) + le24(0) + [0]
        )
        #expect(PM5.AdditionalStatus(bytes: noBelt)?.heartRate == nil)
    }

    /// ! The single most valuable test in this file.
    ///
    /// The multiplexed characteristic (0x0080) echoes these IDs with *different*
    /// byte layouts: its 0x0032 is 19 bytes where this one is 17, its 0x0033 is
    /// 18 where this one is 20, and its 0x0035 is 18 where this one is 20. A
    /// 19-byte payload parsed as the standalone layout would put `speed`'s high
    /// byte into `stroke rate` and shift everything after it, producing numbers
    /// that look plausible and are wrong. If this test starts failing because
    /// someone relaxed the length guard, that is the bug.
    @Test("the multiplexed layouts are rejected, not silently misread")
    func multiplexedLayoutsAreNotAccepted() throws {
        #expect(PM5.AdditionalStatus(bytes: data(Array(repeating: 0, count: 19))) == nil)
        #expect(PM5.AdditionalStatus2(bytes: data(Array(repeating: 0, count: 18))) == nil)
        #expect(PM5.StrokeData(bytes: data(Array(repeating: 0, count: 18))) == nil)

        // And the lengths it does accept are the standalone ones.
        #expect(PM5.AdditionalStatus(bytes: data(Array(repeating: 0, count: 17))) != nil)
        #expect(PM5.AdditionalStatus2(bytes: data(Array(repeating: 0, count: 20))) != nil)
        #expect(PM5.StrokeData(bytes: data(Array(repeating: 0, count: 20))) != nil)
    }

    // MARK: 0x0033 — additional status 2

    @Test("0x0033: interval count, power, calories, and the split just finished")
    func additionalStatus2() throws {
        let payload = data(
            le24(10_000)            // elapsed
            + [3]                   // interval count
            + le16(210)             // average power, watts
            + le16(95)              // total calories
            + le16(9_400)           // split average pace, hundredths
            + le16(205)             // split average power
            + le16(18)              // split average calories
            + le24(9_500)           // last split time, HUNDREDTHS — see below
            + le24(500)             // last split distance, whole metres
        )
        #expect(payload.count == 20)

        let status = try #require(PM5.AdditionalStatus2(bytes: payload))
        #expect(status.intervalCount == 3)
        #expect(status.averagePower == 210)
        #expect(status.totalCalories == 95)
        #expect(near(status.splitAveragePace, 94.0))
        #expect(status.splitAveragePower == 205)
        #expect(near(status.lastSplitTime, 95.0))
        #expect(status.lastSplitDistance == 500)
    }

    /// ! The one scale in this file the spec gets wrong, so the test states
    /// both readings and the difference between them.
    @Test("0x0033: lastSplitTime is hundredths, whatever the spec's table says")
    func lastSplitTimeIsHundredths() throws {
        // Bytes in the shape of a real PM5 mid-split: 24.89 s elapsed and a
        // raw lastSplitTime of 2492. Against the same split, 0x0037 carried a
        // raw 249 — the same instant in tenths. So this field is hundredths,
        // while the spec labels it "0.1 sec lsb".
        let payload = data(
            le24(2_489)                     // elapsed, hundredths of a second
            + [0]                           // interval count
            + le16(0) + le16(0)
            + le16(0) + le16(0) + le16(0)
            + le24(2_492)                   // last split time
            + le24(0)                       // last split distance
        )
        #expect(payload.count == 20)

        let status = try #require(PM5.AdditionalStatus2(bytes: payload))
        #expect(near(status.elapsedTime, 24.89))
        #expect(near(status.lastSplitTime, 24.92))
        // The reading the spec's column would produce: longer than the workout
        // that contains it. Asserted so a regression is unmistakable.
        #expect(!near(status.lastSplitTime, 249.2))
    }

    // MARK: 0x0035 — stroke data

    @Test("0x0035: drive length and work per stroke, which the PM5's own screen does not show")
    func strokeData() throws {
        let payload = data(
            le24(10_000)            // elapsed
            + le24(1_500)           // distance, tenths of a metre
            + [145, 75]             // drive length (hundredths of a m), drive time (hundredths of a s)
            + le16(120)             // stroke recovery time, hundredths
            + le16(950)             // stroke distance, hundredths of a metre
            + le16(420)             // peak drive force, tenths of a pound
            + le16(310)             // average drive force
            + le16(8_400)           // work per stroke, tenths of a joule
            + le16(37)              // stroke count
        )
        #expect(payload.count == 20)

        let stroke = try #require(PM5.StrokeData(bytes: payload))
        #expect(near(stroke.driveLength, 1.45))
        #expect(near(stroke.driveTime, 0.75))
        #expect(near(stroke.strokeRecoveryTime, 1.20))
        #expect(near(stroke.strokeDistance, 9.50))
        #expect(near(stroke.peakDriveForce, 42.0))
        #expect(near(stroke.averageDriveForce, 31.0))
        #expect(near(stroke.workPerStroke, 840.0))
        #expect(stroke.strokeCount == 37)
    }

    // MARK: 0x0036 — additional stroke data

    @Test("0x0036: stroke power and the projected finish")
    func additionalStrokeData() throws {
        let payload = data(
            le24(10_000)            // elapsed
            + le16(215)             // stroke power, watts
            + le16(840)             // stroke calories, per HOUR
            + le16(37)              // stroke count
            + le24(1_800)           // projected work time, whole seconds
            + le24(5_000)           // projected work distance, whole metres
        )
        #expect(payload.count == 15)

        let stroke = try #require(PM5.AdditionalStrokeData(bytes: payload))
        #expect(stroke.strokePower == 215)
        #expect(stroke.strokeCalories == 840)
        #expect(stroke.projectedWorkTime == 1_800)
        #expect(stroke.projectedWorkDistance == 5_000)
    }

    // MARK: 0x0037 — split / interval

    @Test("0x0037: the split in progress, in whole metres and seconds")
    func splitInterval() throws {
        let payload = data(
            le24(10_000)            // elapsed
            + le24(1_500)           // distance
            + le24(9_500)           // split time, tenths of a second
            + le24(500)             // split distance, whole metres
            + le16(60)              // interval rest time, whole seconds
            + le16(0)               // interval rest distance, whole metres
            + [0, 2]                // split type (time), split number
        )
        #expect(payload.count == 18)

        let split = try #require(PM5.SplitIntervalData(bytes: payload))
        #expect(near(split.splitIntervalTime, 950.0))
        #expect(split.splitIntervalDistance == 500)
        #expect(split.intervalRestTime == 60)
        #expect(split.splitIntervalType == .time)
        #expect(split.splitIntervalNumber == 2)
    }

    // MARK: 0x0038 — additional split / interval

    @Test("0x0038: both heart rates for the split, and pace in TENTHS")
    func additionalSplitInterval() throws {
        let payload = data(
            le24(10_000)            // elapsed
            + [24, 152, 118]        // stroke rate, work HR, rest HR
            + le16(940)             // average pace, TENTHS of a second
            + le16(95)              // total calories
            + le16(860)             // average calories, per hour
            + le16(4_350)           // speed, thousandths of a m/s
            + le16(208)             // power, watts
            + [128, 2]              // average drag factor, split number
            + [0]                   // erg machine type
        )
        #expect(payload.count == 19)

        let split = try #require(PM5.AdditionalSplitIntervalData(bytes: payload))
        #expect(split.averageStrokeRate == 24)
        #expect(split.workHeartRate == 152)
        #expect(split.restHeartRate == 118)
        // ! Tenths here, versus 0x0032's hundredths. Same word, different unit.
        #expect(near(split.averagePace, 94.0))
        #expect(near(split.speed, 4.35))
        #expect(split.power == 208)
        #expect(split.averageDragFactor == 128)
    }

    // MARK: 0x0039 — end of workout summary

    @Test("0x0039: the finished workout, and the second send that carries recovery heart rate")
    func workoutSummary() throws {
        // The spec is explicit that the PM5 sends this again about a minute
        // after the workout ends, with recovery HR filled in — and that a zero
        // recovery HR on the first send means "not valid data", not 0 bpm.
        func summary(recoveryHeartRate: Int, workoutType: Int) -> Data {
            data(
                le16(1) + le16(2)           // log entry date, time
                + le24(180_000)             // elapsed, hundredths — 30 minutes
                + le24(5_000)               // distance, tenths of a metre — 500 m
                + [24, 150, 140, 95, 178]   // stroke rate, ending, average, min, max HR
                + [130, recoveryHeartRate, workoutType]
                + le16(950)                 // average pace, TENTHS of a second
            )
        }

        let first = summary(recoveryHeartRate: 0, workoutType: 1)
        #expect(first.count == 20)

        let ended = try #require(PM5.WorkoutSummary(bytes: first))
        #expect(near(ended.elapsedTime, 1_800.0))
        #expect(near(ended.distance, 500.0))
        #expect(ended.averageStrokeRate == 24)
        #expect(ended.endingHeartRate == 150)
        #expect(ended.averageHeartRate == 140)
        #expect(ended.minHeartRate == 95)
        #expect(ended.maxHeartRate == 178)
        #expect(ended.averageDragFactor == 130)
        #expect(ended.workoutType == .justRowSplits)
        #expect(near(ended.averagePace, 95.0))
        // ! Zero means absent here, where the live characteristic uses 255.
        #expect(ended.recoveryHeartRate == nil)

        let revised = try #require(
            PM5.WorkoutSummary(bytes: summary(recoveryHeartRate: 88, workoutType: 1))
        )
        #expect(revised.recoveryHeartRate == 88)
    }

    // MARK: 0x003A and 0x003B

    @Test("0x003A: watts and rest totals, which the summary does not carry")
    func additionalSummary() throws {
        let payload = data(
            le16(1) + le16(2)       // log entry date, time
            + [0]                   // split interval type
            + le16(500)             // split interval size, whole metres here
            + [2]                   // split interval count
            + le16(95)              // total calories
            + le16(211)             // watts
            + le24(120)             // total rest distance, whole metres
            + le16(45)              // interval rest time, whole seconds
            + le16(860)             // average calories, per hour
        )
        #expect(payload.count == 19)

        let summary = try #require(PM5.AdditionalSummary(bytes: payload))
        #expect(summary.splitIntervalType == .time)
        #expect(summary.splitIntervalSize == 500)
        #expect(summary.splitIntervalCount == 2)
        #expect(summary.totalCalories == 95)
        #expect(summary.watts == 211)
        #expect(summary.totalRestDistance == 120)
        #expect(summary.intervalRestTime == 45)
    }

    @Test("0x003B: which belt the PM5 is paired to, as a 32-bit id")
    func heartRateBelt() throws {
        let payload = data([1, 2, 0x11, 0x22, 0x33, 0x44])
        #expect(payload.count == 6)

        let belt = try #require(PM5.HeartRateBeltInfo(bytes: payload))
        #expect(belt.manufacturerID == 1)
        #expect(belt.deviceType == 2)
        // Little-endian across four bytes, so the first byte is the lowest.
        #expect(belt.beltID == 0x4433_2211)
    }

    // MARK: Rejection

    @Test("no payload reads past a truncated notification")
    func truncatedPayloadsAreRejected() throws {
        for count in 0..<19 {
            #expect(PM5.GeneralStatus(bytes: data(Array(repeating: 0, count: count))) == nil)
        }
        for count in 0..<17 {
            #expect(PM5.AdditionalStatus(bytes: data(Array(repeating: 0, count: count))) == nil)
        }
        for count in 0..<20 {
            #expect(PM5.StrokeData(bytes: data(Array(repeating: 0, count: count))) == nil)
        }
        for count in 0..<18 {
            #expect(PM5.SplitIntervalData(bytes: data(Array(repeating: 0, count: count))) == nil)
        }
        #expect(PM5.GeneralStatus(bytes: data(Array(repeating: 0, count: 19))) != nil)
    }

    // MARK: The dispatch seam

    @Test("decode() routes by UUID, and gives nil rather than throwing for anything else")
    func decoding() throws {
        let payload = data(
            le24(10_000) + le16(4_500) + [24, 145] + le16(9_500) + le16(9_600)
                + le16(0) + le24(0) + [0]
        )
        let uuid = PM5.Characteristic.additionalStatus.rawValue

        let event = try #require(PM5.decode(uuid: uuid, bytes: payload))
        #expect(event == .additionalStatus(try #require(PM5.AdditionalStatus(bytes: payload))))

        // CoreBluetooth's casing is not contractual, so the lookup is not
        // case-sensitive.
        #expect(PM5.decode(uuid: uuid.lowercased(), bytes: payload) != nil)

        // A service, an unrelated standard UUID, a characteristic this client
        // deliberately ignores, and a short payload: all nil, none a crash.
        #expect(PM5.decode(uuid: PM5.Characteristic.rowingService.rawValue, bytes: payload) == nil)
        #expect(PM5.decode(uuid: "0000180D-0000-1000-8000-00805F9B34FB", bytes: payload) == nil)
        #expect(PM5.decode(uuid: PM5.Characteristic.sampleRate.rawValue, bytes: payload) == nil)
        #expect(PM5.decode(uuid: uuid, bytes: data([1, 2, 3])) == nil)
    }

    // MARK: Enumerated values

    @Test("the enums keep values they do not know, and DurationType is not 0…3")
    func enumeratedValues() throws {
        #expect(PM5.ErgMachineType(192) == .bike)
        #expect(PM5.ErgMachineType(224) == .multiErgRow)
        #expect(PM5.ErgMachineType(226).label == "BikeErg (MultiErg)")
        // The spec's numbering skips 4 entirely, so it must not fall through to
        // a named case.
        #expect(PM5.ErgMachineType(4) == .other(4))
        #expect(PM5.ErgMachineType(99) == .other(99))

        // ! 0, 0x40, 0x80, 0xC0 — not 0, 1, 2, 3.
        #expect(PM5.DurationType(0x00) == .time)
        #expect(PM5.DurationType(0x40) == .calories)
        #expect(PM5.DurationType(0x80) == .distance)
        #expect(PM5.DurationType(0xC0) == .watts)
        #expect(PM5.DurationType(1) == .other(1))

        // 255 is a value, not a terminator.
        #expect(PM5.IntervalType(255) == .none)
        #expect(PM5.WorkoutState(13) == .rearm)
        #expect(PM5.WorkoutState(14) == .other(14))
        #expect(PM5.RowingState(1) == .active)
        #expect(PM5.StrokeState(2) == .driving)
    }

    // MARK: Units a person reads

    @Test("pace reads in minutes and tenths, elapsed in minutes and seconds")
    func formatting() throws {
        #expect(PM5.Format.pace(95.0) == "1:35.0")
        #expect(PM5.Format.pace(118.4) == "1:58.4")
        // The PM5 sends zero for "no reading yet", which is not 0:00.0.
        #expect(PM5.Format.pace(0) == "—")
        #expect(PM5.Format.elapsed(1_800) == "30:00")
        #expect(PM5.Format.elapsed(3_725) == "1:02:05")
    }
}
