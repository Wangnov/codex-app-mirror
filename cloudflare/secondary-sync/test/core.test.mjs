import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  SupersededMirrorError,
  aliasBackupKeys,
  buildObjectPlan,
  cleanupRollbackBackups,
  cleanupStageObjects,
  commitObjectToAliases,
  commitOrder,
  commitSingleAlias,
  createIncrementalSha256,
  deleteStaleAliasObjects,
  decoratePlanWithStage,
  deriveReleaseTag,
  discoverSourceManifest,
  isSupersededError,
  pruneAbandonedStageObjects,
  pruneStaleLatestMacObjects,
  reconcileSync,
  recordSwitchoverCommittedCheckpoint,
  rollbackCommittedAliases,
  startSync,
  uploadObjectToStage,
  verifyPriorSwitchoverCheckpoint,
  verifySourceManifestCurrent,
  workflowInstanceId,
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

test("commitOrder advances checksums and manifest only after referenced objects", () => {
  const plan = buildObjectPlan(fixtureManifest(), "codex-app-2.0.0");
  const ordered = commitOrder(plan.items).map((item) => item.role);

  assert.equal(ordered.at(-1), "manifest");
  assert.equal(ordered.at(-2), "checksums");
  assert.ok(ordered.indexOf("appcast") < ordered.indexOf("checksums"));
  assert.ok(ordered.indexOf("archive") < ordered.indexOf("appcast"));
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

test("restores the published alias when the commit copy fails", async () => {
  const stageKey = "staging/test/instance-1/objects/win-x64";
  const s3 = createMockS3({ failCopyFrom: (sourceKey) => sourceKey === stageKey });
  s3.objects.set(stageKey, objectEntry("next-release"));
  s3.objects.set("latest/win", objectEntry("published-release"));
  globalThis.fetch = s3.fetch;

  const item = { id: "win-x64", stageKey, aliasKeys: ["latest/win"] };

  await assert.rejects(() => commitObjectToAliases(fixtureEnv(new Map()), item));

  assert.equal(text(s3.objects.get("latest/win").bytes), "published-release");
  assert.equal(s3.objects.has("latest/win.rollback"), false);
});

test("commits the alias and clears its rollback backup on success", async () => {
  const stageKey = "staging/test/instance-1/objects/win-x64";
  const s3 = createMockS3();
  s3.objects.set(stageKey, objectEntry("next-release"));
  s3.objects.set("latest/win", objectEntry("published-release"));
  globalThis.fetch = s3.fetch;

  const item = { id: "win-x64", stageKey, aliasKeys: ["latest/win"] };
  const commit = await commitObjectToAliases(fixtureEnv(new Map()), item);

  assert.deepEqual(commit.aliases, [{ key: "latest/win", size: 12 }]);
  assert.equal(text(s3.objects.get("latest/win").bytes), "next-release");
  assert.equal(s3.objects.has("latest/win.rollback"), false);
});

test("treats server-completed COPY that returned transient 502 as succeeded without hitting IHEP overwrite error", async () => {
  const stageKey = "staging/test/instance-1/objects/win-x64";
  let stageCopyCalls = 0;
  const s3 = createMockS3({
    onCopy(sourceKey, destinationKey, store) {
      if (sourceKey === stageKey && destinationKey === "latest/win") {
        stageCopyCalls += 1;
        if (stageCopyCalls === 1) {
          // Simulate IHEP completing the server-side copy right before proxy returns 502;
          // a blind retry without HEAD would see destinationKey existing and return 502 forever.
          store.set(destinationKey, objectEntry("next-release"));
          return new Response("Bad Gateway", { status: 502 });
        }
        if (store.has(destinationKey)) {
          return new Response("<Error><Code>InternalError</Code></Error>", { status: 502 });
        }
      }
      return null;
    },
  });
  s3.objects.set(stageKey, objectEntry("next-release"));
  s3.objects.set("latest/win", objectEntry("published-release"));
  globalThis.fetch = s3.fetch;

  const item = { id: "win-x64", stageKey, aliasKeys: ["latest/win"] };
  const commit = await commitObjectToAliases(fixtureEnv(new Map()), item);

  assert.deepEqual(commit.aliases, [{ key: "latest/win", size: 12 }]);
  assert.equal(stageCopyCalls, 1, "must detect already-copied target via HEAD without re-issuing COPY");
  assert.equal(text(s3.objects.get("latest/win").bytes), "next-release");
  assert.equal(s3.objects.has("latest/win.rollback"), false);
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

test("prunes abandoned staging objects and multipart uploads without touching active work", async () => {
  const s3 = createMockS3();
  const old = new Date("2020-01-01T00:00:00Z");
  const recent = new Date(Date.now() + 60_000);
  const activePrefix = "staging/secondary-sync/release/active";
  s3.objects.set("staging/secondary-sync/release/old/objects/archive", objectEntry("old", old));
  s3.objects.set("staging/secondary-sync/release/recent/objects/archive", objectEntry("recent", recent));
  s3.objects.set(`${activePrefix}/objects/archive`, objectEntry("active", old));
  s3.objects.set("latest/win", objectEntry("published", old));
  s3.uploads.set("upload-old", {
    key: "staging/secondary-sync/release/old/objects/partial",
    parts: new Map(),
    initiated: old,
  });
  s3.uploads.set("upload-active", {
    key: `${activePrefix}/objects/partial`,
    parts: new Map(),
    initiated: old,
  });
  globalThis.fetch = s3.fetch;

  const result = await pruneAbandonedStageObjects(fixtureEnv(new Map()), activePrefix, {
    graceHours: 1,
  });

  assert.deepEqual(result.deleted, ["staging/secondary-sync/release/old/objects/archive"]);
  assert.deepEqual(result.aborted, [
    {
      key: "staging/secondary-sync/release/old/objects/partial",
      uploadId: "upload-old",
    },
  ]);
  assert.equal(s3.objects.has("staging/secondary-sync/release/recent/objects/archive"), true);
  assert.equal(s3.objects.has(`${activePrefix}/objects/archive`), true);
  assert.equal(s3.objects.has("latest/win"), true);
  assert.equal(s3.uploads.has("upload-old"), false);
  assert.equal(s3.uploads.has("upload-active"), true);
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

test("retries transient S3 5xx and network errors per multipart part without aborting upload", async () => {
  const manifest = fixtureManifest();
  const tag = deriveReleaseTag(manifest);
  const payload = "0123456789abcdefghijklmnopqrstuvwxyz";
  const r2Objects = fixtureR2Objects(manifest, {
    "latest/win-x64": payload,
  });
  let part2Failures = 0;
  let abortedCount = 0;
  let part1Uploads = 0;
  const s3 = createMockS3({
    onUploadPart(partNumber) {
      if (partNumber === 1) {
        part1Uploads += 1;
      }
      if (partNumber === 2 && part2Failures < 3) {
        part2Failures += 1;
        if (part2Failures === 2) {
          throw new TypeError("fetch failed: socket hang up");
        }
        return new Response("<Error><Code>InternalError</Code><Message>网络故障，请稍后重试</Message></Error>", {
          status: part2Failures === 1 ? 500 : 502,
        });
      }
      return null;
    },
    onAbortMultipart() {
      abortedCount += 1;
    },
  });
  globalThis.fetch = s3.fetch;

  const env = fixtureEnv(r2Objects);
  const plan = decoratePlanWithStage(buildObjectPlan(manifest, tag), "instance-retry", {
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
  assert.equal(part2Failures, 3);
  assert.equal(part1Uploads, 1, "part 1 must not be re-uploaded when part 2 retries in place");
  assert.equal(abortedCount, 0, "multipart upload must not abort on recoverable part errors");
  assert.equal(text(s3.objects.get(item.stageKey).bytes), payload);
});

test("aborts multipart upload and reports failing part number after exhausting S3 retries", async () => {
  const manifest = fixtureManifest();
  const tag = deriveReleaseTag(manifest);
  const r2Objects = fixtureR2Objects(manifest, {
    "latest/win-x64": "0123456789abcdef",
  });
  let abortedCount = 0;
  const s3 = createMockS3({
    onUploadPart(partNumber) {
      if (partNumber === 2) {
        return new Response("<Error><Code>InternalError</Code></Error>", { status: 500 });
      }
      return null;
    },
    onAbortMultipart() {
      abortedCount += 1;
    },
  });
  globalThis.fetch = s3.fetch;

  const env = {
    ...fixtureEnv(r2Objects),
    SECONDARY_S3_MAX_ATTEMPTS: "3",
  };
  const plan = decoratePlanWithStage(buildObjectPlan(manifest, tag), "instance-exhaust", {
    SECONDARY_SYNC_STAGE_PREFIX: "staging/test",
  });
  const item = plan.items.find((entry) => entry.id === "win-x64");

  await assert.rejects(
    () =>
      uploadObjectToStage(env, item, {
        forceUpload: true,
        singlePutMaxBytes: 8,
        partSizeBytes: 8,
        minPartSizeBytes: 1,
      }),
    /part 2 failed with HTTP 500/,
  );
  assert.equal(abortedCount, 1);
  assert.equal(s3.uploads.size, 0);
});

test("reconcileSync deduplicates in-flight canonical workflow and restarts errored canonical workflow", async () => {
  const manifest = fixtureManifest();
  const r2Objects = fixtureR2Objects(manifest);
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;

  const instances = new Map();
  let createCalls = 0;
  let restartCalls = 0;
  let failRestart = false;

  const env = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        createCalls += 1;
        const inst = {
          id: opts.id,
          currentState: "running",
          async status() {
            return { status: this.currentState };
          },
          async restart() {
            if (failRestart) {
              throw new Error("cannot restart");
            }
            restartCalls += 1;
            this.currentState = "running";
          },
        };
        instances.set(opts.id, inst);
        return inst;
      },
      async get(id) {
        const found = instances.get(id);
        if (!found) {
          throw new Error("not found");
        }
        return found;
      },
    },
  };

  // First reconcile creates canonical workflow.
  const first = await reconcileSync(env, {});
  assert.equal(first.created, true);
  assert.equal(createCalls, 1);

  // Concurrent cron reconcile while running reuses canonical workflow instead of spawning duplicate.
  const second = await reconcileSync(env, {});
  assert.equal(second.reused, true);
  assert.equal(second.id, first.id);
  assert.equal(createCalls, 1);

  // When canonical workflow errored, reconcile restarts it in place.
  instances.get(first.id).currentState = "errored";
  const third = await reconcileSync(env, {});
  assert.equal(third.restarted, true);
  assert.equal(third.id, first.id);
  assert.equal(restartCalls, 1);
  assert.equal(createCalls, 1);

  // If restart is rejected (e.g. expired instance), reconcile falls back to a salted instance.
  instances.get(first.id).currentState = "complete";
  failRestart = true;
  const fourth = await reconcileSync(env, {});
  assert.equal(fourth.created, true);
  assert.notEqual(fourth.id, first.id);
  assert.equal(createCalls, 2);

  // Subsequent reconcile while salted fallback instance is running reuses it via active-sync pointer.
  const fifth = await reconcileSync(env, { releaseTag: "codex-app-older-tag-hint" });
  assert.equal(fifth.reused, true);
  assert.equal(fifth.id, fourth.id);
  assert.equal(createCalls, 2);
});

test("createIncrementalSha256 matches WebCrypto SHA-256 across all block boundaries", async () => {
  for (const len of [0, 1, 55, 56, 63, 64, 65, 128, 1000]) {
    const raw = new Uint8Array(len);
    for (let i = 0; i < len; i += 1) raw[i] = (i * 131 + 17) & 0xff;
    const expectedBuf = await crypto.subtle.digest("SHA-256", raw);
    const expectedHex = [...new Uint8Array(expectedBuf)]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    const inc = createIncrementalSha256();
    for (let offset = 0; offset < len; offset += 13) {
      inc.update(raw.subarray(offset, Math.min(len, offset + 13)));
    }
    assert.equal(inc.digestHex(), expectedHex, `mismatch at length ${len}`);
  }
});

test("rejects HTTP 200 XML <Error> on backup COPY and CompleteMultipartUpload without losing aliases or leaking uploads", async () => {
  const stageKey = "staging/test/instance-200err/objects/win-x64";
  let abortCalls = 0;
  const s3 = createMockS3({
    onCopy(sourceKey, destinationKey) {
      if (sourceKey === "latest/win" && destinationKey === "latest/win.rollback") {
        return new Response("<Error><Code>InternalError</Code><Message>copy failed</Message></Error>", {
          status: 200,
        });
      }
      return null;
    },
    onCompleteMultipart() {
      return new Response("<Error><Code>InternalError</Code><Message>complete failed</Message></Error>", {
        status: 200,
      });
    },
    onAbortMultipart() {
      abortCalls += 1;
    },
  });
  s3.objects.set(stageKey, objectEntry("next-release"));
  s3.objects.set("latest/win", objectEntry("published-release"));
  globalThis.fetch = s3.fetch;

  const env = { ...fixtureEnv(new Map([["latest/win-x64", bytes("0123456789abcdef")]])), SECONDARY_S3_MAX_ATTEMPTS: "2" };
  await assert.rejects(
    () => commitObjectToAliases(env, { id: "win-x64", stageKey, aliasKeys: ["latest/win"] }),
    /200 XML InternalError/,
  );
  // Published alias must NOT be deleted when backup COPY returned 200 + <Error>.
  assert.equal(text(s3.objects.get("latest/win").bytes), "published-release");

  await assert.rejects(
    () =>
      uploadObjectToStage(
        env,
        {
          id: "win-x64",
          sourceKey: "latest/win-x64",
          stageKey: "staging/test/instance-200err/objects/mp",
          filename: "Codex-Windows-x64.msix",
          contentType: "application/vnd.ms-appx",
          required: true,
        },
        { forceUpload: true, singlePutMaxBytes: 4, partSizeBytes: 4, minPartSizeBytes: 1 },
      ),
    /200 XML InternalError/,
  );
  assert.equal(abortCalls, 1, "CompleteMultipartUpload 200 + <Error> must trigger AbortMultipartUpload");
});

test("COPY idempotency recovery rejects same-size wrong-content destination objects", async () => {
  const stageKey = "staging/test/instance-same-len/objects/win";
  const s3 = createMockS3({
    onCopy(sourceKey, destinationKey, store) {
      if (sourceKey === stageKey && destinationKey === "latest/win") {
        // Concurrent/stale writer leaves same-length wrong bytes ("BBBB" vs "AAAA").
        store.set(destinationKey, objectEntry("BBBB", new Date(), { syncSha256: "b".repeat(64) }));
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
  });
  s3.objects.set(stageKey, objectEntry("AAAA", new Date(), { syncSha256: "a".repeat(64) }));
  s3.objects.set("latest/win", objectEntry("OLD!", new Date(), { syncSha256: "0".repeat(64) }));
  globalThis.fetch = s3.fetch;

  const env = { ...fixtureEnv(new Map()), SECONDARY_S3_MAX_ATTEMPTS: "2" };
  await assert.rejects(() =>
    commitObjectToAliases(env, { id: "win", stageKey, aliasKeys: ["latest/win"] }),
  );
  // Must restore prior published object ("OLD!") rather than accepting wrong same-size "BBBB".
  assert.equal(text(s3.objects.get("latest/win").bytes), "OLD!");
});

test("prevents cross-version R2 splicing via ETag conditional reads, retries transient R2 read errors, and pins manifest bytes", async () => {
  const manifestA = fixtureManifest();
  const textA = JSON.stringify(manifestA);
  const shaA = createIncrementalSha256();
  shaA.update(bytes(textA));
  const manifestASha = shaA.digestHex();

  let part2ReadCalls = 0;
  const r2Objects = fixtureR2Objects(manifestA, { "latest/win-x64": "AAAABBBB" });
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;

  const env = fixtureEnv(r2Objects, {
    onR2Get(key, options) {
      if (key === "latest/win-x64" && options?.range?.offset === 4) {
        part2ReadCalls += 1;
        if (part2ReadCalls === 1) {
          throw new Error("transient R2 read glitch");
        }
      }
    },
  });

  const plan = decoratePlanWithStage(
    buildObjectPlan(manifestA, deriveReleaseTag(manifestA), {
      manifestText: textA,
      manifestSha256: manifestASha,
    }),
    "instance-pin",
    env,
  );
  const winItem = plan.items.find((i) => i.id === "win-x64");
  const uploadOk = await uploadObjectToStage(env, winItem, {
    forceUpload: true,
    singlePutMaxBytes: 4,
    partSizeBytes: 4,
    minPartSizeBytes: 1,
  });
  assert.equal(uploadOk.uploaded, true);
  assert.equal(part2ReadCalls, 2, "transient R2 read failure must retry part 2 in place");
  assert.equal(text(s3.objects.get(winItem.stageKey).bytes), "AAAABBBB");

  // Mutate R2 latest/manifest to version B before uploading manifest item: pinned inlineText must still stage A,
  // and verifySourceManifestCurrent must block committing stale A!
  const manifestB = { ...fixtureManifest(), codexVersion: "3.0.0" };
  r2Objects.set("latest/manifest", bytes(JSON.stringify(manifestB)));
  const manifestItem = plan.items.find((i) => i.id === "manifest");
  await uploadObjectToStage(env, manifestItem, { forceUpload: true });
  assert.equal(text(s3.objects.get(manifestItem.stageKey).bytes), textA);
  await assert.rejects(
    () => verifySourceManifestCurrent(env, manifestASha),
    /advanced during sync/,
  );

  // Simulate R2 switching latest/win-x64 mid-multipart between part 1 and part 2 -> must reject via ETag!
  r2Objects.set("latest/win-x64", bytes("AAAABBBB"));
  const envSwap = fixtureEnv(r2Objects, {
    onR2Get(key, options) {
      if (key === "latest/win-x64" && options?.range?.offset === 4) {
        r2Objects.set("latest/win-x64", bytes("xxxxYYYY"));
      }
    },
  });
  await assert.rejects(
    () =>
      uploadObjectToStage(
        envSwap,
        { ...winItem, stageKey: "staging/test/instance-pin/objects/spliced" },
        { forceUpload: true, singlePutMaxBytes: 4, partSizeBytes: 4, minPartSizeBytes: 1 },
      ),
    /changed mid-transfer/,
  );
});

test("rolls back earlier committed aliases on group switchover failure, heals missing secondary binaries, and protects active staging", async () => {
  const manifest = fixtureManifest();
  const manifestText = JSON.stringify(manifest);
  const r2Objects = fixtureR2Objects(manifest);
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;

  s3.objects.set("stage/mac-arm64", objectEntry("new-arm"));
  s3.objects.set("stage/mac-intel", objectEntry("new-intel"));
  s3.objects.set("latest/mac-arm64", objectEntry("old-arm"));
  s3.objects.set("latest/mac-intel", objectEntry("old-intel"));

  const env = fixtureEnv(r2Objects);
  const c1 = await commitSingleAlias(env, "stage/mac-arm64", "latest/mac-arm64", { keepBackup: true });
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "new-arm");
  assert.equal(s3.objects.has("latest/mac-arm64.rollback"), true);

  // Simulate failure on second alias -> group rollback restores latest/mac-arm64 back to old-arm!
  await rollbackCommittedAliases(env, [c1]);
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "old-arm");
  assert.equal(s3.objects.has("latest/mac-arm64.rollback"), false);

  // Reconcile must NOT skip when latest/manifest matches R2 if any referenced binary/ZIP is missing.
  s3.objects.set("latest/manifest", objectEntry(manifestText));
  let started = 0;
  const envWithWf = {
    ...env,
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        started += 1;
        return { id: opts.id, async status() { return { status: "running" }; } };
      },
      async get(id) {
        if (id === "running-peer") {
          return { id, async status() { return { status: "running" }; } };
        }
        return null;
      },
    },
  };
  const healRes = await reconcileSync(envWithWf, {});
  assert.equal(healRes.created, true, "reconcileSync must heal when secondary binaries are missing");
  assert.equal(started, 1);

  // pruneAbandonedStageObjects must NOT delete >2h staging belonging to an active workflow instance.
  const old = new Date("2020-01-01T00:00:00Z");
  s3.objects.set("staging/secondary-sync/codex-app-2.0.0/running-peer/objects/part", objectEntry("keep", old));
  const pruned = await pruneAbandonedStageObjects(envWithWf, "staging/secondary-sync/codex-app-2.0.0/caller", {
    graceHours: 1,
  });
  assert.equal(pruned.deleted.includes("staging/secondary-sync/codex-app-2.0.0/running-peer/objects/part"), false);
  assert.equal(s3.objects.has("staging/secondary-sync/codex-app-2.0.0/running-peer/objects/part"), true);
});

test("fences superseded workflows, preserves rollback backup across step retry, validates checksums digest, and fails safe on RPC errors", async () => {
  const manifestA = fixtureManifest();
  const textA = JSON.stringify(manifestA);
  const shaA = contentHashHex(bytes(textA));
  const manifestB = { ...fixtureManifest(), codexVersion: "3.0.0" };
  const textB = JSON.stringify(manifestB);
  const shaB = contentHashHex(bytes(textB));

  const r2Objects = fixtureR2Objects(manifestA);
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;

  let terminatedOld = 0;
  const wfInstances = new Map();
  const env = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        const inst = {
          id: opts.id,
          currentState: "running",
          async status() { return { status: this.currentState }; },
          async terminate() { terminatedOld += 1; this.currentState = "terminated"; },
        };
        wfInstances.set(opts.id, inst);
        return inst;
      },
      async get(id) {
        if (id === "rpc-glitch-peer") {
          throw new Error("Workflow RPC HTTP 503 (request id 6c404ab)");
        }
        return wfInstances.get(id) || null;
      },
    },
  };

  // 1. startSync launches A, then when R2 updates to B, startSync terminates A and updates active-sync.json to B.
  const syncA = await startSync(env, {});
  assert.equal(syncA.created, true);
  r2Objects.set("latest/manifest", bytes(textB));
  r2Objects.set("latest/checksums", bytes(`${shaB}  release-manifest.json\n`));
  const syncB = await startSync(env, {});
  assert.equal(syncB.created, true);
  assert.equal(terminatedOld, 1, "startSync must terminate superseded active workflow");

  // 2. Queued Workflow A fails immediately in discoverSourceManifest when payload.manifestSha256 != current R2.
  await assert.rejects(
    () => discoverSourceManifest(env, "", shaA),
    (err) => err instanceof SupersededMirrorError && isSupersededError(err),
  );

  // 3. Stale Workflow A resuming per-alias commitSingleAlias is fenced by expectedManifestSha256 & instanceId,
  //    and rollbackCommittedAliases refuses to overwrite newer release B!
  s3.objects.set("stage-a/win", objectEntry("WIN-A", new Date(), { syncSha256: "a".repeat(64) }));
  s3.objects.set("latest/win", objectEntry("WIN-B", new Date(), { syncSha256: "b".repeat(64) }));
  await assert.rejects(
    () =>
      commitSingleAlias(env, "stage-a/win", "latest/win", {
        keepBackup: true,
        expectedManifestSha256: shaA,
        instanceId: syncA.id,
      }),
    (err) => isSupersededError(err),
  );
  assert.equal(text(s3.objects.get("latest/win").bytes), "WIN-B");
  const skippedRb = await rollbackCommittedAliases(
    env,
    [{ aliasKey: "latest/win", backupKey: "latest/win.rollback", hadExisting: true }],
    { expectedManifestSha256: shaA, instanceId: syncA.id },
  );
  assert.equal(skippedRb.skippedSuperseded, true);
  assert.equal(text(s3.objects.get("latest/win").bytes), "WIN-B");

  // 4. Step retry on commitSingleAlias(..., { keepBackup: true }) preserves original .rollback ("OLD!") instead of clobbering with "NEXT".
  s3.objects.set("stage-b/mac", objectEntry("NEXT", new Date(), { syncSha256: "c".repeat(64) }));
  s3.objects.set("latest/mac-arm64", objectEntry("OLD!", new Date(), { syncSha256: "d".repeat(64) }));
  const attempt1 = await commitSingleAlias(env, "stage-b/mac", "latest/mac-arm64", {
    keepBackup: true,
    expectedManifestSha256: shaB,
    instanceId: syncB.id,
  });
  const attempt2 = await commitSingleAlias(env, "stage-b/mac", "latest/mac-arm64", {
    keepBackup: true,
    expectedManifestSha256: shaB,
    instanceId: syncB.id,
  });
  assert.equal(attempt1.hadExisting, true);
  assert.equal(attempt2.hadExisting, true);
  assert.equal(text(s3.objects.get("latest/mac-arm64.rollback").bytes), "OLD!");
  await rollbackCommittedAliases(env, [attempt2], { expectedManifestSha256: shaB, instanceId: syncB.id });
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "OLD!");

  // 5. Failed backup COPY (200 + <Error>) must NOT accept a pre-existing wrong multipart .rollback object.
  let failBackup200 = true;
  const s3Multipart = createMockS3({
    onCopy(src, dst) {
      if (failBackup200 && src === "latest/mp" && dst === "latest/mp.rollback") {
        return new Response("<Error><Code>InternalError</Code></Error>", { status: 200 });
      }
      return null;
    },
  });
  globalThis.fetch = s3Multipart.fetch;
  s3Multipart.objects.set("stage/mp", objectEntry("NEW!", new Date(), { etag: '"111-2"', syncSha256: "e".repeat(64) }));
  s3Multipart.objects.set("latest/mp", objectEntry("OLD!", new Date(), { etag: '"222-2"', syncSha256: "" }));
  s3Multipart.objects.set("latest/mp.rollback", objectEntry("BAD!", new Date(), { etag: '"333-2"', syncSha256: "" }));
  await assert.rejects(() =>
    commitSingleAlias({ ...fixtureEnv(r2Objects), SECONDARY_S3_MAX_ATTEMPTS: "2" }, "stage/mp", "latest/mp"),
  );
  assert.equal(text(s3Multipart.objects.get("latest/mp").bytes), "OLD!");

  // 6. uploadObjectToStage rejects checksums mismatching manifestSha256 and overwrites unstamped stage manifest.
  globalThis.fetch = s3.fetch;
  const planB = decoratePlanWithStage(
    buildObjectPlan(manifestB, deriveReleaseTag(manifestB), {
      manifestText: textB,
      manifestSha256: shaB,
      secondaryPrefix: "prefixed",
    }),
    "inst-prefixed",
    { SECONDARY_S3_PREFIX: "prefixed" },
  );
  assert.ok(planB.stagePrefix.startsWith("prefixed/staging/secondary-sync/"));
  const manifestItemB = planB.items.find((i) => i.id === "manifest");
  // Same-size unstamped stage object with wrong bytes must NOT be skipped!
  s3.objects.set(manifestItemB.stageKey, objectEntry("X".repeat(textB.length), new Date(), { syncSha256: "" }));
  const upManifest = await uploadObjectToStage(env, manifestItemB, { forceUpload: false });
  assert.equal(upManifest.uploaded, true);
  assert.equal(text(s3.objects.get(manifestItemB.stageKey).bytes), textB);

  const checksumsItemB = planB.items.find((i) => i.id === "checksums");
  r2Objects.set("latest/checksums", bytes(`${shaA}  release-manifest.json\n`));
  await assert.rejects(
    () => uploadObjectToStage(env, checksumsItemB, { forceUpload: true }),
    /does not match expected release checksums/,
  );

  // 7. belongsToActiveWorkflow fails safe when Workflow RPC throws a transient 503 error (even with '404' in request id).
  const old = new Date("2020-01-01T00:00:00Z");
  s3.objects.set("staging/secondary-sync/codex-app-3.0.0/rpc-glitch-peer/objects/part", objectEntry("keep", old));
  const rpcPrune = await pruneAbandonedStageObjects(env, "staging/secondary-sync/codex-app-3.0.0/current", {
    graceHours: 1,
  });
  assert.equal(rpcPrune.deleted.includes("staging/secondary-sync/codex-app-3.0.0/rpc-glitch-peer/objects/part"), false);

  // 8. Unchanged pre-existing installer is NOT deleted on group rollback; appcast mismatch is rejected;
  //    delta URL with %20 and ?query resolves decoded basename; SECONDARY_S3_PREFIX with '/objects/' cleans safely.
  s3.objects.set("stage-same/win", objectEntry("SAME", new Date(), { syncSha256: "f".repeat(64) }));
  s3.objects.set("latest/win-same", objectEntry("SAME", new Date(), { syncSha256: "f".repeat(64) }));
  const sameCommit = await commitSingleAlias(env, "stage-same/win", "latest/win-same", {
    keepBackup: true,
    expectedManifestSha256: shaB,
    instanceId: syncB.id,
  });
  assert.equal(sameCommit.hadExisting, true);
  await rollbackCommittedAliases(env, [sameCommit], { expectedManifestSha256: shaB, instanceId: syncB.id });
  assert.equal(text(s3.objects.get("latest/win-same").bytes), "SAME");

  const deltaUrlManifest = fixtureManifest();
  deltaUrlManifest.sources.macos.arm64.appcast.deltas = [
    { url: "https://persistent.oaistatic.com/codex-app-prod/Update%20A.delta?expires=1" },
  ];
  const deltaPlan = buildObjectPlan(deltaUrlManifest, deriveReleaseTag(deltaUrlManifest));
  assert.equal(
    deltaPlan.items.find((i) => i.role === "delta" && i.id.includes("arm64")).sourceKey,
    "latest/mac/arm64/Update A.delta",
  );

  const appcastItemB = planB.items.find((i) => i.id === "appcast-arm64");
  r2Objects.set(
    "latest/appcast.xml",
    bytes('<rss><channel><item><enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-9.9.9.zip" /></item></channel></rss>'),
  );
  await assert.rejects(
    () => uploadObjectToStage(env, appcastItemB, { forceUpload: false, singlePutMaxBytes: 0 }),
    /does not match manifest appcast/,
  );

  const trickyStage = decoratePlanWithStage(
    buildObjectPlan(manifestB, deriveReleaseTag(manifestB), { secondaryPrefix: "team/objects/east" }),
    "inst-clean",
    { SECONDARY_S3_PREFIX: "team/objects/east" },
  );
  s3.objects.set("team/objects/", objectEntry("keep-marker"));
  await cleanupStageObjects(env, trickyStage.items);
  assert.equal(s3.objects.has("team/objects/"), true, "cleanupStageObjects must use lastIndexOf('/objects/')");

  // 9. Per-instance stagePrefix backups isolate Workflow B's recovery data from delayed Workflow A cleanup!
  s3.objects.set("stage-iso/win", objectEntry("ISO-B", new Date(), { syncSha256: "1".repeat(64) }));
  s3.objects.set("latest/win-iso", objectEntry("ISO-ORIG", new Date(), { syncSha256: "2".repeat(64) }));
  const isoB = await commitSingleAlias(env, "stage-iso/win", "latest/win-iso", {
    keepBackup: true,
    expectedManifestSha256: shaB,
    instanceId: syncB.id,
    stagePrefix: "staging/secondary-sync/codex-app-3.0.0/inst-b",
  });
  assert.ok(isoB.backupKey.startsWith("staging/secondary-sync/codex-app-3.0.0/inst-b/backups/"));
  await cleanupRollbackBackups(env, [
    {
      aliasKey: "latest/win-iso",
      backupKey: "staging/secondary-sync/codex-app-2.0.0/inst-a/backups/latest-win-iso.rollback",
      stateKey: "staging/secondary-sync/codex-app-2.0.0/inst-a/backups/latest-win-iso.state.json",
    },
  ]);
  await rollbackCommittedAliases(env, [isoB], { expectedManifestSha256: shaB, instanceId: syncB.id });
  assert.equal(text(s3.objects.get("latest/win-iso").bytes), "ISO-ORIG");
});

test("retains unrestored rollback backup on persistent 502, clears restored marker on restarted recommit, and recovers from cleanup DELETE 503", async () => {
  const manifest = fixtureManifest();
  const manifestText = JSON.stringify(manifest);
  const manifestSha = contentHashHex(bytes(manifestText));
  const r2Objects = fixtureR2Objects(manifest);
  let blockCommitAndRestore = true;
  let failCleanupDeleteOnce = false;
  let cleanupDeleteFailed = false;

  const s3 = createMockS3({
    onCopy(src, dst) {
      if (blockCommitAndRestore && dst === "latest/win-x64") {
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
    onDelete(key) {
      if (failCleanupDeleteOnce && !cleanupDeleteFailed && key.endsWith(".rollback")) {
        cleanupDeleteFailed = true;
        return new Response("Service Unavailable", { status: 503 });
      }
      return null;
    },
  });
  globalThis.fetch = s3.fetch;

  const env = { ...fixtureEnv(r2Objects), SECONDARY_S3_MAX_ATTEMPTS: "1" };
  const stagePrefix = "staging/secondary-sync/codex-app-2.0.0/inst-502";
  s3.objects.set(`${stagePrefix}/objects/win-x64`, objectEntry("NEW-WIN", new Date(), { syncSha256: "a".repeat(64) }));
  s3.objects.set("latest/win-x64", objectEntry("LIVE-WIN", new Date(), { syncSha256: "b".repeat(64) }));

  // 1. Persistent 502 during commit AND restore: failed alias never enters committedAliases,
  //    rollbackCommittedAliases scans stagePrefix/backups/*.state.json and throws on 502,
  //    and cleanupStageObjects MUST retain the verified .rollback backup even if preserveBackups=false!
  await assert.rejects(() =>
    commitSingleAlias(env, `${stagePrefix}/objects/win-x64`, "latest/win-x64", {
      keepBackup: true,
      stagePrefix,
    }),
  );
  await assert.rejects(() =>
    rollbackCommittedAliases(env, [], { stagePrefix }),
  );
  await cleanupStageObjects(env, [{ stageKey: `${stagePrefix}/objects/win-x64` }], stagePrefix, {
    preserveBackups: false,
  });
  const retainedBackups = [...s3.objects.keys()].filter(
    (k) => k.startsWith(`${stagePrefix}/backups/`) && k.endsWith(".rollback"),
  );
  assert.equal(retainedBackups.length, 1, "unrestored .rollback backup must survive failure cleanup");
  assert.equal(text(s3.objects.get(retainedBackups[0]).bytes), "LIVE-WIN");

  // Once 502 clears, rollbackCommittedAliases([], { stagePrefix }) restores LIVE-WIN from the retained backup!
  blockCommitAndRestore = false;
  const recovered = await rollbackCommittedAliases(env, [], { stagePrefix });
  assert.deepEqual(recovered.restored, ["latest/win-x64"]);
  assert.equal(text(s3.objects.get("latest/win-x64").bytes), "LIVE-WIN");

  // 2. Partial rollback leaves restored: true on mac-intel; restarting the SAME workflow instanceId
  //    recommits mac-intel and MUST clear restored: true so a subsequent rollback restores OLD-INTEL!
  const restartPrefix = "staging/secondary-sync/codex-app-2.0.0/inst-restart";
  s3.objects.set(`${restartPrefix}/objects/mac-arm`, objectEntry("NEW-ARM", new Date(), { syncSha256: "1".repeat(64) }));
  s3.objects.set(`${restartPrefix}/objects/mac-intel`, objectEntry("NEW-INTEL", new Date(), { syncSha256: "2".repeat(64) }));
  s3.objects.set("latest/mac-arm64", objectEntry("OLD-ARM", new Date(), { syncSha256: "3".repeat(64) }));
  s3.objects.set("latest/mac-intel", objectEntry("OLD-INTEL", new Date(), { syncSha256: "4".repeat(64) }));

  const cArm1 = await commitSingleAlias(env, `${restartPrefix}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix: restartPrefix,
  });
  const cIntel1 = await commitSingleAlias(env, `${restartPrefix}/objects/mac-intel`, "latest/mac-intel", {
    keepBackup: true,
    stagePrefix: restartPrefix,
  });

  // Simulate partial rollback: mac-intel restores and writes restored: true, then mac-arm restore fails!
  const s3Partial = createMockS3({
    onCopy(src, dst) {
      if (dst === "latest/mac-arm64") {
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3Partial.objects.set(k, v);
  globalThis.fetch = s3Partial.fetch;
  await assert.rejects(() =>
    rollbackCommittedAliases(env, [cArm1, cIntel1], { stagePrefix: restartPrefix }),
  );
  assert.equal(text(s3Partial.objects.get("latest/mac-intel").bytes), "OLD-INTEL");

  // Restart same workflow instance: recommit mac-arm and mac-intel, then roll back again!
  for (const [k, v] of s3Partial.objects.entries()) s3.objects.set(k, v);
  globalThis.fetch = s3.fetch;
  const cArm2 = await commitSingleAlias(env, `${restartPrefix}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix: restartPrefix,
  });
  const cIntel2 = await commitSingleAlias(env, `${restartPrefix}/objects/mac-intel`, "latest/mac-intel", {
    keepBackup: true,
    stagePrefix: restartPrefix,
  });
  assert.equal(text(s3.objects.get("latest/mac-intel").bytes), "NEW-INTEL");

  // 3. Inject 503 on cleanup DELETE of the second .rollback after the first .rollback+.state.json were deleted:
  //    retrying rollbackCommittedAliases must succeed via _batch_restored.json checkpoint!
  let rollbackDeleteCount = 0;
  const s3DelRetry = createMockS3({
    onDelete(key) {
      if (key.endsWith(".rollback")) {
        rollbackDeleteCount += 1;
        if (rollbackDeleteCount === 2) {
          return new Response("Service Unavailable", { status: 503 });
        }
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3DelRetry.objects.set(k, v);
  globalThis.fetch = s3DelRetry.fetch;

  await assert.rejects(() =>
    rollbackCommittedAliases(env, [cArm2, cIntel2], { stagePrefix: restartPrefix }),
  );
  // Both live aliases are ALREADY restored to OLD-ARM and OLD-INTEL!
  assert.equal(text(s3DelRetry.objects.get("latest/mac-arm64").bytes), "OLD-ARM");
  assert.equal(text(s3DelRetry.objects.get("latest/mac-intel").bytes), "OLD-INTEL");

  // Step retry succeeds cleanly without failing on the already-deleted first .rollback!
  const retryResult = await rollbackCommittedAliases(env, [cArm2, cIntel2], {
    stagePrefix: restartPrefix,
  });
  assert.equal(retryResult.restored.length, 2);
  assert.equal(text(s3DelRetry.objects.get("latest/mac-arm64").bytes), "OLD-ARM");
  assert.equal(text(s3DelRetry.objects.get("latest/mac-intel").bytes), "OLD-INTEL");
  assert.equal(
    [...s3DelRetry.objects.keys()].some((k) => k.startsWith(`${restartPrefix}/backups/`)),
    false,
  );
});

test("validates Sparkle enclosureSignature, required version tags, exact delta set, and triggers reconcileSync repair on feed drift", async () => {
  const manifest = fixtureManifest();
  manifest.sources.macos.arm64.appcast = {
    shortVersionString: "2.0.0",
    version: "100",
    mirrorEnclosureBasename: "Codex-darwin-arm64-2.0.0.zip",
    enclosureLength: 9,
    enclosureSignature: "GOOD_MAIN_SIG==",
    deltas: [
      {
        basename: "Codex9999-live-arm64.delta",
        length: 11,
        deltaFrom: "99",
        edSignature: "GOOD_DELTA_SIG==",
      },
    ],
  };
  manifest.sources.macos.x64.appcast = {
    shortVersionString: "2.0.0",
    version: "100",
    mirrorEnclosureBasename: "Codex-darwin-x64-2.0.0.zip",
    enclosureLength: 7,
    enclosureSignature: "GOOD_X64_SIG==",
    deltas: [],
  };

  const validArmFeed = `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip" length="9" type="application/octet-stream" sparkle:edSignature="GOOD_MAIN_SIG==" /><sparkle:deltas><enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex9999-live-arm64.delta" sparkle:deltaFrom="99" length="11" type="application/octet-stream" sparkle:edSignature="GOOD_DELTA_SIG==" /></sparkle:deltas></item></channel></rss>`;
  const validX64Feed = `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url="https://codexapp.agentsmirror.com/latest/mac/intel/Codex-darwin-x64-2.0.0.zip" length="7" type="application/octet-stream" sparkle:edSignature="GOOD_X64_SIG==" /></item></channel></rss>`;

  const manifestText = JSON.stringify(manifest);
  const manifestSha = contentHashHex(bytes(manifestText));
  const r2Objects = fixtureR2Objects(manifest, {
    "latest/appcast.xml": validArmFeed,
    "latest/appcast-x64.xml": validX64Feed,
  });
  const s3 = createMockS3();
  globalThis.fetch = s3.fetch;
  const env = fixtureEnv(r2Objects);
  const plan = decoratePlanWithStage(
    buildObjectPlan(manifest, deriveReleaseTag(manifest), {
      manifestText,
      manifestSha256: manifestSha,
    }),
    "inst-appcast",
    env,
  );
  const armAppcastItem = plan.items.find((i) => i.id === "appcast-arm64");

  const invalidFeeds = [
    // Obsolete primary enclosureSignature
    validArmFeed.replace("GOOD_MAIN_SIG==", "OBSOLETE_SIG=="),
    // Missing <sparkle:version>
    validArmFeed.replace("<sparkle:version>100</sparkle:version>", ""),
    // Missing <sparkle:shortVersionString>
    validArmFeed.replace("<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>", ""),
    // Extra unreferenced delta still present in feed
    validArmFeed.replace(
      "</sparkle:deltas>",
      '<enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/Codex9999-removed-arm64.delta" sparkle:deltaFrom="98" length="10" type="application/octet-stream" sparkle:edSignature="OLD==" /></sparkle:deltas>',
    ),
    // Removed required delta
    validArmFeed.replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/, ""),
    // Obsolete delta edSignature
    validArmFeed.replace("GOOD_DELTA_SIG==", "BAD_DELTA_SIG=="),
    // Path-prefixed /staging/latest/mac/... URL that would 404 on router
    validArmFeed.replace(
      "https://codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
      "https://codexapp.agentsmirror.com/staging/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
    ),
    // Wrong origin host
    validArmFeed.replace(
      "https://codexapp.agentsmirror.com/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
      "https://evil.example/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip",
    ),
    // <sparkle:version> present only inside an XML comment
    validArmFeed.replace(
      "<sparkle:version>100</sparkle:version>",
      "<!-- <sparkle:version>100</sparkle:version> -->",
    ),
    // Missing xmlns:sparkle namespace binding (unbound prefix)
    validArmFeed.replace(
      'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" ',
      "",
    ),
    // Second <item> advertising a higher build on an external host
    validArmFeed.replace(
      "</channel>",
      '<item><sparkle:version>9999</sparkle:version><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString><enclosure url="https://evil.example/latest/mac/arm64/Codex.zip" sparkle:edSignature="EVIL==" /></item></channel>',
    ),
    // Invalid XML 1.0 control character reference &#x1;
    validArmFeed.replace("<channel>", "<channel><title>Codex&#x1;</title>"),
    // Adjacent attributes without XML whitespace
    validArmFeed.replace('length="9" type=', 'length="9"type='),
    // Delta enclosure with conflicting sparkle:version
    validArmFeed.replace('sparkle:deltaFrom="99"', 'sparkle:deltaFrom="99" sparkle:version="999"'),
    // Misplaced whitespace inside self-closing '/ >'
    validArmFeed.replace(" />", " / >"),
    // Uppercase '#X' hex character reference rejected by XML 1.0
    validArmFeed.replace("<channel>", "<channel><title>Codex&#X31;</title>"),
  ];

  for (const badFeed of invalidFeeds) {
    r2Objects.set("latest/appcast.xml", bytes(badFeed));
    await assert.rejects(
      () => uploadObjectToStage(env, armAppcastItem, { forceUpload: true, singlePutMaxBytes: 0 }),
      /does not match manifest appcast/,
    );
  }

  // Invalid UTF-8 bytes inside title must ALSO fail closed instead of substituting U+FFFD!
  const prefixBytes = bytes('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><title>');
  const suffixBytes = bytes(validArmFeed.slice(validArmFeed.indexOf("<sparkle:version>")));
  const invalidUtf8Feed = concatBytes([prefixBytes, new Uint8Array([0xff, 0xfe]), bytes("</title>"), suffixBytes]);
  r2Objects.set("latest/appcast.xml", invalidUtf8Feed);
  await assert.rejects(
    () => uploadObjectToStage(env, armAppcastItem, { forceUpload: true, singlePutMaxBytes: 0 }),
    /invalid UTF-8/i,
  );

  // Restore valid R2 feed and stage + commit every item cleanly.
  r2Objects.set("latest/appcast.xml", bytes(validArmFeed));
  for (const item of plan.items) {
    await uploadObjectToStage(env, item, { forceUpload: true });
    for (const aliasKey of item.aliasKeys) {
      await commitSingleAlias(env, item.stageKey, aliasKey, { keepBackup: false });
    }
  }

  let createdCount = 0;
  const envWithWf = {
    ...env,
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        createdCount += 1;
        return { id: opts.id, async status() { return { status: "running" }; } };
      },
      async get() {
        return null;
      },
    },
  };

  // Matching S3 feed -> skipped: true.
  const okReconcile = await reconcileSync(envWithWf, {});
  assert.equal(okReconcile.skipped, true);

  // Stale feed on S3 (obsolete signature + extra delta) while R2 holds corrected feed -> MUST NOT skip!
  s3.objects.set(
    "latest/appcast.xml",
    objectEntry(invalidFeeds[0], new Date(), { syncSha256: contentHashHex(bytes(invalidFeeds[0])) }),
  );
  const repairReconcile = await reconcileSync(envWithWf, {});
  assert.equal(repairReconcile.skipped, undefined);
  assert.equal(repairReconcile.created, true);
  assert.equal(createdCount, 1);
});

test("continues rolling back healthy aliases when another alias fails 502, protects backups across pruning, and keeps inline restore backups during group commit", async () => {
  const manifest = fixtureManifest();
  const r2Objects = fixtureR2Objects(manifest);
  const old = new Date("2020-01-01T00:00:00Z");
  const stagePrefix = "staging/secondary-sync/codex-app-2.0.0/inst-cont";

  let failSecondCommit = true;
  let blockSecondRestore = true;
  let failStateDelete503 = true;

  const s3 = createMockS3({
    onCopy(src, dst) {
      if (failSecondCommit && src.endsWith("/objects/mac-intel") && dst === "latest/mac-intel") {
        return new Response("Bad Gateway", { status: 502 });
      }
      if (blockSecondRestore && src.includes("/backups/") && dst === "latest/mac-intel") {
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
    onDelete(key) {
      if (failStateDelete503 && key.endsWith(".state.json")) {
        return new Response("Service Unavailable", { status: 503 });
      }
      return null;
    },
  });
  globalThis.fetch = s3.fetch;

  const env = { ...fixtureEnv(r2Objects), SECONDARY_S3_MAX_ATTEMPTS: "1" };
  s3.objects.set(`${stagePrefix}/objects/mac-arm`, objectEntry("NEW-ARM", old, { syncSha256: "1".repeat(64) }));
  s3.objects.set(`${stagePrefix}/objects/mac-intel`, objectEntry("NEW-INTEL", old, { syncSha256: "2".repeat(64) }));
  s3.objects.set("latest/mac-arm64", objectEntry("OLD-ARM", old, { syncSha256: "3".repeat(64) }));
  s3.objects.set("latest/mac-intel", objectEntry("OLD-INTEL", old, { syncSha256: "4".repeat(64) }));

  // 1. Alias 1 commits; Alias 2 fails commit AND restore with 502.
  const c1 = await commitSingleAlias(env, `${stagePrefix}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix,
  });
  await assert.rejects(() =>
    commitSingleAlias(env, `${stagePrefix}/objects/mac-intel`, "latest/mac-intel", {
      keepBackup: true,
      stagePrefix,
    }),
  );

  // Batch rollback throws because mac-intel is still returning 502, YET healthy mac-arm64 MUST already be rolled back to OLD-ARM!
  await assert.rejects(() =>
    rollbackCommittedAliases(env, [c1], { stagePrefix }),
  );
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "OLD-ARM");

  // Backdate backup timestamps past grace period -> pruneAbandonedStageObjects MUST NOT delete backups while mac-intel is unrestored!
  for (const [k, v] of s3.objects.entries()) {
    if (k.startsWith(`${stagePrefix}/backups/`)) {
      v.lastModified = old;
    }
  }
  await pruneAbandonedStageObjects(env, "staging/secondary-sync/codex-app-2.0.0/other", { graceHours: 1 });

  // Once 502 & 503 clear, batch rollback restores mac-intel too and cleans up backups!
  blockSecondRestore = false;
  failStateDelete503 = false;
  const finalRb = await rollbackCommittedAliases(env, [c1], { stagePrefix });
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "OLD-ARM");
  assert.equal(text(s3.objects.get("latest/mac-intel").bytes), "OLD-INTEL");
  assert.equal(finalRb.restored.length, 2);

  // 2. Inline restore during keepBackup=true group commit must NOT delete .rollback/.state.json on 503!
  const stageInline = "staging/secondary-sync/codex-app-2.0.0/inst-inline503";
  s3.objects.set(`${stageInline}/objects/mac-arm`, objectEntry("NEW-ARM", old, { syncSha256: "1".repeat(64) }));
  s3.objects.set(`${stageInline}/objects/mac-intel`, objectEntry("NEW-INTEL", old, { syncSha256: "2".repeat(64) }));
  failStateDelete503 = true;
  const ci1 = await commitSingleAlias(env, `${stageInline}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix: stageInline,
  });
  await assert.rejects(() =>
    commitSingleAlias(env, `${stageInline}/objects/mac-intel`, "latest/mac-intel", {
      keepBackup: true,
      stagePrefix: stageInline,
    }),
  );
  // Inline restore succeeded for mac-intel (keeping backup + restored: true without issuing DELETE); now storage recovers -> batch rollback succeeds!
  failStateDelete503 = false;
  await rollbackCommittedAliases(env, [ci1], { stagePrefix: stageInline });
  assert.equal(text(s3.objects.get("latest/mac-arm64").bytes), "OLD-ARM");
  assert.equal(text(s3.objects.get("latest/mac-intel").bytes), "OLD-INTEL");

  // 3. Persistent 502 on GET of one .state.json during backup discovery still restores all healthy aliases!
  const stageState502 = "staging/secondary-sync/codex-app-2.0.0/inst-state502";
  s3.objects.set(`${stageState502}/objects/mac-arm`, objectEntry("NEW-ARM", old, { syncSha256: "1".repeat(64) }));
  s3.objects.set(`${stageState502}/objects/mac-intel`, objectEntry("NEW-INTEL", old, { syncSha256: "2".repeat(64) }));
  const cs1 = await commitSingleAlias(env, `${stageState502}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix: stageState502,
  });
  failSecondCommit = true;
  blockSecondRestore = true;
  await assert.rejects(() =>
    commitSingleAlias(env, `${stageState502}/objects/mac-intel`, "latest/mac-intel", {
      keepBackup: true,
      stagePrefix: stageState502,
    }),
  );
  const brokenStateKey = [...s3.objects.keys()].find(
    (k) => k.startsWith(`${stageState502}/backups/`) && k.includes("mac-intel") && k.endsWith(".state.json"),
  );
  const s3State502 = createMockS3({
    onGet(key) {
      if (key === brokenStateKey) {
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3State502.objects.set(k, v);
  globalThis.fetch = s3State502.fetch;
  await assert.rejects(() => rollbackCommittedAliases(env, [cs1], { stagePrefix: stageState502 }));
  assert.equal(text(s3State502.objects.get("latest/mac-arm64").bytes), "OLD-ARM", "healthy alias must restore even when peer .state.json GET returns 502");

  // Also when mac-intel deletion took effect + .state.json is 502 while .rollback IS readable -> mac-intel MUST STILL restore!
  const s3UnreadableStateReadableBackup = createMockS3({
    onGet(key) {
      if (key === brokenStateKey) {
        return new Response("Bad Gateway", { status: 502 });
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3UnreadableStateReadableBackup.objects.set(k, v);
  globalThis.fetch = s3UnreadableStateReadableBackup.fetch;
  await assert.rejects(() => rollbackCommittedAliases(env, [cs1], { stagePrefix: stageState502 }));
  assert.equal(text(s3UnreadableStateReadableBackup.objects.get("latest/mac-intel").bytes), "OLD-INTEL", "readable .rollback must restore in-flight alias even when .state.json GET is 502");

  // 4. 503 midway through post-switchover backup deletion + pruning 503 + workflow restart MUST NOT undo completed switchover!
  const stageDone = "staging/secondary-sync/codex-app-2.0.0/inst-done";
  s3.objects.set(`${stageDone}/objects/mac-arm`, objectEntry("NEW-ARM", old, { syncSha256: "1".repeat(64) }));
  s3.objects.set(`${stageDone}/objects/manifest`, objectEntry("NEW-MANIFEST", old, { syncSha256: "9".repeat(64) }));
  s3.objects.set("latest/mac-arm64", objectEntry("OLD-ARM", old, { syncSha256: "3".repeat(64) }));
  s3.objects.set("latest/manifest", objectEntry("OLD-MANIFEST", old, { syncSha256: "8".repeat(64) }));
  globalThis.fetch = s3.fetch;
  failSecondCommit = false;
  blockSecondRestore = false;
  const cd1 = await commitSingleAlias(env, `${stageDone}/objects/mac-arm`, "latest/mac-arm64", {
    keepBackup: true,
    stagePrefix: stageDone,
  });
  const cd2 = await commitSingleAlias(env, `${stageDone}/objects/manifest`, "latest/manifest", {
    keepBackup: true,
    stagePrefix: stageDone,
  });
  let postCommitDeletes = 0;
  const s3PostCommit = createMockS3({
    onDelete(key) {
      if (key.endsWith(".rollback")) {
        postCommitDeletes += 1;
        if (postCommitDeletes === 2) {
          return new Response("Service Unavailable", { status: 503 });
        }
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3PostCommit.objects.set(k, v);
  globalThis.fetch = s3PostCommit.fetch;
  await assert.rejects(() =>
    cleanupRollbackBackups(env, [cd1, cd2], { stagePrefix: stageDone }),
  );
  // Even if pruneAbandonedStageObjects runs after grace period and hits 503 on remaining .rollback, _batch_committed.json MUST remain!
  for (const [k, v] of s3PostCommit.objects.entries()) {
    if (k.startsWith(`${stageDone}/`)) v.lastModified = old;
  }
  postCommitDeletes = 1; // next .rollback DELETE throws 503
  await assert.rejects(() =>
    pruneAbandonedStageObjects(env, "staging/secondary-sync/codex-app-2.0.0/other", { graceHours: 1 }),
  );
  assert.equal(
    s3PostCommit.objects.has(`${stageDone}/backups/_batch_committed.json`),
    true,
    "_batch_committed.json must be deleted strictly after all .rollback copies",
  );
  // Restarting and even calling rollbackCommittedAliases MUST preserve NEW-ARM and NEW-MANIFEST!
  const skippedCompletedRb = await rollbackCommittedAliases(env, [cd1, cd2], { stagePrefix: stageDone });
  assert.equal(skippedCompletedRb.skippedAlreadyCommitted, true);
  assert.equal(text(s3PostCommit.objects.get("latest/mac-arm64").bytes), "NEW-ARM");
  assert.equal(text(s3PostCommit.objects.get("latest/manifest").bytes), "NEW-MANIFEST");

  // 5. Commit retry when .state.json is 404 (both after alias delete AND after candidate copy) preserves original backup,
  //    and rollback restores equal-length legacy multipart backups instead of skipping on size!
  const stageRetry404 = "staging/secondary-sync/codex-app-2.0.0/inst-retry404";
  globalThis.fetch = s3.fetch;
  s3.objects.set(
    `${stageRetry404}/objects/win`,
    objectEntry("NEW!", old, { etag: '"111-2"', syncSha256: contentHashHex(bytes("NEW!")) }),
  );
  const detWin = aliasBackupKeys(`${stageRetry404}/objects/win`, "latest/win-x64", stageRetry404);
  // Case 5a: alias already deleted, .state.json missing, .rollback holds OLD!
  s3.objects.delete("latest/win-x64");
  s3.objects.delete(detWin.stateKey);
  s3.objects.set(detWin.backupKey, objectEntry("OLD!", old, { etag: '"222-2"', syncSha256: "" }));
  const crA = await commitSingleAlias(env, `${stageRetry404}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    stagePrefix: stageRetry404,
  });
  assert.equal(crA.hadExisting, true);
  assert.equal(text(s3.objects.get(detWin.backupKey).bytes), "OLD!");

  // Case 5b: alias already holds candidate NEW!, .state.json missing, .rollback holds equal-length legacy multipart OLD!
  s3.objects.delete(detWin.stateKey);
  const crB = await commitSingleAlias(env, `${stageRetry404}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    stagePrefix: stageRetry404,
  });
  assert.equal(crB.hadExisting, true);
  assert.equal(text(s3.objects.get(detWin.backupKey).bytes), "OLD!", "retry must not overwrite backup with candidate");
  await rollbackCommittedAliases(env, [crB], { stagePrefix: stageRetry404 });
  assert.equal(text(s3.objects.get("latest/win-x64").bytes), "OLD!", "equal-length multipart backup must be copied back");

  // 6. Backup failing verification on attempt 1 MUST NOT be reused on retry when live alias still holds original bytes;
  //    invalid UTF-8 in R2 manifest is rejected, while invalid UTF-8 in S3 manifest triggers reconcileSync repair!
  const stageShortBk = "staging/secondary-sync/codex-app-2.0.0/inst-shortbk";
  const detShort = aliasBackupKeys(`${stageShortBk}/objects/win`, "latest/win-x64", stageShortBk);
  s3.objects.set(`${stageShortBk}/objects/win`, objectEntry("NEW-PAYLOAD", old, { syncSha256: "9".repeat(64) }));
  s3.objects.set("latest/win-x64", objectEntry("LIVE-ORIGINAL", old, { syncSha256: "8".repeat(64) }));
  let corruptFirstBackupCopy = true;
  const s3ShortBk = createMockS3({
    onCopy(src, dst, store) {
      if (corruptFirstBackupCopy && src === "latest/win-x64" && dst === detShort.backupKey) {
        corruptFirstBackupCopy = false;
        store.set(dst, objectEntry("BAD", old, { syncSha256: "7".repeat(64) }));
        return new Response('<CopyObjectResult><ETag>"bad"</ETag></CopyObjectResult>', { status: 200 });
      }
      return null;
    },
  });
  for (const [k, v] of s3.objects.entries()) s3ShortBk.objects.set(k, v);
  globalThis.fetch = s3ShortBk.fetch;
  await assert.rejects(
    () => commitSingleAlias(env, `${stageShortBk}/objects/win`, "latest/win-x64", { keepBackup: true, stagePrefix: stageShortBk }),
    /Backup verification failed/,
  );
  // Simulate leftover corrupt 3-byte backup on retry while live alias still holds LIVE-ORIGINAL: retry MUST re-copy LIVE-ORIGINAL!
  s3ShortBk.objects.set(detShort.backupKey, objectEntry("BAD", old, { syncSha256: "7".repeat(64) }));
  const crShortOk = await commitSingleAlias(env, `${stageShortBk}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    stagePrefix: stageShortBk,
  });
  await rollbackCommittedAliases(env, [crShortOk], { stagePrefix: stageShortBk });
  assert.equal(text(s3ShortBk.objects.get("latest/win-x64").bytes), "LIVE-ORIGINAL");

  // Invalid UTF-8 in R2 latest/manifest fails closed in discoverSourceManifest.
  const badR2Manifest = new Map(r2Objects);
  badR2Manifest.set("latest/manifest", new Uint8Array([0x7b, 0x22, 0xff, 0x22, 0x7d]));
  await assert.rejects(() => discoverSourceManifest(fixtureEnv(badR2Manifest)), /invalid UTF-8/i);

  // Invalid UTF-8 in S3 latest/manifest triggers repair in reconcileSync instead of throwing!
  s3ShortBk.objects.set("latest/manifest", objectEntry(new Uint8Array([0x7b, 0xff, 0x7d]), old));
  let repairStarted = 0;
  const envRepair = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        repairStarted += 1;
        return { id: opts.id, async status() { return { status: "running" }; } };
      },
      async get() { return null; },
    },
  };
  const utf8Heal = await reconcileSync(envRepair, {});
  assert.equal(utf8Heal.created, true);
  assert.equal(repairStarted, 1);

  // 7. Truncated HTTP 200 ListBucketResult XML or IsTruncated=true without NextContinuationToken
  //    MUST fail closed and preserve unrestored .rollback backups!
  const stageTruncList = "staging/secondary-sync/codex-app-2.0.0/inst-trunclist";
  const detTrunc = aliasBackupKeys(`${stageTruncList}/objects/win`, "latest/win-x64", stageTruncList);
  const s3TruncList = createMockS3({
    onList(prefix) {
      if (prefix.startsWith(`${stageTruncList}/backups/`)) {
        return new Response("<ListBucketResult><Contents><Key>cut-off", { status: 200 });
      }
      return null;
    },
  });
  s3TruncList.objects.set(detTrunc.backupKey, objectEntry("UNRESTORED-BACKUP", old));
  s3TruncList.objects.set(detTrunc.stateKey, objectEntry(JSON.stringify({ aliasKey: "latest/win-x64", restored: false }), old));
  globalThis.fetch = s3TruncList.fetch;
  await cleanupStageObjects(env, [{ stageKey: `${stageTruncList}/objects/win`, aliasKeys: ["latest/win-x64"] }], {
    stagePrefix: stageTruncList,
  });
  assert.equal(s3TruncList.objects.has(detTrunc.backupKey), true, "truncated LIST XML must retain .rollback");
  await pruneAbandonedStageObjects(env, "staging/secondary-sync/codex-app-2.0.0/other", { graceHours: 1 });
  assert.equal(s3TruncList.objects.has(detTrunc.backupKey), true, "pruner must retain .rollback on truncated LIST XML");

  // 8. Round-11 regressions:
  //    8a) Equal-length live + staged objects with multipart ETag + 403 HEAD fallback MUST reject 3-byte .rollback on both priorState=null and priorState!=null!
  const stageEq403 = "staging/secondary-sync/codex-app-2.0.0/inst-eq403";
  const aliasEq403 = "latest/head-403-win";
  const detEq403 = aliasBackupKeys(`${stageEq403}/objects/win`, aliasEq403, stageEq403);
  let injectShortBackup403 = true;
  const s3Eq403 = createMockS3({
    onCopy(src, dst, store) {
      if (injectShortBackup403 && src === aliasEq403 && dst === detEq403.backupKey) {
        injectShortBackup403 = false;
        store.set(dst, objectEntry("BAD", old, { etag: '"bad-2"', syncSha256: "" }));
        return new Response('<CopyObjectResult><ETag>"bad-2"</ETag></CopyObjectResult>', { status: 200 });
      }
      return null;
    },
  });
  s3Eq403.objects.set(`${stageEq403}/objects/win`, objectEntry("NEW!", old, { etag: '"111-2"', syncSha256: contentHashHex(bytes("NEW!")) }));
  s3Eq403.objects.set(aliasEq403, objectEntry("LIVE", old, { etag: '"222-2"', syncSha256: "" }));
  globalThis.fetch = s3Eq403.fetch;
  await assert.rejects(() =>
    commitSingleAlias(env, `${stageEq403}/objects/win`, aliasEq403, { keepBackup: true, stagePrefix: stageEq403 }),
  );
  s3Eq403.objects.set(detEq403.backupKey, objectEntry("BAD", old, { etag: '"bad-2"', syncSha256: "" }));
  await rollbackCommittedAliases(env, [], { stagePrefix: stageEq403 });
  assert.equal(text(s3Eq403.objects.get(aliasEq403).bytes), "LIVE", "unverified backup must never overwrite LIVE");

  //    8b) Unclosed <Contents> inside <ListBucketResult> and empty <IsTruncated/> MUST fail closed!
  const s3BadXml = createMockS3({
    onList() {
      return new Response("<ListBucketResult><Contents><Key>latest/head-403-win</Key></ListBucketResult>", { status: 200 });
    },
  });
  s3BadXml.objects.set(aliasEq403, objectEntry("LIVE", old));
  globalThis.fetch = s3BadXml.fetch;
  await assert.rejects(() =>
    commitSingleAlias(env, `${stageEq403}/objects/win`, aliasEq403, { keepBackup: true, stagePrefix: stageEq403 }),
  );
  const s3EmptyTrunc = createMockS3({
    onList() {
      return new Response("<ListBucketResult><IsTruncated/></ListBucketResult>", { status: 200 });
    },
  });
  globalThis.fetch = s3EmptyTrunc.fetch;
  await assert.rejects(() => pruneAbandonedStageObjects(env, "", { graceHours: 1 }), /IsTruncated/);

  //    8c) Omitted backup in LIST after 503 DELETE must NOT erase _batch_committed.json in cleanupStageObjects!
  const stageOmit = "staging/secondary-sync/codex-app-2.0.0/inst-omit";
  const detOmitWin = aliasBackupKeys(`${stageOmit}/objects/win`, "latest/win-x64", stageOmit);
  const s3Omit = createMockS3({
    onList(prefix, store) {
      if (prefix.startsWith(`${stageOmit}/backups/`)) {
        const items = [...store.entries()]
          .filter(([k]) => k.startsWith(prefix) && k !== detOmitWin.backupKey)
          .map(([k, v]) => `<Contents><Key>${xmlEscape(k)}</Key><LastModified>${v.lastModified.toISOString()}</LastModified><ETag>${xmlEscape(v.etag)}</ETag><Size>${v.bytes.byteLength}</Size></Contents>`)
          .join("");
        return new Response(`<ListBucketResult>${items}</ListBucketResult>`, { status: 200 });
      }
      return null;
    },
    onDelete(key) {
      if (key === detOmitWin.backupKey) {
        return new Response("Unavailable", { status: 503 });
      }
      return null;
    },
  });
  s3Omit.objects.set(detOmitWin.backupKey, objectEntry("OLD-WIN", old));
  s3Omit.objects.set(
    `${stageOmit}/backups/_batch_committed.json`,
    objectEntry(JSON.stringify({ completed: true, entries: [{ aliasKey: "latest/win-x64", backupKey: detOmitWin.backupKey, stateKey: detOmitWin.stateKey }] }), old),
  );
  globalThis.fetch = s3Omit.fetch;
  await assert.rejects(() =>
    cleanupStageObjects(env, [{ stageKey: `${stageOmit}/objects/win`, aliasKeys: ["latest/win-x64"] }], stageOmit, { switchoverComplete: true }),
  );
  assert.equal(s3Omit.objects.has(`${stageOmit}/backups/_batch_committed.json`), true);

  //    8d) Newly introduced alias (hadExisting=false, restored=false) retains .state.json across pruning until rollback deletes it!
  const stageNewAlias = "staging/secondary-sync/codex-app-2.0.0/inst-newalias";
  const detNewArm = aliasBackupKeys(`${stageNewAlias}/objects/arm`, "latest/win-arm64", stageNewAlias);
  const s3NewAlias = createMockS3();
  s3NewAlias.objects.set("latest/win-arm64", objectEntry("UNPUBLISHED-ARM", old));
  s3NewAlias.objects.set(
    detNewArm.stateKey,
    objectEntry(JSON.stringify({ aliasKey: "latest/win-arm64", backupKey: detNewArm.backupKey, stateKey: detNewArm.stateKey, hadExisting: false, restored: false }), old),
  );
  globalThis.fetch = s3NewAlias.fetch;
  await pruneAbandonedStageObjects(env, "staging/secondary-sync/codex-app-2.0.0/other", { graceHours: 1 });
  assert.equal(s3NewAlias.objects.has(detNewArm.stateKey), true, "unrestored hadExisting=false state must survive pruning");
  const rbNew = await rollbackCommittedAliases(env, [], { stagePrefix: stageNewAlias });
  assert.deepEqual(rbNew.restored, ["latest/win-arm64"]);
  assert.equal(s3NewAlias.objects.has("latest/win-arm64"), false);

  //    8e) Corrupt byte in S3 latest/manifest with intact length & x-amz-meta-sync-sha256 is overwritten on commit!
  const cleanManifestBytes = bytes(JSON.stringify(manifest));
  const cleanManifestSha = contentHashHex(cleanManifestBytes);
  const corruptSameMeta = cleanManifestBytes.slice();
  corruptSameMeta[2] = 0xff;
  s3NewAlias.objects.set("stage-heal/manifest", objectEntry(cleanManifestBytes, old, { syncSha256: cleanManifestSha }));
  s3NewAlias.objects.set("latest/manifest", objectEntry(corruptSameMeta, old, { syncSha256: cleanManifestSha }));
  await commitSingleAlias(env, "stage-heal/manifest", "latest/manifest");
  assert.deepEqual(s3NewAlias.objects.get("latest/manifest").bytes, cleanManifestBytes);

  //    8f) R2 latest/manifest with UTF-8 BOM promotes without SHA-256 mismatch!
  const bomManifestBytes = concatBytes([new Uint8Array([0xef, 0xbb, 0xbf]), cleanManifestBytes]);
  const bomManifestSha = contentHashHex(bomManifestBytes);
  const bomR2 = fixtureR2Objects(manifest);
  bomR2.set("latest/manifest", bomManifestBytes);
  bomR2.set("latest/checksums", bytes(`${bomManifestSha}  release-manifest.json\n`));
  const bomEnv = fixtureEnv(bomR2);
  const bomSource = await discoverSourceManifest(bomEnv);
  assert.equal(bomSource.manifestSha256, bomManifestSha);
  const bomPlan = decoratePlanWithStage(
    buildObjectPlan(bomSource.manifest, bomSource.releaseTag, {
      manifestText: bomSource.manifestText,
      manifestSha256: bomSource.manifestSha256,
    }),
    "inst-bom",
    bomEnv,
  );
  const bomManifestItem = bomPlan.items.find((i) => i.id === "manifest");
  const bomUpload = await uploadObjectToStage(bomEnv, bomManifestItem, { forceUpload: true });
  assert.equal(bomUpload.sha256, bomManifestSha);
  assert.deepEqual(s3NewAlias.objects.get(bomManifestItem.stageKey).bytes, bomManifestBytes);

  // 9. Round-12 regressions:
  //    9a) HEAD 403 + LIST omitting live alias MUST still detect live alias via GET probe and preserve it when COPY fails!
  const stageOmitLive = "staging/secondary-sync/codex-app-2.0.0/inst-omitlive";
  const s3OmitLive = createMockS3({
    onList(prefix) {
      if (prefix === "latest/head-403-win") {
        return new Response("<ListBucketResult></ListBucketResult>", { status: 200 });
      }
      return null;
    },
    onCopy(src, dst, store) {
      if (dst === "latest/head-403-win" && store.has(dst)) {
        return new Response("Overwrite rejected", { status: 502 });
      }
      return null;
    },
  });
  s3OmitLive.objects.set(`${stageOmitLive}/objects/win`, objectEntry("NEW-WIN", old, { syncSha256: contentHashHex(bytes("NEW-WIN")) }));
  s3OmitLive.objects.set("latest/head-403-win", objectEntry("LIVE-WIN", old));
  globalThis.fetch = s3OmitLive.fetch;
  const committedOmitLive = await commitSingleAlias(env, `${stageOmitLive}/objects/win`, "latest/head-403-win", {
    keepBackup: true,
    stagePrefix: stageOmitLive,
  });
  assert.equal(committedOmitLive.hadExisting, true);
  await rollbackCommittedAliases(env, [committedOmitLive], { stagePrefix: stageOmitLive });
  assert.equal(text(s3OmitLive.objects.get("latest/head-403-win").bytes), "LIVE-WIN");

  //    9b) Missing .state.json (404) with leftover partial .rollback while LIVE is still at aliasKey MUST NOT overwrite LIVE;
  //        and conflicting backup ETag with matching syncSha256 MUST fail rollback verification!
  const stageState404 = "staging/secondary-sync/codex-app-2.0.0/inst-state404";
  const det404 = aliasBackupKeys(`${stageState404}/objects/win`, "latest/win-x64", stageState404);
  const s3State404 = createMockS3();
  s3State404.objects.set(`${stageState404}/objects/win`, objectEntry("NEW-WIN", old, { syncSha256: contentHashHex(bytes("NEW-WIN")) }));
  s3State404.objects.set("latest/win-x64", objectEntry("LIVE-WIN", old, { syncSha256: contentHashHex(bytes("LIVE-WIN")) }));
  s3State404.objects.set(det404.backupKey, objectEntry("BAD", old));
  globalThis.fetch = s3State404.fetch;
  await rollbackCommittedAliases(env, [], { stagePrefix: stageState404 });
  assert.equal(text(s3State404.objects.get("latest/win-x64").bytes), "LIVE-WIN");

  s3State404.objects.set(
    det404.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        stageKey: `${stageState404}/objects/win`,
        backupKey: det404.backupKey,
        stateKey: det404.stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: 8,
        backupEtag: '"expected-etag"',
        backupSha256: "f".repeat(64),
        restored: false,
      }),
      old,
    ),
  );
  s3State404.objects.set(det404.backupKey, objectEntry("TAMPERED", old, { etag: '"different-etag"', syncSha256: "f".repeat(64) }));
  await assert.rejects(() => rollbackCommittedAliases(env, [], { stagePrefix: stageState404 }), /recorded metadata/);
  assert.equal(text(s3State404.objects.get("latest/win-x64").bytes), "LIVE-WIN");

  //    9c) Timed-out COPY completing AFTER inline DELETE + restored=true on hadExisting=false alias is still deleted by batch rollback!
  const stageLateCopy = "staging/secondary-sync/codex-app-2.0.0/inst-latecopy";
  const detLate = aliasBackupKeys(`${stageLateCopy}/objects/arm`, "latest/win-arm64", stageLateCopy);
  const s3Late = createMockS3();
  s3Late.objects.set("latest/win-arm64", objectEntry("LATE-ARRIVED-NEW", old));
  s3Late.objects.set(
    detLate.stateKey,
    objectEntry(JSON.stringify({ aliasKey: "latest/win-arm64", backupKey: detLate.backupKey, stateKey: detLate.stateKey, hadExisting: false, restored: true }), old),
  );
  globalThis.fetch = s3Late.fetch;
  await rollbackCommittedAliases(env, [{ aliasKey: "latest/win-arm64", backupKey: detLate.backupKey, stateKey: detLate.stateKey, hadExisting: false }], {
    stagePrefix: stageLateCopy,
  });
  assert.equal(s3Late.objects.has("latest/win-arm64"), false, "batch rollback must re-delete late-completed hadExisting=false alias");

  //    9d) Repeated reconcileSync during in-flight UTF-8 repair reuses the active repair workflow instead of creating a competing one!
  s3Late.objects.set("latest/manifest", objectEntry(new Uint8Array([0x7b, 0xff, 0x7d]), old));
  const activeRepairMap = new Map([
    [
      "secondary-canonical-done",
      { id: "secondary-canonical-done", currentState: "complete", async status() { return { status: this.currentState }; } },
    ],
  ]);
  let repairCreateCount = 0;
  const envPoll = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        repairCreateCount += 1;
        const inst = { id: opts.id, currentState: "running", async status() { return { status: this.currentState }; } };
        activeRepairMap.set(opts.id, inst);
        return inst;
      },
      async get(id) {
        return activeRepairMap.get(id) || null;
      },
    },
  };
  const poll1 = await reconcileSync(envPoll, {});
  const poll2 = await reconcileSync(envPoll, {});
  assert.equal(repairCreateCount, 1);
  assert.equal(poll2.reused, true);
  assert.equal(poll2.id, poll1.id);

  // 10. Round-13 regressions:
  //   10a) .state.json 404 + LIVE == stage + unsealed 3-byte .rollback MUST NOT clobber LIVE;
  //        whereas a sealed (.seal.json) backup DOES restore original LIVE!
  const stageSeal = "staging/secondary-sync/codex-app-2.0.0/inst-seal404";
  const detSeal = aliasBackupKeys(`${stageSeal}/objects/win`, "latest/win-x64", stageSeal);
  const s3Seal = createMockS3();
  const stageWinHash = contentHashHex(bytes("STAGE-WIN"));
  s3Seal.objects.set(`${stageSeal}/objects/win`, objectEntry("STAGE-WIN", old, { syncSha256: stageWinHash }));
  s3Seal.objects.set("latest/win-x64", objectEntry("STAGE-WIN", old, { syncSha256: stageWinHash }));
  s3Seal.objects.set(detSeal.backupKey, objectEntry("BAD", old));
  globalThis.fetch = s3Seal.fetch;
  await rollbackCommittedAliases(env, [], { stagePrefix: stageSeal });
  assert.equal(text(s3Seal.objects.get("latest/win-x64").bytes), "STAGE-WIN", "unsealed partial backup must not clobber live");

  const origEntry = objectEntry("ORIG-LIVE", old);
  s3Seal.objects.set(detSeal.backupKey, origEntry);
  s3Seal.objects.set(
    `${detSeal.backupKey}.seal.json`,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        backupKey: detSeal.backupKey,
        backupVerified: true,
        backupSize: origEntry.bytes.byteLength,
        backupEtag: origEntry.etag,
        backupSha256: contentHashHex(origEntry.bytes),
      }),
      old,
    ),
  );
  await rollbackCommittedAliases(env, [], { stagePrefix: stageSeal });
  assert.equal(text(s3Seal.objects.get("latest/win-x64").bytes), "ORIG-LIVE", "sealed backup restores live when state.json is missing");

  //   10b) force: true commitSingleAlias when existing == stage still creates a verified backup (hadExisting: true)
  const stageForceEq = "staging/secondary-sync/codex-app-2.0.0/inst-force-eq";
  const s3ForceEq = createMockS3();
  s3ForceEq.objects.set(`${stageForceEq}/objects/win`, objectEntry("SAME-WIN", old, { syncSha256: contentHashHex(bytes("SAME-WIN")) }));
  s3ForceEq.objects.set("latest/win-x64", objectEntry("SAME-WIN", old, { syncSha256: contentHashHex(bytes("SAME-WIN")) }));
  globalThis.fetch = s3ForceEq.fetch;
  const forcedEqRes = await commitSingleAlias(env, `${stageForceEq}/objects/win`, "latest/win-x64", {
    force: true,
    keepBackup: true,
    stagePrefix: stageForceEq,
  });
  assert.equal(forcedEqRes.hadExisting, true);
  assert.equal(s3ForceEq.objects.has(forcedEqRes.backupKey), true);

  //   10c) Conflicting single-part ETag on destination rejects post-copy verification even when syncSha256 matches and copyEtag="copied"
  const stageBadEtag = "staging/secondary-sync/codex-app-2.0.0/inst-badetag";
  const s3BadEtag = createMockS3({
    onCopy(src, dst, store) {
      if (dst === "latest/win-x64") {
        const srcObj = store.get(src);
        store.set(dst, objectEntry(srcObj.bytes, old, { etag: '"ffffffffffffffffffffffffffffffff"', syncSha256: srcObj.syncSha256 }));
        return new Response('<CopyObjectResult><ETag>"copied"</ETag></CopyObjectResult>', { status: 200 });
      }
      return null;
    },
  });
  s3BadEtag.objects.set(`${stageBadEtag}/objects/win`, objectEntry("NEW-WIN", old, { syncSha256: contentHashHex(bytes("NEW-WIN")) }));
  globalThis.fetch = s3BadEtag.fetch;
  await assert.rejects(
    () => commitSingleAlias(env, `${stageBadEtag}/objects/win`, "latest/win-x64", { stagePrefix: stageBadEtag }),
    /Secondary alias verification failed/,
  );

  //   10d) Late backup COPY materializing right before _batch_restored.json delete throws and retains _batch_restored.json!
  const stageLateBk = "staging/secondary-sync/codex-app-2.0.0/inst-latebk";
  const detLateBk = aliasBackupKeys(`${stageLateBk}/objects/win`, "latest/win-x64", stageLateBk);
  let injectLateBk = true;
  const s3LateBk = createMockS3({
    onDelete(delKey, store) {
      if (delKey === detLateBk.stateKey && injectLateBk) {
        injectLateBk = false;
        store.delete(delKey);
        store.set(detLateBk.backupKey, objectEntry("LATE-BACKUP", old));
        return new Response(null, { status: 204 });
      }
      return null;
    },
  });
  const liveOrig = objectEntry("LIVE-ORIG", old);
  s3LateBk.objects.set(detLateBk.backupKey, liveOrig);
  s3LateBk.objects.set(
    detLateBk.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        backupKey: detLateBk.backupKey,
        stateKey: detLateBk.stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: liveOrig.bytes.byteLength,
        backupEtag: liveOrig.etag,
        backupSha256: contentHashHex(liveOrig.bytes),
        restored: false,
      }),
      old,
    ),
  );
  globalThis.fetch = s3LateBk.fetch;
  await assert.rejects(
    () => rollbackCommittedAliases(env, [], { stagePrefix: stageLateBk }),
    /reappeared before checkpoint removal/,
  );
  assert.equal(s3LateBk.objects.has(`${stageLateBk}/backups/_batch_restored.json`), true);

  //   10e) Metadata alias GET 503 during commitSingleAlias rethrows instead of treating 503 as a mismatch;
  //        and tampered staged inlineText of identical byte length is overwritten by uploadObjectToStage!
  const stageMeta503 = "staging/secondary-sync/codex-app-2.0.0/inst-meta503";
  const s3Meta503 = createMockS3({
    onGet(getKey) {
      if (getKey === "latest/manifest") {
        return new Response("Service Unavailable", { status: 503 });
      }
      return null;
    },
  });
  s3Meta503.objects.set(`${stageMeta503}/objects/manifest`, objectEntry('{"ok":1}', old, { syncSha256: contentHashHex(bytes('{"ok":1}')) }));
  s3Meta503.objects.set("latest/manifest", objectEntry('{"ok":1}', old));
  globalThis.fetch = s3Meta503.fetch;
  const envNoRetry = { ...env, SECONDARY_S3_MAX_ATTEMPTS: "1" };
  await assert.rejects(
    () => commitSingleAlias(envNoRetry, `${stageMeta503}/objects/manifest`, "latest/manifest", { stagePrefix: stageMeta503 }),
    /HTTP 503/,
  );

  const s3InlineTamper = createMockS3();
  const inlinePlan = decoratePlanWithStage(
    buildObjectPlan(manifest, "codex-app-2.0.0", {
      manifestText: JSON.stringify(manifest),
      manifestSha256: contentHashHex(bytes(JSON.stringify(manifest))),
    }),
    "inst-inlinetamper",
    env,
  );
  const inlineManifestItem = inlinePlan.items.find((i) => i.id === "manifest");
  const expectedInlineBytes = bytes(inlineManifestItem.inlineText);
  const sameLenCorrupt = bytes("X".repeat(expectedInlineBytes.byteLength));
  s3InlineTamper.objects.set(inlineManifestItem.stageKey, objectEntry(sameLenCorrupt, old, { syncSha256: contentHashHex(expectedInlineBytes) }));
  globalThis.fetch = s3InlineTamper.fetch;
  await uploadObjectToStage(env, inlineManifestItem, { forceUpload: false });
  assert.deepEqual(s3InlineTamper.objects.get(inlineManifestItem.stageKey).bytes, expectedInlineBytes);

  //   10f) findActiveRecordedWorkflow propagates transient 503 from inst.status() instead of spawning a duplicate workflow,
  //        while treating instance.not_found as inactive!
  s3InlineTamper.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "wf-status-503", manifestSha256: contentHashHex(bytes(JSON.stringify(manifest))) }), old),
  );
  const envWf503 = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create() {
        throw new Error("must not create duplicate workflow during status 503");
      },
      async get(id) {
        return {
          id,
          async status() {
            throw new Error("Workflow status RPC failed: 503 Service Unavailable");
          },
        };
      },
    },
  };
  await assert.rejects(() => reconcileSync(envWf503, {}), /503 Service Unavailable/);

  // 11. Round-14 regressions:
  //   11a) Sealed backup is NEVER overwritten when .state.json returns 404 and multipart stage is visible via LIST!
  const stageR14 = "staging/secondary-sync/codex-app-2.0.0/inst-r14-mp";
  const detR14 = aliasBackupKeys(`${stageR14}/objects/head-403-mp`, "latest/win-x64", stageR14);
  const s3R14 = createMockS3();
  const origR14 = objectEntry("ORIG-MP", old);
  const nextR14Bytes = bytes("NEXT-MP");
  s3R14.objects.set(
    `${stageR14}/objects/head-403-mp`,
    objectEntry(nextR14Bytes, old, { etag: '"mp-etag-2"', syncSha256: contentHashHex(nextR14Bytes) }),
  );
  s3R14.objects.set("latest/win-x64", objectEntry(nextR14Bytes, old));
  s3R14.objects.set(detR14.backupKey, origR14);
  s3R14.objects.set(
    `${detR14.backupKey}.seal.json`,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        stageKey: `${stageR14}/objects/head-403-mp`,
        backupKey: detR14.backupKey,
        backupVerified: true,
        backupSize: origR14.bytes.byteLength,
        backupEtag: origR14.etag,
        backupSha256: contentHashHex(origR14.bytes),
      }),
      old,
    ),
  );
  globalThis.fetch = s3R14.fetch;
  await commitSingleAlias(env, `${stageR14}/objects/head-403-mp`, "latest/win-x64", {
    keepBackup: true,
    stagePrefix: stageR14,
  });
  assert.equal(text(s3R14.objects.get(detR14.backupKey).bytes), "ORIG-MP", "sealed backup must remain ORIG-MP");
  await rollbackCommittedAliases(env, [], { stagePrefix: stageR14 });
  assert.equal(text(s3R14.objects.get("latest/win-x64").bytes), "ORIG-MP");

  //   11b) HTTP 503 whose body mentions "HTTP 404" MUST NOT be misclassified as 404;
  //        and startSync({ force: true }) creates a fresh instance with payload.force === true!
  const s3Fake404 = createMockS3({
    onGet(getKey) {
      if (getKey === "latest/manifest") {
        return new Response("Gateway 503: upstream mirror returned HTTP 404", { status: 503 });
      }
      return null;
    },
  });
  s3Fake404.objects.set(`${stageR14}/objects/manifest`, objectEntry('{"ok":1}', old, { syncSha256: contentHashHex(bytes('{"ok":1}')) }));
  s3Fake404.objects.set("latest/manifest", objectEntry('{"ok":1}', old));
  globalThis.fetch = s3Fake404.fetch;
  await assert.rejects(
    () => commitSingleAlias(envNoRetry, `${stageR14}/objects/manifest`, "latest/manifest", { stagePrefix: stageR14 }),
    /HTTP 503/,
  );

  const createdPayloads = [];
  const s3StartForce = createMockS3();
  globalThis.fetch = s3StartForce.fetch;
  const envStartForce = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async create(opts) {
        createdPayloads.push(opts);
        return { id: opts.id, async status() { return { status: "running" }; } };
      },
      async get(id) {
        return { id, async status() { return { status: "complete" }; }, async restart() { throw new Error("must not restart force=false instance"); } };
      },
    },
  };
  const forcedStart = await startSync(envStartForce, { force: true });
  assert.equal(forcedStart.created, true);
  assert.equal(createdPayloads[0].params.force, true);

  // 12. Round-15 regressions:
  //   12a) Supersession between DELETE and COPY in W1 + later rollback in W2 restores ORIG via orphan backup adoption!
  let w1DeletedLive = false;
  const s3SuperAdopt = createMockS3({
    onDelete(delKey, store) {
      if (delKey === "latest/win-x64" && !w1DeletedLive) {
        w1DeletedLive = true;
        store.delete(delKey);
        const nextManifest = { ...manifest, codexVersion: "2.0.1" };
        r2SuperMap.set("latest/manifest", bytes(JSON.stringify(nextManifest)));
        return new Response(null, { status: 204 });
      }
      return null;
    },
    onCopy(src, dst) {
      if (src.includes("inst-w2") && dst === "latest/mac-arm64") {
        return new Response("Gateway error", { status: 502 });
      }
      return null;
    },
  });
  const r2SuperMap = fixtureR2Objects(manifest);
  const envSuper = fixtureEnv(r2SuperMap);
  const shaV1 = contentHashHex(r2SuperMap.get("latest/manifest"));
  s3SuperAdopt.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-w1", manifestSha256: shaV1 }), old),
  );
  s3SuperAdopt.objects.set("latest/win-x64", objectEntry("ORIG-V0-WIN", old));
  s3SuperAdopt.objects.set(
    "staging/secondary-sync/codex-app-2.0.0/inst-w1/objects/win",
    objectEntry("V1-WIN", old, { syncSha256: contentHashHex(bytes("V1-WIN")) }),
  );
  globalThis.fetch = s3SuperAdopt.fetch;
  await assert.rejects(
    () =>
      commitSingleAlias(envSuper, "staging/secondary-sync/codex-app-2.0.0/inst-w1/objects/win", "latest/win-x64", {
        keepBackup: true,
        expectedManifestSha256: shaV1,
        instanceId: "inst-w1",
        stagePrefix: "staging/secondary-sync/codex-app-2.0.0/inst-w1",
      }),
    (err) => isSupersededError(err),
  );
  assert.equal(s3SuperAdopt.objects.has("latest/win-x64"), false, "W1 stopped after DELETE before COPY");

  const shaV2 = contentHashHex(r2SuperMap.get("latest/manifest"));
  s3SuperAdopt.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-w2", manifestSha256: shaV2 }), new Date()),
  );
  s3SuperAdopt.objects.set(
    "staging/secondary-sync/codex-app-2.0.1/inst-w2/objects/win",
    objectEntry("V2-WIN", new Date(), { syncSha256: contentHashHex(bytes("V2-WIN")) }),
  );
  s3SuperAdopt.objects.set(
    "staging/secondary-sync/codex-app-2.0.1/inst-w2/objects/mac",
    objectEntry("V2-MAC", new Date(), { syncSha256: contentHashHex(bytes("V2-MAC")) }),
  );
  const w2WinCommitted = await commitSingleAlias(
    envSuper,
    "staging/secondary-sync/codex-app-2.0.1/inst-w2/objects/win",
    "latest/win-x64",
    {
      keepBackup: true,
      expectedManifestSha256: shaV2,
      instanceId: "inst-w2",
      stagePrefix: "staging/secondary-sync/codex-app-2.0.1/inst-w2",
    },
  );
  assert.equal(w2WinCommitted.hadExisting, true, "W2 must adopt W1's verified backup");
  await assert.rejects(() =>
    commitSingleAlias(
      envSuper,
      "staging/secondary-sync/codex-app-2.0.1/inst-w2/objects/mac",
      "latest/mac-arm64",
      {
        keepBackup: true,
        expectedManifestSha256: shaV2,
        instanceId: "inst-w2",
        stagePrefix: "staging/secondary-sync/codex-app-2.0.1/inst-w2",
      },
    ),
  );
  await rollbackCommittedAliases(envSuper, [w2WinCommitted], {
    expectedManifestSha256: shaV2,
    instanceId: "inst-w2",
    stagePrefix: "staging/secondary-sync/codex-app-2.0.1/inst-w2",
  });
  assert.equal(text(s3SuperAdopt.objects.get("latest/win-x64").bytes), "ORIG-V0-WIN");

  //   12b) Overlapping reconcileSync calls where one restarts canonical and the other gets 503 reuse canonical!
  let raceState = "complete";
  let restartCalls = 0;
  let raceCreates = 0;
  let resolveBothEntered;
  const bothEntered = new Promise((r) => {
    resolveBothEntered = r;
  });
  const s3Race = createMockS3();
  globalThis.fetch = s3Race.fetch;
  const envRace = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        return {
          id,
          async status() {
            return { status: raceState };
          },
          async restart() {
            restartCalls += 1;
            if (restartCalls === 1) {
              await bothEntered;
              raceState = "running";
              return;
            }
            resolveBothEntered();
            throw new Error("HTTP 503 Service Unavailable");
          },
        };
      },
      async create() {
        raceCreates += 1;
        throw new Error("must not create salted duplicate workflow");
      },
    },
  };
  const [race1, race2] = await Promise.allSettled([reconcileSync(envRace), reconcileSync(envRace)]);
  assert.equal(raceCreates, 0);
  assert.equal(race1.status, "fulfilled");
  if (race2.status === "fulfilled") {
    assert.equal(race2.value.id, race1.value.id);
  }
});

test("Round 17 regressions: contradictory sync digest repair, legacy unstamped stage/metadata, absent-baseline orphan rollback, failed _batch_committed protection, purge 503 safety, and manifest-keyed slot restart", async () => {
  const manifest = fixtureManifest();
  const r2Objects = fixtureR2Objects(manifest);
  const manifestSha = contentHashHex(r2Objects.get("latest/manifest"));
  const old = new Date(Date.now() - 86400_000);

  // 1) Contradictory installer digest (syncSha256 !== bodySha256 via HEAD 403 -> GET 206 no-total) is repaired & restorable
  const s3Contra = createMockS3({
    onList(prefix) {
      if (prefix.startsWith("latest/head-403-contra") || prefix.includes("/backups/")) {
        return new Response("<ListBucketResult></ListBucketResult>", { status: 200 });
      }
      return null;
    },
    onGet(key, store, reqHeaders) {
      const entry = store.get(key);
      if (!entry) return null;
      if (
        reqHeaders?.get("range") === "bytes=0-0" &&
        (key === "latest/head-403-contra" || key.endsWith(".rollback"))
      ) {
        return new Response(entry.bytes.slice(0, 1), {
          status: 206,
          headers: {
            "content-range": "bytes 0-0/*",
            ...(entry.syncSha256 ? { "x-amz-meta-sync-sha256": entry.syncSha256 } : {}),
          },
        });
      }
      return null;
    },
  });
  const goodBytes = bytes("GOOD-INSTALLER-BYTES");
  const goodSha = contentHashHex(goodBytes);
  const corruptBytes = bytes("CORRUPT-SAME-LEN-BYT");
  s3Contra.objects.set(
    "latest/head-403-contra",
    objectEntry(corruptBytes, old, { syncSha256: goodSha }),
  );
  const contraStage = "staging/secondary-sync/codex-app-2.0.0/inst-contra/objects/win";
  s3Contra.objects.set(contraStage, objectEntry(goodBytes, old, { syncSha256: goodSha }));
  globalThis.fetch = s3Contra.fetch;
  const envContra = fixtureEnv(r2Objects);
  const contraRes = await commitSingleAlias(envContra, contraStage, "latest/head-403-contra", {
    keepBackup: true,
    stagePrefix: "staging/secondary-sync/codex-app-2.0.0/inst-contra",
    itemExpectedSha256: goodSha,
  });
  assert.equal(text(s3Contra.objects.get("latest/head-403-contra").bytes), "GOOD-INSTALLER-BYTES");
  await rollbackCommittedAliases(envContra, [contraRes], {
    stagePrefix: "staging/secondary-sync/codex-app-2.0.0/inst-contra",
  });
  assert.equal(text(s3Contra.objects.get("latest/head-403-contra").bytes), "CORRUPT-SAME-LEN-BYT");

  // 2) Legacy unstamped installer (with HEAD 403 LIST-only stage) + unchanged unstamped appcast are stamped so reconcileSync skips
  const s3Legacy = createMockS3();
  globalThis.fetch = s3Legacy.fetch;
  const envLegacy = fixtureEnv(r2Objects);
  const planLegacy = decoratePlanWithStage(
    buildObjectPlan(manifest, "codex-app-2.0.0", {
      manifestText: text(r2Objects.get("latest/manifest")),
      manifestSha256: manifestSha,
    }),
    "head-403-legacy",
    envLegacy,
  );
  for (const item of planLegacy.items) {
    const srcBytes = r2Objects.get(item.sourceKey);
    for (const ak of item.aliasKeys) {
      s3Legacy.objects.set(ak, objectEntry(srcBytes, old, { syncSha256: "" }));
    }
    await uploadObjectToStage(envLegacy, item);
  }
  for (const item of commitOrder(planLegacy.items)) {
    for (const ak of item.aliasKeys) {
      await commitSingleAlias(envLegacy, item.stageKey, ak, {
        keepBackup: false,
        stagePrefix: planLegacy.stagePrefix,
        expectedManifestSha256: manifestSha,
      });
    }
  }
  const envLegacyWf = {
    ...envLegacy,
    SECONDARY_MIRROR_WORKFLOW: {
      async create() {
        throw new Error("reconcileSync must skip after stamping legacy installer and appcast");
      },
      async get() {
        return null;
      },
    },
  };
  const recLegacy = await reconcileSync(envLegacyWf, {});
  assert.equal(recLegacy.skipped, true);

  // 3 & 4) Predecessor introducing previously absent alias (hadExisting: false) is deleted back to absent on successor failure
  const s3Absent = createMockS3();
  globalThis.fetch = s3Absent.fetch;
  const m1Json = JSON.stringify({ ...manifest, codexVersion: "2.1.0" });
  const m2Json = JSON.stringify({ ...manifest, codexVersion: "2.2.0" });
  const m1Sha = contentHashHex(bytes(m1Json));
  const m2Sha = contentHashHex(bytes(m2Json));
  const r2M1 = fixtureR2Objects(JSON.parse(m1Json), { "latest/manifest": m1Json });
  const r2M2 = fixtureR2Objects(JSON.parse(m2Json), { "latest/manifest": m2Json });
  const stgW1 = "staging/secondary-sync/codex-app-2.1.0/inst-abs-w1";
  const stgW2 = "staging/secondary-sync/codex-app-2.2.0/inst-abs-w2";
  s3Absent.objects.set(`${stgW1}/objects/arm`, objectEntry("UNPUB-W1-ARM64", old, { syncSha256: contentHashHex(bytes("UNPUB-W1-ARM64")) }));
  s3Absent.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-abs-w1", manifestSha256: m1Sha }), old),
  );
  await commitSingleAlias(fixtureEnv(r2M1), `${stgW1}/objects/arm`, "latest/win-arm64", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-abs-w1",
    stagePrefix: stgW1,
  });
  assert.equal(s3Absent.objects.has("latest/win-arm64"), true);
  // Successor W2 supersedes W1, commits win-arm64, then fails and rolls back -> win-arm64 MUST be deleted!
  s3Absent.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-abs-w2", manifestSha256: m2Sha }), old),
  );
  s3Absent.objects.set(`${stgW2}/objects/arm`, objectEntry("UNPUB-W2-ARM64", old, { syncSha256: contentHashHex(bytes("UNPUB-W2-ARM64")) }));
  const w2ArmRes = await commitSingleAlias(fixtureEnv(r2M2), `${stgW2}/objects/arm`, "latest/win-arm64", {
    keepBackup: true,
    expectedManifestSha256: m2Sha,
    instanceId: "inst-abs-w2",
    stagePrefix: stgW2,
  });
  assert.equal(w2ArmRes.hadExisting, false, "W2 must inherit hadExisting=false from W1");
  await rollbackCommittedAliases(fixtureEnv(r2M2), [w2ArmRes], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-abs-w2",
    stagePrefix: stgW2,
  });
  assert.equal(s3Absent.objects.has("latest/win-arm64"), false, "absent baseline alias must be deleted on rollback");

  // 5) Failed _batch_committed.json write leaves published release protected from later staging-failure rollback
  const s3Pub = createMockS3();
  globalThis.fetch = s3Pub.fetch;
  const m0Json = JSON.stringify({ ...manifest, codexVersion: "1.9.0" });
  s3Pub.objects.set("latest/win-x64", objectEntry("V190-WIN", old));
  s3Pub.objects.set("latest/manifest", objectEntry(m0Json, old));
  const stgPub1 = "staging/secondary-sync/codex-app-2.1.0/inst-pub1";
  s3Pub.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-pub1", manifestSha256: m1Sha }), old),
  );
  s3Pub.objects.set(`${stgPub1}/objects/win`, objectEntry("V210-WIN", old, { syncSha256: contentHashHex(bytes("V210-WIN")) }));
  s3Pub.objects.set(`${stgPub1}/objects/manifest`, objectEntry(m1Json, old, { syncSha256: m1Sha }));
  await commitSingleAlias(fixtureEnv(r2M1), `${stgPub1}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-pub1",
    stagePrefix: stgPub1,
  });
  await commitSingleAlias(fixtureEnv(r2M1), `${stgPub1}/objects/manifest`, "latest/manifest", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-pub1",
    stagePrefix: stgPub1,
  });
  // Simulate _batch_committed.json write having failed 503 AND cleanup failed 503, then W2 fails during staging:
  s3Pub.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-pub2", manifestSha256: m2Sha }), old),
  );
  await rollbackCommittedAliases(fixtureEnv(r2M2), [], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-pub2",
    stagePrefix: "staging/secondary-sync/codex-app-2.2.0/inst-pub2",
  });
  assert.equal(text(s3Pub.objects.get("latest/win-x64").bytes), "V210-WIN", "published release must not roll back when _batch_committed.json was missing");
  assert.equal(text(s3Pub.objects.get("latest/manifest").bytes), m1Json);

  // 6) Purge Workflow status 503 throws instead of skipping retired backup, and failure cleanup retains _batch_committed.json when older backup survives
  const stgOldRet = "staging/secondary-sync/codex-app-1.9.0/inst-old-ret";
  const stgCurRet = "staging/secondary-sync/codex-app-2.1.0/inst-cur-ret";
  let failPurgeDel = false;
  const s3Purge = createMockS3({
    onDelete(delKey) {
      if (failPurgeDel && delKey.startsWith(`${stgOldRet}/backups/`)) {
        return new Response("Unavailable", { status: 503 });
      }
      return null;
    },
  });
  globalThis.fetch = s3Purge.fetch;
  const detOldArm = aliasBackupKeys(`${stgOldRet}/objects/arm`, "latest/win-arm64", stgOldRet);
  s3Purge.objects.set(detOldArm.backupKey, objectEntry("RETIRED-ARM64", old));
  s3Purge.objects.set(
    `${detOldArm.backupKey}.seal.json`,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-arm64",
        backupKey: detOldArm.backupKey,
        backupVerified: true,
        backupSize: bytes("RETIRED-ARM64").byteLength,
        backupSha256: contentHashHex(bytes("RETIRED-ARM64")),
      }),
      old,
    ),
  );
  s3Purge.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-cur-ret", manifestSha256: m1Sha }), old),
  );
  const envPurgeWf503 = {
    ...fixtureEnv(r2M1),
    SECONDARY_S3_MAX_ATTEMPTS: "1",
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        return {
          id,
          async status() {
            throw new Error("HTTP 503 Workflow status unavailable");
          },
        };
      },
    },
  };
  await assert.rejects(
    () =>
      cleanupRollbackBackups(envPurgeWf503, [], {
        expectedManifestSha256: m1Sha,
        instanceId: "inst-cur-ret",
        stagePrefix: stgCurRet,
        purgeSupersededOrphans: true,
      }),
    /503/,
  );
  // Now Workflow status is terminated, but DELETE on older backup fails 503 -> failure cleanup must retain _batch_committed.json!
  failPurgeDel = true;
  const envPurgeTerm = {
    ...fixtureEnv(r2M1),
    SECONDARY_S3_MAX_ATTEMPTS: "1",
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        return {
          id,
          async status() {
            return { status: "terminated" };
          },
        };
      },
    },
  };
  await assert.rejects(
    () =>
      cleanupRollbackBackups(envPurgeTerm, [], {
        expectedManifestSha256: m1Sha,
        instanceId: "inst-cur-ret",
        stagePrefix: stgCurRet,
        purgeSupersededOrphans: true,
      }),
    /503/,
  );
  await cleanupStageObjects(envPurgeTerm, [], stgCurRet, { switchoverComplete: true });
  assert.equal(
    s3Purge.objects.has(`${stgCurRet}/backups/_batch_committed.json`),
    true,
    "_batch_committed.json must be retained while older superseded backup survives",
  );

  // 7 & 8) Fallback/repair slot IDs ignore caller releaseTag and restart errored repair slots after 8 failures
  const s3Slots = createMockS3();
  s3Slots.objects.set("latest/manifest", objectEntry(new Uint8Array([0xff, 0xfe]), old));
  globalThis.fetch = s3Slots.fetch;
  const createdSlots = new Map();
  let restartedSlotCount = 0;
  const canonicalForSlots = workflowInstanceId("manifest", manifestSha);
  const envSlots = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        if (id === canonicalForSlots) {
          return {
            id,
            async status() {
              return { status: "complete" };
            },
          };
        }
        return createdSlots.get(id) || null;
      },
      async create({ id, params }) {
        const inst = {
          id,
          params,
          state: "errored",
          async status() {
            return { status: this.state };
          },
          async restart() {
            restartedSlotCount += 1;
            this.state = "running";
          },
        };
        createdSlots.set(id, inst);
        return inst;
      },
    },
  };
  const call1 = await reconcileSync(envSlots, { releaseTag: "codex-app-1.9.9" });
  // Simulate 9 subsequent repair reconciles after S3 recovers (and with different caller releaseTag)
  for (let i = 0; i < 9; i += 1) {
    const slotInst = createdSlots.get(call1.id);
    slotInst.state = "errored";
    s3Slots.objects.delete("staging/secondary-sync/active-sync.json");
    const nextCall = await reconcileSync(envSlots, { releaseTag: i % 2 === 0 ? "" : "codex-app-1.9.9" });
    assert.equal(nextCall.id, call1.id, "must reuse/restart same manifest-keyed repair-slot-1 across releaseTags and >8 failures");
  }
  assert.equal(createdSlots.size, 1);
  assert.equal(restartedSlotCount, 9);
});

test("Round 18 regressions: stale header exposure on LIST-sealed backup, unstamped migration & multipart checksum stamping, 503 manifest guard, same-manifest repair rollback, fenced checkpoint/pruner, and stale repair-slot checkpoint invalidation", async () => {
  const manifest = fixtureManifest();
  const r2Objects = fixtureR2Objects(manifest);
  const manifestText = text(r2Objects.get("latest/manifest"));
  const manifestSha = contentHashHex(r2Objects.get("latest/manifest"));
  const old = new Date(Date.now() - 86400_000);

  // 1) Orphan backup sealed via LIST fallback (HEAD 403) restores cleanly when HEAD later exposes stale syncSha256
  let forceListFallback = true;
  const s3StaleVis = createMockS3({
    onHead() {
      return forceListFallback ? new Response("forbidden", { status: 403 }) : null;
    },
  });
  globalThis.fetch = s3StaleVis.fetch;
  const origWinBytes = bytes("ORIG-BODY-WITH-STALE-HDR");
  const staleSha = "f".repeat(64);
  s3StaleVis.objects.set("latest/win-x64", objectEntry(origWinBytes, old, { syncSha256: staleSha }));
  const m1Json = JSON.stringify({ ...manifest, codexVersion: "2.1.0" });
  const m2Json = JSON.stringify({ ...manifest, codexVersion: "2.2.0" });
  const m1Sha = contentHashHex(bytes(m1Json));
  const m2Sha = contentHashHex(bytes(m2Json));
  const r2M1 = fixtureR2Objects(JSON.parse(m1Json), { "latest/manifest": m1Json });
  const r2M2 = fixtureR2Objects(JSON.parse(m2Json), { "latest/manifest": m2Json });
  const stgVisW1 = "staging/secondary-sync/codex-app-2.1.0/inst-vis-w1";
  s3StaleVis.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-vis-w1", manifestSha256: m1Sha, epoch: 10 }), old),
  );
  s3StaleVis.objects.set(
    `${stgVisW1}/objects/win`,
    objectEntry("UNPUBLISHED-W1-WIN", old, { syncSha256: contentHashHex(bytes("UNPUBLISHED-W1-WIN")) }),
  );
  await commitSingleAlias(fixtureEnv(r2M1), `${stgVisW1}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-vis-w1",
    stagePrefix: stgVisW1,
  });
  assert.equal(text(s3StaleVis.objects.get("latest/win-x64").bytes), "UNPUBLISHED-W1-WIN");
  // Now HEAD succeeds and exposes the stale syncSha256 !== backupSha256 on the orphan backup!
  forceListFallback = false;
  s3StaleVis.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-vis-w2", manifestSha256: m2Sha, epoch: 11 }), old),
  );
  await rollbackCommittedAliases(fixtureEnv(r2M2), [], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-vis-w2",
    stagePrefix: "staging/secondary-sync/codex-app-2.2.0/inst-vis-w2",
  });
  assert.equal(
    text(s3StaleVis.objects.get("latest/win-x64").bytes),
    "ORIG-BODY-WITH-STALE-HDR",
    "verified orphan backup must not be discarded when stale sync header becomes visible",
  );

  // 2 & 3) Fully unstamped release schedules migration with 0 binary GET reads, and >threshold multipart installer with digest in latest/checksums stamps & skips
  let binaryGetBytes = 0;
  const s3Unstamped = createMockS3({
    onGet(key, store) {
      if (!key.endsWith("manifest") && !key.endsWith("checksums") && !key.endsWith(".xml") && !key.endsWith(".json")) {
        binaryGetBytes += store.get(key)?.bytes.byteLength || 0;
      }
      return null;
    },
  });
  globalThis.fetch = s3Unstamped.fetch;
  const mpWinBytes = new Uint8Array(6 * 1024 * 1024 + 17);
  mpWinBytes.fill(0x5a);
  const mpWinSha = contentHashHex(mpWinBytes);
  const manifestNoEmbeddedWinSha = structuredClone(manifest);
  if (manifestNoEmbeddedWinSha.derived?.latestChecksums) {
    delete manifestNoEmbeddedWinSha.derived.latestChecksums["OpenAI.Codex_1.2.3.4_x64.Msix"];
  }
  manifestNoEmbeddedWinSha.sources.windows.architectures.x64.contentLength = mpWinBytes.byteLength;
  const mpManifestJson = JSON.stringify(manifestNoEmbeddedWinSha);
  const mpManifestSha = contentHashHex(bytes(mpManifestJson));
  const r2Mp = fixtureR2Objects(manifestNoEmbeddedWinSha, {
    "latest/win-x64": mpWinBytes,
    "latest/manifest": mpManifestJson,
  });
  const origChecksums = text(r2Mp.get("latest/checksums"));
  r2Mp.set("latest/checksums", bytes(`${origChecksums}${mpWinSha}  Codex-Windows-x64.msix\n`));
  const envMpBase = {
    ...fixtureEnv(r2Mp),
    SECONDARY_SYNC_SINGLE_PUT_MAX_BYTES: String(5 * 1024 * 1024),
    SECONDARY_SYNC_PART_SIZE_BYTES: String(5 * 1024 * 1024),
  };
  const mpPlan = decoratePlanWithStage(
    buildObjectPlan(manifestNoEmbeddedWinSha, "codex-app-2.0.0", {
      manifestText: mpManifestJson,
      manifestSha256: mpManifestSha,
    }),
    "inst-mp-stamp",
    envMpBase,
  );
  // Seed fully unstamped release on S3 (including unstamped latest/manifest)
  for (const item of mpPlan.items) {
    const srcB = r2Mp.get(item.sourceKey);
    for (const ak of item.aliasKeys) {
      s3Unstamped.objects.set(ak, objectEntry(srcB, old, { syncSha256: "" }));
    }
  }
  let scheduledMigrations = 0;
  const envMpWf = {
    ...envMpBase,
    SECONDARY_MIRROR_WORKFLOW: {
      async get() {
        return null;
      },
      async create({ id }) {
        scheduledMigrations += 1;
        return {
          id,
          async status() {
            return { status: "running" };
          },
        };
      },
    },
  };
  const migRes = await reconcileSync(envMpWf, {});
  assert.equal(migRes.created, true, "fully unstamped release must schedule stamp migration");
  assert.equal(binaryGetBytes, 0, "unstamped release check must not stream gigabytes of binaries");
  // Now execute stage uploads + commits (including multipart win-x64 whose sha256 is only in latest/checksums)
  s3Unstamped.objects.delete("staging/secondary-sync/active-sync.json");
  for (const item of mpPlan.items) {
    await uploadObjectToStage(envMpBase, item);
  }
  for (const item of commitOrder(mpPlan.items)) {
    for (const ak of item.aliasKeys) {
      await commitSingleAlias(envMpBase, item.stageKey, ak, {
        keepBackup: false,
        stagePrefix: mpPlan.stagePrefix,
        expectedManifestSha256: mpManifestSha,
      });
    }
  }
  assert.equal(s3Unstamped.objects.get("latest/win-x64").syncSha256, mpWinSha);
  const afterStampRes = await reconcileSync(envMpWf, {});
  assert.equal(afterStampRes.skipped, true, "healthy multipart installer with checksum in latest/checksums must skip after publish");
  assert.equal(scheduledMigrations, 1);

  // 4 & 5) Both _batch_committed.json PUTs returning 503 preserve <manifest>.state.json in cleanupStageObjects AND prevent self-rollback on restart
  let failBatchCommittedPut = true;
  const s3Cp503 = createMockS3({
    onPut(key) {
      if (failBatchCommittedPut && key.endsWith("/_batch_committed.json")) {
        return new Response("Unavailable", { status: 503 });
      }
      return null;
    },
  });
  globalThis.fetch = s3Cp503.fetch;
  const m0Json = JSON.stringify({ ...manifest, codexVersion: "1.9.0" });
  s3Cp503.objects.set("latest/win-x64", objectEntry("V190-WIN", old));
  s3Cp503.objects.set("latest/manifest", objectEntry(m0Json, old));
  // Seed an older predecessor orphan backup in inst-w0
  const stgW0 = "staging/secondary-sync/codex-app-2.0.5/inst-w0";
  const detW0Win = aliasBackupKeys(`${stgW0}/objects/win`, "latest/win-x64", stgW0);
  s3Cp503.objects.set(detW0Win.backupKey, objectEntry("V190-WIN", old));
  s3Cp503.objects.set(
    detW0Win.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        backupKey: detW0Win.backupKey,
        stateKey: detW0Win.stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: bytes("V190-WIN").byteLength,
        backupSha256: contentHashHex(bytes("V190-WIN")),
        ownerEpoch: 50,
        restored: false,
      }),
      old,
    ),
  );
  const envCp503 = { ...fixtureEnv(r2M1), SECONDARY_S3_MAX_ATTEMPTS: "1" };
  const stgPub503 = "staging/secondary-sync/codex-app-2.1.0/inst-pub503";
  s3Cp503.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-pub503", manifestSha256: m1Sha, epoch: 60 }), old),
  );
  s3Cp503.objects.set(
    `${stgPub503}/objects/win`,
    objectEntry("V210-WIN", old, { syncSha256: contentHashHex(bytes("V210-WIN")) }),
  );
  s3Cp503.objects.set(`${stgPub503}/objects/manifest`, objectEntry(m1Json, old, { syncSha256: m1Sha }));
  const pubWin = await commitSingleAlias(envCp503, `${stgPub503}/objects/win`, "latest/win-x64", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-pub503",
    stagePrefix: stgPub503,
  });
  const pubManifest = await commitSingleAlias(envCp503, `${stgPub503}/objects/manifest`, "latest/manifest", {
    keepBackup: true,
    expectedManifestSha256: m1Sha,
    instanceId: "inst-pub503",
    stagePrefix: stgPub503,
  });
  // Restarted self-rollback check BEFORE cleanup (with _batch_committed.json missing!)
  const selfRb = await rollbackCommittedAliases(envCp503, [pubWin, pubManifest], {
    expectedManifestSha256: m1Sha,
    instanceId: "inst-pub503",
    stagePrefix: stgPub503,
  });
  assert.equal(selfRb.skippedAlreadyCommitted, true, "restarted publisher must not roll back its own published release");
  assert.equal(text(s3Cp503.objects.get("latest/win-x64").bytes), "V210-WIN");
  assert.equal(text(s3Cp503.objects.get("latest/manifest").bytes), m1Json);
  // Failure cleanup runs with _batch_committed.json PUT still returning 503 -> must keep <manifest>.state.json!
  await cleanupStageObjects(
    envCp503,
    [
      { stageKey: `${stgPub503}/objects/win`, aliasKeys: ["latest/win-x64"] },
      { stageKey: `${stgPub503}/objects/manifest`, aliasKeys: ["latest/manifest"] },
    ],
    stgPub503,
    { switchoverComplete: true, expectedManifestSha256: m1Sha, instanceId: "inst-pub503" },
  );
  assert.equal(s3Cp503.objects.has(pubManifest.stateKey), true, "cleanup must preserve <manifest>.state.json when _batch_committed.json fails 503");
  // Subsequent staging failure W2 must NOT restore W0's V190-WIN!
  s3Cp503.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-w2", manifestSha256: m2Sha, epoch: 70 }), old),
  );
  await rollbackCommittedAliases({ ...fixtureEnv(r2M2), SECONDARY_S3_MAX_ATTEMPTS: "1" }, [], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-w2",
    stagePrefix: "staging/secondary-sync/codex-app-2.2.0/inst-w2",
  });
  assert.equal(text(s3Cp503.objects.get("latest/win-x64").bytes), "V210-WIN");

  // 6) Retained checkpoint for M1 does NOT hide a newer forced repair targeting the SAME manifest M1
  failBatchCommittedPut = false;
  let supersedeOnDelete = false;
  const s3SameM = createMockS3({
    onDelete(delKey, store) {
      if (supersedeOnDelete && delKey === "latest/win-x64") {
        store.delete(delKey);
        s3SameM.objects.set(
          "staging/secondary-sync/active-sync.json",
          objectEntry(JSON.stringify({ instanceId: "inst-m2-after-repair", manifestSha256: m2Sha, epoch: 120 }), old),
        );
        s3SameM.r2Ref.set("latest/manifest", bytes(m2Json));
        return new Response(null, { status: 204 });
      }
      return null;
    },
  });
  const r2SameM = new Map(r2M1);
  s3SameM.r2Ref = r2SameM;
  globalThis.fetch = s3SameM.fetch;
  s3SameM.objects.set("latest/win-x64", objectEntry("M1-GOOD-WIN", old, { syncSha256: contentHashHex(bytes("M1-GOOD-WIN")) }));
  s3SameM.objects.set("latest/manifest", objectEntry(m1Json, old, { syncSha256: m1Sha }));
  const stgOrigM1 = "staging/secondary-sync/codex-app-2.1.0/inst-orig-m1";
  s3SameM.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-orig-m1", manifestSha256: m1Sha, epoch: 100 }), old),
  );
  await recordSwitchoverCommittedCheckpoint(fixtureEnv(r2SameM), stgOrigM1, [], {
    manifestSha256: m1Sha,
    instanceId: "inst-orig-m1",
  });
  // Now forced repair targeting M1 runs at epoch 110 and is superseded right after deleting latest/win-x64
  const stgRepairM1 = "staging/secondary-sync/codex-app-2.1.0/inst-repair-m1";
  s3SameM.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-repair-m1", manifestSha256: m1Sha, epoch: 110 }), old),
  );
  s3SameM.objects.set(
    `${stgRepairM1}/objects/win`,
    objectEntry("M1-REPAIRED-WIN", old, { syncSha256: contentHashHex(bytes("M1-REPAIRED-WIN")) }),
  );
  supersedeOnDelete = true;
  await assert.rejects(
    () =>
      commitSingleAlias(fixtureEnv(r2SameM), `${stgRepairM1}/objects/win`, "latest/win-x64", {
        keepBackup: true,
        force: true,
        expectedManifestSha256: m1Sha,
        instanceId: "inst-repair-m1",
        stagePrefix: stgRepairM1,
      }),
    /SUPERSEDED/,
  );
  assert.equal(s3SameM.objects.has("latest/win-x64"), false);
  // Next workflow fails during staging and rolls back -> MUST restore M1-GOOD-WIN!
  await rollbackCommittedAliases(fixtureEnv(r2SameM), [], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-m2-after-repair",
    stagePrefix: "staging/secondary-sync/codex-app-2.2.0/inst-m2-after-repair",
  });
  assert.equal(text(s3SameM.objects.get("latest/win-x64").bytes), "M1-GOOD-WIN");

  // 7 & 8) Older workflow cannot mark successor backups superseded, and pruner retains checkpoint until late predecessor state is gone
  const s3FencePrune = createMockS3();
  globalThis.fetch = s3FencePrune.fetch;
  s3FencePrune.objects.set("latest/win-arm64", objectEntry("PUB-ARM64", old));
  s3FencePrune.objects.set("latest/manifest", objectEntry(m1Json, old));
  const stgOldPub = "staging/secondary-sync/codex-app-2.1.0/inst-old-pub";
  s3FencePrune.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-old-pub", manifestSha256: m1Sha, epoch: 200 }), old),
  );
  await recordSwitchoverCommittedCheckpoint(fixtureEnv(r2M1), stgOldPub, [], {
    manifestSha256: m1Sha,
    instanceId: "inst-old-pub",
  });
  // Successor W2 (epoch 210) writes backup in inst-succ-w2; delayed inst-old-pub cleanup must be fenced & never add inst-succ-w2!
  const stgSuccW2 = "staging/secondary-sync/codex-app-2.2.0/inst-succ-w2";
  s3FencePrune.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-succ-w2", manifestSha256: m2Sha, epoch: 210 }), old),
  );
  const detSuccWin = aliasBackupKeys(`${stgSuccW2}/objects/win`, "latest/win-x64", stgSuccW2);
  s3FencePrune.objects.set(detSuccWin.backupKey, objectEntry("SUCC-BACKUP", old));
  await assert.rejects(
    () =>
      recordSwitchoverCommittedCheckpoint(fixtureEnv(r2M2), stgOldPub, [], {
        manifestSha256: m1Sha,
        instanceId: "inst-old-pub",
      }),
    /SUPERSEDED/,
  );
  const savedOldCp = JSON.parse(text(s3FencePrune.objects.get(`${stgOldPub}/backups/_batch_committed.json`).bytes));
  assert.equal(savedOldCp.supersededBackupDirs.includes(`${stgSuccW2}/backups/`), false);

  // Late predecessor state (epoch 190 < 200) lands after inst-old-pub's scan; while Workflow.status() 503s, pruner MUST retain _batch_committed.json!
  s3FencePrune.objects.delete(detSuccWin.backupKey);
  const stgLatePred = "staging/secondary-sync/codex-app-2.0.0/inst-late-pred";
  const detLateArm = aliasBackupKeys(`${stgLatePred}/objects/arm`, "latest/win-arm64", stgLatePred);
  s3FencePrune.objects.set(
    detLateArm.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-arm64",
        backupKey: detLateArm.backupKey,
        stateKey: detLateArm.stateKey,
        hadExisting: false,
        ownerEpoch: 190,
        restored: false,
      }),
      old,
    ),
  );
  // Make _batch_committed.json also old enough for age pruning
  s3FencePrune.objects.get(`${stgOldPub}/backups/_batch_committed.json`).lastModified = old;
  let predStatus503 = true;
  const envPruneLate = {
    ...fixtureEnv(r2M2),
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        return {
          id,
          async status() {
            if (id === "inst-late-pred" && predStatus503) {
              throw new Error("HTTP 503 Workflow status unavailable");
            }
            return { status: "terminated" };
          },
        };
      },
    },
  };
  await pruneAbandonedStageObjects(envPruneLate, "", { graceHours: 1 });
  assert.equal(
    s3FencePrune.objects.has(`${stgOldPub}/backups/_batch_committed.json`),
    true,
    "pruner must retain checkpoint while late predecessor state survives due to status 503",
  );
  // Once status() recovers, pruner deletes superseded epoch-190 state AND checkpoint, leaving published latest/win-arm64 intact!
  predStatus503 = false;
  await pruneAbandonedStageObjects(envPruneLate, "", { graceHours: 1 });
  assert.equal(s3FencePrune.objects.has(detLateArm.stateKey), false);
  assert.equal(s3FencePrune.objects.has(`${stgOldPub}/backups/_batch_committed.json`), false);
  await rollbackCommittedAliases(envPruneLate, [], {
    expectedManifestSha256: m2Sha,
    instanceId: "inst-succ-w2",
    stagePrefix: stgSuccW2,
  });
  assert.equal(text(s3FencePrune.objects.get("latest/win-arm64").bytes), "PUB-ARM64");

  // 9) Restarted repair slot with leftover _batch_committed.json and corrupt live manifest invalidates checkpoint via verifyPriorSwitchoverCheckpoint
  const s3StaleCp = createMockS3();
  globalThis.fetch = s3StaleCp.fetch;
  const envStaleCp = fixtureEnv(r2Objects);
  const repairPlan = decoratePlanWithStage(
    buildObjectPlan(manifest, "codex-app-2.0.0", {
      manifestText,
      manifestSha256: manifestSha,
    }),
    "inst-repair-slot-1",
    envStaleCp,
  );
  s3StaleCp.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-repair-slot-1", manifestSha256: manifestSha, epoch: 300 }), old),
  );
  await recordSwitchoverCommittedCheckpoint(envStaleCp, repairPlan.stagePrefix, [], {
    releaseTag: "codex-app-2.0.0",
    manifestSha256: manifestSha,
    instanceId: "inst-repair-slot-1",
  });
  // Corrupt live manifest with invalid UTF-8 and restart inst-repair-slot-1 at epoch 301
  s3StaleCp.objects.set("latest/manifest", objectEntry(new Uint8Array([0xff, 0xfe]), old));
  s3StaleCp.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-repair-slot-1", manifestSha256: manifestSha, epoch: 301 }), old),
  );
  const verifiedCp = await verifyPriorSwitchoverCheckpoint(
    envStaleCp,
    { releaseTag: "codex-app-2.0.0", manifest, manifestText, manifestSha256: manifestSha },
    repairPlan,
    { instanceId: "inst-repair-slot-1" },
  );
  assert.equal(verifiedCp, null, "verifyPriorSwitchoverCheckpoint must reject stale checkpoint when live manifest is corrupt");
  const invalidatedDoc = JSON.parse(
    text(s3StaleCp.objects.get(`${repairPlan.stagePrefix}/backups/_batch_committed.json`).bytes),
  );
  assert.equal(invalidatedDoc.completed, false);
  assert.equal(invalidatedDoc.priorRunSuperseded, true);
  assert.equal(invalidatedDoc.committedEpoch, 300);
});

test("Round 19 regressions: monotonic pointer retry, permanent committed-epoch ledger, own-slot superseded state/restored guard, reused-dir epoch recovery & pruner, invalidation before delete, failure-cleanup guard, moniker checksums, and 0-byte mixed-HEAD migration", async () => {
  const manifest = fixtureManifest();
  const r2Objects = fixtureR2Objects(manifest);
  const manifestText = text(r2Objects.get("latest/manifest"));
  const manifestSha = contentHashHex(r2Objects.get("latest/manifest"));
  const old = new Date(Date.now() - 86400_000);

  // 1) Retried active-sync.json PUT 503 cannot regress epoch over an intervening forced repair
  let pointerAttempt = 0;
  const wfInstances = new Map();
  const s3Ptr = createMockS3({
    onPut(key, store) {
      if (key === "staging/secondary-sync/active-sync.json") {
        pointerAttempt += 1;
        if (pointerAttempt === 1) {
          // Intervening forced repair writes a higher epoch in another isolate before retry
          const forcedEpoch = Date.now() * 512 + 999_999;
          store.set(
            key,
            objectEntry(
              JSON.stringify({
                instanceId: "inst-forced-repair",
                manifestSha256: manifestSha,
                epoch: forcedEpoch,
                runEpoch: forcedEpoch,
              }),
              new Date(),
            ),
          );
          wfInstances.set("inst-forced-repair", "running");
          return new Response("Unavailable", { status: 503 });
        }
      }
      return null;
    },
  });
  globalThis.fetch = s3Ptr.fetch;
  const envPtr = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async get(id) {
        if (!wfInstances.has(id)) return null;
        return {
          id,
          async status() {
            return { status: wfInstances.get(id) };
          },
          async terminate() {
            wfInstances.set(id, "terminated");
          },
        };
      },
      async create({ id }) {
        wfInstances.set(id, "running");
        return {
          id,
          async status() {
            return { status: wfInstances.get(id) };
          },
          async terminate() {
            wfInstances.set(id, "terminated");
          },
        };
      },
    },
  };
  await assert.rejects(
    () => startSync(envPtr, { instanceId: "inst-normal-sync" }),
    /SUPERSEDED/,
  );
  const finalPtr = JSON.parse(
    text(s3Ptr.objects.get("staging/secondary-sync/active-sync.json").bytes),
  );
  assert.equal(finalPtr.instanceId, "inst-forced-repair", "pointer retry must not overwrite newer repair owner");
  await verifySourceManifestCurrent(envPtr, manifestSha, {
    instanceId: "inst-forced-repair",
    requirePointer: true,
  });
  await assert.rejects(
    () =>
      verifySourceManifestCurrent(envPtr, manifestSha, {
        instanceId: "inst-normal-sync",
        requirePointer: true,
      }),
    /SUPERSEDED/,
  );

  // 2) Late in-flight predecessor PUT .state.json landing AFTER successor cleanup is blocked by committed-state.json
  const s3Ledger = createMockS3();
  globalThis.fetch = s3Ledger.fetch;
  const envLedger = fixtureEnv(r2Objects);
  const stgSucc = "staging/secondary-sync/codex-app-2.0.0/inst-succ-ledger";
  s3Ledger.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-succ-ledger", manifestSha256: manifestSha, epoch: 500 }), old),
  );
  s3Ledger.objects.set(
    `${stgSucc}/objects/arm64`,
    objectEntry("PUB-ARM64-V200", old, { syncSha256: contentHashHex(bytes("PUB-ARM64-V200")) }),
  );
  s3Ledger.objects.set(
    `${stgSucc}/objects/manifest`,
    objectEntry(manifestText, old, { syncSha256: manifestSha }),
  );
  const succArm = await commitSingleAlias(envLedger, `${stgSucc}/objects/arm64`, "latest/win-arm64", {
    keepBackup: true,
    expectedManifestSha256: manifestSha,
    instanceId: "inst-succ-ledger",
    stagePrefix: stgSucc,
  });
  const succMan = await commitSingleAlias(envLedger, `${stgSucc}/objects/manifest`, "latest/manifest", {
    keepBackup: true,
    expectedManifestSha256: manifestSha,
    instanceId: "inst-succ-ledger",
    stagePrefix: stgSucc,
  });
  await recordSwitchoverCommittedCheckpoint(envLedger, stgSucc, [succArm, succMan], {
    releaseTag: "codex-app-2.0.0",
    manifestSha256: manifestSha,
    instanceId: "inst-succ-ledger",
  });
  await cleanupStageObjects(
    envLedger,
    [
      { stageKey: `${stgSucc}/objects/arm64`, aliasKeys: ["latest/win-arm64"] },
      { stageKey: `${stgSucc}/objects/manifest`, aliasKeys: ["latest/manifest"] },
    ],
    stgSucc,
    {
      switchoverComplete: true,
      purgeSupersededOrphans: true,
      expectedManifestSha256: manifestSha,
      instanceId: "inst-succ-ledger",
    },
  );
  assert.equal(s3Ledger.objects.has(`${stgSucc}/backups/_batch_committed.json`), false);
  assert.equal(s3Ledger.objects.has("staging/secondary-sync/committed-state.json"), true);
  // Late predecessor PUT lands after checkpoint deletion
  const stgLatePred = "staging/secondary-sync/codex-app-1.9.0/inst-late-pred";
  const detLateArm = aliasBackupKeys("", "latest/win-arm64", stgLatePred);
  s3Ledger.objects.set(
    detLateArm.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-arm64",
        backupKey: detLateArm.backupKey,
        stateKey: detLateArm.stateKey,
        hadExisting: false,
        absentBaselineVerified: true,
        ownerEpoch: 450,
        restored: false,
      }),
      new Date(),
    ),
  );
  s3Ledger.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-next-fail", manifestSha256: manifestSha, epoch: 510 }), new Date()),
  );
  await rollbackCommittedAliases(envLedger, [], {
    expectedManifestSha256: manifestSha,
    instanceId: "inst-next-fail",
    stagePrefix: "staging/secondary-sync/codex-app-2.0.0/inst-next-fail",
  });
  assert.equal(
    text(s3Ledger.objects.get("latest/win-arm64").bytes),
    "PUB-ARM64-V200",
    "late predecessor absent-baseline state must not delete published latest/win-arm64",
  );

  // 3 & 4) Restarted slot ignores its own superseded Run-#1 state/_batch_restored, while a newer backup (epoch 630 > 610) in that reused dir survives pruning and recovers
  const s3Slot = createMockS3();
  globalThis.fetch = s3Slot.fetch;
  const envSlot = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async get() {
        return {
          id: "inst-slot-s1",
          async status() {
            return { status: "errored" };
          },
        };
      },
    },
  };
  const stgS1 = "staging/secondary-sync/codex-app-2.0.0/inst-slot-s1";
  const detS1Win = aliasBackupKeys(`${stgS1}/objects/win`, "latest/win-x64", stgS1);
  s3Slot.objects.set(detS1Win.backupKey, objectEntry("OLD-WIN-600", old));
  s3Slot.objects.set(
    detS1Win.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        backupKey: detS1Win.backupKey,
        stateKey: detS1Win.stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: bytes("OLD-WIN-600").byteLength,
        backupSha256: contentHashHex(bytes("OLD-WIN-600")),
        ownerEpoch: 600,
        restored: false,
      }),
      old,
    ),
  );
  s3Slot.objects.set(
    `${stgS1}/backups/_batch_restored.json`,
    objectEntry(
      JSON.stringify({
        completed: true,
        ownerEpoch: 600,
        restored: ["latest/win-arm64"],
        entries: [{ aliasKey: "latest/win-arm64", backupKey: "", stateKey: "", hadExisting: false }],
        completedAt: old.toISOString(),
      }),
      old,
    ),
  );
  s3Slot.objects.set("latest/win-x64", objectEntry("NEW-WIN-610", old, { syncSha256: contentHashHex(bytes("NEW-WIN-610")) }));
  s3Slot.objects.set("latest/win-arm64", objectEntry("NEW-ARM64-610", old, { syncSha256: contentHashHex(bytes("NEW-ARM64-610")) }));
  s3Slot.objects.set("latest/manifest", objectEntry(manifestText, old, { syncSha256: manifestSha }));
  const stgPub610 = "staging/secondary-sync/codex-app-2.0.0/inst-pub-610";
  s3Slot.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-pub-610", manifestSha256: manifestSha, epoch: 610 }), old),
  );
  await recordSwitchoverCommittedCheckpoint(envSlot, stgPub610, [], {
    releaseTag: "codex-app-2.0.0",
    manifestSha256: manifestSha,
    instanceId: "inst-pub-610",
    supersededBackupDirs: [`${stgS1}/backups/`],
  });
  // Restart inst-slot-s1 at epoch 620 and fail during staging
  s3Slot.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-slot-s1", manifestSha256: manifestSha, epoch: 620 }), old),
  );
  await rollbackCommittedAliases(envSlot, [], {
    expectedManifestSha256: manifestSha,
    instanceId: "inst-slot-s1",
    stagePrefix: stgS1,
  });
  assert.equal(text(s3Slot.objects.get("latest/win-x64").bytes), "NEW-WIN-610", "restarted slot must not restore its own superseded Run-#1 backup");
  assert.equal(text(s3Slot.objects.get("latest/win-arm64").bytes), "NEW-ARM64-610", "restarted slot must not replay its own superseded _batch_restored.json");

  // Reuse stgS1 at epoch 630 (> 610), supersede between DELETE and COPY of latest/win-x64
  let supersede630 = false;
  const s3Reuse = createMockS3({
    onDelete(delKey, store) {
      if (supersede630 && delKey === "latest/win-x64") {
        store.delete(delKey);
        store.set(
          "staging/secondary-sync/active-sync.json",
          objectEntry(JSON.stringify({ instanceId: "inst-640", manifestSha256: manifestSha, epoch: 640 }), old),
        );
        return new Response(null, { status: 204 });
      }
      return null;
    },
  });
  for (const [k, v] of s3Slot.objects.entries()) {
    s3Reuse.objects.set(k, v);
  }
  globalThis.fetch = s3Reuse.fetch;
  s3Reuse.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-slot-s1", manifestSha256: manifestSha, epoch: 630 }), old),
  );
  s3Reuse.objects.set(
    `${stgS1}/objects/win`,
    objectEntry("REPAIR-WIN-630", old, { syncSha256: contentHashHex(bytes("REPAIR-WIN-630")) }),
  );
  supersede630 = true;
  await assert.rejects(
    () =>
      commitSingleAlias(envSlot, `${stgS1}/objects/win`, "latest/win-x64", {
        keepBackup: true,
        force: true,
        expectedManifestSha256: manifestSha,
        instanceId: "inst-slot-s1",
        stagePrefix: stgS1,
      }),
    /SUPERSEDED/,
  );
  supersede630 = false;
  assert.equal(s3Reuse.objects.has("latest/win-x64"), false);
  // Age-out backup objects so pruner attempts to prune abandoned entries
  for (const [k, v] of s3Reuse.objects.entries()) {
    if (k.startsWith(stgS1)) {
      v.lastModified = old;
    }
  }
  await pruneAbandonedStageObjects(envSlot, "", { graceHours: 1 });
  assert.equal(s3Reuse.objects.has(detS1Win.backupKey), true, "pruner must NOT delete epoch-630 backup in dir named by epoch-610 checkpoint");
  await rollbackCommittedAliases(envSlot, [], {
    expectedManifestSha256: manifestSha,
    instanceId: "inst-640",
    stagePrefix: "staging/secondary-sync/codex-app-2.0.0/inst-640",
  });
  assert.equal(text(s3Reuse.objects.get("latest/win-x64").bytes), "NEW-WIN-610", "recovery must restore epoch-630 backup in reused directory");

  // 5 & 6) Restart invalidation when _batch_committed.json was missing persists guard BEFORE deleting <manifest>.state.json, and failure cleanup retains priorRunSuperseded while superseded backups exist
  const s3Inv = createMockS3();
  globalThis.fetch = s3Inv.fetch;
  const envInv = {
    ...fixtureEnv(r2Objects),
    SECONDARY_MIRROR_WORKFLOW: {
      async get() {
        return null;
      },
    },
  };
  const stgPred700 = "staging/secondary-sync/codex-app-1.9.0/inst-pred-700";
  const detPred700 = aliasBackupKeys(`${stgPred700}/objects/win`, "latest/win-x64", stgPred700);
  s3Inv.objects.set(detPred700.backupKey, objectEntry("OBSOLETE-700-WIN", old));
  s3Inv.objects.set(
    detPred700.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/win-x64",
        backupKey: detPred700.backupKey,
        stateKey: detPred700.stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: bytes("OBSOLETE-700-WIN").byteLength,
        backupSha256: contentHashHex(bytes("OBSOLETE-700-WIN")),
        ownerEpoch: 700,
        restored: false,
      }),
      old,
    ),
  );
  const plan710 = decoratePlanWithStage(
    buildObjectPlan(manifest, "codex-app-2.0.0", { manifestText, manifestSha256: manifestSha }),
    "inst-slot-710",
    envInv,
  );
  const det710Man = aliasBackupKeys("", "latest/manifest", plan710.stagePrefix);
  s3Inv.objects.set("latest/win-x64", objectEntry("LIVE-710-WIN", old, { syncSha256: contentHashHex(bytes("LIVE-710-WIN")) }));
  s3Inv.objects.set("latest/manifest", objectEntry(manifestText, old, { syncSha256: manifestSha }));
  // Only <manifest>.state.json survived (no _batch_committed.json, no ledger yet)
  s3Inv.objects.set(
    det710Man.stateKey,
    objectEntry(
      JSON.stringify({
        aliasKey: "latest/manifest",
        backupKey: det710Man.backupKey,
        stateKey: det710Man.stateKey,
        hadExisting: false,
        absentBaselineVerified: true,
        ownerEpoch: 710,
        targetManifestSha256: manifestSha,
        supersededBackupDirs: [`${stgPred700}/backups/`],
        restored: false,
      }),
      old,
    ),
  );
  // Restart inst-slot-710 at epoch 720 while an alias is missing so verifyPriorSwitchoverCheckpoint invalidates
  s3Inv.objects.set(
    "staging/secondary-sync/active-sync.json",
    objectEntry(JSON.stringify({ instanceId: "inst-slot-710", manifestSha256: manifestSha, epoch: 720 }), old),
  );
  const invRes = await verifyPriorSwitchoverCheckpoint(
    envInv,
    { releaseTag: "codex-app-2.0.0", manifest, manifestText, manifestSha256: manifestSha },
    plan710,
    { instanceId: "inst-slot-710" },
  );
  assert.equal(invRes, null);
  assert.equal(s3Inv.objects.has(`${plan710.stagePrefix}/backups/_batch_committed.json`), true);
  assert.equal(s3Inv.objects.has("staging/secondary-sync/committed-state.json"), true);
  // First staging failure rollback + failure cleanup
  await rollbackCommittedAliases(envInv, [], {
    expectedManifestSha256: manifestSha,
    instanceId: "inst-slot-710",
    stagePrefix: plan710.stagePrefix,
  });
  assert.equal(text(s3Inv.objects.get("latest/win-x64").bytes), "LIVE-710-WIN");
  await cleanupStageObjects(envInv, plan710.items, plan710.stagePrefix, {
    switchoverComplete: false,
    expectedManifestSha256: manifestSha,
    instanceId: "inst-slot-710",
  });
  assert.equal(
    s3Inv.objects.has(`${plan710.stagePrefix}/backups/_batch_committed.json`),
    true,
    "failure cleanup must retain priorRunSuperseded _batch_committed.json while superseded backup remains",
  );
  // Second staging failure rollback MUST STILL preserve LIVE-710-WIN
  await rollbackCommittedAliases(envInv, [], {
    expectedManifestSha256: manifestSha,
    instanceId: "inst-slot-710",
    stagePrefix: plan710.stagePrefix,
  });
  assert.equal(text(s3Inv.objects.get("latest/win-x64").bytes), "LIVE-710-WIN");

  // 7 & 8) Codex <packageMoniker>.Msix checksum lookup + 0-byte mixed LIST-fallback/unstamped-HEAD migration
  const moniker = "OpenAI.Codex_26.313.41514.0_x64__2p2nqsd0c76g0";
  const manifestMoniker = {
    ...manifest,
    sources: {
      ...manifest.sources,
      windows: {
        ...manifest.sources.windows,
        packageMoniker: moniker,
        architectures: {
          x64: { downloadable: true, packageMoniker: moniker },
          arm64: { downloadable: false },
        },
      },
    },
  };
  delete manifestMoniker.derived;
  const bigWinGood = new Uint8Array(6 * 1024 * 1024);
  bigWinGood.fill(0x41);
  const bigWinCorrupt = bigWinGood.slice(0);
  bigWinCorrupt[bigWinCorrupt.length - 1] = 0x42;
  const bigWinGoodSha = contentHashHex(bigWinGood);
  const r2Moniker = fixtureR2Objects(manifestMoniker, {
    "latest/win-x64": bigWinGood,
  });
  const monikerManifestText = text(r2Moniker.get("latest/manifest"));
  const monikerManifestSha = contentHashHex(r2Moniker.get("latest/manifest"));
  // Replace Codex-Windows-x64.msix with <packageMoniker>.Msix in latest/checksums!
  const checksumLines = [
    `${bigWinGoodSha}  ${moniker}.Msix`,
    `${contentHashHex(r2Moniker.get("latest/mac-arm64"))}  Codex-mac-arm64.dmg`,
    `${contentHashHex(r2Moniker.get("latest/mac-intel"))}  Codex-mac-x64.dmg`,
    `${contentHashHex(r2Moniker.get("latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip"))}  Codex-darwin-arm64-2.0.0.zip`,
    `${contentHashHex(r2Moniker.get("latest/mac/intel/Codex-darwin-x64-2.0.0.zip"))}  Codex-darwin-x64-2.0.0.zip`,
    `${contentHashHex(r2Moniker.get("latest/mac/arm64/Codex9999-live-arm64.delta"))}  Codex9999-live-arm64.delta`,
    `${contentHashHex(r2Moniker.get("latest/mac/intel/Codex9999-live-x64.delta"))}  Codex9999-live-x64.delta`,
    `${monikerManifestSha}  release-manifest.json`,
  ].join("\n") + "\n";
  r2Moniker.set("latest/checksums", bytes(checksumLines));

  let mixedBinaryGetBytes = 0;
  let head403WinX64 = true;
  const s3Moniker = createMockS3({
    onHead(key) {
      if (head403WinX64 && key === "latest/win-x64") {
        return new Response("Forbidden", { status: 403 });
      }
      return null;
    },
    onGet(key, store, reqHeaders) {
      if (key === "latest/win-x64" || key === "latest/win" || key.startsWith("latest/mac")) {
        if (!reqHeaders?.get("range")) {
          const ent = store.get(key);
          if (ent) mixedBinaryGetBytes += ent.bytes.byteLength;
        } else if (head403WinX64 && key === "latest/win-x64") {
          return new Response("Forbidden", { status: 403 });
        }
      }
      return null;
    },
  });
  globalThis.fetch = s3Moniker.fetch;
  const monikerPlan = decoratePlanWithStage(
    buildObjectPlan(manifestMoniker, "codex-app-2.0.0", {
      manifestText: monikerManifestText,
      manifestSha256: monikerManifestSha,
    }),
    "inst-moniker",
    fixtureEnv(r2Moniker),
  );
  // Seed secondary S3: latest/win-x64 via LIST fallback (corrupt 1 byte), latest/win via authoritative unstamped HEAD!
  for (const item of monikerPlan.items) {
    const val =
      item.id === "win-x64"
        ? bigWinCorrupt
        : r2Moniker.get(item.sourceKey) || bytes(item.inlineText || "");
    for (const ak of item.aliasKeys) {
      s3Moniker.objects.set(ak, objectEntry(val, old));
    }
  }
  let createdCount = 0;
  const envMonikerBase = {
    ...fixtureEnv(r2Moniker),
    SECONDARY_SYNC_SINGLE_PUT_MAX_BYTES: String(5 * 1024 * 1024),
    SECONDARY_SYNC_PART_SIZE_BYTES: String(5 * 1024 * 1024),
  };
  const envMonikerWf = {
    ...envMonikerBase,
    SECONDARY_MIRROR_WORKFLOW: {
      async get() {
        return null;
      },
      async create({ id }) {
        createdCount += 1;
        return {
          id,
          async status() {
            return { status: "running" };
          },
        };
      },
    },
  };
  const mixedRes = await reconcileSync(envMonikerWf, {});
  assert.equal(mixedRes.created, true, "mixed LIST-fallback + unstamped HEAD must schedule migration");
  assert.equal(mixedBinaryGetBytes, 0, "mixed HEAD visibility must NOT stream 6 MiB installer before spotting unstamped alias");

  // Upload & commit all items (multipart win-x64 looks up <packageMoniker>.Msix in latest/checksums and stamps syncSha256)
  head403WinX64 = false;
  s3Moniker.objects.delete("staging/secondary-sync/active-sync.json");
  for (const item of monikerPlan.items) {
    const up = await uploadObjectToStage(envMonikerBase, item);
    for (const ak of item.aliasKeys) {
      await commitSingleAlias(envMonikerBase, item.stageKey, ak, {
        keepBackup: false,
        stagePrefix: monikerPlan.stagePrefix,
        expectedManifestSha256: monikerManifestSha,
        itemExpectedSha256: up.sha256 || item.expectedSha256 || "",
      });
    }
  }
  assert.equal(s3Moniker.objects.get("latest/win-x64").syncSha256, bigWinGoodSha);
  const afterMoniker = await reconcileSync(envMonikerWf, {});
  assert.equal(afterMoniker.skipped, true, "stamped multipart installer with <packageMoniker>.Msix checksum must skip");
  assert.equal(createdCount, 1);

  // Corrupt 1 byte on secondary S3 without stamp (under LIST fallback) -> reconcileSync must detect digest mismatch via <packageMoniker>.Msix!
  s3Moniker.objects.set("latest/win-x64", objectEntry(bigWinCorrupt, old));
  head403WinX64 = true;
  const corruptRes = await reconcileSync(envMonikerWf, {});
  assert.equal(corruptRes.created, true, "1-byte corruption under LIST fallback must be caught via <packageMoniker>.Msix checksum");
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
  const manifestJson = JSON.stringify(manifest);
  const manifestHex = contentHashHex(bytes(manifestJson));
  const armZip = manifest?.sources?.macos?.arm64?.appcast?.mirrorEnclosureBasename || "Codex-darwin-arm64-2.0.0.zip";
  const x64Zip = manifest?.sources?.macos?.x64?.appcast?.mirrorEnclosureBasename || "Codex-darwin-x64-2.0.0.zip";
  const armDelta = manifest?.sources?.macos?.arm64?.appcast?.deltas?.[0]?.basename || "Codex9999-live-arm64.delta";
  const x64Delta = manifest?.sources?.macos?.x64?.appcast?.deltas?.[0]?.basename || "Codex9999-live-x64.delta";
  const objects = new Map(
    Object.entries({
      "latest/win-x64": "win-x64",
      "latest/win-arm64": "win-arm64",
      "latest/mac-arm64": "mac-arm64",
      "latest/mac-intel": "mac-intel",
      [`latest/mac/arm64/${armZip}`]: "arm64-zip",
      [`latest/mac/intel/${x64Zip}`]: "x64-zip",
      [`latest/mac/arm64/${armDelta}`]: "arm64-delta",
      [`latest/mac/intel/${x64Delta}`]: "x64-delta",
      "latest/checksums": `${manifestHex}  release-manifest.json\n`,
      "latest/appcast.xml": `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/${armZip}" /><sparkle:deltas><enclosure url="https://codexapp.agentsmirror.com/latest/mac/arm64/${armDelta}" /></sparkle:deltas></item></channel></rss>`,
      "latest/appcast-x64.xml": `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString><enclosure url="https://codexapp.agentsmirror.com/latest/mac/intel/${x64Zip}" /><sparkle:deltas><enclosure url="https://codexapp.agentsmirror.com/latest/mac/intel/${x64Delta}" /></sparkle:deltas></item></channel></rss>`,
      "latest/manifest": manifestJson,
      ...overrides,
    }).map(([key, value]) => [key, bytes(value)]),
  );
  return objects;
}

function fixtureEnv(r2Objects, r2Hooks = {}) {
  return {
    GLOBAL_R2: new MockR2Bucket(r2Objects, r2Hooks),
    SECONDARY_S3_ENDPOINT: "https://s3.example.test",
    SECONDARY_S3_BUCKET: "bucket",
    SECONDARY_S3_REGION: "auto",
    SECONDARY_S3_ACCESS_KEY_ID: "key",
    SECONDARY_S3_SECRET_ACCESS_KEY: "secret",
    SECONDARY_S3_RETRY_BASE_DELAY_MS: "0",
  };
}

class MockR2Bucket {
  constructor(objects, hooks = {}) {
    this.objects = objects;
    this.onR2Get = hooks.onR2Get || null;
  }

  etagFor(value) {
    return contentHashHex(value);
  }

  async head(key) {
    const value = this.objects.get(key);
    return value ? { size: value.byteLength, etag: this.etagFor(value) } : null;
  }

  async get(key, options = {}) {
    if (this.onR2Get) {
      this.onR2Get(key, options);
    }
    const value = this.objects.get(key);
    if (!value) {
      return null;
    }
    const etag = this.etagFor(value);
    if (options.onlyIf?.etagMatches && options.onlyIf.etagMatches !== etag) {
      return { size: value.byteLength, etag };
    }
    const range = options.range;
    const sliced = range ? value.slice(range.offset, range.offset + range.length) : value;
    return {
      size: sliced.byteLength,
      etag,
      async arrayBuffer() {
        return sliced.slice(0);
      },
      async text() {
        return text(sliced);
      },
    };
  }
}

function createMockS3(options = {}) {
  const objects = new Map();
  const uploads = new Map();
  let uploadCounter = 0;
  const failCopyFrom = options.failCopyFrom || (() => false);
  const onCopy = options.onCopy || (() => null);
  const onGet = options.onGet || (() => null);
  const onHead = options.onHead || (() => null);
  const onPut = options.onPut || (() => null);
  const onDelete = options.onDelete || (() => null);
  const onList = options.onList || (() => null);
  const onUploadPart = options.onUploadPart || (() => null);
  const onCompleteMultipart = options.onCompleteMultipart || (() => null);
  const onAbortMultipart = options.onAbortMultipart || (() => {});

  async function fetch(input, init = {}) {
    const url = new URL(input);
    const { key } = parseS3Path(url.pathname);
    const method = init.method || "GET";
    const headers = new Headers(init.headers || {});

    if (method === "GET" && url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") || "";
      const injectedList = onList(prefix, objects);
      if (injectedList) {
        return injectedList;
      }
      const contents = [...objects.entries()]
        .filter(([objectKey]) => objectKey.startsWith(prefix))
        .map(
          ([objectKey, entry]) =>
            `<Contents><Key>${xmlEscape(objectKey)}</Key><LastModified>${entry.lastModified.toISOString()}</LastModified><ETag>${xmlEscape(entry.etag)}</ETag><Size>${entry.bytes.byteLength}</Size></Contents>`,
        )
        .join("");
      return new Response(`<ListBucketResult>${contents}</ListBucketResult>`, { status: 200 });
    }

    if (method === "GET" && url.searchParams.has("uploads")) {
      const prefix = url.searchParams.get("prefix") || "";
      const entries = [...uploads.entries()]
        .filter(([, upload]) => upload.key.startsWith(prefix))
        .map(
          ([uploadId, upload]) =>
            `<Upload><Key>${xmlEscape(upload.key)}</Key><UploadId>${xmlEscape(uploadId)}</UploadId><Initiated>${upload.initiated.toISOString()}</Initiated></Upload>`,
        )
        .join("");
      return new Response(`<ListMultipartUploadsResult>${entries}</ListMultipartUploadsResult>`, {
        status: 200,
      });
    }

    if (method === "HEAD") {
      const injectedHead = onHead(key, objects, headers);
      if (injectedHead) {
        return injectedHead;
      }
      if (key.includes("head-403")) {
        return new Response("forbidden", { status: 403 });
      }
      const entry = objects.get(key);
      if (!entry) {
        return new Response(null, { status: 404 });
      }
      const resHeaders = {
        "content-length": key.includes("head-zero") ? "0" : String(entry.bytes.byteLength),
        "last-modified": entry.lastModified.toUTCString(),
        etag: entry.etag,
      };
      if (entry.syncSha256) {
        resHeaders["x-amz-meta-sync-sha256"] = entry.syncSha256;
      }
      return new Response(null, {
        status: 200,
        headers: resHeaders,
      });
    }

    if (method === "GET") {
      const injectedGet = onGet(key, objects, headers);
      if (injectedGet) {
        return injectedGet;
      }
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
      uploads.set(uploadId, {
        key,
        parts: new Map(),
        initiated: new Date(),
        syncSha256: headers.get("x-amz-meta-sync-sha256") || "",
      });
      return new Response(`<InitiateMultipartUploadResult><UploadId>${uploadId}</UploadId></InitiateMultipartUploadResult>`);
    }

    if (method === "PUT" && url.searchParams.has("partNumber")) {
      const partNumber = Number(url.searchParams.get("partNumber"));
      const injected = onUploadPart(partNumber);
      if (injected) {
        return injected;
      }
      const uploadId = url.searchParams.get("uploadId");
      const upload = uploads.get(uploadId);
      upload.parts.set(partNumber, await bodyBytes(init.body));
      return new Response(null, { status: 200, headers: { etag: `"part-${upload.parts.size}"` } });
    }

    if (method === "POST" && url.searchParams.has("uploadId")) {
      const injectedComplete = onCompleteMultipart(key, url.searchParams.get("uploadId"));
      if (injectedComplete) {
        return injectedComplete;
      }
      const upload = uploads.get(url.searchParams.get("uploadId"));
      const joined = concatBytes([...upload.parts.entries()].sort(([a], [b]) => a - b).map(([, value]) => value));
      objects.set(
        upload.key,
        objectEntry(joined, new Date(), {
          etag: `"${contentHashHex(joined)}-${upload.parts.size}"`,
          syncSha256: upload.syncSha256,
        }),
      );
      uploads.delete(url.searchParams.get("uploadId"));
      return new Response("<CompleteMultipartUploadResult><ETag>\"mp\"</ETag></CompleteMultipartUploadResult>");
    }

    if (method === "DELETE" && url.searchParams.has("uploadId")) {
      onAbortMultipart(url.searchParams.get("uploadId"));
      uploads.delete(url.searchParams.get("uploadId"));
      return new Response(null, { status: 204 });
    }

    if (method === "PUT" && headers.has("x-amz-copy-source")) {
      const sourceKey = parseCopySource(headers.get("x-amz-copy-source"));
      const injectedCopy = onCopy(sourceKey, key, objects);
      if (injectedCopy) {
        return injectedCopy;
      }
      if (failCopyFrom(sourceKey)) {
        return new Response("<Error><Code>InternalError</Code></Error>", { status: 500 });
      }
      const source = objects.get(sourceKey);
      if (!source) {
        return new Response("missing copy source", { status: 404 });
      }
      const copiedEntry = objectEntry(source.bytes.slice(0), new Date(), {
        syncSha256: source.syncSha256,
      });
      objects.set(key, copiedEntry);
      return new Response(`<CopyObjectResult><ETag>${xmlEscape(copiedEntry.etag)}</ETag></CopyObjectResult>`);
    }

    if (method === "PUT") {
      const injectedPut = onPut(key, objects, headers);
      if (injectedPut) {
        return injectedPut;
      }
      objects.set(
        key,
        objectEntry(await bodyBytes(init.body), new Date(), {
          syncSha256: headers.get("x-amz-meta-sync-sha256") || "",
        }),
      );
      return new Response(null, { status: 200 });
    }

    if (method === "DELETE") {
      const injectedDelete = onDelete(key, objects);
      if (injectedDelete) {
        return injectedDelete;
      }
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

function contentHashHex(valueBytes) {
  const inc = createIncrementalSha256();
  inc.update(valueBytes);
  return inc.digestHex();
}

function objectEntry(value, lastModified = new Date(), meta = {}) {
  const valueBytes = value instanceof Uint8Array ? value : bytes(value);
  return {
    bytes: valueBytes,
    lastModified,
    etag: meta.etag || `"${contentHashHex(valueBytes).slice(0, 32)}"`,
    syncSha256: meta.syncSha256 || "",
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
