import Foundation

/// One past row, in the terms a list draws.
///
/// Deliberately not `RowingWorkout`: that is what the PM5 just said, and this
/// is what Health remembers — which is not the same set. Health holds rows this
/// app never saw (ErgData writes there too), rows whose per-stroke detail was
/// never stored anywhere, and rows whose numbers have been through HealthKit's
/// own rounding. Keeping them separate stops a list of history being mistaken
/// for a list of sessions this app recorded.
public struct RowingHistoryItem: Sendable, Equatable, Identifiable {
    /// HealthKit's own identifier for the workout, so a row keeps its identity
    /// across fetches.
    public let id: UUID
    public let startedAt: Date
    public let duration: TimeInterval
    public let distance: Double
    /// Seconds per 500 m, derived from the two above rather than stored —
    /// HealthKit does not keep a split, and the rower's own average is only
    /// present on rows this app wrote.
    public var averagePace: TimeInterval? {
        guard duration > 0, distance > 0 else { return nil }
        return duration / (distance / 500)
    }
    public let averageStrokeRate: UInt8?
    public let averageHeartRate: UInt8?
    public let machine: String?
    /// Which app wrote it — "Hub", "ErgData", or whatever else. Shown because
    /// a history that silently mixes sources is confusing when the numbers
    /// disagree.
    public let source: String?

    public init(
        id: UUID,
        startedAt: Date,
        duration: TimeInterval,
        distance: Double,
        averageStrokeRate: UInt8? = nil,
        averageHeartRate: UInt8? = nil,
        machine: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.distance = distance
        self.averageStrokeRate = averageStrokeRate
        self.averageHeartRate = averageHeartRate
        self.machine = machine
        self.source = source
    }
}

/// Past rows, newest first, with the few sums a screen actually shows.
///
/// The aggregation is here rather than in the HealthKit query because it is
/// arithmetic, not I/O — which means it is tested on the box that has no phone.
public struct RowingHistory: Sendable, Equatable {
    public let items: [RowingHistoryItem]

    public init(items: [RowingHistoryItem]) {
        // Sorted here rather than trusted from the caller: everything below
        // assumes newest first, and a query's sort order is not a guarantee
        // this type can enforce from the outside.
        self.items = items.sorted { $0.startedAt > $1.startedAt }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var totalDistance: Double { items.reduce(0) { $0 + $1.distance } }
    public var totalTime: TimeInterval { items.reduce(0) { $0 + $1.duration } }

    /// Everything on or after a date. Takes the date rather than reaching for
    /// "now", so a test decides what today is.
    public func since(_ date: Date) -> RowingHistory {
        RowingHistory(items: items.filter { $0.startedAt >= date })
    }

    /// The last seven days.
    public func thisWeek(from now: Date) -> RowingHistory {
        since(now.addingTimeInterval(-7 * 24 * 60 * 60))
    }

    /// The best average split, among rows that actually covered ground.
    ///
    /// ! A row with no distance has no split, and `averagePace` returns nil for
    /// it — so those are skipped rather than compared as infinity, which would
    /// make a row that never moved the fastest one on record.
    public var fastestSplit: RowingHistoryItem? {
        items
            .filter { $0.distance > 0 && $0.duration > 0 }
            .min { ($0.averagePace ?? .infinity) < ($1.averagePace ?? .infinity) }
    }

    /// The furthest single row.
    public var longest: RowingHistoryItem? {
        items.filter { $0.distance > 0 }.max { $0.distance < $1.distance }
    }
}

extension RowingHistoryItem {
    /// `"4,250 m"` — a distance with a thousands separator, which is how a
    /// rower reads anything over a kilometre.
    public var distanceText: String {
        let metres = Int(distance.rounded())
        return "\(metres.formatted(.number.grouping(.automatic))) m"
    }
}
