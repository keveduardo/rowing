import Foundation
import Testing
@testable import RowingKit

/// The arithmetic over past rows.
///
/// This is the half of history that does not need a phone: the HealthKit query
/// is in the `Hub` target and cannot be built here, but everything it feeds can
/// be, which is the point of splitting them.
@Suite("rowing history")
struct RowingHistoryTests {
    /// A fixed reference point, so "this week" means the same thing every run.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(
        _ id: Int,
        daysAgo: Double,
        seconds: TimeInterval,
        metres: Double,
        rate: UInt8? = nil,
        heart: UInt8? = nil
    ) -> RowingHistoryItem {
        RowingHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", id))")!,
            startedAt: now.addingTimeInterval(-daysAgo * 86_400),
            duration: seconds,
            distance: metres,
            averageStrokeRate: rate,
            averageHeartRate: heart
        )
    }

    @Test("newest first, whatever order they arrive in")
    func sortsNewestFirst() throws {
        let history = RowingHistory(items: [
            row(1, daysAgo: 5, seconds: 600, metres: 2_000),
            row(2, daysAgo: 1, seconds: 600, metres: 2_000),
            row(3, daysAgo: 3, seconds: 600, metres: 2_000),
        ])
        // Fed as 5 days ago, 1 day ago, 3 days ago — so the newest is the one
        // day old row, and each item is no older than the one before it.
        #expect(history.items.count == 3)
        for (older, newer) in zip(history.items.dropFirst(), history.items) {
            #expect(older.startedAt <= newer.startedAt)
        }
        #expect(history.items.first?.startedAt == now.addingTimeInterval(-86_400))
        #expect(history.items.last?.startedAt == now.addingTimeInterval(-5 * 86_400))
    }

    @Test("totals add up the rows it holds")
    func totals() throws {
        let history = RowingHistory(items: [
            row(1, daysAgo: 1, seconds: 600, metres: 2_000),
            row(2, daysAgo: 2, seconds: 900, metres: 3_000),
        ])
        #expect(history.count == 2)
        #expect(history.totalDistance == 5_000)
        #expect(history.totalTime == 1_500)
        #expect(RowingHistory(items: []).isEmpty)
    }

    @Test("this week is the last seven days, not the calendar week")
    func thisWeek() throws {
        let history = RowingHistory(items: [
            row(1, daysAgo: 0.5, seconds: 600, metres: 2_000),
            row(2, daysAgo: 6, seconds: 600, metres: 2_000),
            row(3, daysAgo: 8, seconds: 600, metres: 2_000),
        ])
        let week = history.thisWeek(from: now)
        #expect(week.count == 2)
        #expect(week.totalDistance == 4_000)
        // A row from eight days ago is out, and the whole set still holds it.
        #expect(history.count == 3)
    }

    @Test("the fastest split skips rows that never covered ground")
    func fastestSplitSkipsEmptyRows() throws {
        let history = RowingHistory(items: [
            // A 2:00 split — 600 s over 2500 m.
            row(1, daysAgo: 1, seconds: 600, metres: 2_500),
            // A 2:30 split.
            row(2, daysAgo: 2, seconds: 750, metres: 2_500),
            // ! Never moved. Its pace is nil, and treating that as a number
            // would make the row that went nowhere the fastest one on record.
            row(3, daysAgo: 3, seconds: 60, metres: 0),
        ])
        #expect(history.fastestSplit?.averagePace == 120)
        #expect(history.longest?.distance == 2_500)
    }

    @Test("a row that moved nothing reports no split rather than a split of zero")
    func emptyRowHasNoPace() throws {
        let item = row(1, daysAgo: 1, seconds: 600, metres: 0)
        #expect(item.averagePace == nil)
        let instant = row(2, daysAgo: 1, seconds: 0, metres: 2_000)
        #expect(instant.averagePace == nil)
    }

    @Test("a split is derived from the totals, in seconds per 500 m")
    func paceIsPerFiveHundred() throws {
        // 600 s over 2,000 m is four 500s, so 150 s each.
        #expect(row(1, daysAgo: 1, seconds: 600, metres: 2_000).averagePace == 150)
        #expect(row(2, daysAgo: 1, seconds: 1_500, metres: 5_000).averagePace == 150)
    }

    @Test("a distance reads with a unit, and small ones without separators")
    func distanceText() throws {
        // Below a thousand there is nothing to group, so this is locale-safe.
        #expect(row(1, daysAgo: 1, seconds: 600, metres: 250).distanceText == "250 m")
        #expect(row(2, daysAgo: 1, seconds: 600, metres: 999).distanceText == "999 m")
        // Above it the separator is the running locale's — "," or "." or a
        // space — so only the unit and the digits are asserted here, and the
        // grouping itself is left to Foundation.
        let big = row(3, daysAgo: 1, seconds: 600, metres: 4_250).distanceText
        #expect(big.hasSuffix(" m"))
        #expect(big.filter(\.isNumber) == "4250")
    }
}
