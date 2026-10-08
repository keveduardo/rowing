// App Store Connect, from this box, with no Xcode and no Mac.
//
// ⚠️ THE UPLOAD PATH HAS NEVER BEEN RUN, and it still has not. It needs an ASC
// API key (APPLE-ACCOUNT.md step 3).
//
// The attribute spellings were re-checked on 2026-09-22 against two independent
// sources — the WWDC25 session's worked example and a working Go client with
// tests — and ONE WAS WRONG: buildUploadFiles wanted `assetType: "ASSET"` plus
// `uti: "com.apple.ipa"`, where this file had guessed `"BUILD"` and no uti.
// That would have failed the first upload. `asc.test.mjs` now pins every body
// against a stubbed Apple, so a re-guess is a red test rather than a bad run.
// What remains unproven is Apple's behaviour, not the shapes: whether it
// accepts these bodies, and what it does after the commit.
//
// The wrong way to read this file: as tested code. The right way: as the exact
// place to look when the first upload fails.

import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const ASC_HOST = 'https://api.appstoreconnect.apple.com';
export const CONFIG_DIR = join(homedir(), '.config', 'appstoreconnect');

const enc = new TextEncoder();

function b64url(input) {
  const bytes = typeof input === 'string' ? enc.encode(input) : new Uint8Array(input);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ---------------------------------------------------------------- credentials
// Two files, neither in git, both created by hand once (APPLE-ACCOUNT.md):
//
//   ~/.config/appstoreconnect/config.json     { "keyId": "...", "issuerId": "..." }
//   ~/.config/appstoreconnect/private_keys/AuthKey_<keyId>.p8
//
// Apple lets the .p8 be downloaded exactly once. Losing it means revoking the
// key and making another, which is annoying rather than fatal — this says so
// because the failure mode of treating it as irreplaceable is hoarding it.
export function loadKey({ configDir = CONFIG_DIR, env = process.env } = {}) {
  const cfgPath = join(configDir, 'config.json');
  let cfg = {};
  try {
    cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));
  } catch (e) {
    if (e.code !== 'ENOENT') throw new Error(`${cfgPath} is not readable JSON: ${e.message}`);
  }
  const keyId = env.ASC_KEY_ID ?? cfg.keyId;
  const issuerId = env.ASC_ISSUER_ID ?? cfg.issuerId;
  if (!keyId || !issuerId) {
    throw new Error(
      `no App Store Connect key configured.\n` +
        `  expected ${cfgPath} to hold {"keyId": "...", "issuerId": "..."}\n` +
        `  (or ASC_KEY_ID / ASC_ISSUER_ID in the environment)\n` +
        `  values come from App Store Connect -> Users and Access -> Integrations -> Team Keys`,
    );
  }
  const p8Path = join(configDir, 'private_keys', `AuthKey_${keyId}.p8`);
  let pem;
  try {
    pem = readFileSync(p8Path, 'utf8');
    const mode = statSync(p8Path).mode & 0o777;
    if (mode & 0o077) throw new Error(`${p8Path} is mode ${mode.toString(8)} — chmod 600 it`);
  } catch (e) {
    if (e.code === 'ENOENT') throw new Error(`no private key at ${p8Path} (keyId ${keyId})`);
    throw e;
  }
  return { keyId, issuerId, pem, p8Path };
}

// -------------------------------------------------------------------- token
// ES256, and the same trap the APNs spike hit: workerd refuses to sign unless
// the hash is named at call time, while Node's WebCrypto fills it in. Two
// constants on purpose — one for importing (the curve), one for signing (the
// hash).
const KEY_ALG = { name: 'ECDSA', namedCurve: 'P-256' };
const SIGN_ALG = { name: 'ECDSA', hash: 'SHA-256' };

// Apple's ceiling is 20 minutes; well inside it, because a clock-skewed token is
// a 401 that reads like a bad key.
export const TOKEN_TTL_S = 15 * 60;

export async function mintToken({ keyId, issuerId, pem }, { now = Math.floor(Date.now() / 1000), ttl = TOKEN_TTL_S } = {}) {
  // atob is load-bearing: without it the "DER" is the base64 TEXT (184 bytes for
  // a 138-byte key) and OpenSSL answers `ASN.1 wrong tag`, which names nothing
  // that leads here. This exact line was retyped from the APNs spike's importP8
  // with the atob dropped, and only running it caught that.
  const body = pem.replace(/\\n/g, '\n').replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, KEY_ALG, false, ['sign']);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: issuerId, iat: now, exp: now + ttl, aud: 'appstoreconnect-v1' }));
  const sig = await crypto.subtle.sign(SIGN_ALG, key, enc.encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64url(sig)}`;
}

// ---------------------------------------------------------------------- api
export async function api(path, { token, method = 'GET', body } = {}) {
  const res = await fetch(`${ASC_HOST}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    // Apple's errors are precise and worth keeping whole: `detail` names the
    // field, which is the entire debugging experience for a request shape that
    // has never been run before.
    const detail = json?.errors?.map((e) => `${e.status} ${e.code}: ${e.detail}`).join('; ') ?? text;
    throw new Error(`${method} ${path} -> ${res.status}: ${detail}`);
  }
  return json;
}

/// The app record's id, which every other call needs. Null when the record does
/// not exist yet — a distinct, expected state: APPLE-ACCOUNT.md step 4.
export async function findApp(token, bundleId) {
  const res = await api(`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`, { token });
  const app = res.data?.[0];
  return app ? { id: app.id, name: app.attributes?.name } : null;
}

/// Builds, newest first. The fields that matter are the two dates and the
/// version, which is CFBundleVersion.
export async function listBuilds(token, appId) {
  const res = await api(
    `/v1/builds?filter[app]=${appId}&limit=50&sort=-uploadedDate` +
      `&fields[builds]=version,uploadedDate,expirationDate,processingState`,
    { token },
  );
  return res.data ?? [];
}

/// Every build number Apple has RECEIVED for the app, including uploads still
/// processing — which `listBuilds` does not show. Numbering from `listBuilds`
/// alone reused 20 for the Hub on 2026-09-25 while the first 20 was still
/// processing, and Apple refused the second (ITMS-90189 Redundant Binary
/// Upload). Best effort: an error here leaves the number to `listBuilds`.
export async function uploadedNumbers(token, appId) {
  try {
    const res = await api(`/v1/apps/${appId}/buildUploads?limit=200`, { token });
    return (res.data ?? []).map((u) => Number(u?.attributes?.cfBundleVersion)).filter(Number.isFinite);
  } catch {
    return [];
  }
}

// ------------------------------------------------------------------- upload
/// The four-step dance: reserve the upload, reserve the file, PUT the bytes to
/// the URLs Apple hands back, commit. Each step's output feeds the next, which
/// is why this is one function rather than four the caller has to sequence.
export async function uploadBuild({ token, appId, ipaPath, shortVersion, bundleVersion, platform = 'IOS' }) {
  const bytes = readFileSync(ipaPath);
  const fileName = ipaPath.split('/').pop();

  // 1. The upload. ⚠️ attribute spellings to confirm at first run.
  const upload = await api('/v1/buildUploads', {
    token,
    method: 'POST',
    body: {
      data: {
        type: 'buildUploads',
        attributes: { cfBundleShortVersionString: shortVersion, cfBundleVersion: bundleVersion, platform },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    },
  });
  const uploadId = upload.data.id;

  // 2. The file. `assetType: "ASSET"` with a `uti`, CORRECTED 2026-09-22 from
  // `"BUILD"` and no uti, which this file had guessed. Two independent sources
  // agree: the WWDC25 session's worked example (fileName/fileSize/assetType
  // ASSET/uti com.apple.ipa) and a working Go client whose tests assert the
  // same spellings. A `.pkg` (macOS) would be `com.apple.pkg`.
  const file = await api('/v1/buildUploadFiles', {
    token,
    method: 'POST',
    body: {
      data: {
        type: 'buildUploadFiles',
        attributes: { fileName, fileSize: bytes.length, assetType: 'ASSET', uti: 'com.apple.ipa' },
        relationships: { buildUpload: { data: { type: 'buildUploads', id: uploadId } } },
      },
    },
  });
  const fileId = file.data.id;
  const operations = file.data.attributes?.uploadOperations ?? [];
  if (operations.length === 0) {
    throw new Error(`no uploadOperations came back for ${fileName} — nothing to PUT`);
  }

  // 3. The bytes, in the order given, sliced by offset/length. The URLs are
  // pre-signed: sending an Authorization header here is the classic way to make
  // a working upload fail.
  for (const op of operations) {
    const slice = bytes.subarray(op.offset ?? 0, (op.offset ?? 0) + (op.length ?? bytes.length));
    const headers = Object.fromEntries((op.requestHeaders ?? []).map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method ?? 'PUT', headers, body: slice });
    if (!res.ok) {
      throw new Error(`chunk PUT at offset ${op.offset} -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
    }
  }

  // 4. Commit: `uploaded: true`, and NO checksum. Confirmed 2026-09-22 against
  // the same two sources — the Go client's tests assert a checksum is not sent
  // ("ASC accepts the upload without one and rejects some checksum
  // encodings"). Note the screenshot/asset flow DOES take a
  // `sourceFileChecksum`; this one does not, so a reader coming from that
  // documentation should not add it here.
  await api(`/v1/buildUploadFiles/${fileId}`, {
    token,
    method: 'PATCH',
    body: { data: { type: 'buildUploadFiles', id: fileId, attributes: { uploaded: true } } },
  });

  return { uploadId, fileId, chunks: operations.length, bytes: bytes.length };
}
