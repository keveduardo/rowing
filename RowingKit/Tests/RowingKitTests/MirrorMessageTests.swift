import Foundation
import Testing
@testable import RowingKit

/// The watch-to-phone wire format.
///
/// The property that matters is round-tripping: `sendToRemoteWorkoutSession`
/// takes `Data`, so a message that encodes but does not decode is a phone
/// screen that goes blank the moment the watch starts rowing, and it would do
/// it only on a real pair of devices.
@Suite("mirror messages")
struct MirrorMessageTests {
    private func roundTrip(_ message: MirrorMessage) throws -> MirrorMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(MirrorMessage.self, from: data)
    }

    @Test("live metrics survive the wire, including a missing power")
    func metricsRoundTrip() throws {
        let withPower = MirrorMessage.metrics(.init(
            elapsed: 123.45, distance: 1_234.5, pace: 95.0,
            strokeRate: 24, power: 210, isRowing: true
        ))
        #expect(try roundTrip(withPower) == withPower)

        // A PM5 that has not reported power yet sends nil, and nil is not zero —
        // a phone showing "0 W" for a rower mid-stroke is a wrong number, not a
        // missing one.
        let withoutPower = MirrorMessage.metrics(.init(
            elapsed: 0, distance: 0, pace: 0,
            strokeRate: 0, power: nil, isRowing: false
        ))
        #expect(try roundTrip(withoutPower) == withoutPower)
    }

    @Test("a finished row survives the wire, including every nullable field")
    func finishedRoundTrip() throws {
        let full = MirrorMessage.finished(.init(
            duration: 1_800, distance: 6_000, averagePace: 150,
            averageStrokeRate: 24, averagePower: 210, machine: "Model D"
        ))
        #expect(try roundTrip(full) == full)

        // The row the PM5 never summarised: no split, no rate, no machine.
        let bare = MirrorMessage.finished(.init(
            duration: 600, distance: 2_000, averagePace: nil,
            averageStrokeRate: nil, averagePower: nil, machine: nil
        ))
        #expect(try roundTrip(bare) == bare)
    }

    @Test("the domain model maps to the wire without losing what the phone draws")
    func mapsFromTheDomainModel() throws {
        var live = RowingLive()
        live.elapsed = 123.45
        live.distance = 1_234.5
        live.pace = 95
        live.strokeRate = 24
        live.power = 210
        live.isRowing = true

        let message = MirrorMessage.metrics(.init(live))
        #expect(message == .metrics(.init(
            elapsed: 123.45, distance: 1_234.5, pace: 95,
            strokeRate: 24, power: 210, isRowing: true
        )))
        // What the phone does not need is deliberately absent: it gets heart
        // rate from HealthKit's own mirroring, not from here.
        #expect(try roundTrip(message) == message)
    }

    @Test("the finished row sends the machine's name, not its byte")
    func resultCarriesTheMachineName() throws {
        let row = RowingWorkout(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            duration: 1_800,
            distance: 6_000,
            averagePace: 150,
            averageStrokeRate: 24,
            averagePower: 210,
            totalCalories: 320,
            averageHeartRate: 145,
            maxHeartRate: 172,
            recoveryHeartRate: 88,
            averageDragFactor: 128,
            machine: .staticD,
            workoutType: .justRowSplits
        )

        let result = MirrorMessage.Result(row)
        #expect(result.machine == "Model D")
        #expect(result.distance == 6_000)
        #expect(result.duration == 1_800)
        // The watch's own heart-rate fields stay behind — HealthKit is already
        // carrying them to the phone, and sending them twice invites the two
        // copies disagreeing on screen.
        #expect(try roundTrip(.finished(result)) == .finished(result))
    }

    @Test("something that is not one of ours fails to decode rather than guessing")
    func garbageIsRejected() throws {
        // The phone must be able to ignore a payload it does not understand —
        // an older watch, or a byte stream that arrived truncated. A decoder
        // that returned a plausible-looking default would put invented numbers
        // on the screen.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MirrorMessage.self, from: Data("{\"nope\":1}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MirrorMessage.self, from: Data())
        }
    }
}
