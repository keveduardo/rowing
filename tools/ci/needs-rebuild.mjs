// Does a TestFlight build need replacing, and what should the next build number
// be? Pure decision logic, so it can be tested with fixtures rather than by
// waiting eighty days.
//
// The question this answers is not "has it been 80 days" — that is a timer
// guessing at the truth. It is "when does the live build expire", asked of the
// service that knows, which is why a run that is not needed does nothing at all.

// TestFlight builds live 90 days. Rebuilding at 30 days left leaves two whole
// missed weekly runs before an app would actually lapse, which is the margin the
// failure deserves: the consequence of being late is that three households stop
// receiving updates with no warning at all.
export const THRESHOLD_DAYS = 30;

const DAY_MS = 24 * 60 * 60 * 1000;

/// ASC's build `version` attribute IS CFBundleVersion (a string, and sometimes
/// not a number if someone once typed a date in). Anything unparseable is
/// ignored rather than crashed on: the next number only has to be greater than
/// the numbers we can read.
export function nextBuildNumber(builds) {
  let max = 0;
  for (const b of builds) {
    const n = Number.parseInt(b?.attributes?.version ?? '', 10);
    if (Number.isFinite(n) && n > max) max = n;
  }
  return String(max + 1);
}

/// `builds` is the ASC list, newest first or not — we sort. Returns a decision,
/// not a boolean, because the reason ends up in the journal and a rebuild that
/// cannot say why it happened is indistinguishable from one that fired by
/// accident.
export function decide(builds, { now = Date.now(), thresholdDays = THRESHOLD_DAYS } = {}) {
  const dated = builds
    .map((b) => ({
      id: b.id,
      version: b?.attributes?.version ?? null,
      uploadedDate: Date.parse(b?.attributes?.uploadedDate ?? '') || 0,
      expiration: Date.parse(b?.attributes?.expirationDate ?? '') || 0,
      state: b?.attributes?.processingState ?? null,
    }))
    .sort((a, b) => b.uploadedDate - a.uploadedDate);

  const next = nextBuildNumber(builds);

  if (dated.length === 0) {
    return { rebuild: true, reason: 'no build has ever been uploaded', next, live: null };
  }

  const live = dated[0];

  // Fail toward rebuilding. An expiration date we cannot read is exactly the
  // unknown that this job exists to eliminate, and a spare build costs one
  // upload while a missed one costs the app.
  if (!live.expiration) {
    return { rebuild: true, reason: `newest build (${live.id}) has no readable expirationDate`, next, live };
  }

  const daysLeft = (live.expiration - now) / DAY_MS;
  if (daysLeft <= 0) {
    return { rebuild: true, reason: `build ${live.version ?? live.id} expired ${Math.abs(daysLeft).toFixed(1)} days ago`, next, live };
  }
  if (daysLeft <= thresholdDays) {
    return { rebuild: true, reason: `build ${live.version ?? live.id} expires in ${daysLeft.toFixed(1)} days`, next, live };
  }
  return { rebuild: false, reason: `build ${live.version ?? live.id} has ${daysLeft.toFixed(1)} days left`, next, live };
}

// ------------------------------------------------------------------ CLI
//   node needs-rebuild.mjs <builds.json> [--threshold-days N]
// Exists so the decision can be run by hand against a saved API response, which
// is also how the fixtures in needs-rebuild.test.mjs were checked.
if (import.meta.url === `file://${process.argv[1]}`) {
  const { readFileSync } = await import('node:fs');
  const [file, ...rest] = process.argv.slice(2);
  if (!file) {
    console.error('usage: needs-rebuild.mjs <builds.json> [--threshold-days N]');
    process.exit(2);
  }
  const daysIdx = rest.indexOf('--threshold-days');
  const thresholdDays = daysIdx === -1 ? THRESHOLD_DAYS : Number(rest[daysIdx + 1]);
  const raw = JSON.parse(readFileSync(file, 'utf8'));
  console.log(JSON.stringify(decide(raw.data ?? raw, { thresholdDays }), null, 2));
}
