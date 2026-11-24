// CI guard: run this mirror's real wrangler.jsonc (ROUTE_CONFIG + access policy
// + split TTL + extended analytics) through the pinned kit download-router
// worker and assert key routing and abuse-protection behaviors. Requires
// agents-mirror-kit checked out at .mirror-kit (the CI workflow does this).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const wrangler = JSON.parse(
  readFileSync(new URL("./wrangler.jsonc", import.meta.url), "utf8"),
);
const vars = wrangler.vars || {};
const routeConfig = vars.ROUTE_CONFIG;
assert.ok(routeConfig && routeConfig.aliases, "wrangler.jsonc must define vars.ROUTE_CONFIG.aliases");
assert.ok(Array.isArray(vars.BLOCKED_UA_SUBSTRINGS) && vars.BLOCKED_UA_SUBSTRINGS.length > 0, "wrangler.jsonc must define vars.BLOCKED_UA_SUBSTRINGS");
assert.ok(Array.isArray(vars.BLOCKED_REFERER_HOSTS) && vars.BLOCKED_REFERER_HOSTS.length > 0, "wrangler.jsonc must define vars.BLOCKED_REFERER_HOSTS");

// Guard against overly broad substrings that could collide with first-party tools.
for (const forbiddenGeneric of ["manager", "updater", "installer", "codex", "curl"]) {
  assert.ok(
    !vars.BLOCKED_UA_SUBSTRINGS.includes(forbiddenGeneric),
    `BLOCKED_UA_SUBSTRINGS must not include bare generic token: ${forbiddenGeneric}`,
  );
}

const { default: worker } = await import(
  new URL("../../.mirror-kit/workers/download-router/src/index.js", import.meta.url)
);

const GLOBAL = vars.GLOBAL_MIRROR_BASE_URL;
const SECONDARY = {
  SECONDARY_COUNTRY_CODES: "CN",
  SECONDARY_S3_ENDPOINT: "https://s3.example.invalid",
  SECONDARY_S3_BUCKET: "secondary-bucket",
  SECONDARY_S3_REGION: "auto",
  SECONDARY_S3_ACCESS_KEY_ID: "AKIAEXAMPLE",
  SECONDARY_S3_SECRET_ACCESS_KEY: "secretexamplekey",
  SECONDARY_S3_PREFIX: "edge",
};

function analytics() {
  return { points: [], writeDataPoint(p) { this.points.push(p); } };
}

function asLatin1ByteString(utf8Text) {
  return String.fromCharCode(...new TextEncoder().encode(utf8Text));
}

async function run(path, { country = "US", method = "GET", secondary = false, headers = {} } = {}) {
  const downloads = analytics();
  const abuse = analytics();
  const env = {
    ...vars,
    DOWNLOAD_ANALYTICS: downloads,
    ABUSE_ANALYTICS: abuse,
    ABUSE_SAMPLE_RATE: "1",
    ...(secondary ? SECONDARY : {}),
  };
  const res = await worker.fetch(
    new Request(`https://codexapp.agentsmirror.com${path}`, {
      method,
      headers: { "CF-IPCountry": country, ...headers },
    }),
    env,
  );
  return { status: res.status, location: res.headers.get("Location"), res, points: downloads.points, abuse: abuse.points };
}

// Installer alias: global 302 + counted as installer with 8-blob extended schema.
{
  const r = await run("/latest/win-x64", { headers: { "User-Agent": "curl/8.13.0" } });
  assert.equal(r.status, 302);
  assert.equal(r.location, `${GLOBAL}/latest/win-x64`);
  assert.equal(r.points.length, 1);
  assert.deepEqual(r.points[0].blobs.slice(0, 4), ["global", "US", "installer", "/latest/win-x64"]);
  assert.equal(r.points[0].blobs[5], "curl/8.13.0");
  assert.equal(r.points[0].blobs.length, 8);
}

// Metadata path: allowed, not counted in download analytics, uses shorter metadata TTL on CN.
{
  const r = await run("/latest/checksums", { country: "CN", secondary: true });
  assert.equal(r.status, 302);
  assert.deepEqual(r.points, []);
  const loc = new URL(r.location);
  assert.equal(loc.searchParams.get("X-Amz-Expires"), "120");
}

// Sparkle delta pattern: counted as update-delta.
{
  const r = await run("/latest/mac/arm64/Codex-1.2.3-arm64.delta", { headers: { "User-Agent": "ChatGPT/26.1117 Sparkle" } });
  assert.equal(r.status, 302);
  assert.deepEqual(r.points[0].blobs.slice(0, 3), ["global", "US", "update-delta"]);
}

// Unknown path: 404.
{
  const r = await run("/latest/definitely-not-a-thing");
  assert.equal(r.status, 404);
}

// CN routing presigns the secondary mirror with the alias's download filename and installer TTL (600s).
{
  const r = await run("/latest/mac-arm64", { country: "CN", secondary: true });
  assert.equal(r.status, 302);
  const loc = new URL(r.location);
  assert.equal(loc.origin, "https://s3.example.invalid");
  assert.equal(loc.searchParams.get("X-Amz-Expires"), "600");
  assert.equal(loc.searchParams.get("response-content-disposition"), 'attachment; filename="Codex-mac-arm64.dmg"');
  assert.deepEqual(r.points[0].blobs.slice(0, 3), ["secondary", "CN", "installer"]);
}

// CJK ByteString unauthorized client UA is blocked with 403 JSON before CN presign.
{
  const r = await run("/latest/win-x64", {
    country: "CN",
    secondary: true,
    headers: { "User-Agent": asLatin1ByteString("Mozilla/5.0 越途AI智枢/1.9.0 Electron/43.2.0") },
  });
  assert.equal(r.status, 403);
  assert.equal(r.res.headers.get("X-Mirror-Policy"), "client-not-authorized");
  const body = await r.res.json();
  assert.equal(body.error, "client_not_authorized");
  assert.equal(r.points.length, 0);
  assert.equal(r.abuse.length, 1);
}

// Hotlink Referer redirects back to official home page.
{
  const r = await run("/latest/win-x64", { headers: { Referer: "https://gpt.dqtx.cc/guide" } });
  assert.equal(r.status, 302);
  assert.equal(r.location, "https://codexapp.agentsmirror.com/");
  assert.equal(r.abuse.length, 1);
}

console.log("download-router config validated against kit worker");
