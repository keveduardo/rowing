import RowingKit
import SwiftUI

/// The whole app, one screen at a time: Row → connecting → rowing → saved.
///
/// **When a row ends.** Either the PM5 says so — a set piece finishes and it
/// sends its summary, and the workout saves on its own — or the person taps
/// End, which closes the row from what the store accumulated. A "Just Row"
/// piece never ends itself, so End is the normal way out of one.
struct RowingScreen: View {
    let radio: PM5Radio
    let store: WorkoutStore
    let session: RowSession

    /// Deep water — the colour the Hub's rowing tile used.
    static let water = Color(red: 0.10, green: 0.60, blue: 0.68)

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                start
            case .starting:
                ProgressView("Starting…")
            case .running:
                RowingLiveView(radio: radio, store: store, session: session, end: end)
            case .saving:
                ProgressView("Saving…")
            case .saved(let row):
                SavedView(row: row, done: done)
            case .discarded:
                message("Nothing to save", detail: "No row was recorded.")
            case .failed(let why):
                // "Not authorized" is Health permission, and the fix is in
                // Settings — saying so is the difference between a dead end
                // and a thirty-second fix (Kevin's first try, 2026-09-29).
                message("Couldn't record", detail: why.localizedCaseInsensitiveContains("authoriz")
                    ? "Allow Health for Rowing: iPhone Settings → Health → Data Access & Devices → Rowing → Turn On All."
                    : why)
            }
        }
        // The PM5 ended the piece itself: save without waiting for a tap.
        .onChange(of: store.phase) { _, phase in
            if phase == .finished, session.phase == .running {
                Task { await finish() }
            }
        }
    }

    private var start: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.rower")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Self.water)
            Button {
                Task {
                    store.reset()
                    await session.start()
                    if session.phase == .running { radio.scan() }
                }
            } label: {
                Text("Row").font(.title3.bold()).frame(maxWidth: .infinity)
            }
            .tint(Self.water)
            Text("Turn the rower on first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done", action: done)
        }
    }

    private func end() {
        // A row the monitor never ended is closed from what was accumulated.
        store.finishNow()
        Task { await finish() }
    }

    private func finish() async {
        let row = store.phase == .finished ? store.latest : nil
        await session.finish(with: row)
        radio.stop()
    }

    private func done() {
        store.reset()
        session.dismiss()
    }
}

/// The live row, laid out the way Apple's own Workout app is: swipe right for
/// the controls, where End lives, and the metrics are the page it opens on.
///
/// ! END IS ONE SWIPE AWAY ON PURPOSE (Kevin, 2026-09-29: "for ending the row
/// can it require a side swipe like apple's native watch workout apps"). A
/// button on the metrics page sat under a sweaty wrist for the whole row.
private struct RowingLiveView: View {
    let radio: PM5Radio
    let store: WorkoutStore
    let session: RowSession
    let end: () -> Void
    @State private var page = LivePage.metrics

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(stats: radio.payloadStats.values.sorted { $0.id < $1.id }, end: end)
                .tag(LivePage.controls)
            Group {
                if radio.phase.isConnected {
                    MetricsPage(values: LiveValues(store: store, session: session))
                } else {
                    connection
                }
            }
            .tag(LivePage.metrics)
        }
        .tabViewStyle(.page)
    }

    private var connection: some View {
        VStack(spacing: 8) {
            switch radio.phase {
            case .scanning, .connecting, .idle:
                ProgressView()
            default:
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(radio.phase.label)
                .font(.footnote)
                .multilineTextAlignment(.center)
            if case .failed = radio.phase {
                Button("Try again") { radio.scan() }
            }
        }
    }
}

enum LivePage: Hashable { case controls, metrics }

/// The numbers a metrics page draws, lifted out of the store and the session
/// so a render can supply its own.
struct LiveValues {
    var distance: Double
    var elapsed: TimeInterval
    var strokeRate: UInt8
    var power: UInt16?
    var heartRate: Double?

    init(distance: Double, elapsed: TimeInterval, strokeRate: UInt8, power: UInt16?, heartRate: Double?) {
        self.distance = distance
        self.elapsed = elapsed
        self.strokeRate = strokeRate
        self.power = power
        self.heartRate = heartRate
    }

    @MainActor
    init(store: WorkoutStore, session: RowSession) {
        let live = store.live
        self.init(
            distance: live.distance,
            elapsed: live.elapsed,
            strokeRate: live.strokeRate,
            power: live.power,
            // The watch's own heart rate, falling back to a strap on the PM5.
            heartRate: session.heartRate ?? live.heartRate.map(Double.init)
        )
    }
}

/// Four large tiles and the heart rate: what a rower glances at mid-stroke.
///
/// (Kevin, 2026-09-29: "the four boxes make them bigger and look better. Get
/// rid of /500 at the top.") Each tile is a colour, a number sized to fill it,
/// and a word — the Workout app's way of making a metric findable at a glance.
struct MetricsPage: View {
    let values: LiveValues

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                Text(values.heartRate.map { "\(Int($0.rounded()))" } ?? "—")
                    .monospacedDigit()
                Text("BPM").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.headline)
            .foregroundStyle(.red)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    tile("\(Int(values.distance.rounded()))", "METERS", .cyan)
                    tile(PM5.Format.elapsed(values.elapsed), "TIME", .yellow)
                }
                GridRow {
                    tile(values.strokeRate > 0 ? "\(values.strokeRate)" : "—", "SPM", .green)
                    tile(values.power.map { "\($0)" } ?? "—", "WATTS", .orange)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func tile(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Swiped to from the metrics: End, and what the rower has sent.
struct ControlsPage: View {
    let stats: [PM5Radio.PayloadStat]
    let end: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button(action: end) {
                    VStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 26, weight: .bold))
                            .frame(width: 62, height: 62)
                            .background(Color.red.opacity(0.25), in: Circle())
                            .foregroundStyle(.red)
                        Text("End").font(.headline)
                    }
                }
                .buttonStyle(.plain)
                if !stats.isEmpty {
                    // A payload the parser refused shows as "0/412 · 19 B" — the
                    // count and the length are what a fix needs to know.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ROWER DATA").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        ForEach(stats) { s in
                            Text("\(s.id)  \(s.decoded)/\(s.seen) · \(s.lastLength) B")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(s.decoded == s.seen ? Color.secondary : Color.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// What was just saved.
private struct SavedView: View {
    let row: RowingWorkout?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Label("Saved to Health", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
            if let row {
                Text("\(Int(row.distance.rounded())) m").font(.title2.bold())
                Text(PM5.Format.elapsed(row.duration)).font(.body.monospacedDigit())
                if let pace = row.averagePace {
                    Text("\(PM5.Format.pace(pace)) /500m")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button("Done", action: done)
        }
    }
}
