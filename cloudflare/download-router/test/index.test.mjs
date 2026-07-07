import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../src/index.js";

test("records installer downloads routed to the global mirror", async () => {
  const analytics = createAnalytics();
  const response = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/latest/win-x64", {
      headers: { "CF-IPCountry": "US" },
    }),
    {
      GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      DOWNLOAD_ANALYTICS: analytics,
    },
  );

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "https://r2.example.com/latest/win-x64");
  assert.deepEqual(analytics.points, [
    {
      blobs: ["global", "US", "installer"],
      doubles: [1],
      indexes: ["global"],
    },
  ]);
});

test("records update archive and delta categories", async () => {
  const analytics = createAnalytics();
  const env = {
    GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
    DOWNLOAD_ANALYTICS: analytics,
  };

  await worker.fetch(new Request("https://codexapp.agentsmirror.com/latest/mac/arm64/Codex.zip"), env);
  await worker.fetch(new Request("https://codexapp.agentsmirror.com/latest/mac/intel/Codex.delta"), env);

  assert.deepEqual(
    analytics.points.map((point) => point.blobs),
    [
      ["global", "", "update-full"],
      ["global", "", "update-delta"],
    ],
  );
});

test("does not record metadata polling paths", async () => {
  const analytics = createAnalytics();
  const response = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/latest/manifest", {
      headers: { "CF-IPCountry": "CN" },
    }),
    {
      GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      DOWNLOAD_ANALYTICS: analytics,
    },
  );

  assert.equal(response.status, 302);
  assert.deepEqual(analytics.points, []);
});

test("does not record non-GET download probes", async () => {
  const analytics = createAnalytics();
  const response = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/latest/win-x64", {
      method: "HEAD",
      headers: { "CF-IPCountry": "US" },
    }),
    {
      GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      DOWNLOAD_ANALYTICS: analytics,
    },
  );

  assert.equal(response.status, 302);
  assert.deepEqual(analytics.points, []);
});

test("records secondary mirror downloads after successful presign", async () => {
  const analytics = createAnalytics();
  const response = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/latest/mac-arm64", {
      headers: { "CF-IPCountry": "CN" },
    }),
    {
      DOWNLOAD_ANALYTICS: analytics,
      GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      SECONDARY_COUNTRY_CODES: "CN",
      SECONDARY_S3_ENDPOINT: "https://s3.example.com",
      SECONDARY_S3_BUCKET: "mirror-bucket",
      SECONDARY_S3_REGION: "auto",
      SECONDARY_S3_ACCESS_KEY_ID: "access-key",
      SECONDARY_S3_SECRET_ACCESS_KEY: "secret-key",
      SECONDARY_S3_PREFIX: "edge",
    },
  );

  assert.equal(response.status, 302);
  const location = new URL(response.headers.get("Location"));
  assert.equal(location.origin, "https://s3.example.com");
  assert.equal(location.pathname, "/mirror-bucket/edge/latest/mac-arm64");
  assert.equal(location.searchParams.get("response-content-disposition"), 'attachment; filename="Codex-mac-arm64.dmg"');
  assert.deepEqual(analytics.points, [
    {
      blobs: ["secondary", "CN", "installer"],
      doubles: [1],
      indexes: ["secondary"],
    },
  ]);
});

test("analytics failures do not block redirects", async () => {
  const response = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/latest/win"),
    {
      GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      DOWNLOAD_ANALYTICS: {
        writeDataPoint() {
          throw new Error("analytics down");
        },
      },
    },
  );

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "https://r2.example.com/latest/win");
});

test("serves the stats badge JSON from the global mirror", async () => {
  const analytics = createAnalytics();
  const badge = '{"schemaVersion":1,"label":"downloads","message":"281.6k","color":"brightgreen"}';
  const response = await withFakeFetch(
    async (input) => {
      assert.equal(String(input), "https://r2.example.com/stats/downloads.json");
      return new Response(badge, {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
    () =>
      worker.fetch(new Request("https://codexapp.agentsmirror.com/stats/downloads.json"), {
        GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
        DOWNLOAD_ANALYTICS: analytics,
      }),
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/json; charset=utf-8");
  assert.equal(await response.text(), badge);
  assert.deepEqual(analytics.points, []);
});

test("maps upstream badge failures to 404", async () => {
  const response = await withFakeFetch(
    async () => new Response("nope", { status: 404 }),
    () =>
      worker.fetch(new Request("https://codexapp.agentsmirror.com/stats/downloads.json"), {
        GLOBAL_MIRROR_BASE_URL: "https://r2.example.com",
      }),
  );

  assert.equal(response.status, 404);
});

test("rejects other stats paths and non-GET badge methods", async () => {
  const env = { GLOBAL_MIRROR_BASE_URL: "https://r2.example.com" };

  const otherPath = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/stats/state.json"),
    env,
  );
  assert.equal(otherPath.status, 404);

  const post = await worker.fetch(
    new Request("https://codexapp.agentsmirror.com/stats/downloads.json", { method: "POST" }),
    env,
  );
  assert.equal(post.status, 405);
  assert.equal(post.headers.get("Allow"), "GET, HEAD");
});

async function withFakeFetch(fake, run) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fake;
  try {
    return await run();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

function createAnalytics() {
  return {
    points: [],
    writeDataPoint(point) {
      this.points.push(structuredClone(point));
    },
  };
}
