// APNs push over HTTP/2 — pure Node (node:crypto + node:http2), no npm deps.
// Sends native "new open shift" alerts to the phones registered in Supabase `devices`.
//
// Secrets (env): APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, and the .p8 as either
//   APNS_KEY_P8   = the PEM text of AuthKey_<KEYID>.p8  (how GitHub Actions passes it), or
//   APNS_KEY_PATH = a file path to the .p8               (local testing).
// The .p8 is a SECRET — never logged. This module reads it but never prints it.
import crypto from 'node:crypto';
import http2 from 'node:http2';
import fs from 'node:fs';

const KEY_ID    = process.env.APNS_KEY_ID;
const TEAM_ID   = process.env.APNS_TEAM_ID;
const BUNDLE_ID = process.env.APNS_BUNDLE_ID;
// TestFlight + App Store builds both use the PRODUCTION APNs host.
const APNS_HOST = process.env.APNS_HOST || 'https://api.push.apple.com';

function loadKey() {
  if (process.env.APNS_KEY_P8 && process.env.APNS_KEY_P8.includes('BEGIN')) return process.env.APNS_KEY_P8;
  if (process.env.APNS_KEY_PATH && fs.existsSync(process.env.APNS_KEY_PATH)) return fs.readFileSync(process.env.APNS_KEY_PATH, 'utf8');
  return null;
}

export function apnsConfigured() {
  return !!(KEY_ID && TEAM_ID && BUNDLE_ID && loadKey());
}

// ES256 JWT for the APNs provider token. Valid ~1h; we mint one per run (runs are short).
function providerToken() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const header  = b64({ alg: 'ES256', kid: KEY_ID });
  const iat     = Math.floor(Date.now() / 1000);
  const payload = b64({ iss: TEAM_ID, iat });
  const signingInput = `${header}.${payload}`;
  // ES256 needs the raw R||S signature (JOSE), not DER — dsaEncoding: 'ieee-p1363'.
  const sig = crypto.sign('sha256', Buffer.from(signingInput),
    { key: loadKey(), dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${signingInput}.${sig}`;
}

/**
 * Push one alert to many device tokens over a single HTTP/2 connection.
 * @param {string[]} tokens  APNs device tokens (hex)
 * @param {{title:string, body:string, data?:object}} msg
 * @returns {Promise<{sent:number, dead:string[], failed:number}>}  dead = tokens APNs says to drop
 */
export async function pushAll(tokens, msg) {
  const out = { sent: 0, dead: [], failed: 0 };
  if (!tokens?.length || !apnsConfigured()) return out;
  const jwt = providerToken();
  const client = http2.connect(APNS_HOST);
  client.on('error', () => {});
  const payload = JSON.stringify({
    aps: { alert: { title: msg.title, body: msg.body }, sound: 'default', 'content-available': 1 },
    ...(msg.data || {})
  });

  const sendOne = (token) => new Promise((resolve) => {
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      'authorization': `bearer ${jwt}`,
      'apns-topic': BUNDLE_ID,
      'apns-push-type': 'alert',
      'apns-priority': '10',
    });
    let status = 0, bodyText = '';
    req.on('response', (h) => { status = h[':status']; });
    req.setEncoding('utf8');
    req.on('data', (d) => { bodyText += d; });
    req.on('end', () => {
      if (status === 200) out.sent++;
      else {
        out.failed++;
        // 410 = token no longer active; 400 BadDeviceToken = never valid → drop it.
        let reason = ''; try { reason = JSON.parse(bodyText).reason || ''; } catch {}
        if (status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered' || reason === 'DeviceTokenNotForTopic')
          out.dead.push(token);
        console.log(`apns: token …${token.slice(-6)} → ${status} ${reason}`);
      }
      resolve();
    });
    req.on('error', () => { out.failed++; resolve(); });
    req.end(payload);
  });

  // modest concurrency
  const batch = 10;
  for (let i = 0; i < tokens.length; i += batch) {
    await Promise.all(tokens.slice(i, i + batch).map(sendOne));
  }
  client.close();
  return out;
}
