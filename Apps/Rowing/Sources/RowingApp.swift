import RowingKit
import SwiftUI

/// Rowing: a watch app that connects to the Concept2 rower and records the row
/// as a workout in Health.
///
/// Watch-only by design (`WORKOUTS.md` §4, option 4). There is no iPhone app:
/// the workout reaches Fitness on the phone through Health, and the Hub stays
/// exactly as it is.
@main
struct RowingApp: App {
    @State private var radio = PM5Radio()
    @State private var store = WorkoutStore()
    @State private var session = RowSession()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let page = RenderDemo.page {
                RenderDemo(page: page)
            } else {
                screen
            }
            #else
            screen
            #endif
        }
    }

    private var screen: some View {
        RowingScreen(radio: radio, store: store, session: session)
            .task {
                // One notification, two readers: the radio keeps the latest
                // value of each metric, and the store adds the row up.
                radio.onEvent = { store.apply($0) }
            }
    }
}

#if DEBUG
/// The live pages with fixed numbers, for screenshots from a simulator — which
/// has no rower and no Health. Launched as `-renderDemo metrics|controls` by
/// the `render` job of rowing-watch.yml. Debug builds only: a TestFlight build
/// cannot be put into this mode.
struct RenderDemo: View {
    static var page: LivePage? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-renderDemo"), i + 1 < args.count else { return nil }
        return args[i + 1] == "controls" ? .controls : .metrics
    }

    @State var page: LivePage

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(stats: [
                .init(id: "0031", seen: 2413, decoded: 2413, lastLength: 19),
                .init(id: "0032", seen: 2413, decoded: 0, lastLength: 19),
                .init(id: "0033", seen: 2413, decoded: 2413, lastLength: 20),
            ], end: {})
            .tag(LivePage.controls)
            // The numbers from Kevin's first row, 2026-09-29.
            MetricsPage(values: LiveValues(distance: 4058, elapsed: 1207, strokeRate: 22, power: 106, heartRate: 135))
                .tag(LivePage.metrics)
        }
        .tabViewStyle(.page)
    }
}
#endif
