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
            RowingScreen(radio: radio, store: store, session: session)
                .task {
                    // One notification, two readers: the radio keeps the latest
                    // value of each metric, and the store adds the row up.
                    radio.onEvent = { store.apply($0) }
                }
        }
    }
}
