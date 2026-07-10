import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  buildObjectPlan,
  cleanupStageObjects,
  commitObjectToAliases,
  deleteStaleAliasObjects,
  decoratePlanWithStage,
  deriveReleaseTag,
  pruneStaleLatestMacObjects,
  uploadObjectToStage,
} from "../src/core.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("buildObjectPlan derives release tag and shares the Windows x64 upload", () => {
  const manifest = fixtureManifest();
  const tag = deriveReleaseTag(manifest);
  const plan = buildObjectPlan(manifest, tag);

  assert.equal(tag, "codex-app-2.0.0");
  assert.equal(plan.items.filter((item) => item.id === "win-x64").length, 1);
  assert.deepEqual(plan.items.find((item) => item.id === "win-x64").aliasKeys, [
    "latest/win-x64",
    "latest/win",
  ]);
  assert.ok(plan.items.some((item) => item.id === "win-arm64"));
  assert.equal(
    plan.items.find((item) => item.id === "mac-arm64-zip").sourceKey,
    "latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
  );
  assert.ok(plan.keepLatestMacKeys.includes("latest/mac/arm64/Codex9999-live-arm64.delta"));
});

test("buildObjectPlan keeps a schema-4 fallback for the current public manifest", () => {
  const manifest = fixtureManifest();
  manifest.schemaVersion = 4;
  delete manifest.sources.macos.arm64.appcast.mirrorEnclosureBasename;
  delete manifest.sources.macos.x64.appcast.mirrorEnclosureBasename;

  const plan = buildObjectPlan(manifest, deriveReleaseTag(manifest));

  assert.equal(
    plan.items.find((item) => item.id === "mac-arm64-zip").sourceKey,
    "latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
  );
  assert.equal(
    plan.items.find((item) => item.id === "mac-x64-zip").sourceKey,
    "latest/mac/intel/Codex-darwin-x64-2.0.0.zip",
  );
});

test("buildObjectPlan rejects missing or unsafe schema-5 archive basenames", () => {
  const missing = fixtureManifest();
  delete missing.sources.macos.arm64.appcast.mirrorEnclosureBasename;
  assert.throws(() => buildObjectPlan(missing, deriveReleaseTag(missing)), /missing.*mirrorEnclosureBasename/i);

  for (const basename of ["../escape.zip", "nested/file.zip", "wrong.delta", "bad\u0001.zip"]) {
    const unsafe = fixtureManifest();
    unsafe.sources.macos.arm64.appcast.mirrorEnclosureBasename = basename;
    assert.throws(() => buildObjectPlan(unsafe, deriveReleaseTag(unsafe)), /Invalid .* basename/);
  }
});

test("buildObjectPlan omits unavailable Windows ARM64 and marks stale alias", () => {
  const manifest = fixtureManifest();
  manifest.sources.windows.architectures.arm64.downloadable = false;

  const plan = buildObjectPlan(manifest, deriveReleaseTag(manifest));

  assert.equal(plan.items.some((item) => item.id === "win-arm64"), false);
  assert.deepEqual(plan.staleAliasKeys, ["latest/win-arm64"]);
});

test("uploads a ranged multipart object to staging and commits both Windows aliases", async () => {
  const manifest = fixtureManifest();
  const tag = deriveReleaseTag(manifest);
  const r2Objects = fixtureR2Objects(manifest, {
    "latest/win-x64": "0123456789abcdefghijklmnopqrstuvwxyz",
  });
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;

  const env = fixtureEnv(r2Objects);
  const plan = decoratePlanWithStage(buildObjectPlan(manifest, tag), "instance-1", {
    SECONDARY_SYNC_STAGE_PREFIX: "staging/test",
  });
  const item = plan.items.find((entry) => entry.id === "win-x64");

  const upload = await uploadObjectToStage(env, item, {
    forceUpload: true,
    singlePutMaxBytes: 8,
    partSizeBytes: 8,
    minPartSizeBytes: 1,
  });
  assert.equal(upload.uploaded, true);

  const commit = await commitObjectToAliases(env, item);
  assert.deepEqual(
    commit.aliases.map((alias) => alias.key).sort(),
    ["latest/win", "latest/win-x64"],
  );
  assert.equal(text(s3.objects.get("latest/win").bytes), text(s3.objects.get("latest/win-x64").bytes));

  await cleanupStageObjects(env, [item]);
  assert.equal(s3.objects.has(item.stageKey), false);
});

test("deletes stale latest aliases from the secondary mirror", async () => {
  const s3 = createMockS3();
  s3.objects.set("latest/win-arm64", objectEntry("old-arm64"));
  s3.objects.set("latest/win-x64", objectEntry("current-x64"));
  globalThis.fetch = s3.fetch;

  const result = await deleteStaleAliasObjects(fixtureEnv(new Map()), ["latest/win-arm64"]);

  assert.deepEqual(result.deleted, ["latest/win-arm64"]);
  assert.equal(s3.objects.has("latest/win-arm64"), false);
  assert.equal(s3.objects.has("latest/win-x64"), true);
});

test("prunes stale unreferenced Sparkle archives but keeps current and recent objects", async () => {
  const s3 = createMockS3();
  const old = new Date("2020-01-01T00:00:00Z");
  const recent = new Date(Date.now() + 60_000);
  s3.objects.set("latest/mac/arm64/current.zip", objectEntry("current", old));
  s3.objects.set("latest/mac/arm64/current.delta", objectEntry("delta", old));
  s3.objects.set("latest/mac/arm64/old.zip", objectEntry("old", old));
  s3.objects.set("latest/mac/intel/recent.zip", objectEntry("recent", recent));
  globalThis.fetch = s3.fetch;

  const result = await pruneStaleLatestMacObjects(
    fixtureEnv(new Map()),
    ["latest/mac/arm64/current.zip", "latest/mac/arm64/current.delta"],
    { graceDays: 1 },
  );

  assert.deepEqual(result.pruned, ["latest/mac/arm64/old.zip"]);
  assert.equal(s3.objects.has("latest/mac/arm64/current.zip"), true);
  assert.equal(s3.objects.has("latest/mac/arm64/current.delta"), true);
  assert.equal(s3.objects.has("latest/mac/intel/recent.zip"), true);
});

test("falls back to ListObjectsV2 when nested HEAD returns 403", async () => {
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;
  const env = fixtureEnv(new Map([["latest/mac/arm64/head-403.zip", bytes("zip")]]));
  const item = {
    id: "nested",
    sourceKey: "latest/mac/arm64/head-403.zip",
    stageKey: "staging/test/head-403.zip",
    filename: "head-403.zip",
    contentType: "application/octet-stream",
    cacheControl: "public, max-age=600",
    required: true,
  };

  const upload = await uploadObjectToStage(env, item, {
    forceUpload: true,
    singlePutMaxBytes: 32,
  });

  assert.equal(upload.uploaded, true);
  assert.equal(s3.objects.get(item.stageKey).bytes.byteLength, 3);
});

test("falls back to ListObjectsV2 when HEAD reports zero bytes for a non-empty object", async () => {
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;
  const env = fixtureEnv(new Map([["latest/checksums", bytes("checksum-body")]]));
  const item = {
    id: "checksums",
    sourceKey: "latest/checksums",
    stageKey: "staging/test/head-zero-checksums",
    filename: "SHA256SUMS.txt",
    contentType: "text/plain; charset=utf-8",
    cacheControl: "public, max-age=600",
    required: true,
  };

  const upload = await uploadObjectToStage(env, item, {
    forceUpload: true,
    singlePutMaxBytes: 32,
  });

  assert.equal(upload.uploaded, true);
  assert.equal(s3.objects.get(item.stageKey).bytes.byteLength, 13);
});

function fixtureManifest() {
  return {
    schemaVersion: 5,
    codexVersion: "2.0.0",
    sources: {
      windows: {
        version: "1.2.3.4",
        appVersion: "2.0.0",
        architectures: {
          x64: { downloadable: true },
          arm64: { downloadable: true },
        },
      },
      macos: {
        arm64: {
          appcast: {
            shortVersionString: "2.0.0",
            version: "100",
            mirrorEnclosureBasename: "Codex-darwin-arm64-2.0.0.zip",
            deltas: [{ basename: "Codex9999-live-arm64.delta" }],
          },
        },
        x64: {
          appcast: {
            shortVersionString: "2.0.0",
            version: "100",
            mirrorEnclosureBasename: "Codex-darwin-x64-2.0.0.zip",
            deltas: [{ basename: "Codex9999-live-x64.delta" }],
          },
        },
      },
    },
  };
}

function fixtureR2Objects(manifest, overrides = {}) {
  const objects = new Map(
    Object.entries({
      "latest/win-x64": "win-x64",
      "latest/win-arm64": "win-arm64",
      "latest/mac-arm64": "mac-arm64",
      "latest/mac-intel": "mac-intel",
      "latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip": "arm64-zip",
      "latest/mac/intel/Codex-darwin-x64-2.0.0.zip": "x64-zip",
      "latest/mac/arm64/Codex9999-live-arm64.delta": "arm64-delta",
      "latest/mac/intel/Codex9999-live-x64.delta": "x64-delta",
      "latest/checksums": "checksums",
      "latest/appcast.xml": "<rss />",
      "latest/appcast-x64.xml": "<rss />",
      "latest/manifest": JSON.stringify(manifest),
      ...overrides,
    }).map(([key, value]) => [key, bytes(value)]),
  );
  return objects;
}

function fixtureEnv(r2Objects) {
  return {
    GLOBAL_R2: new MockR2Bucket(r2Objects),
    SECONDARY_S3_ENDPOINT: "https://s3.example.test",
    SECONDARY_S3_BUCKET: "bucket",
    SECONDARY_S3_REGION: "auto",
    SECONDARY_S3_ACCESS_KEY_ID: "key",
    SECONDARY_S3_SECRET_ACCESS_KEY: "secret",
  };
}

class MockR2Bucket {
  constructor(objects) {
    this.objects = objects;
  }

  async head(key) {
    const value = this.objects.get(key);
    return value ? { size: value.byteLength } : null;
  }

  async get(key, options = {}) {
    const value = this.objects.get(key);
    if (!value) {
      return null;
    }
    const range = options.range;
    const sliced = range ? value.slice(range.offset, range.offset + range.length) : value;
    return {
      size: sliced.byteLength,
      async arrayBuffer() {
        return sliced.slice(0);
      },
      async text() {
        return text(sliced);
      },
    };
  }
}

function createMockS3() {
  const objects = new Map();
  const uploads = new Map();
  let uploadCounter = 0;

  async function fetch(input, init = {}) {
    const url = new URL(input);
    const { key } = parseS3Path(url.pathname);
    const method = init.method || "GET";
    const headers = new Headers(init.headers || {});

    if (method === "GET" && url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") || "";
      const contents = [...objects.entries()]
        .filter(([objectKey]) => objectKey.startsWith(prefix))
        .map(
          ([objectKey, entry]) =>
            `<Contents><Key>${xmlEscape(objectKey)}</Key><LastModified>${entry.lastModified.toISOString()}</LastModified><Size>${entry.bytes.byteLength}</Size></Contents>`,
        )
        .join("");
      return new Response(`<ListBucketResult>${contents}</ListBucketResult>`, { status: 200 });
    }

    if (method === "HEAD") {
      if (key.includes("head-403")) {
        return new Response("forbidden", { status: 403 });
      }
      const entry = objects.get(key);
      if (!entry) {
        return new Response(null, { status: 404 });
      }
      return new Response(null, {
        status: 200,
        headers: {
          "content-length": key.includes("head-zero") ? "0" : String(entry.bytes.byteLength),
          "last-modified": entry.lastModified.toUTCString(),
          etag: entry.etag,
        },
      });
    }

    if (method === "GET") {
      const entry = objects.get(key);
      if (!entry) {
        return new Response("missing", { status: 404 });
      }
      return new Response(entry.bytes, {
        status: 200,
        headers: { "content-length": String(entry.bytes.byteLength) },
      });
    }

    if (method === "POST" && url.searchParams.has("uploads")) {
      const uploadId = `upload-${++uploadCounter}`;
      uploads.set(uploadId, { key, parts: new Map() });
      return new Response(`<InitiateMultipartUploadResult><UploadId>${uploadId}</UploadId></InitiateMultipartUploadResult>`);
    }

    if (method === "PUT" && url.searchParams.has("partNumber")) {
      const uploadId = url.searchParams.get("uploadId");
      const upload = uploads.get(uploadId);
      upload.parts.set(Number(url.searchParams.get("partNumber")), await bodyBytes(init.body));
      return new Response(null, { status: 200, headers: { etag: `"part-${upload.parts.size}"` } });
    }

    if (method === "POST" && url.searchParams.has("uploadId")) {
      const upload = uploads.get(url.searchParams.get("uploadId"));
      const joined = concatBytes([...upload.parts.entries()].sort(([a], [b]) => a - b).map(([, value]) => value));
      objects.set(upload.key, objectEntry(joined));
      uploads.delete(url.searchParams.get("uploadId"));
      return new Response("<CompleteMultipartUploadResult />");
    }

    if (method === "DELETE" && url.searchParams.has("uploadId")) {
      uploads.delete(url.searchParams.get("uploadId"));
      return new Response(null, { status: 204 });
    }

    if (method === "PUT" && headers.has("x-amz-copy-source")) {
      const sourceKey = parseCopySource(headers.get("x-amz-copy-source"));
      const source = objects.get(sourceKey);
      if (!source) {
        return new Response("missing copy source", { status: 404 });
      }
      objects.set(key, objectEntry(source.bytes.slice(0)));
      return new Response("<CopyObjectResult />");
    }

    if (method === "PUT") {
      objects.set(key, objectEntry(await bodyBytes(init.body)));
      return new Response(null, { status: 200 });
    }

    if (method === "DELETE") {
      objects.delete(key);
      return new Response(null, { status: 204 });
    }

    return new Response(`unexpected ${method} ${url}`, { status: 500 });
  }

  return { fetch, objects, uploads };
}

function parseS3Path(pathname) {
  const parts = pathname.split("/").filter(Boolean).map(decodeURIComponent);
  return {
    bucket: parts[0],
    key: parts.slice(1).join("/"),
  };
}

function parseCopySource(value) {
  const parts = value.split("/").filter(Boolean).map(decodeURIComponent);
  return parts.slice(1).join("/");
}

async function bodyBytes(body) {
  if (!body) {
    return new Uint8Array();
  }
  if (body instanceof ArrayBuffer) {
    return new Uint8Array(body);
  }
  if (body instanceof Uint8Array) {
    return body;
  }
  if (typeof body === "string") {
    return bytes(body);
  }
  return new Uint8Array(await new Response(body).arrayBuffer());
}

function objectEntry(value, lastModified = new Date()) {
  const valueBytes = value instanceof Uint8Array ? value : bytes(value);
  return {
    bytes: valueBytes,
    lastModified,
    etag: `"${valueBytes.byteLength}"`,
  };
}

function bytes(value) {
  if (value instanceof Uint8Array) {
    return value;
  }
  return encoder.encode(String(value));
}

function text(value) {
  return decoder.decode(value);
}

function concatBytes(parts) {
  const total = parts.reduce((sum, part) => sum + part.byteLength, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.byteLength;
  }
  return output;
}

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
