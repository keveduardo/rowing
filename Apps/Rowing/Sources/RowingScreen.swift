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
                message("Couldn't record", detail: why)
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

/// The numbers while rowing, or the connection's state until there are some.
private struct RowingLiveView: View {
    let radio: PM5Radio
    let store: WorkoutStore
    let session: RowSession
    let end: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if radio.phase.isConnected {
                metrics
            } else {
                connection
            }
            Spacer(minLength: 0)
            Button("End", role: .destructive, action: end)
        }
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
            heartRateLine
        }
    }

    private var metrics: some View {
        let live = store.live
        return VStack(spacing: 4) {
            Text(PM5.Format.pace(live.pace))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RowingScreen.water)
            Text("/500m").font(.caption2).foregroundStyle(.secondary)
            HStack {
                figure("\(Int(live.distance.rounded()))", unit: "m")
                figure(PM5.Format.elapsed(live.elapsed), unit: "time")
            }
            HStack {
                figure(live.strokeRate > 0 ? "\(live.strokeRate)" : "—", unit: "spm")
                figure(live.power.map { "\($0)" } ?? "—", unit: "W")
            }
            heartRateLine
        }
    }

    /// The watch's own heart rate, falling back to a strap paired to the PM5.
    @ViewBuilder private var heartRateLine: some View {
        if let bpm = session.heartRate ?? store.live.heartRate.map(Double.init) {
            Label("\(Int(bpm.rounded()))", systemImage: "heart.fill")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.red)
        }
    }

    private func figure(_ value: String, unit: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.body.monospacedDigit().weight(.semibold))
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
