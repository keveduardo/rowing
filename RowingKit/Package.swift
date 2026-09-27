// swift-tools-version: 6.0

import PackageDescription

// The rowing kit: the Concept2 PM5's protocol, one row accumulated from its
// notifications, and the arithmetic over past rows.
//
// **Why this is its own package and not part of BrisalocaKit.** BrisalocaKit is
// the estate's *server* contract — hostnames, credentials, what a Worker
// returns. A rowing machine talking over a radio is not that, and putting the
// two together would mean a watch app carried the estate's whole API surface,
// and with it an auth stack, to read a stroke rate.
//
// **Why it has no dependencies at all.** The three sources import Foundation
// and Observation and nothing else, which is what makes this the piece a
// watchOS target can take whole. See `WORKOUTS.md` §4 — Phase 2 is a watch app
// that connects to the rower itself, and it needs every line of this and none
// of BrisalocaKit.
//
// `.watchOS` is declared so that target can be built. It changes nothing on
// this box, which compiles and tests for the host.
let package = Package(
    name: "RowingKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "RowingKit", targets: ["RowingKit"]),
    ],
    targets: [
        .target(name: "RowingKit"),
        .testTarget(name: "RowingKitTests", dependencies: ["RowingKit"]),
    ]
)
