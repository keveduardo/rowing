// Is the Rowing watch app's TestFlight build close enough to expiry to replace?
//
//   node tools/ci/rowing-due.mjs [bundle id, default com.brisaloca.rowing]
//
// ! WHY THIS EXISTS (2026-09-29). Every other app here is rebuilt by
// brisaloca-rebuild.timer on kevg10, which asks App Store Connect how long the
// live build has left and uploads a new one at 30 days. Rowing cannot be in
// that loop — it is built by Xcode on a GitHub macOS runner, not by xtool — so
// without this its builds would simply lapse after 90 days, the first around
// 2026-12-28, and the watch app would stop opening.
//
// Same rule, same code: `decide()` from needs-rebuild.mjs, so the two robots
// cannot disagree about what "due" means. Run by the `due` job of
// .github/workflows/rowing-watch.yml on a schedule; it writes `due=true|false`
// to $GITHUB_OUTPUT, and only `due=true` starts the macOS build and upload.
// A failure to ask exits non-zero — an unanswered question must not read as
// "not due".
import { appendFileSync } from 'node:fs';
import { loadKey, mintToken, findApp, listBuilds } from './asc.mjs';
import { decide } from './needs-rebuild.mjs';

// Swim (2026-09-30) is the same kind of app with the same problem, so it
// passes its own bundle id rather than getting a copy of this file.
const BUNDLE_ID = process.argv[2] || 'com.brisaloca.rowing';

const token = await mintToken(loadKey());
const app = await findApp(token, BUNDLE_ID);
if (!app) throw new Error(`no App Store Connect record for ${BUNDLE_ID}`);

const verdict = decide(await listBuilds(token, app.id));
console.log(`${BUNDLE_ID}: ${verdict.rebuild ? 'due' : 'not due'} — ${verdict.reason}`);
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `due=${verdict.rebuild}\n`);
}
