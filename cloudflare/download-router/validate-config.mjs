// CI guard: run this mirror's real ROUTE_CONFIG (from wrangler.jsonc) through
// the pinned kit download-router worker and assert the key routing behaviors.
// This catches drift/typos in the hand-maintained ROUTE_CONFIG that the kit's
// own tests (which use their own fixture) cannot see. Requires agents-mirror-kit
// checked out at .mirror-kit (the CI workflow does this).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const wrangler = JSON.parse(
  readFileSync(new URL("./wrangler.jsonc", import.meta.url), "utf8"),
);
const routeConfig = wrangler.vars?.ROUTE_CONFIG;
assert.ok(routeConfig && routeConfig.aliases, "wrangler.jsonc must define vars.ROUTE_CONFIG.aliases");

const { default: worker } = await import(
  new URL("../../.mirror-kit/workers/download-router/src/index.js", import.meta.url)
);

const GLOBAL = wrangler.vars.GLOBAL_MIRROR_BASE_URL;
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

async function run(path, { country = "US", method = "GET", secondary = false } = {}) {
  const a = analytics();
  const env = { ROUTE_CONFIG: routeConfig, GLOBAL_MIRROR_BASE_URL: GLOBAL, DOWNLOAD_ANALYTICS: a, ...(secondary ? SECONDARY : {}) };
  const res = await worker.fetch(
    new Request(`https://codexapp.agentsmirror.com${path}`, { method, headers: { "CF-IPCountry": country } }),
    env,
  );
  return { status: res.status, location: res.headers.get("Location"), points: a.points };
}

// Installer alias: global 302 + counted as installer.
{
  const r = await run("/latest/win-x64");
  assert.equal(r.status, 302);
  assert.equal(r.location, `${GLOBAL}/latest/win-x64`);
  assert.deepEqual(r.points.map((p) => p.blobs), [["global", "US", "installer"]]);
}

// Metadata path: allowed but not counted.
{
  const r = await run("/latest/checksums");
  assert.equal(r.status, 302);
  assert.deepEqual(r.points, []);
}

// Sparkle delta pattern: counted as update-delta.
{
  const r = await run("/latest/mac/arm64/Codex-1.2.3-arm64.delta");
  assert.equal(r.status, 302);
  assert.deepEqual(r.points.map((p) => p.blobs), [["global", "US", "update-delta"]]);
}

// Unknown path: 404.
{
  const r = await run("/latest/definitely-not-a-thing");
  assert.equal(r.status, 404);
}

// CN routing presigns the secondary mirror with the alias's download filename.
{
  const r = await run("/latest/mac-arm64", { country: "CN", secondary: true });
  assert.equal(r.status, 302);
  const loc = new URL(r.location);
  assert.equal(loc.origin, "https://s3.example.invalid");
  assert.equal(loc.searchParams.get("response-content-disposition"), 'attachment; filename="Codex-mac-arm64.dmg"');
  assert.deepEqual(r.points.map((p) => p.blobs), [["secondary", "CN", "installer"]]);
}

console.log("download-router config validated against kit worker");
