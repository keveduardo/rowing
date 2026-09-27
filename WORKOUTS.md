# Rowing: the Hub's Workouts module — scope

Scoped 2026-09-27. Read with `SCOPE.md` §1 (the Linux constraint) and §5 (what
becomes an app) — this document assumes both and does not restate them.

**The ask, in Kevin's words:** a Workouts tile in the Hub; connect the rower to
the phone and the watch; a Hub watch app that opens, navigates to Workout and
connects to the rower; rower data and watch biometrics together; and the whole
thing landing in the Fitness app on the phone as one workout. No separate iOS
app — the Hub is the surface.

**Where it stands:** nothing exists. Greps for `HealthKit`, `CoreBluetooth`,
`workout`, `rowing`, `PM5` and `FTMS` return zero hits across this repo and all
46 sibling projects. This is greenfield — no entitlement plumbing, no
peripheral I/O, no backend, and no precedent for any of it.

---

## 1. Three constraints that decide the design

**1. The PM5's Bluetooth is 1:1 — phone *or* watch, never both.** Per the
Concept2 forum, "you can connect your phone OR your watch, but not both at the
same time using Bluetooth"; a Concept2 staff-adjacent poster calls it "a design
choice from Concept2, either to save battery or to prevent conflict handling."
ANT+ is broadcast and allows unlimited listeners, but Apple Watch does not do
ANT+. So the literal ask — rower connected to phone *and* watch — is the one
thing that cannot be built. Exactly one device holds the rower; the other either
receives relayed data or contributes something else.

*Worth ten minutes to verify on the actual machine rather than trust a forum:
connect ErgData on the phone, then try to pair the watch, and see what the PM5
refuses.*

**2. watchOS has no Linux path.** `SCOPE.md` §1 already records this — "No
xtool, no SwiftPM watch target. Watch apps require macOS CI, full stop." §7.2
adds that Xcode Cloud's 25 hours/month may cover it. Nothing in this scope
changes that, and it is the line the phasing below is drawn on.

**3. iOS 26 changed the phone half completely.** WWDC25 session 322,
*"Track workouts with HealthKit on iOS and iPadOS"*: workout sessions and the
workout builder now run on iPhone. Apple's words — *"If you're already running
workouts in an app on Apple Watch, you'll be able to use the same code on iPhone
and iPad with only minimal changes… use the workout builder to save the workout
in HealthKit."* An iPhone app can now create a real workout in Fitness with **no
Apple Watch and no watchOS app**. This is new enough that it is worth stating
plainly: the thing Kevin assumed needed a watch app does not, for the phone half.

---

## 2. The phasing

**Phase 1 — from kevg10, no Mac.** A Workouts tile in the Hub. The phone
connects to the PM5 over Bluetooth, shows live rower data, and saves one rowing
workout to Health, which is what makes it appear in Fitness. Rower metrics ride
along as workout metadata. **No heart rate** (decided 2026-09-27) — the iPhone
has no HR sensor, so HR is Phase 2's business.

**Phase 2 — needs the Mac.** The Hub Watch app: open it, tap Workout, connect to
the rower. The watch holds the PM5 link and runs the workout session, so watch
heart rate and rower data land in a single workout natively. The phone mirrors
the session for live stats on both screens. This is Apple's own recommended
architecture (WWDC23 *"Build a multidevice workout app"*, and WWDC25 repeats it —
*"If you have a Watch app, be sure to start the workout there… and mirror the
workout to the iPhone"*), and it is the version Kevin described. It is second
because it is the version that cannot be built from this box.

Phase 1 is not a throwaway: the PM5 client, the byte parsing and the metric
model are all shared, and Phase 2 swaps which device owns the radio.

---

## 3. Phase 1, concretely

### The module split is forced by the repo's own convention — and it comes out right

`HubCore` must build on Linux, so it can hold **no CoreBluetooth**. That sounds
like an obstacle and is actually the correct decomposition:

| Lives in | What | Testable on kevg10 |
|---|---|---|
| `HubCore` | **The PM5 protocol parser and its models**: `Data` bytes → typed metrics | **yes — this is the point** |
| `Hub` (SwiftUI) | `CBCentralManager`, peripheral discovery, notifications | no, Apple-only |

**Built 2026-09-27** — `Apps/Hub/Sources/HubCore/PM5.swift` and
`Tests/HubCoreTests/PM5Tests.swift`, 16 tests, all passing;
`Apps/Hub/Sources/Hub/PM5Radio.swift` for the `CBCentralManager`, which builds
clean under `xtool dev build` and which `swift test` cannot see by construction.

Two things a reader of the radio should know:

- **`bluetooth-central` and `NSBluetoothAlwaysUsageDescription` are now in
  `Apps/Hub/Info.plist`.** The usage string is not a nicety: iOS terminates the
  app the instant a `CBCentralManager` is created without it, so the tile cannot
  run without that key.
- **CoreBluetooth is not annotated for Swift 6.** It hands out `CBCentralManager`,
  `CBPeripheral` and `CBCharacteristic`, none of them `Sendable`, so the strict
  region checker rejects passing them into `MainActor.assumeIsolated`. The fix
  in `PM5Radio.swift` is to extract the `Sendable` values first wherever
  possible (a `CBManagerState`, a UUID string, a `Data` payload) and to use one
  narrow, documented `@unchecked Sendable` box only where a callback has to call
  back into the peripheral. The safety argument is real rather than convenient:
  every callback arrives on the main queue, because that is the queue the
  manager was created with, and `assumeIsolated` asserts it. Do not "fix" this
  by dropping `@MainActor` — that trades a sound annotation for hand-marshalled
  callbacks and loses the ordering that makes a stroke's data follow the status
  it belongs to.

The models went into `HubCore` alongside the parser rather than into
`BrisalocaKit` as this document first said. `BrisalocaKit` is the estate's
*server* contract — hostnames, credentials, what a Worker returns. The PM5 is a
device talking over a radio, and splitting a `Data` parser from the structs it
returns across a package boundary would have been artificial for no gain. Both
are pure Swift with no Apple frameworks, so both are exercised by `swift test`.

The parser is pure Swift over `Data`. Every characteristic in the Concept2 spec
is a fixed byte layout, so the entire protocol — 0x0031 status, 0x0032 additional
status, 0x0035 stroke data, 0x0039 end-of-workout summary — is unit-testable on
kevg10 against canned byte arrays, in the same style as the existing
`HubCoreTests`. Only the radio is untestable here. This is exactly the shape the
repo already argues for in `Apps/Hub/Package.swift:18`: logic in the testable
target, framework glue in the view target.

### Which services to read

Two options, and the choice is a real one:

- **FTMS (standard, `0x1826`), Rower Data `0x2AD1`.** Standardised, simpler,
  and the PM5 supports it on firmware >150. Fewer metrics.
- **Concept2's proprietary service (`CE060030-…`), characteristics 0x0031–0x003D.**
  Everything: drag factor, drive length, drive/recovery time, peak and average
  drive force, work per stroke, force curve, interval splits, and HR relay.

**Recommendation: the Concept2 service.** It is documented in Concept2's own
[PM5 Bluetooth Smart Interface Definition](https://www.concept2.co.uk/files/pdf/us/monitors/PM5_BluetoothSmartInterfaceDefinition.pdf)
(revision 1.30, free), it is what ErgData itself uses, and it is the only one
that has the per-stroke data that makes an app worth having over the PM5's own
screen. FTMS would be the fallback if the proprietary service proves awkward.

Note what the spec gives for free: `0x0032` carries **heart rate**, relayed from
whatever strap is paired to the PM5. This is the cheapest HR in the whole
document — no extra BLE link, no extra permission, no watch app. The strap pairs
to the rower, the PM5 puts HR in the same stream the app is already reading, and
one strap feeds both the PM5's own screen and the app.

Given §4, this deserves revisiting. HR was deferred on 2026-09-27 to Phase 2 on
the understanding that Phase 2 meant "needs the Mac". It now also means the Hub
leaves the Linux pipeline — and a ~$50 strap buys the same HR for roughly a day's
work inside Phase 1. That is a decision to re-take, not one this document should
quietly reverse.

### Saving the workout

Two sub-options. **1a is the MVP and does not need iOS 26.**

**1a — build the workout at the end and save it.** `HKWorkout(type: .rowing, …)`
plus `healthStore.save()` has existed since iOS 8, so this works at the Hub's
current `.iOS(.v17)`. No deployment-target change, no live session, no crash
recovery. The workout appears in Fitness.

**The ring question resolves in 1a's favour** *(checked against Apple's docs
2026-09-27)*. `HKWorkout`'s own reference says: *"In iOS. No additional work is
necessary. Workout objects automatically contribute to both the Move and
Exercise rings. The Exercise ring increases by the workout's total duration, and
the Move ring increases by the number of calories in the associated active
energy burned samples."* So a plainly-saved workout does move the rings, and the
earlier worry here — that 1a might land in Fitness without them — was wrong.
Apple does still say to prefer the builder ("always use the workout builder API
to create and save a workout"), so treat that as best practice rather than as a
gate on 1a.

**1b — a live session.** `HKWorkoutSession` is **iOS 17+, not iOS 26** — it is
`HKLiveWorkoutBuilder`, the piece that actually collects, that arrived on iOS in
26. So the session API has been available all along; only the collection is new.
1b buys live metrics, a Lock Screen Live Activity, and crash recovery through
the new scene delegate.

Build 1a first. Promote to 1b once the rowing itself is proven, and treat the
deployment-target bump to `.iOS(.v26)` as its own small decision.

### Entitlement and Info.plist

**Verified, not assumed — HealthKit signing from Linux is unblocked.**
`tools/ci/distsign.mjs:264-325` extracts the `Entitlements` dict *out of the
provisioning profile itself* with `plistlib` and hands it to
`rcodesign sign --entitlements-xml-file`. So whatever the profile declares is
what the signature carries. Enabling HealthKit on the App ID for
`com.brisaloca.hub` in the developer portal and regenerating the profile should
flow straight through with no repo-side signing change. This is the single
biggest Phase 1 risk and it is a portal task, not a code one.

Repo-side, the Hub's `Info.plist` currently has **no usage-description strings at
all**. Phase 1 needs:

- `NSHealthShareUsageDescription` — to read workouts back
- `NSHealthUpdateUsageDescription` — to save the rowing workout
- `NSBluetoothAlwaysUsageDescription` — to talk to the PM5

Plus `bluetooth-central` in `UIBackgroundModes` if the connection must survive
the phone locking mid-row — that array currently holds only `fetch`
(`Apps/Hub/Info.plist`), so the row is a real edit rather than a formality.

### The tile

A `WorkoutTile` in `HubScreen.body` and a `WorkoutStore` in `HubCore`, following
the existing pattern exactly: `@MainActor @Observable`, injected `tokens` and
`transport`, a `Phase` enum, and `refresh()` wired into the three existing
refresh paths (`.refreshable`, `.task`, `onChange(of: scenePhase)`) — see
`HubScreen.swift:62-102`. Visual convention is `minHeight: 140`, radius 14, an SF
Symbol at size 22, `chevron.right` top-trailing.

One genuine difference from every existing tile: **this tile is not backed by a
Worker.** The others are reads against a service in the catalogue. This one is a
local BLE session with HealthKit on the end. It still needs a `Phase` state
because it can fail — no rower in range, Bluetooth off, Health permission
refused — and the Hub's existing rule applies unchanged: render the failure, never
a blank tile (`HubScreen.swift:6-11`).

### What is *not* Phase 1

No new Worker, no D1, no service in `Service.swift`. Nothing about rowing needs a
server; it is a local radio and a local Health write. History can come back out of
HealthKit via `HKQuery.predicateForSamples` over the workout window. Revisit only
if per-stroke detail and force curves prove worth syncing — those have no home in
HealthKit (custom *quantity types* cannot be created) and would need somewhere else
to live.

---

## 4. Phase 2 — the watch app, and the problem it creates

**The data path is clean and Apple-sanctioned.** Watch app connects to the PM5
directly as BLE central, runs `HKWorkoutSession` for heart rate, and calls
`startMirroringToCompanionDevice()`. The phone receives it through
`workoutSessionMirroringStartHandler` and can push rower metrics back with
`sendToRemoteWorkoutSession(data:)`. One workout, both data streams, live on both
screens. This is precisely Kevin's picture: watch app → Workout → connect to
rower.

Two field-reported caveats to design around from the start, both documented in
Apple's developer forums:

- `sendToRemoteWorkoutSession` **sometimes silently hangs** — reported at roughly
  5% of workouts, unreproducible, affecting watchOS 10/11 with iOS 17/18, and
  fixable only by restarting both devices.
- It throws *"remote session delegate is not set up"* if called before
  `session.prepare()`. Prepare first; retry the send.

Mitigation is to treat mirroring as an enhancement, not the spine: the watch
records and saves on its own, and the phone is a viewer. A hung mirror costs the
phone's live view, not the workout.

**The expensive part is not the Swift — it is the pipeline, and xtool cannot be
bent into it.** The Hub today is a plain SwiftPM package plus `xtool.yml`, with
no `.xcodeproj` (it is generated on macOS and gitignored). A watchOS app normally
ships *inside* the iOS bundle as a nested `Watch/App.app` carrying
`WKCompanionAppBundleIdentifier`, built and archived together by Xcode.

This was checked against xtool's source at **tag 1.20.1 — the version installed
here** — rather than inferred from its docs. The gap is architectural, in five
independent places, not a missing flag:

1. **No bundle type for it.** `Plan.ProductType` has exactly two cases,
   `.application` and `.appExtension`, and their placement is hardcoded — the app
   at the bundle root, an appex at `PlugIns/<product>.appex`. Nothing can emit
   `Watch/Foo.app`.
2. **One platform, hardcoded to iOS**, for the app and every extension:
   the generated builder package declares `platforms: [.iOS(…)]` only.
3. **`xtool.yml` has no way to express it.** The whole schema is `version`, `orgID`,
   `bundleID`, `product`, `infoPath`, `entitlementsPath`, `iconPath`, `resources`,
   `extensions`, `skipLSP`. `extensions:` is the only nesting mechanism and its
   type is fixed as an appex.
4. **Provisioning never registers a watchOS App ID.** The registration path
   enumerates only `PlugIns` and `Extensions` for `.appex` folders and passes
   `platform: .init(.ios)` as a literal. A `Watch/Foo.app` would get no App ID, no
   profile and no entitlements.
5. **Entitlements only ever land on the root app** — an open bug
   ([#131](https://github.com/xtool-org/xtool/issues/131)) that already mis-signs
   today's iOS appexes, so there is no path for a watch extension's distinct
   entitlements.

The maintainer's only public statement on watchOS is in the 1.20.0 release notes,
framing it as hypothetical: *"if a future update of xtool added watchOS
support…"*. All 282 issues and PRs were searched — none mention it.

**So the injection idea is closed.** `resources:` does copy to the app bundle
root, so a directory named `Watch` could physically be placed there — but on the
evidence above it would be provisioned and signed wrongly and would not survive
App Store validation. That leaves:

1. **Move the Hub to a Mac-built, Xcode-project pipeline.** The realistic path.
   Correct and boring, and it costs the Hub its Linux build — including its share
   of the weekly TestFlight rebuild that currently runs unattended. This is the
   real price of Phase 2, and it is a price on the *whole Hub*, not on rowing.
2. **Contribute watchOS support to xtool.** Items 1 and 3 above are the two the
   maintainer has never started; it is the kind of gap worth asking him about
   directly, since the 1.20.0 note shows he has thought about it. Not a plan, an
   option.

One genuinely surprising finding, recorded as **unverified**: the default xtool
SDK install keeps all of Xcode.app, so `WatchOS27.0.sdk` is already on this disk,
the toolchain ships `arm64_32-apple-watchos` Swift interfaces, and both
`swiftc -print-target-info` and the shipped LLD 21.1.6 accept the target. The
platform is unpatched and unwired, and the one naive compile attempt failed on
`SwiftShims`. "Possible with significant hand-rolling" is a hypothesis, not a
finding — do not budget on it.

Do not start Phase 2 without picking one.

---

## 5. Open source worth using

| Project | License | What it is worth |
|---|---|---|
| [JaapvanEkris/openrowingmonitor](https://github.com/JaapvanEkris/openrowingmonitor) | GPL-3.0 | The best open reference for the PM5 protocol. **It also emulates a PM5** — a fake rower to develop against with no machine in the room. GPL, so reference it, do not copy it. |
| [ptwobrussell/Concept2-SDK](https://github.com/ptwobrussell/Concept2-SDK) | MIT | Swift PM5 BLE parsing. A lightly-used fork: CocoaPods only, no SwiftPM, and only stroke rate and distance demonstrated. Useful for byte-parsing shapes; the parser gets rewritten either way. |
| [christophercotton/concept2_rower](https://github.com/christophercotton/concept2_rower) | MIT | A Swift 5 port of the above, as a working iOS app. |
| [Concept2 PM5 Bluetooth spec](https://www.concept2.co.uk/files/pdf/us/monitors/PM5_BluetoothSmartInterfaceDefinition.pdf) | — | Authoritative, free, and the thing to read first. |
| Apple WWDC25 #322 + its demo app | — | The Phase 1 skeleton, working code. |
| Apple *"Build a multidevice workout app"* (WWDC23) | — | The Phase 2 skeleton. |
| [laberning/openrowingmonitor](https://laberning.github.io/openrowingmonitor/) | GPL-3.0 | The upstream Pi project; the PM5 emulator on a Raspberry Pi is the useful part. |

**Explicitly not a shortcut:** Concept2's own ErgData app already does much of
this — but its Watch app does not connect to the PM5 directly either, so it is
not a model to copy for the watch half.

---

## 6. Risks and open questions

1. **HealthKit capability on the App ID** — must be enabled in the portal before
   any of Phase 1 can be tested on a device. The signing path is verified
   (`distsign.mjs`), the portal step is not.
2. **The PM5 1:1 claim is from a forum, not from Concept2.** Ten minutes with the
   actual machine settles it, and it decides whether Phase 2's watch-primary
   design is even available.
3. **Rings behaviour under 1a** — a plain saved `HKWorkout` versus a session-built
   one. Test the cheap path before paying for the deployment-target bump.
4. **Phase 2 costs the Hub its Linux build.** xtool cannot produce a watch
   companion (§4, verified at 1.20.1), so a watch app means moving the Hub to a
   Mac-built Xcode pipeline — including giving up its part of the unattended
   weekly TestFlight rebuild. Unpicked, and it is a price on the whole Hub rather
   than on rowing.
5. **No rower attached to kevg10, ever.** The parser is unit-testable; the radio
   is not. Every BLE change is a build-and-walk-over-to-the-rower loop. The
   openrowingmonitor PM5 emulator is the mitigation.
6. **Background BLE is a connection, not an execution window.** `bluetooth-central`
   keeps the *link* across a locked screen, which is what a 30-minute row needs —
   but Apple is explicit that an app *"can't run forever"*: each wake gives
   *"around 10 seconds"*, the system may terminate the app to reclaim memory, and
   *"apps that spend too much time executing in the background can be throttled
   back by the system or killed."* The recovery mechanism is Core Bluetooth's
   state preservation and restoration, which means the radio layer has to opt in
   via `CBCentralManagerOptionRestoreIdentifierKey` and handle
   `centralManager(_:willRestoreState:)` — and, in a scene-based app,
   `launchOptions` is always nil so the identifier must be persisted and passed
   in on every launch rather than read back at startup. Design the session so a
   termination loses the *display*, never the workout. Separately, Apple notes
   *"health data is not normally available while a device is locked"*, so the UI
   should degrade rather than show stale numbers.
7. **Per-stroke and force-curve data have no HealthKit home.** Custom workout
   metadata takes `NSString`/`NSNumber`/`NSDate` only, so summaries fit and
   detailed series do not. Decide where they live, or accept losing them.

## 7. Decisions taken

**2026-09-27:**

1. **The monitor is a PM5** (Kevin, 2026-09-27) — so Bluetooth is available and
   none of this needs a retrofit kit.
2. **No heart rate in Phase 1.** HR arrives with the watch app. The phone half
   ships without it rather than buying a chest strap to bridge the gap.
   **Re-open this one** — it was taken when Phase 2 meant only "needs the Mac",
   and §4 has since raised that price (§3, the strap note).
3. **Its own document.** This file, linked from `SCOPE.md`.
4. **The Hub is the surface — no separate iOS app.** The tile is the entry point,
   matching the estate's existing rule that the Hub holds modules and standalone
   apps are for what earns its own icon.
5. **Concept2's proprietary service over FTMS**, for the per-stroke metrics
   (recommendation, not yet tested).

**Still open:**

6. **Whether Phase 2 is worth its price (§4).** It is no longer a question of
   *how* to build a watch companion — xtool cannot, and the Hub would have to
   move to a Mac pipeline. The live question is whether a watch app is worth
   that, or whether a BLE strap and Phase 1 are enough. Settle this before
   Phase 2 is scheduled at all.
7. Whether to promote Phase 1 from 1a to 1b, and the `.iOS(.v26)` bump that
   implies.
8. Which household Mac, and whether Remote Login is available on it — already
   open in `SCOPE.md` §8.5-6, and Phase 2 cannot start without it.
