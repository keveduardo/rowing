# Rowing: the Hub's Workouts module — scope

Scoped 2026-09-27. Read with `SCOPE.md` §1 (the Linux constraint) and §5 (what
becomes an app) — this document assumes both and does not restate them.

**The ask, in Kevin's words:** a Workouts tile in the Hub; connect the rower to
the phone and the watch; a Hub watch app that opens, navigates to Workout and
connects to the rower; rower data and watch biometrics together; and the whole
thing landing in the Fitness app on the phone as one workout. No separate iOS
app — the Hub is the surface.

**Where this started:** nothing existed. Greps for `HealthKit`, `CoreBluetooth`,
`workout`, `rowing`, `PM5` and `FTMS` returned zero hits across this repo and all
46 sibling projects — greenfield, with no entitlement plumbing, no peripheral
I/O, no backend, and no precedent for any of it.

**Kevin's priorities (2026-09-27), which outrank anything below:** the Hub stays
as it is — no significant change, at most a new tile for health and fitness. The
big part is **the Apple Watch app** that starts the connection to the rower for a
workout. That settled the pipeline: the watch app is a **standalone watch app**
that does not touch the Hub's build or bundle at all (§4, §7.6).

**Where it stands, 2026-09-27.** Phase 1 is **code-complete** and Phase 2 has
started; §3 lists what exists and §7 what is still open. The honest summary of the gap:
**none of it has run against real hardware**, and the one build that reached
App Store Connect's door — a local release build — was never uploaded.

Three things have to be true before Phase 1 is testable on a phone, and two of
them are not yet:

| | |
|---|---|
| HealthKit capability on `com.brisaloca.hub` | **not enabled** — §3, and waiting on review |
| A TestFlight build carrying this code | **not uploaded** — §3 |
| The PM5's 1:1 Bluetooth claim | **unverified** — §1, and ten minutes with the rower |

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

**Phase 2 — needs the Mac, and is the main event.** A watch app: open it, tap
Workout, connect to the rower. The watch holds the PM5 link and runs the workout
session, so watch heart rate and rower data land in a single workout natively,
and Health carries it to Fitness on the phone with no phone code involved. It is
a **standalone** watch app (§4), so the phone does *not* mirror the session —
Apple's multidevice architecture (WWDC23 *"Build a multidevice workout app"*)
needs the watch app bundled inside an iPhone app, and bundling it into the Hub
is the change to the Hub that Kevin ruled out. It is second only because it is
the part that cannot be built from this box.

Phase 1 is not a throwaway: the byte parsing, the store and the metric model
live in `RowingKit`, which the watch app takes whole. Whether the Hub keeps its
own phone-side rower connection once the watch exists is open (§7.10).

---

## 3. Phase 1, concretely

### The module split is forced by the repo's own convention — and it comes out right

`HubCore` must build on Linux, so it can hold **no CoreBluetooth**. That sounds
like an obstacle and is actually the correct decomposition:

| Lives in | What | Testable on kevg10 |
|---|---|---|
| `RowingKit` | **The PM5 protocol, the store, the history** — `Data` in, structs out | **yes — this is the point** |
| `HubCore` | The estate's own stores, which know nothing about rowing | yes |
| `Hub` (SwiftUI) | `CBCentralManager`, HealthKit, the views | no, Apple-only |

The parser started in `HubCore` and moved to `RowingKit` when Phase 2 began —
§4 has the two reasons, one of which is a trap. The decomposition itself was
right from the start: the protocol never needed a radio, so the whole of it is
tested here.

**Built 2026-09-27** — `RowingKit` is its own package, the rest is in the Hub:

| File | What |
|---|---|
| `RowingKit/PM5.swift` | The byte layouts and the enums |
| `RowingKit/WorkoutStore.swift` | One row, accumulated from the notification stream |
| `RowingKit/RowingHistory.swift` | Past rows, and the sums a screen shows over them |
| `RowingKit/MirrorMessage.swift` | The watch-to-phone wire format (§4) |
| `Hub/PM5Radio.swift` | The `CBCentralManager` |
| `Hub/HealthStore.swift` | Writes finished rows to Health and reads past ones back |
| `Hub/WorkoutScreen.swift` | The Workouts tile and the screen behind it |

```bash
swift test --package-path RowingKit   # 47 tests — the module a watch app shares
swift test --package-path Apps/Hub    # 21 tests — the estate's own stores
xtool dev build                       # in Apps/Hub — clean, no warnings
```

`RowingKit` is its own package rather than a second target inside `Apps/Hub`,
for both reasons in §4: xtool refuses a package with two library products, and a
watch target should not carry the estate's API surface. It has no dependencies
at all, which is what makes it shareable.

**Three `Info.plist` keys are now load-bearing**, and all three fail by
terminating rather than by erroring: `NSBluetoothAlwaysUsageDescription`
(a missing one kills the app the moment a `CBCentralManager` is made),
`NSHealthUpdateUsageDescription` and `NSHealthShareUsageDescription` (a missing
one raises inside `requestAuthorization`, and an Objective-C exception is not
something `try` can catch). The health pair covers the two halves — Update for
writing a workout, Share for reading workouts back.

**What the Hub deliberately does not ask for.** Read access to *heart rate* is
not requested, even though a history with heart rate in it would be nicer. The
Hub already holds the average and peak when it saves a row, so it records them
in its own metadata and reads them back from there — asking Health for the same
numbers again would mean a second, far more alarming permission prompt for data
the app already had. The cost is worth stating: heart rate appears on rows the
Hub wrote and not on rows ErgData wrote, because those carry no such metadata.
The list names the source on any row that is not the Hub's own, so a mixed
history says so rather than silently disagreeing with itself.

**The HealthKit capability is not on the app record yet, and nothing ships
until it is.** `com.brisaloca.hub` carries `IN_APP_PURCHASE` and
`PUSH_NOTIFICATIONS` and nothing else — checked against the live account
2026-09-27. Without it a build runs the whole rowing half and fails the Health
half, and reports it as "Health access is off — allow it in Settings", which
would send anyone looking in the wrong place.

This does not need the portal. `tools/ci/enable-capability.mjs` — renamed from
`enable-push.mjs` on 2026-09-27, when HealthKit became its third capability —
turns a capability on through the ASC API and retires the profile so the next
build issues one carrying the entitlement:

```bash
node tools/ci/enable-capability.mjs healthkit com.brisaloca.hub --dry-run  # what it would do
node tools/ci/enable-capability.mjs healthkit com.brisaloca.hub            # do it
```

Both paths were exercised on 2026-09-27 — HealthKit reports it *would* turn on,
and push reports already on, which is the idempotence the script promises.
**The write has not been run.** It changes state on the Apple account and may
not ship ahead of review.

**The parsers were cross-checked against other implementations and a hardware
capture of a real PM5, which found two bugs worth keeping the reasoning for.**
Both were in the spec rather than in the reading of it:

1. **`0x0033`'s `lastSplitTime` is hundredths, not the tenths its table says.**
   A capture shows this characteristic carrying a raw 2492 while `0x0037`
   carried 249 for the same split at the same 100 m mark — a ratio of exactly
   ten, against an elapsed time of 24.89 s. The spec's own column is a known
   defect; reading it as written reports a split longer than the workout
   containing it. The trap inside the trap: `splitAveragePace`, three fields
   earlier in the same payload, *is* hundredths and *is* labelled correctly.
2. **`0x0031`'s `workoutDuration` is only a time when `durationType` is
   `.time`.** The spec's "(if time, 0.01 sec lsb)" qualifier is load-bearing:
   a captured status from a 100 m distance piece carries `durationType` 0x80
   with a raw 100, which is 100 metres. Scaling it unconditionally renders a
   distance target as a hundredth of itself.

Both are now pinned by tests that assert the wrong reading *and* the right one,
so the difference is unmissable rather than silent. A third bug was the store's
own: it trusted whichever notification arrived last, so a status arriving
zeroed as a piece ended would have saved half an hour of rowing as an empty
workout. It keeps a high-water mark now.

**The release build is verified, the upload is not.** `node tools/ci/rebuild.mjs
--app hub --no-upload --no-sign --force` was run on 2026-09-27 and produced
`Apps/Hub/xtool/Hub.ipa` with the plist bump reverted afterwards, leaving the
tree as it was. The ipa carries `CFBundleIdentifier com.brisaloca.hub`, build
25, `MinimumOSVersion 17.0`, `bluetooth-central` among its background modes, all
three usage strings, and a binary that links both `CoreBluetooth.framework` and
`HealthKit.framework`. That is a real release build of this code.

What it does *not* prove: the upload path, which has still never run for any
app on this box, and signing, which `--no-sign` skipped. Note the unsigned ipa
has no `DTPlatformName` — those keys are stamped by `distsign.mjs` at signing
time, so their absence here is expected rather than a fault.

`rebuild.mjs` correctly declines to rebuild the Hub on its own terms — the live
build 24 has 88 days left against a 30-day threshold — so shipping new work
takes `--force`, which exists for exactly this.

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

The models live in `RowingKit` with the parser, not in `BrisalocaKit` as this
document first said. `BrisalocaKit` is the estate's *server* contract —
hostnames, credentials, what a Worker returns. The PM5 is a device talking over
a radio, and splitting a `Data` parser from the structs it returns across a
package boundary would have been artificial for no gain.

The parser is pure Swift over `Data`. Every characteristic in the Concept2 spec
is a fixed byte layout, so the entire protocol — 0x0031 status, 0x0032 additional
status, 0x0035 stroke data, 0x0039 end-of-workout summary — is unit-testable on
kevg10 against canned byte arrays (`RowingKitTests`). Only the radio is
untestable here: logic in the testable package, framework glue in the view
target, as the rest of the Hub already does.

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
whatever strap is paired to the PM5. The code already uses it: `WorkoutStore`
tracks live, average, max and recovery HR from `0x0032`/`0x0039` and saves them
as workout metadata, so a strap paired to the PM5 puts HR into Phase 1 rows
today. What it does not do is write HR *samples*, which is what Fitness charts —
that would need HealthKit write access to heart rate. With the watch app now the
main event (§7.7), the watch's own HR is the intended source and this stays a
side benefit.

### Saving the workout

> **Where this stands:** built, as **1a** below — `HealthStore` saves a
> finished row through `HKWorkoutBuilder`, and a tap on the finished card is
> what does it. The one thing outstanding is the HealthKit capability on the app
> record (§3): an ASC API call, not a portal job, but account state that no
> commit can make. Note that `distanceRowing` is **iOS 18+** while the Hub still
> supports iOS 17, so on an older phone a row saves with its energy and
> metadata but no distance sample — raising the Hub's floor for one health type
> would cost every other tile its iOS 17 support.

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

**1b — a live session.** Likely **iOS 26**: `HKWorkoutSession` appears on iOS
from 17, but there it only *receives* a session mirrored from a watch. Starting
a primary session on the iPhone, with `HKLiveWorkoutBuilder` collecting, is what
WWDC25 #322 presents as new. *(An earlier version of this section said iOS 17+;
check the SDK headers before relying on either.)* 1b buys live metrics, a Lock
Screen Live Activity, and crash recovery through the new scene delegate.

Build 1a first. Promote to 1b once the rowing itself is proven, and treat the
deployment-target bump to `.iOS(.v26)` as its own small decision.

### Entitlement and Info.plist

**Verified, not assumed — HealthKit signing from Linux is unblocked.**
`tools/ci/distsign.mjs:264-325` extracts the `Entitlements` dict *out of the
provisioning profile itself* with `plistlib` and hands it to
`rcodesign sign --entitlements-xml-file`. So whatever the profile declares is
what the signature carries. Enabling HealthKit on the App ID for
`com.brisaloca.hub` (via `enable-capability.mjs`, above) and regenerating the
profile should flow straight through with no repo-side signing change.

Repo-side, `Apps/Hub/Info.plist` now carries all three usage strings
(`NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`,
`NSBluetoothAlwaysUsageDescription`) and `bluetooth-central` alongside `fetch`
in `UIBackgroundModes`, so the connection survives the phone locking mid-row.

### The tile

A `WorkoutTile`, fourth in `HubScreen`'s grid, and a `WorkoutStore` in
`RowingKit`. The store is `@MainActor @Observable` with a `Phase` enum like the
others, but takes no `tokens` or `transport` — nothing about rowing talks to the
estate. Visual convention matches the other tiles: `minHeight: 140`, radius 14,
an SF Symbol at size 22, `chevron.right` top-trailing.

**It is additive and nothing else in the Hub changed** — no existing tile or
screen was touched. The permission prompts are lazy: Health asks when the
workout screen first opens, Bluetooth only on "Find my rower". Someone who never
taps the tile sees the Hub exactly as before.

One genuine difference from every existing tile: **this tile is not backed by a
Worker.** It still needs a `Phase` state because it can fail — no rower in
range, Bluetooth off, Health permission refused — and the Hub's existing rule
applies unchanged: render the failure, never a blank tile.

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

**The injection idea was closed for the wrong reason. It is open again.** An
earlier pass concluded that a watch app could not be injected into the
xtool-built ipa, on evidence about *xtool's* signer — its hardcoded `.appex`
placement and its [#131](https://github.com/xtool-org/xtool/issues/131)
inability to carry per-bundle entitlements. Both findings are sound. Both are
beside the point, because **xtool does not sign this app.**

`rebuild.mjs:341` calls `buildIpa(app, { sign: false })` — xtool produces an
*unsigned* ipa — and `:345` hands it to `distsign.mjs`, which signs with
`rcodesign` using the entitlements read out of the profile (`distsign.mjs:264`).
The signer is ours, it is a script on this box, and per-bundle entitlements are
within its reach. The `resources:` route into `xtool.yml` was always the wrong
lever; the right one was never xtool at all.

So the realistic options, corrected:

1. **Build the watch app on macOS CI, inject and sign it here.** The Hub keeps
   its Linux build, the rowing module keeps being tested here, and the watch
   app is the only thing that needs a Mac — once, per change to it, rather than
   on every Hub build. What it needs, all of it bounded:
   - `HubWatch.app` built by Xcode on a macOS runner, plus its own profile.
   - The watch bundle id registered under the **watchOS** platform — an ASC API
     call, and `ensureProfile` is already parameterised by bundle id.
   - `ensureProfile` extended for a watchOS profile; `signIpa` extended to sign
     the nested bundle inside-out with its own entitlements, then the outer app.
   - Nesting at `Payload/Hub.app/Watch/HubWatch.app`, with
     `WKCompanionAppBundleIdentifier` pointing home.
   Items 2–4 are perhaps a hundred lines in `distsign.mjs`, none of it
   speculative in kind — the file already unpacks, patches, signs and repacks an
   ipa. What is genuinely unknown is the last one: whether Apple's validation
   accepts a hand-assembled Watch bundle. That cannot be settled on this box.
2. **Move the Hub to a Mac-built, Xcode-project pipeline.** Correct and boring,
   and it costs the Hub its Linux build — including its share of the weekly
   TestFlight rebuild that currently runs unattended. A price on the *whole
   Hub*, not on rowing, and options 1 and 4 both avoid it.
3. **Contribute watchOS support to xtool.** Items 1 and 3 above are the two the
   maintainer has never started; worth asking him about directly, since the
   1.20.0 note shows he has thought about it. Not a plan, an option.

4. **A standalone watch app, outside the Hub entirely.** *(Added 2026-09-27;
   none of the options above had considered it.)* The watch app connects to the
   rower, runs the session and saves the workout to Health, and Health carries it
   to Fitness on the phone. It has its own bundle id and App Store record, is
   built on a Mac or Xcode Cloud, and shares only `RowingKit` with the Hub. It
   costs the phone's live view during a row, because mirroring launches *"your
   companion iPhone app"* and a standalone watch app has none. It gains
   everything Kevin asked to protect: the Hub's build, bundle, signing and
   weekly rebuild are untouched, and the riskiest open question in option 1 —
   whether Apple accepts a hand-assembled `Watch/` bundle — disappears.

**Decided 2026-09-27: option 4** (Kevin). Options 1 and 3 remain on record as
the way back to live stats on the phone, if that ever matters more than keeping
the Hub unchanged. Option 2 is ruled out: it changes how the whole Hub is built.

One genuinely surprising finding, recorded as **unverified**: the default xtool
SDK install keeps all of Xcode.app, so `WatchOS27.0.sdk` is already on this disk,
the toolchain ships `arm64_32-apple-watchos` Swift interfaces, and both
`swiftc -print-target-info` and the shipped LLD 21.1.6 accept the target. The
platform is unpatched and unwired, and the one naive compile attempt failed on
`SwiftShims`. "Possible with significant hand-rolling" is a hypothesis, not a
finding — do not budget on it.

### What is already in place for Phase 2

Done 2026-09-27, and verifiable on this box:

- **`RowingKit` is its own package** (`RowingKit/`), with no dependencies at all
  — Foundation and Observation, nothing else. The PM5 protocol, `WorkoutStore`
  and `RowingHistory` moved out of `HubCore` and out of `Apps/Hub`, because
  xtool refuses a package with more than one library product ("Multiple library
  products were found") *and* because a watch target should not carry the
  estate's API surface and an auth stack to read a stroke rate. This is the
  piece a watch app takes whole.
- **`.watchOS(.v11)` is declared** on both packages, so a watch target is
  declarable. It changes nothing here, which builds for the host.
- **The watch-to-phone wire format exists and is tested** —
  `RowingKit/Sources/RowingKit/MirrorMessage.swift`. It carries only what
  HealthKit's own mirroring does *not*: pace, rate, watts and the machine.
  **Unused under option 4**, which has no mirroring. It stays because it costs
  nothing and is exactly what options 1 or 3 would need.

### What the Mac session must produce

Not yet written. For option 4:

1. An Xcode project or XcodeGen spec holding **one watch-only app target**. There
   is no Hub target in it and no companion relationship, so the Hub's Linux
   pipeline never sees it.
2. The watch app built against `RowingKit` as a path dependency — no
   `BrisalocaKit`, which is the whole reason that package exists.
3. The watch app's `Info.plist`: `WKApplication`, `WKWatchOnly`, and
   `WKBackgroundModes` with `workout-processing` — which is what lets an active
   session keep running with the wrist down. `workout-processing` is the only
   workout value watchOS has ever had; there is no older `workout` spelling.
   Plus `NSBluetoothAlwaysUsageDescription` and the two Health usage strings.
4. Its own bundle id (not under `com.brisaloca.hub`), registered for watchOS,
   with **HealthKit** enabled on it, and its own App Store Connect record.
5. An Xcode Cloud workflow, or a documented manual archive, so later changes do
   not each need an afternoon on the Mac.

---

## 5. Open source worth using

| Project | License | What it is worth |
|---|---|---|
| [JaapvanEkris/openrowingmonitor](https://github.com/JaapvanEkris/openrowingmonitor) | GPL-3.0 | The best open reference for the PM5 protocol. **It also emulates a PM5** — a fake rower to develop against with no machine in the room. GPL, so reference it, do not copy it. |
| [ptwobrussell/Concept2-SDK](https://github.com/ptwobrussell/Concept2-SDK) | MIT | Swift PM5 BLE parsing. A lightly-used fork: CocoaPods only, no SwiftPM, and only stroke rate and distance demonstrated. Useful for byte-parsing shapes; the parser gets rewritten either way. |
| [christophercotton/concept2_rower](https://github.com/christophercotton/concept2_rower) | MIT | A Swift 5 port of the above, as a working iOS app. |
| [Concept2 PM5 Bluetooth spec, Revision 1.30](https://web.archive.org/web/2024id_/https://www.concept2.co.uk/files/pdf/us/monitors/PM5_BluetoothSmartInterfaceDefinition.pdf) | — | Authoritative, free, and the thing to read first — **but read §3's two corrections with it.** ! Concept2's own URLs for this now 404 (the live one redirects to a page-not-found, and search results still point at the dead one); this Wayback copy is what the parser was transcribed from. |
| Apple WWDC25 #322 + its demo app | — | The Phase 1 skeleton, working code. |
| Apple *"Build a multidevice workout app"* (WWDC23) | — | The Phase 2 skeleton. |
| [laberning/openrowingmonitor](https://laberning.github.io/openrowingmonitor/) | GPL-3.0 | The upstream Pi project; the PM5 emulator on a Raspberry Pi is the useful part. |

**Explicitly not a shortcut:** Concept2's own ErgData app already does much of
this — but its Watch app does not connect to the PM5 directly either, so it is
not a model to copy for the watch half.

---

## 6. Risks and open questions

1. **HealthKit capability on the App ID — open, and the next action.** Not a
   portal job: `tools/ci/enable-capability.mjs` does it through the ASC API and
   retires the profile so the next build carries the entitlement. Dry-run only
   as of 2026-09-27; the write is waiting on review (§3).
2. **The PM5 1:1 claim is from a forum, not from Concept2.** Ten minutes with the
   actual machine settles it. Under option 4 the watch holds the link either
   way, so it no longer decides the design — it decides whether the Hub's own
   phone-side connection could get in the watch's way (§7.10).
3. ~~Rings behaviour under 1a~~ — **resolved 2026-09-27.** `HKWorkout`'s own
   reference says *"In iOS. No additional work is necessary. Workout objects
   automatically contribute to both the Move and Exercise rings."* So a plainly
   saved workout does move them, and this is no longer a reason to prefer 1b
   (§3). Worth an eyeball on the first real row, but not a blocker.
4. ~~Phase 2 costs the Hub its Linux build~~ — **closed 2026-09-27.** Option 4
   (§4) builds the watch app as its own app on a Mac and never touches the
   Hub's pipeline, so neither this price nor option 1's hand-assembled-bundle
   risk applies.
5. **No rower attached to kevg10, ever.** The parser is unit-testable; the radio
   is not. Every BLE change is a build-and-walk-over-to-the-rower loop. The
   openrowingmonitor PM5 emulator is the mitigation.
6. **Background BLE is a connection, not an execution window.** `bluetooth-central`
   keeps the *link* across a locked screen, which is what a 30-minute row needs —
   but Apple is explicit that an app *"can't run forever"*: each wake gives
   *"around 10 seconds"*, the system may terminate the app to reclaim memory, and
   *"apps that spend too much time executing in the background can be throttled
   back by the system or killed."* The recovery mechanism is Core Bluetooth's
   state preservation and restoration, which `PM5Radio` already opts into via
   `CBCentralManagerOptionRestoreIdentifierKey` and
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
   ships without it rather than buying a chest strap to bridge the gap. (In
   practice the code already records a PM5-relayed HR as metadata if a strap
   happens to be paired to the rower — §3, the strap note.)
3. **Its own document.** This file, linked from `SCOPE.md`.
4. **The Hub is the surface — no separate iOS app.** The tile is the entry point,
   matching the estate's existing rule that the Hub holds modules and standalone
   apps are for what earns its own icon.
5. **Concept2's proprietary service over FTMS**, for the per-stroke metrics
   (recommendation, not yet tested).

6. **The Phase 2 pipeline is option 4: a standalone watch app** (Kevin,
   2026-09-27). The Hub stays as it is; the watch app is its own app, built on a
   Mac, sharing only `RowingKit`. The cost, accepted: no live stats on the
   phone during a row (§4).
7. **Phase 2 is worth doing — it is the main part** (Kevin, 2026-09-27). The
   watch app that starts the rower connection is what this work is for; the Hub
   gets at most a tile.

**Still open:**

8. Whether to promote Phase 1 from 1a to 1b, and the `.iOS(.v26)` bump that
   implies. Largely moot now that the watch is the main surface — and a
   deployment-target bump is exactly the kind of Hub-wide change Kevin ruled out.
9. Which household Mac, and whether Remote Login is available on it — already
   open in `SCOPE.md` §8.5-6, and Phase 2 cannot start without it. Option 4
   needs a Mac only for the watch app — never for a Hub release — and once an
   Xcode Cloud workflow exists, only for changes to the project itself. A
   borrowed machine on a weekend is plausibly enough.
10. **What the Hub tile does once the watch app exists.** Today it can connect
    the phone to the rower and save a row itself. With the watch doing that, the
    tile could shrink to history only (it already reads past rows from Health),
    which also removes any chance of the phone holding the PM5's one connection
    when the watch wants it (§6.2). Leaving it as is costs nothing until the
    watch app ships; decide then.
