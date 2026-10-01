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
            ControlsPage(end: end)
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
    var power: UInt16?
    var heartRate: Double?

    init(distance: Double, elapsed: TimeInterval, power: UInt16?, heartRate: Double?) {
        self.distance = distance
        self.elapsed = elapsed
        self.power = power
        self.heartRate = heartRate
    }

    @MainActor
    init(store: WorkoutStore, session: RowSession) {
        let live = store.live
        self.init(
            distance: live.distance,
            elapsed: live.elapsed,
            power: live.power,
            // The watch's own heart rate, falling back to a strap on the PM5.
            heartRate: session.heartRate ?? live.heartRate.map(Double.init)
        )
    }
}

/// Four large tiles: what a rower glances at mid-stroke.
///
/// (Kevin, 2026-09-29: "the four boxes make them bigger and look better. Get
/// rid of /500 at the top" — then "swap out spm for heart rate data".) Each
/// tile is a colour, a number sized to fill it, and a word — the Workout app's
/// way of making a metric findable at a glance. Stroke rate is still recorded
/// with the row; it is just not on the screen.
struct MetricsPage: View {
    let values: LiveValues

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                tile("\(Int(values.distance.rounded()))", "METERS", .cyan)
                tile(PM5.Format.elapsed(values.elapsed), "TIME", .yellow)
            }
            GridRow {
                tile(values.heartRate.map { "\(Int($0.rounded()))" } ?? "—", "BPM", .red, icon: "heart.fill")
                tile(values.power.map { "\($0)" } ?? "—", "WATTS", .orange)
            }
        }
        .padding(.horizontal, 2)
    }

    private func tile(_ value: String, _ label: String, _ tint: Color, icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(tint)
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Swiped to from the metrics: End.
///
/// ! NOTHING ELSE LIVES HERE (Kevin, 2026-09-30: "remove it in 1.0.1"). Until
/// 1.0.1 this page also listed the rower's payload counters — "0032 0/412 ·
/// 19 B" — which found the missing pace and stroke rate on 2026-09-29 and then
/// shipped in 1.0, where a customer reads them as gibberish. The radio still
/// counts (`PM5Radio.payloadStats`); a debugger can read them.
struct ControlsPage: View {
    let end: () -> Void

    var body: some View {
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
