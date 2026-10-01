# Rowing — App Store Connect listing

Drafted 2026-09-30, in the shape of `Apps/Soccer/APPSTORE.md`. Everything in
the tables and quoted blocks below was written into App Store Connect through
the API the same day (app `6817373000`, version 1.0); this file is the record
of what was sent and the place to edit it before sending again.

Distribution: **Unlisted, requested 2026-10-01.** It was submitted as public
(Kevin's first answer) and he changed his mind the same night: "make sure the
other submitted apps tonight also were requested to be unlisted". The request
form went to Apple after the submission; once approved the app can never be
made public again. As answered: a single household, Internally, 4 people,
1 organization, audience "Members of one household", category Other —
"Fitness (workout recording)", Unmanaged, 4 devices, USA. Free.

**Submitted 2026-10-01 01:18 UTC, build 11.** Release is MANUAL: after approval
nothing is on the store until Release is pressed. Two things the API could not
do were done on the website: the App Privacy answer ("Data Not Collected",
published) and the **Regulated Medical Device declaration** (App Information →
"No") — a Health & Fitness app cannot be added to a submission without it, and
the refusal names it only in the 409's `meta.associatedErrors`.

---

## App information

| Field | Value |
|---|---|
| Name (30) | Brisaloca Rowing |
| Subtitle (30) | Indoor rows, saved to Fitness |
| Category | Health & Fitness (secondary: Sports) |
| Content rights | Does not contain third-party content |
| Age rating | "None"/No to everything except **Health or Wellness Topics: yes** (it is a workout recorder) |
| Copyright | 2026 Kevin Amaya |
| Privacy policy URL | https://brisaloca.com/rowing/privacy/ |
| Support URL | https://brisaloca.com/rowing/support/ |
| Marketing URL | (blank) |
| Price | Free |
| Release | Manual, after approval |

The subtitle and the name deliberately carry no Concept2 mark; the description
names the hardware it works with and says the app is independent.

## Promotional text (170)

Tap Row, start pulling, and your Concept2 row is on your wrist — meters, time, heart rate and watts — then saved to Apple Health as a rowing workout.

## Description (4000)

Brisaloca Rowing records your row on a Concept2 rowing machine as an Apple Watch workout. No phone is needed while you row.

Tap Row on your watch and start pulling. The watch connects to the rower's PM5 Performance Monitor over Bluetooth and shows what you glance at mid-stroke, in four large tiles:

• Meters, from the rower
• Time, from the rower
• Heart rate, from your watch
• Watts, from the rower

When a set piece ends on the PM5, the row saves itself. For Just Row, swipe right and tap End, the way you end a workout in Apple's own Workout app.

SAVED TO HEALTH
Each row is saved to Apple Health as a rowing workout, with the distance the rower measured and the heart rate and active energy your watch recorded. It appears in Fitness on your iPhone and counts toward your Activity rings.

WATCH ONLY
There is no iPhone app to open and no account to create. The row keeps recording with your wrist down.

PRIVATE
No sign-in, no ads, no analytics, no server. Nothing leaves your watch except what you allow into Apple Health.

REQUIREMENTS
A Concept2 rowing machine with a PM5 Performance Monitor, and an Apple Watch running watchOS 11 or later.

Concept2 and PM5 are trademarks of Concept2, Inc. Brisaloca Rowing is an independent app and is not affiliated with or endorsed by Concept2.

## Keywords (100)

rowing,rower,erg,ergometer,concept2,pm5,indoor rowing,rowerg,workout,heart rate,watts,meters

## What's New

First release (the field does not exist on a first version).

---

## App Review information

**Sign-in required: no.**

**Notes (4000):**

> Brisaloca Rowing is a watch-only app. The iOS target is the stub container
> every watch-only app ships in; there is no iPhone app and nothing to open on
> the phone.
>
> HARDWARE. The app records a row on a Concept2 rowing machine and needs the
> machine's PM5 Performance Monitor, which it connects to over Bluetooth LE to
> read distance, time, pace, power and stroke rate. It has no other function.
>
> WITHOUT THE HARDWARE you will see: the start screen with a Row button; on
> tapping Row, the Health permission sheet, then a workout session starting and
> the app searching for the rower. Swipe right and tap End to stop; with no row
> recorded it says "Nothing to save" and writes nothing to Health.
>
> WITH THE HARDWARE the watch shows four tiles (meters, time, heart rate,
> watts), and on End — or when the PM5 finishes a set piece — saves a rowing
> workout to Health. We are glad to send a screen recording of a full row on
> request.
>
> HEALTHKIT. Writes: the workout, active energy, rowing distance. Reads: heart
> rate and active energy, only to display them during the row. Health data is
> not sent anywhere; the app has no server and makes no network requests.
>
> BACKGROUND MODE. workout-processing, so the workout session and the Bluetooth
> link to the rower stay alive with the wrist down.
>
> No account, no sign-in, no purchases, no ads, no analytics.

**Contact:** the same contact as Soccer's review detail (copied by API).

⚠️ **Both earlier apps got "Guideline 2.1 — Information Needed" and were asked
for a device recording** (memory: asc-rejection-resubmit). For a hardware app
that is close to certain. A recording of one real row on the watch, linked in
these notes before submitting, saves a round trip.

---

## App Privacy (the questionnaire — website only, the API cannot set it)

**Data collection: No, we do not collect data from this app.** The app has no
server and no network code; Health data stays in Health. This matches
brisaloca.com/rowing/privacy.

## Screenshots

Apple Watch is the only family a watch-only app needs. Uploaded: the live
metrics page at 410 × 502 (Apple Watch Ultra), from the `render` job of
`rowing-watch.yml` — the real SwiftUI in a simulator, showing the numbers from
the first real row (2026-09-29). Screenshots from the watch itself during a row
would be better and can replace it.

## Known before submitting

- **Build 11** is the build attached. The End page in it still shows the
  "ROWER DATA" decode counters — a diagnostic readout. Harmless, but it is what
  a customer would see. **Removed in 1.0.1** (2026-09-30), which is built and
  in TestFlight and is submitted once 1.0 is approved and released — a new
  version cannot be created while 1.0 is in review. What's New for it: "The
  End page shows only End."
- The app always saves a **rowing** workout, so the listing claims the rower
  only — not the SkiErg or BikeErg, though they carry the same monitor.
