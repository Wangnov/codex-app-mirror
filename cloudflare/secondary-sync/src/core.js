const DEFAULT_PART_SIZE_BYTES = 32 * 1024 * 1024;
const DEFAULT_SINGLE_PUT_MAX_BYTES = 32 * 1024 * 1024;
const DEFAULT_S3_MAX_ATTEMPTS = 5;
const DEFAULT_S3_COPY_MAX_ATTEMPTS = 3;
const DEFAULT_R2_MAX_ATTEMPTS = 3;
const DEFAULT_S3_RETRY_BASE_DELAY_MS = 1000;
const DEFAULT_S3_RETRY_MAX_DELAY_MS = 10000;
const DEFAULT_S3_REQUEST_TIMEOUT_MS = 180000;
const DEFAULT_S3_COPY_TIMEOUT_MS = 270000;
const DEFAULT_CACHE_CONTROL = "public, max-age=600, s-maxage=86400";
const SHORT_CACHE_CONTROL = "public, max-age=600";
const DEFAULT_PUBLIC_BASE_URL = "https://codexapp.agentsmirror.com";
function decodeStrictUtf8(bytesLike) {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
      bytesLike instanceof Uint8Array ? bytesLike : new Uint8Array(bytesLike),
    );
  } catch (cause) {
    const err = new TypeError(`Invalid UTF-8 byte sequence: ${cause?.message || "decode failed"}`);
    err.code = "ERR_INVALID_UTF8";
    throw err;
  }
}

function stripOptionalUtf8Bom(text) {
  const str = String(text || "");
  return str.charCodeAt(0) === 0xfeff ? str.slice(1) : str;
}

function parseJsonAllowingBom(text) {
  return JSON.parse(stripOptionalUtf8Bom(text));
}

async function readR2ObjectStrictBytesAndText(r2Obj, label = "R2 object") {
  if (typeof r2Obj.arrayBuffer === "function") {
    const rawBytes = new Uint8Array(await r2Obj.arrayBuffer());
    const sha256 = await sha256Hex(rawBytes);
    try {
      const text = decodeStrictUtf8(rawBytes);
      return { rawBytes, text, sha256 };
    } catch {
      throw new NonRetryableMirrorError(`${label} contains invalid UTF-8 bytes.`);
    }
  }
  const text = await r2Obj.text();
  return { rawBytes: utf8(text), text, sha256: await sha256Hex(text) };
}

async function readR2ObjectStrictText(r2Obj) {
  if (typeof r2Obj.arrayBuffer === "function") {
    return decodeStrictUtf8(await r2Obj.arrayBuffer());
  }
  return r2Obj.text();
}

const DEFAULT_STAGE_PREFIX = "staging/secondary-sync";
const ACTIVE_SYNC_POINTER_NAME = "active-sync.json";
const COMMITTED_STATE_LEDGER_NAME = "committed-state.json";
const ALIAS_ROLLBACK_SUFFIX = ".rollback";
const SYNC_SHA256_HEADER = "x-amz-meta-sync-sha256";
const DEFAULT_PRUNE_GRACE_DAYS = 1;
const DEFAULT_STAGE_GRACE_HOURS = 2;

export class NonRetryableMirrorError extends Error {
  constructor(message) {
    super(message);
    this.name = "NonRetryableMirrorError";
  }
}

export class SupersededMirrorError extends NonRetryableMirrorError {
  constructor(message) {
    const text = String(message || "Sync superseded by newer release.");
    super(text.startsWith("[SUPERSEDED]") ? text : `[SUPERSEDED] ${text}`);
    this.name = "SupersededMirrorError";
  }
}

export function isSupersededError(error) {
  return (
    error instanceof SupersededMirrorError ||
    error?.name === "SupersededMirrorError" ||
    String(error?.message || "").includes("[SUPERSEDED]")
  );
}

export async function handleApiRequest(request, env) {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/health") {
    return jsonResponse({ ok: true, service: "codex-app-mirror-secondary-sync" });
  }

  assertAuthorized(request, env);

  if (request.method === "POST" && url.pathname === "/sync/start") {
    const body = await readJsonBody(request);
    const result = await startSync(env, body);
    return jsonResponse(result, { status: result.ok ? 202 : 409 });
  }

  if (request.method === "POST" && url.pathname === "/sync/reconcile") {
    const body = await readJsonBody(request);
    const result = await reconcileSync(env, body);
    return jsonResponse(result, { status: result.ok ? 200 : 409 });
  }

  if (request.method === "GET" && url.pathname === "/sync/status") {
    const id = url.searchParams.get("id");
    if (!id) {
      return jsonResponse({ ok: false, error: "Missing id query parameter." }, { status: 400 });
    }
    const result = await workflowStatus(env, id);
    return jsonResponse(result, { status: result.ok ? 200 : 404 });
  }

  if (request.method === "GET" && url.pathname === "/sync/plan") {
    const source = await discoverSourceManifest(env, url.searchParams.get("releaseTag") || "");
    const plan = buildObjectPlan(source.manifest, source.releaseTag, {
      manifestText: source.manifestText,
      manifestSha256: source.manifestSha256,
      secondaryPrefix: env.SECONDARY_S3_PREFIX || "",
      publicBaseUrl: env.PUBLIC_BASE_URL || "",
    });
    return jsonResponse({
      ok: true,
      releaseTag: source.releaseTag,
      items: plan.items.map((item) => ({
        id: item.id,
        sourceKey: item.sourceKey,
        stageRelativeKey: item.stageRelativeKey,
        aliases: item.aliasKeys,
        role: item.role,
      })),
      staleAliases: plan.staleAliasKeys,
    });
  }

  return jsonResponse({ ok: false, error: "Not found" }, { status: 404 });
}

export async function startSync(env, params = {}, _depth = 0) {
  assertWorkflowBinding(env);
  let source = await discoverSourceManifest(env, params.releaseTag || "");
  const force = Boolean(params.force);

  // Deduplicate against any currently active workflow recorded in S3 when matching,
  // or best-effort terminate a genuinely older workflow after re-verifying R2 latest/manifest.
  if (!params.instanceId && !params.idSalt) {
    const active = await findActiveRecordedWorkflow(env, null);
    const refreshed = await discoverSourceManifest(env, params.releaseTag || "");
    if (refreshed.manifestSha256 !== source.manifestSha256) {
      if (_depth < 2) {
        return startSync(env, params, _depth + 1);
      }
      source = refreshed;
    }
    if (active) {
      if (!force && (!active.manifestSha256 || active.manifestSha256 === source.manifestSha256)) {
        return {
          ok: true,
          id: active.id,
          state: active.state,
          status: active.status,
          releaseTag: source.releaseTag,
          created: false,
          restarted: false,
          reused: true,
        };
      }
      if (active.manifestSha256 !== source.manifestSha256 || force) {
        const latestSource = await discoverSourceManifest(env, params.releaseTag || "");
        if (latestSource.manifestSha256 !== source.manifestSha256) {
          if (_depth < 2) {
            return startSync(env, params, _depth + 1);
          }
          throw new SupersededMirrorError(
            `R2 latest/manifest advanced from ${source.manifestSha256} to ${latestSource.manifestSha256} during startSync.`,
          );
        }
        if (active.manifestSha256 !== latestSource.manifestSha256 || force) {
          try {
            await active.instance?.terminate?.();
          } catch {
            // Best-effort termination; active-sync.json + manifest checks also fence stale commits.
          }
        }
      }
    }
  }

  const effectiveIdSalt =
    params.idSalt || (force && !params.instanceId ? `${source.manifestSha256}-force-${Date.now()}` : "");
  const instanceId =
    params.instanceId ||
    (effectiveIdSalt
      ? workflowInstanceId(source.manifestSha256 ? "manifest" : source.releaseTag, effectiveIdSalt)
      : canonicalManifestWorkflowId(source.manifestSha256, source.releaseTag));

  const payload = {
    releaseTag: source.releaseTag,
    manifestSha256: source.manifestSha256,
    force,
    requestedAt: new Date().toISOString(),
  };

  try {
    const instance = await env.SECONDARY_MIRROR_WORKFLOW.create({
      id: instanceId,
      params: payload,
      retention: {
        successRetention: env.WORKFLOW_SUCCESS_RETENTION || "1 day",
        errorRetention: env.WORKFLOW_ERROR_RETENTION || "7 days",
      },
    });
    const status = await instance.status();
    try {
      await recordActiveSyncPointer(env, {
        instanceId: instance.id,
        instance,
        manifestSha256: source.manifestSha256,
        releaseTag: source.releaseTag,
        bumpEpoch: true,
      });
    } catch (pointerError) {
      try {
        await instance.terminate?.();
      } catch {
        // Ignore cleanup failure when pointer write failed or was superseded.
      }
      if (isSupersededError(pointerError) && _depth < 2 && !params.instanceId) {
        return startSync(env, params, _depth + 1);
      }
      throw pointerError;
    }
    return {
      ok: true,
      id: instance.id,
      state: normalizeWorkflowState(status),
      status,
      releaseTag: source.releaseTag,
      created: true,
    };
  } catch (error) {
    if (isSupersededError(error)) {
      throw error;
    }
    const existing = await getWorkflowIfExists(env, instanceId);
    if (!existing || error?.fromPointerWrite) {
      throw error;
    }

    const status = await existing.status();
    const state = normalizeWorkflowState(status);
    if (force && !(params.reuseActiveOnForceCollision && isActiveWorkflowState(state))) {
      await verifySourceManifestCurrent(env, source.manifestSha256);
      try {
        await existing.terminate?.();
      } catch {
        // Best-effort termination before launching a fresh instance carrying force=true.
      }
      if (_depth < 2) {
        return startSync(
          env,
          {
            ...params,
            instanceId: undefined,
            idSalt: `${source.manifestSha256}-force-${Date.now()}-${_depth}`,
          },
          _depth + 1,
        );
      }
      throw error;
    }

    if (!force && shouldRestartState(state)) {
      await verifySourceManifestCurrent(env, source.manifestSha256);
      await existing.restart();
      await recordActiveSyncPointer(env, {
        instanceId: existing.id,
        instance: existing,
        manifestSha256: source.manifestSha256,
        releaseTag: source.releaseTag,
        bumpEpoch: true,
      });
      const restartedStatus = await existing.status();
      return {
        ok: true,
        id: existing.id,
        state: normalizeWorkflowState(restartedStatus),
        status: restartedStatus,
        releaseTag: source.releaseTag,
        created: false,
        restarted: true,
      };
    }

    await recordActiveSyncPointer(env, {
      instanceId: existing.id,
      instance: existing,
      manifestSha256: source.manifestSha256,
      releaseTag: source.releaseTag,
    });
    return {
      ok: true,
      id: existing.id,
      state,
      status,
      releaseTag: source.releaseTag,
      created: false,
      restarted: false,
      reused: true,
    };
  }
}

export async function reconcileSync(env, params = {}) {
  assertWorkflowBinding(env);
  const force = Boolean(params.force);
  const source = await discoverSourceManifest(env, params.releaseTag || "");
  const s3 = createS3Client(env);
  const plan = buildObjectPlan(source.manifest, source.releaseTag, {
    manifestText: source.manifestText,
    manifestSha256: source.manifestSha256,
    secondaryPrefix: env.SECONDARY_S3_PREFIX || "",
    publicBaseUrl: env.PUBLIC_BASE_URL || "",
  });

  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env.SECONDARY_S3_PREFIX || "");
  let secondaryManifest = null;
  let manifestReadError = null;
  let manifestInvalidUtf8 = false;
  try {
    secondaryManifest = await s3.getObjectText(manifestAliasKey);
  } catch (error) {
    if (error?.code === "ERR_INVALID_UTF8") {
      manifestInvalidUtf8 = true;
    } else if (!isS3NotFoundError(error)) {
      manifestReadError = error;
      console.error(
        JSON.stringify({
          event: "secondary_manifest_read_failed",
          error: error.message,
        }),
      );
    }
  }

  // Do not mistake a transient S3 403/5xx read error for a manifest mismatch unless forced.
  if (manifestReadError && !force) {
    throw manifestReadError;
  }

  if (secondaryManifest === source.manifestText && !force) {
    if (await secondaryAliasesMatchPlan(env, s3, plan, source.manifestSha256, manifestAliasKey)) {
      return {
        ok: true,
        skipped: true,
        reason: "secondary manifest and referenced aliases match R2 latest/*",
        releaseTag: source.releaseTag,
      };
    }
  }

  const effectiveForce = force || manifestInvalidUtf8;

  // Reuse any active fallback or canonical instance recorded in S3 for the current manifest,
  // or terminate a genuinely older workflow before launching the current manifest sync.
  if (!force) {
    const active = await findActiveRecordedWorkflow(env, null);
    if (active) {
      if (!active.manifestSha256 || active.manifestSha256 === source.manifestSha256) {
        return {
          ok: true,
          id: active.id,
          state: active.state,
          status: active.status,
          releaseTag: source.releaseTag,
          created: false,
          restarted: false,
          reused: true,
        };
      }
      const latestSource = await discoverSourceManifest(env, params.releaseTag || "");
      if (
        latestSource.manifestSha256 === source.manifestSha256 &&
        active.manifestSha256 !== latestSource.manifestSha256
      ) {
        try {
          await active.instance?.terminate?.();
        } catch {
          // Ignore best-effort terminate error.
        }
      }
    }
  }

  const canonicalId = canonicalManifestWorkflowId(source.manifestSha256, source.releaseTag);
  const existing = await getWorkflowIfExists(env, canonicalId);
  if (!existing) {
    try {
      return await startSync(env, {
        releaseTag: source.releaseTag,
        force: effectiveForce,
        instanceId: canonicalId,
        reuseActiveOnForceCollision: !force,
      });
    } catch (err) {
      if (err?.fromPointerWrite || isSupersededError(err)) {
        throw err;
      }
      if (!force) {
        const reused = await reuseActiveOrCanonicalWorkflow(env, source, canonicalId);
        if (reused) {
          return reused;
        }
      }
      if (isTransientWorkflowRpcError(err)) {
        throw err;
      }
      if (!force) {
        return startDeterministicFallbackSync(env, source, effectiveForce);
      }
      return startSync(env, {
        releaseTag: source.releaseTag,
        force: true,
        idSalt: `${source.manifestSha256}-force-${Date.now()}`,
      });
    }
  }

  const status = await existing.status();
  const state = normalizeWorkflowState(status);
  if (isActiveWorkflowState(state)) {
    await recordActiveSyncPointer(env, {
      instanceId: existing.id,
      instance: existing,
      manifestSha256: source.manifestSha256,
      releaseTag: source.releaseTag,
    });
    return {
      ok: true,
      id: existing.id,
      state,
      status,
      releaseTag: source.releaseTag,
      created: false,
      restarted: false,
      reused: true,
    };
  }

  if (force) {
    return startSync(env, {
      releaseTag: source.releaseTag,
      force: true,
      idSalt: `${source.manifestSha256}-force-${Date.now()}`,
    });
  }

  if (effectiveForce) {
    return startDeterministicFallbackSync(env, source, true);
  }

  let restartSucceeded = false;
  try {
    await verifySourceManifestCurrent(env, source.manifestSha256);
    await existing.restart();
    restartSucceeded = true;
    await recordActiveSyncPointer(env, {
      instanceId: existing.id,
      instance: existing,
      manifestSha256: source.manifestSha256,
      releaseTag: source.releaseTag,
      bumpEpoch: true,
    });
    const restartedStatus = await existing.status();
    return {
      ok: true,
      id: existing.id,
      state: normalizeWorkflowState(restartedStatus),
      status: restartedStatus,
      releaseTag: source.releaseTag,
      created: false,
      restarted: true,
    };
  } catch (restartErr) {
    if (restartSucceeded || restartErr?.fromPointerWrite || isSupersededError(restartErr)) {
      throw restartErr;
    }
    const reused = await reuseActiveOrCanonicalWorkflow(env, source, canonicalId);
    if (reused) {
      return reused;
    }
    if (isTransientWorkflowRpcError(restartErr)) {
      throw restartErr;
    }
    return startDeterministicFallbackSync(env, source, false);
  }
}

async function startDeterministicFallbackSync(env, source, effectiveForce) {
  let lastError = null;
  for (let slot = 1; slot <= 8; slot += 1) {
    const slotSalt = effectiveForce
      ? `${source.manifestSha256}-repair-slot-${slot}`
      : `${source.manifestSha256}-fallback-slot-${slot}`;
    const slotId = workflowInstanceId("manifest", slotSalt);
    const existingSlot = await getWorkflowIfExists(env, slotId);
    if (existingSlot) {
      const slotStatus = await existingSlot.status();
      const slotState = normalizeWorkflowState(slotStatus);
      if (isActiveWorkflowState(slotState)) {
        await recordActiveSyncPointer(env, {
          instanceId: existingSlot.id,
          instance: existingSlot,
          manifestSha256: source.manifestSha256,
          releaseTag: source.releaseTag,
        });
        return {
          ok: true,
          id: existingSlot.id,
          state: slotState,
          status: slotStatus,
          releaseTag: source.releaseTag,
          created: false,
          restarted: false,
          reused: true,
        };
      }
      let slotRestartSucceeded = false;
      try {
        await verifySourceManifestCurrent(env, source.manifestSha256);
        await existingSlot.restart();
        slotRestartSucceeded = true;
        await recordActiveSyncPointer(env, {
          instanceId: existingSlot.id,
          instance: existingSlot,
          manifestSha256: source.manifestSha256,
          releaseTag: source.releaseTag,
          bumpEpoch: true,
        });
        const restartedSlotStatus = await existingSlot.status();
        return {
          ok: true,
          id: existingSlot.id,
          state: normalizeWorkflowState(restartedSlotStatus),
          status: restartedSlotStatus,
          releaseTag: source.releaseTag,
          created: false,
          restarted: true,
        };
      } catch (slotRestartErr) {
        if (
          slotRestartSucceeded ||
          slotRestartErr?.fromPointerWrite ||
          isSupersededError(slotRestartErr) ||
          isTransientWorkflowRpcError(slotRestartErr)
        ) {
          throw slotRestartErr;
        }
        const reusedAfterRestart = await reuseActiveOrCanonicalWorkflow(env, source, slotId);
        if (reusedAfterRestart) {
          return reusedAfterRestart;
        }
        lastError = slotRestartErr;
        continue;
      }
    }
    try {
      return await startSync(env, {
        releaseTag: source.releaseTag,
        force: effectiveForce,
        instanceId: slotId,
        reuseActiveOnForceCollision: true,
      });
    } catch (slotErr) {
      if (slotErr?.fromPointerWrite || isSupersededError(slotErr) || isTransientWorkflowRpcError(slotErr)) {
        throw slotErr;
      }
      const reusedSlot = await reuseActiveOrCanonicalWorkflow(env, source, slotId);
      if (reusedSlot) {
        return reusedSlot;
      }
      lastError = slotErr;
    }
  }
  const activeRecorded = await findActiveRecordedWorkflow(env, source.manifestSha256);
  if (activeRecorded && (!activeRecorded.manifestSha256 || activeRecorded.manifestSha256 === source.manifestSha256)) {
    return {
      ok: true,
      id: activeRecorded.id,
      state: activeRecorded.state,
      status: activeRecorded.status,
      releaseTag: source.releaseTag,
      created: false,
      restarted: false,
      reused: true,
    };
  }
  const minuteBucket = Math.floor(Date.now() / 60000);
  for (const bucket of [minuteBucket - 1, minuteBucket]) {
    const bucketSalt = effectiveForce
      ? `${source.manifestSha256}-repair-win-${bucket}`
      : `${source.manifestSha256}-fallback-win-${bucket}`;
    const bucketId = workflowInstanceId("manifest", bucketSalt);
    const existingBucket = await getWorkflowIfExists(env, bucketId);
    if (existingBucket) {
      const bucketStatus = await existingBucket.status();
      const bucketState = normalizeWorkflowState(bucketStatus);
      if (isActiveWorkflowState(bucketState)) {
        await recordActiveSyncPointer(env, {
          instanceId: existingBucket.id,
          instance: existingBucket,
          manifestSha256: source.manifestSha256,
          releaseTag: source.releaseTag,
        });
        return {
          ok: true,
          id: existingBucket.id,
          state: bucketState,
          status: bucketStatus,
          releaseTag: source.releaseTag,
          created: false,
          restarted: false,
          reused: true,
        };
      }
      continue;
    }
    if (bucket === minuteBucket) {
      return startSync(env, {
        releaseTag: source.releaseTag,
        force: effectiveForce,
        instanceId: bucketId,
        reuseActiveOnForceCollision: true,
      });
    }
  }
  throw lastError || new Error(`Exhausted fallback workflow slots for ${source.releaseTag}.`);
}

function isTransientWorkflowRpcError(error) {
  const status = Number(error?.status || error?.statusCode || 0);
  if (status >= 500 || status === 429 || status === 408) {
    return true;
  }
  const msg = String(error?.message || error || "");
  return (
    /\b(?:HTTP\s+)?5\d\d\b/i.test(msg) ||
    /\b(?:timeout|timed\s*out|unavailable|internal\s+error|bad\s+gateway|rate\s*limit|too\s+many\s+requests)\b/i.test(
      msg,
    )
  );
}

async function reuseActiveOrCanonicalWorkflow(env, source, canonicalId) {
  const activeNow = await findActiveRecordedWorkflow(env, source.manifestSha256);
  if (activeNow && (!activeNow.manifestSha256 || activeNow.manifestSha256 === source.manifestSha256)) {
    return {
      ok: true,
      id: activeNow.id,
      state: activeNow.state,
      status: activeNow.status,
      releaseTag: source.releaseTag,
      created: false,
      restarted: false,
      reused: true,
    };
  }
  const checkExisting = await getWorkflowIfExists(env, canonicalId);
  if (checkExisting) {
    const checkStatus = await checkExisting.status();
    const checkState = normalizeWorkflowState(checkStatus);
    if (isActiveWorkflowState(checkState)) {
      await recordActiveSyncPointer(env, {
        instanceId: checkExisting.id,
        instance: checkExisting,
        manifestSha256: source.manifestSha256,
        releaseTag: source.releaseTag,
      });
      return {
        ok: true,
        id: checkExisting.id,
        state: checkState,
        status: checkStatus,
        releaseTag: source.releaseTag,
        created: false,
        restarted: false,
        reused: true,
      };
    }
  }
  return null;
}

function itemChecksumCandidateNames(item) {
  const names = [];
  if (Array.isArray(item?.checksumNames)) {
    for (const n of item.checksumNames) {
      if (n && !names.includes(n)) {
        names.push(n);
      }
    }
  }
  if (item?.filename && !names.includes(item.filename)) {
    names.push(item.filename);
  }
  return names;
}

function resolveItemChecksumFromMap(checksumMap, item) {
  let resolved = "";
  for (const name of itemChecksumCandidateNames(item)) {
    if (!checksumMap.has(name)) {
      continue;
    }
    const val = String(checksumMap.get(name) || "").toLowerCase();
    if (!val) {
      continue;
    }
    if (resolved && resolved !== val) {
      return { digest: "", conflict: true };
    }
    resolved = val;
  }
  return { digest: resolved, conflict: false };
}

async function secondaryAliasesMatchPlan(
  env,
  s3,
  plan,
  expectedManifestSha256 = "",
  manifestAliasKey = "",
) {
  const checksumMap = new Map();
  const checksumsItem = plan.items.find((item) => item.role === "checksums");
  if (checksumsItem) {
    for (const aliasKey of checksumsItem.aliasKeys) {
      try {
        const checksumsText = await s3.getObjectText(aliasKey);
        const parsed = parseChecksumsMap(checksumsText);
        if (!parsed) {
          return false;
        }
        const requiredChecksums = {
          ...(checksumsItem.expectedChecksums || {}),
          ...(expectedManifestSha256
            ? { "release-manifest.json": expectedManifestSha256.toLowerCase() }
            : {}),
        };
        if (!checksumsMatchesExpected(checksumsText, requiredChecksums)) {
          return false;
        }
        if (env?.GLOBAL_R2) {
          const r2ChecksumsObj = await env.GLOBAL_R2.get(checksumsItem.sourceKey);
          if (r2ChecksumsObj) {
            const r2ChecksumsText = await readR2ObjectStrictText(r2ChecksumsObj);
            if (
              checksumsMatchesExpected(r2ChecksumsText, requiredChecksums) &&
              checksumsText !== r2ChecksumsText
            ) {
              return false;
            }
          }
        }
        for (const [k, v] of parsed.entries()) {
          checksumMap.set(k, v);
        }
      } catch {
        return false;
      }
    }
  }

  const singlePutMaxBytes = parseBytes(
    env?.SECONDARY_SYNC_SINGLE_PUT_MAX_BYTES,
    DEFAULT_SINGLE_PUT_MAX_BYTES,
    0,
  );
  const pendingDigestStreams = [];

  for (const item of plan.items) {
    const mapLookup = resolveItemChecksumFromMap(checksumMap, item);
    if (mapLookup.conflict) {
      return false;
    }
    const expectedDigest = (item.expectedSha256 || mapLookup.digest || "").toLowerCase();
    if (
      item.expectedSha256 &&
      mapLookup.digest &&
      mapLookup.digest !== item.expectedSha256.toLowerCase()
    ) {
      return false;
    }

    for (const aliasKey of item.aliasKeys) {
      const head = await s3.headObject(aliasKey);
      if (!head) {
        return false;
      }
      if (item.expectedSize !== undefined && head.contentLength !== item.expectedSize) {
        return false;
      }
      if (
        !head.fromListFallback &&
        head.syncSha256 &&
        head.bodySha256 &&
        head.syncSha256 !== head.bodySha256
      ) {
        return false;
      }
      if (head.syncSha256 && expectedDigest && head.syncSha256 !== expectedDigest) {
        return false;
      }
      if (head.bodySha256 && expectedDigest && head.bodySha256 !== expectedDigest) {
        return false;
      }
      const effectiveByteLength = item.expectedSize ?? head.contentLength;
      const expectsSyncStamp =
        Boolean(expectedDigest) ||
        item.inlineText !== undefined ||
        item.role === "checksums" ||
        item.role === "appcast" ||
        item.role === "manifest" ||
        (Number.isFinite(effectiveByteLength) && effectiveByteLength <= singlePutMaxBytes);
      if (expectsSyncStamp && !head.fromListFallback && !head.syncSha256) {
        return false;
      }
      if (expectedDigest && (head.fromListFallback || !head.syncSha256) && !head.bodySha256) {
        pendingDigestStreams.push({
          aliasKey,
          expectedSize: item.expectedSize,
          expectedDigest,
        });
      }
      if (item.role === "appcast" && item.expectedAppcast) {
        try {
          const appcastText = await s3.getObjectText(aliasKey);
          if (!appcastMatchesExpected(appcastText, item.expectedAppcast)) {
            return false;
          }
          if (env?.GLOBAL_R2) {
            const r2AppcastObj = await env.GLOBAL_R2.get(item.sourceKey);
            if (r2AppcastObj) {
              const r2AppcastText = await readR2ObjectStrictText(r2AppcastObj);
              if (
                appcastMatchesExpected(r2AppcastText, item.expectedAppcast) &&
                appcastText !== r2AppcastText
              ) {
                return false;
              }
            }
          }
        } catch {
          return false;
        }
      }
    }
  }
  for (const staleKey of plan.staleAliasKeys || []) {
    const staleHead = await s3.headObject(staleKey);
    if (staleHead) {
      return false;
    }
  }
  for (const pending of pendingDigestStreams) {
    try {
      const streamed = await s3.streamObjectDigest(pending.aliasKey);
      if (
        (pending.expectedSize !== undefined && streamed.byteLength !== pending.expectedSize) ||
        streamed.sha256 !== pending.expectedDigest
      ) {
        return false;
      }
    } catch {
      return false;
    }
  }
  return true;
}

function effectiveStageRoot(env = {}) {
  const baseStage = cleanPrefix(env.SECONDARY_SYNC_STAGE_PREFIX || DEFAULT_STAGE_PREFIX);
  return withSecondaryPrefix(baseStage, env.SECONDARY_S3_PREFIX || "");
}

function activeSyncPointerKey(env = {}) {
  return `${effectiveStageRoot(env)}/${ACTIVE_SYNC_POINTER_NAME}`;
}

function committedStateLedgerKey(env = {}) {
  return `${effectiveStageRoot(env)}/${COMMITTED_STATE_LEDGER_NAME}`;
}

async function findActiveRecordedWorkflow(env, expectedManifestSha256 = null) {
  if (!hasS3Env(env) || !env?.SECONDARY_MIRROR_WORKFLOW) {
    return null;
  }
  const s3 = createS3Client(env);
  let raw;
  try {
    raw = await s3.getObjectText(activeSyncPointerKey(env));
  } catch (error) {
    if (error?.code === "ERR_INVALID_UTF8" || isS3NotFoundError(error)) {
      return null;
    }
    throw error;
  }
  let parsed;
  try {
    parsed = parseJsonAllowingBom(raw);
  } catch {
    return null;
  }
  if (!parsed?.instanceId) {
    return null;
  }
  if (expectedManifestSha256 && parsed.manifestSha256 && parsed.manifestSha256 !== expectedManifestSha256) {
    return null;
  }
  const inst = await getWorkflowIfExists(env, parsed.instanceId);
  if (!inst) {
    return null;
  }
  let status;
  try {
    status = await inst.status();
  } catch (statusError) {
    if (isWorkflowNotFoundError(statusError)) {
      return null;
    }
    throw statusError;
  }
  const state = normalizeWorkflowState(status);
  if (!isActiveWorkflowState(state)) {
    return null;
  }
  return {
    id: inst.id,
    instance: inst,
    manifestSha256: parsed.manifestSha256 || "",
    state,
    status,
  };
}

let localSyncEpochFloor = 0;
let localLatestPointerClaim = {
  epoch: 0,
  runEpoch: 0,
  instanceId: "",
  manifestSha256: "",
  releaseTag: "",
};
const localLastBumpByInstance = new Map();

async function readCommittedEpochLedger(env, s3) {
  if (!hasS3Env(env)) {
    return null;
  }
  try {
    const raw = await s3.getObjectText(committedStateLedgerKey(env));
    return parseJsonAllowingBom(raw);
  } catch (err) {
    if (isS3NotFoundError(err) || err?.code === "ERR_INVALID_UTF8") {
      return null;
    }
    throw err;
  }
}

async function advanceCommittedEpochLedger(env, s3, targetEpoch, meta = {}) {
  const cleanEpoch = Number.isSafeInteger(targetEpoch) && targetEpoch > 0 ? targetEpoch : 0;
  if (!hasS3Env(env) || cleanEpoch <= 0) {
    return null;
  }
  if (cleanEpoch > localSyncEpochFloor) {
    localSyncEpochFloor = cleanEpoch;
  }
  const ledgerKey = committedStateLedgerKey(env);
  for (let round = 0; round < 3; round += 1) {
    const curDoc = await readCommittedEpochLedger(env, s3);
    const curEpoch = Number.isSafeInteger(curDoc?.committedEpoch) ? curDoc.committedEpoch : 0;
    if (curEpoch > cleanEpoch) {
      if (curEpoch > localSyncEpochFloor) {
        localSyncEpochFloor = curEpoch;
      }
      return curDoc;
    }
    if (
      curEpoch === cleanEpoch &&
      (!meta.manifestSha256 || curDoc?.manifestSha256 === meta.manifestSha256)
    ) {
      return curDoc;
    }
    let alreadyAdvancedDoc = null;
    const payload = {
      committedEpoch: cleanEpoch,
      manifestSha256: meta.manifestSha256 || curDoc?.manifestSha256 || "",
      releaseTag: meta.releaseTag || curDoc?.releaseTag || "",
      instanceId: meta.instanceId || curDoc?.instanceId || "",
      updatedAt: new Date().toISOString(),
    };
    try {
      await s3.putObject(ledgerKey, utf8(JSON.stringify(payload)), {
        filename: COMMITTED_STATE_LEDGER_NAME,
        contentType: "application/json",
        cacheControl: "no-store",
        beforeAttempt: async () => {
          const latestDoc = await readCommittedEpochLedger(env, s3);
          const latestEpoch = Number.isSafeInteger(latestDoc?.committedEpoch)
            ? latestDoc.committedEpoch
            : 0;
          if (latestEpoch > cleanEpoch) {
            alreadyAdvancedDoc = latestDoc;
            const sentinel = new SupersededMirrorError("Committed epoch ledger already advanced.");
            sentinel.ledgerAdvanced = true;
            throw sentinel;
          }
        },
      });
    } catch (err) {
      if (err?.ledgerAdvanced && alreadyAdvancedDoc) {
        return alreadyAdvancedDoc;
      }
      throw err;
    }
    const verifyDoc = await readCommittedEpochLedger(env, s3);
    const verifyEpoch = Number.isSafeInteger(verifyDoc?.committedEpoch)
      ? verifyDoc.committedEpoch
      : 0;
    if (verifyEpoch >= cleanEpoch) {
      return verifyDoc;
    }
  }
  return readCommittedEpochLedger(env, s3);
}

async function scanMaxRecordedEpoch(env, s3) {
  let maxEpoch = 0;
  const ledgerDoc = await readCommittedEpochLedger(env, s3);
  if (Number.isSafeInteger(ledgerDoc?.committedEpoch) && ledgerDoc.committedEpoch > maxEpoch) {
    maxEpoch = ledgerDoc.committedEpoch;
  }
  const stageRoot = `${effectiveStageRoot(env)}/`;
  if (!stageRoot || stageRoot === "/") {
    return maxEpoch;
  }
  const objects = await s3.listObjects(stageRoot);
  for (const obj of objects) {
    if (!obj?.key || !obj.key.includes("/backups/")) {
      continue;
    }
    if (
      obj.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) ||
      obj.key.endsWith(".state.json") ||
      obj.key.endsWith(".seal.json")
    ) {
      const doc = await readJsonStateOrNull(s3, obj.key);
      const ep = Math.max(
        Number.isSafeInteger(doc?.committedEpoch) ? doc.committedEpoch : 0,
        Number.isSafeInteger(doc?.ownerEpoch) ? doc.ownerEpoch : 0,
      );
      if (ep > maxEpoch) {
        maxEpoch = ep;
      }
    }
  }
  return maxEpoch;
}

async function recordActiveSyncPointer(env, record) {
  if (!hasS3Env(env) || !record?.instanceId) {
    return { epoch: 0 };
  }
  if (record.manifestSha256) {
    await verifySourceManifestCurrent(env, record.manifestSha256);
  }
  const s3 = createS3Client(env);
  const pointerKey = activeSyncPointerKey(env);
  let existingParsed = null;
  let ledgerEpoch = 0;
  try {
    const ledgerDoc = await readCommittedEpochLedger(env, s3);
    if (Number.isSafeInteger(ledgerDoc?.committedEpoch) && ledgerDoc.committedEpoch > 0) {
      ledgerEpoch = ledgerDoc.committedEpoch;
    }
    const existingRaw = await s3.getObjectText(pointerKey);
    existingParsed = parseJsonAllowingBom(existingRaw);
    if (
      record.manifestSha256 &&
      existingParsed?.manifestSha256 &&
      existingParsed.manifestSha256 !== record.manifestSha256
    ) {
      await verifySourceManifestCurrent(env, record.manifestSha256);
    }
  } catch (error) {
    if (isSupersededError(error)) {
      throw error;
    }
    if (!isS3NotFoundError(error)) {
      error.fromPointerWrite = true;
      throw error;
    }
  }
  const isSamePointerIdentity = (doc) =>
    Boolean(
      doc?.instanceId === record.instanceId &&
        (!record.manifestSha256 ||
          !doc?.manifestSha256 ||
          String(doc.manifestSha256).toLowerCase() === String(record.manifestSha256).toLowerCase()),
    );
  const existingEpoch =
    Number.isSafeInteger(existingParsed?.epoch) && existingParsed.epoch > 0
      ? existingParsed.epoch
      : 0;
  let epoch = 0;
  let runEpoch = 0;
  if (
    !record.bumpEpoch &&
    isSamePointerIdentity(existingParsed) &&
    existingEpoch > 0 &&
    existingEpoch >= ledgerEpoch
  ) {
    epoch = existingEpoch;
    runEpoch = Number.isSafeInteger(existingParsed?.runEpoch) ? existingParsed.runEpoch : 0;
    if (epoch > localSyncEpochFloor) {
      localSyncEpochFloor = epoch;
    }
  } else if (
    !record.bumpEpoch &&
    existingEpoch === 0 &&
    isSamePointerIdentity(localLatestPointerClaim) &&
    localLatestPointerClaim.epoch > 0 &&
    localLatestPointerClaim.epoch >= ledgerEpoch
  ) {
    epoch = localLatestPointerClaim.epoch;
    runEpoch = localLatestPointerClaim.runEpoch || 0;
  } else {
    let recoveredFloor = Math.max(existingEpoch, ledgerEpoch);
    if (recoveredFloor === 0) {
      try {
        recoveredFloor = await scanMaxRecordedEpoch(env, s3);
      } catch (scanErr) {
        scanErr.fromPointerWrite = true;
        throw scanErr;
      }
    }
    epoch = Math.max(Date.now() * 256, localSyncEpochFloor + 1, recoveredFloor + 1);
    runEpoch = record.bumpEpoch
      ? epoch
      : (isSamePointerIdentity(existingParsed) && Number.isSafeInteger(existingParsed?.runEpoch)
          ? existingParsed.runEpoch
          : 0) ||
        localLastBumpByInstance.get(record.instanceId) ||
        0;
    if (record.bumpEpoch) {
      localLastBumpByInstance.set(record.instanceId, epoch);
    }
    localSyncEpochFloor = epoch;
    localLatestPointerClaim = {
      epoch,
      runEpoch,
      instanceId: record.instanceId,
      manifestSha256: record.manifestSha256 || "",
      releaseTag: record.releaseTag || "",
    };
  }

  const canCoalesceWithNewerSameOwner = (doc) => {
    if (!isSamePointerIdentity(doc)) {
      return false;
    }
    const latestLocalBump = localLastBumpByInstance.get(record.instanceId) || 0;
    if (latestLocalBump > epoch) {
      return false;
    }
    const docRunEpoch = Number.isSafeInteger(doc?.runEpoch) ? doc.runEpoch : 0;
    if (docRunEpoch > epoch) {
      return false;
    }
    return true;
  };

  for (let round = 0; round < 3; round += 1) {
    if (
      localLatestPointerClaim.epoch > epoch &&
      canCoalesceWithNewerSameOwner(localLatestPointerClaim)
    ) {
      epoch = localLatestPointerClaim.epoch;
    }
    let sameOwnerConfirmedEpoch = 0;
    const body = utf8(
      JSON.stringify({
        instanceId: record.instanceId,
        manifestSha256: record.manifestSha256 || "",
        releaseTag: record.releaseTag || "",
        epoch,
        ...(runEpoch > 0 ? { runEpoch } : {}),
        updatedAt: new Date().toISOString(),
      }),
    );
    try {
      await s3.putObject(pointerKey, body, {
        filename: ACTIVE_SYNC_POINTER_NAME,
        contentType: "application/json",
        cacheControl: "no-store",
        beforeAttempt: async () => {
          if (localLatestPointerClaim.epoch > epoch) {
            if (canCoalesceWithNewerSameOwner(localLatestPointerClaim)) {
              const upgrade = new SupersededMirrorError("Same owner upgraded epoch.");
              upgrade.upgradeSameOwnerEpoch = localLatestPointerClaim.epoch;
              throw upgrade;
            }
            throw new SupersededMirrorError(
              `Sync pointer claim for ${record.instanceId} (epoch ${epoch}) superseded by newer local claim ${localLatestPointerClaim.instanceId || "unknown"} (epoch ${localLatestPointerClaim.epoch}).`,
            );
          }
          if (localSyncEpochFloor > epoch) {
            throw new SupersededMirrorError(
              `Sync pointer claim for ${record.instanceId} (epoch ${epoch}) superseded by newer local epoch ${localSyncEpochFloor}.`,
            );
          }
          if (record.manifestSha256) {
            await verifySourceManifestCurrent(env, record.manifestSha256);
          }
          let curDoc = null;
          try {
            curDoc = parseJsonAllowingBom(await s3.getObjectText(pointerKey));
          } catch (readErr) {
            if (!isS3NotFoundError(readErr) && readErr?.code !== "ERR_INVALID_UTF8") {
              throw readErr;
            }
          }
          const curEpoch = Number.isSafeInteger(curDoc?.epoch) ? curDoc.epoch : 0;
          if (curEpoch > epoch) {
            if (curEpoch > localSyncEpochFloor) {
              localSyncEpochFloor = curEpoch;
            }
            if (curEpoch > localLatestPointerClaim.epoch && curDoc?.instanceId) {
              localLatestPointerClaim = {
                epoch: curEpoch,
                runEpoch: Number.isSafeInteger(curDoc?.runEpoch) ? curDoc.runEpoch : 0,
                instanceId: curDoc.instanceId,
                manifestSha256: curDoc.manifestSha256 || "",
                releaseTag: curDoc.releaseTag || "",
              };
            }
            if (canCoalesceWithNewerSameOwner(curDoc)) {
              sameOwnerConfirmedEpoch = curEpoch;
              const done = new SupersededMirrorError("Same owner already recorded newer epoch.");
              done.sameOwnerDone = true;
              throw done;
            }
            throw new SupersededMirrorError(
              `Sync pointer claim for ${record.instanceId} (epoch ${epoch}) superseded by newer S3 owner ${curDoc?.instanceId || "unknown"} (epoch ${curEpoch}).`,
            );
          }
        },
      });
    } catch (putError) {
      if (putError?.sameOwnerDone && sameOwnerConfirmedEpoch > 0) {
        return { epoch: sameOwnerConfirmedEpoch };
      }
      if (putError?.upgradeSameOwnerEpoch > epoch) {
        epoch = putError.upgradeSameOwnerEpoch;
        continue;
      }
      if (!isSupersededError(putError)) {
        putError.fromPointerWrite = true;
      }
      throw putError;
    }
    let afterDoc = null;
    try {
      afterDoc = parseJsonAllowingBom(await s3.getObjectText(pointerKey));
    } catch (afterErr) {
      if (isSupersededError(afterErr)) {
        throw afterErr;
      }
      afterErr.fromPointerWrite = true;
      throw afterErr;
    }
    const afterEpoch = Number.isSafeInteger(afterDoc?.epoch) ? afterDoc.epoch : 0;
    if (afterEpoch > epoch) {
      if (afterEpoch > localSyncEpochFloor) {
        localSyncEpochFloor = afterEpoch;
      }
      if (afterEpoch > localLatestPointerClaim.epoch && afterDoc?.instanceId) {
        localLatestPointerClaim = {
          epoch: afterEpoch,
          runEpoch: Number.isSafeInteger(afterDoc?.runEpoch) ? afterDoc.runEpoch : 0,
          instanceId: afterDoc.instanceId,
          manifestSha256: afterDoc.manifestSha256 || "",
          releaseTag: afterDoc.releaseTag || "",
        };
      }
      if (canCoalesceWithNewerSameOwner(afterDoc)) {
        return { epoch: afterEpoch };
      }
      throw new SupersededMirrorError(
        `Sync pointer claim for ${record.instanceId} (epoch ${epoch}) overwritten by newer owner ${afterDoc?.instanceId || "unknown"} (epoch ${afterEpoch}).`,
      );
    }
    if (localLatestPointerClaim.epoch > afterEpoch) {
      if (canCoalesceWithNewerSameOwner(localLatestPointerClaim)) {
        epoch = localLatestPointerClaim.epoch;
        continue;
      }
      if (localLatestPointerClaim.instanceId) {
        try {
          await s3.putObject(
            pointerKey,
            utf8(
              JSON.stringify({
                instanceId: localLatestPointerClaim.instanceId,
                manifestSha256: localLatestPointerClaim.manifestSha256 || "",
                releaseTag: localLatestPointerClaim.releaseTag || "",
                epoch: localLatestPointerClaim.epoch,
                ...(localLatestPointerClaim.runEpoch > 0
                  ? { runEpoch: localLatestPointerClaim.runEpoch }
                  : {}),
                updatedAt: new Date().toISOString(),
              }),
            ),
            {
              filename: ACTIVE_SYNC_POINTER_NAME,
              contentType: "application/json",
              cacheControl: "no-store",
            },
          );
        } catch {
          // Newer owner will also re-verify or re-heal pointer.
        }
      }
      throw new SupersededMirrorError(
        `Sync pointer claim for ${record.instanceId} (epoch ${epoch}) superseded by newer local claim ${localLatestPointerClaim.instanceId || "unknown"} (epoch ${localLatestPointerClaim.epoch}).`,
      );
    }
    if (afterDoc?.instanceId === record.instanceId && afterEpoch === epoch) {
      return { epoch };
    }
  }
  return { epoch };
}

function hasS3Env(env) {
  return Boolean(
    env?.SECONDARY_S3_ENDPOINT &&
      env?.SECONDARY_S3_BUCKET &&
      env?.SECONDARY_S3_ACCESS_KEY_ID &&
      env?.SECONDARY_S3_SECRET_ACCESS_KEY,
  );
}

function canonicalManifestWorkflowId(manifestSha256, fallbackTag = "") {
  return workflowInstanceId("manifest", manifestSha256 || fallbackTag);
}

export async function workflowStatus(env, id) {
  assertWorkflowBinding(env);
  const instance = await getWorkflowIfExists(env, id);
  if (!instance) {
    return { ok: false, error: `Workflow instance not found: ${id}` };
  }
  const status = await instance.status();
  return {
    ok: true,
    id: instance.id,
    state: normalizeWorkflowState(status),
    terminal: isTerminalWorkflowState(normalizeWorkflowState(status)),
    status,
  };
}

export async function discoverSourceManifest(
  env,
  releaseTagOverride = "",
  expectedManifestSha256 = "",
  options = {},
) {
  assertR2Binding(env);
  const manifestObject = await env.GLOBAL_R2.get("latest/manifest");
  if (!manifestObject) {
    throw new NonRetryableMirrorError("R2 latest/manifest is missing.");
  }
  const { text: manifestText, sha256: manifestSha256 } = await readR2ObjectStrictBytesAndText(
    manifestObject,
    "R2 latest/manifest",
  );
  if (expectedManifestSha256 && manifestSha256 !== expectedManifestSha256.toLowerCase()) {
    throw new SupersededMirrorError(
      `R2 latest/manifest changed before workflow started (expected ${expectedManifestSha256}, got ${manifestSha256}).`,
    );
  }
  const manifest = parseJsonAllowingBom(manifestText);
  const releaseTag = releaseTagOverride || deriveReleaseTag(manifest);
  if (!releaseTag) {
    throw new NonRetryableMirrorError("Could not derive release tag from manifest.");
  }
  if (options.claimPointer && options.instanceId && hasS3Env(env)) {
    const active = await findActiveRecordedWorkflow(env, null);
    await verifySourceManifestCurrent(env, manifestSha256);
    if (active && active.id !== options.instanceId) {
      if (!active.manifestSha256 || active.manifestSha256 === manifestSha256) {
        throw new SupersededMirrorError(
          `Workflow ${options.instanceId} superseded by active owner ${active.id} (${active.manifestSha256}).`,
        );
      }
      await verifySourceManifestCurrent(env, manifestSha256);
      try {
        await active.instance?.terminate?.();
      } catch {
        // Best-effort termination of stale older-manifest workflow.
      }
    }
    await recordActiveSyncPointer(env, {
      instanceId: options.instanceId,
      manifestSha256,
      releaseTag,
    });
  }
  return {
    releaseTag,
    manifest,
    manifestText,
    manifestSha256,
    manifestEtag: r2ObjectEtag(manifestObject),
  };
}

export async function verifySourceManifestCurrent(env, expectedManifestSha256, options = {}) {
  if (!expectedManifestSha256 && !options.instanceId) {
    return { currentSha256: "", ownerEpoch: 0 };
  }
  let currentSha256 = "";
  let ownerEpoch = 0;
  if (expectedManifestSha256) {
    assertR2Binding(env);
    const current = await env.GLOBAL_R2.get("latest/manifest");
    if (!current) {
      throw new NonRetryableMirrorError("R2 latest/manifest disappeared before commit.");
    }
    const { sha256: strictCurrentSha } = await readR2ObjectStrictBytesAndText(
      current,
      "R2 latest/manifest",
    );
    currentSha256 = strictCurrentSha;
    if (currentSha256 !== expectedManifestSha256.toLowerCase()) {
      throw new SupersededMirrorError(
        `R2 latest/manifest advanced during sync (expected ${expectedManifestSha256}, got ${currentSha256}); aborting stale commit.`,
      );
    }
  }
  if (options.instanceId && hasS3Env(env)) {
    const s3 = options.s3 || createS3Client(env);
    try {
      const raw = await s3.getObjectText(activeSyncPointerKey(env));
      const parsed = parseJsonAllowingBom(raw);
      const pointerSha = String(parsed?.manifestSha256 || "").toLowerCase();
      if (currentSha256 && pointerSha && pointerSha !== currentSha256) {
        // Stale pointer from an older manifest cannot fence out the workflow owning current R2 manifest; heal pointer.
        const healed = await recordActiveSyncPointer(env, {
          instanceId: options.instanceId,
          manifestSha256: currentSha256,
        });
        return { currentSha256, ownerEpoch: healed?.epoch || 0 };
      }
      if (parsed?.instanceId && parsed.instanceId !== options.instanceId) {
        throw new SupersededMirrorError(
          `Workflow ${options.instanceId} was superseded by active sync ${parsed.instanceId} (${parsed.manifestSha256}).`,
        );
      }
      if (Number.isSafeInteger(parsed?.epoch) && parsed.epoch > 0) {
        ownerEpoch = parsed.epoch;
      }
    } catch (error) {
      if (error instanceof SupersededMirrorError) {
        throw error;
      }
      if (isS3NotFoundError(error)) {
        if (options.requirePointer) {
          throw new SupersededMirrorError(
            `Active sync pointer is missing for workflow ${options.instanceId}; refusing unowned commit.`,
          );
        }
        return { currentSha256, ownerEpoch: 0 };
      }
      throw error;
    }
  }
  return { currentSha256, ownerEpoch };
}

function normalizePublicBaseUrl(rawUrl) {
  const trimmed = String(rawUrl || "").trim().replace(/\/+$/, "").replace(/\/latest$/, "");
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new NonRetryableMirrorError(`Invalid PUBLIC_BASE_URL: ${JSON.stringify(rawUrl)}.`);
  }
  if (
    (parsed.protocol !== "https:" && parsed.protocol !== "http:") ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash
  ) {
    throw new NonRetryableMirrorError(`Invalid PUBLIC_BASE_URL: ${JSON.stringify(rawUrl)}.`);
  }
  const basePath = parsed.pathname.replace(/\/+$/, "");
  return `${parsed.origin}${basePath}`;
}

export function buildObjectPlan(manifest, releaseTag, options = {}) {
  const windows = manifest?.sources?.windows || {};
  const macos = manifest?.sources?.macos || {};
  const latestChecksums = manifest?.derived?.latestChecksums || {};
  const secondaryPrefix = options.secondaryPrefix || "";
  const publicBaseUrl = normalizePublicBaseUrl(options.publicBaseUrl || DEFAULT_PUBLIC_BASE_URL);
  const items = [];
  const staleAliasKeys = [];

  const winX64Moniker = windows.architectures?.x64?.packageMoniker || windows.packageMoniker || "";
  addItem(items, {
    id: "win-x64",
    sourceKey: "latest/win-x64",
    stageRelativeKey: "win-x64",
    aliasKeys: [
      withSecondaryPrefix("latest/win-x64", secondaryPrefix),
      withSecondaryPrefix("latest/win", secondaryPrefix),
    ],
    filename: "Codex-Windows-x64.msix",
    checksumNames: [
      ...(winX64Moniker ? [`${winX64Moniker}.Msix`] : []),
      "Codex-Windows-x64.msix",
    ],
    contentType: "application/vnd.ms-appx",
    role: "installer",
    required: true,
    expectedSize: optionalPositiveInt(
      windows.architectures?.x64?.contentLength ?? windows.contentLength,
    ),
    expectedSha256: optionalSha256(
      (winX64Moniker && latestChecksums[`${winX64Moniker}.Msix`]) ||
        latestChecksums["Codex-Windows-x64.msix"],
    ),
  });

  if (windows.architectures?.arm64?.downloadable === true) {
    const winArm64Moniker = windows.architectures?.arm64?.packageMoniker || "";
    addItem(items, {
      id: "win-arm64",
      sourceKey: "latest/win-arm64",
      stageRelativeKey: "win-arm64",
      aliasKeys: [withSecondaryPrefix("latest/win-arm64", secondaryPrefix)],
      filename: "Codex-Windows-arm64.msix",
      checksumNames: [
        ...(winArm64Moniker ? [`${winArm64Moniker}.Msix`] : []),
        "Codex-Windows-arm64.msix",
      ],
      contentType: "application/vnd.ms-appx",
      role: "installer",
      required: true,
      expectedSize: optionalPositiveInt(windows.architectures?.arm64?.contentLength),
      expectedSha256: optionalSha256(
        (winArm64Moniker && latestChecksums[`${winArm64Moniker}.Msix`]) ||
          latestChecksums["Codex-Windows-arm64.msix"],
      ),
    });
  } else {
    staleAliasKeys.push(withSecondaryPrefix("latest/win-arm64", secondaryPrefix));
  }

  addItem(items, {
    id: "mac-arm64",
    sourceKey: "latest/mac-arm64",
    stageRelativeKey: "mac-arm64",
    aliasKeys: [withSecondaryPrefix("latest/mac-arm64", secondaryPrefix)],
    filename: "Codex-mac-arm64.dmg",
    contentType: "application/x-apple-diskimage",
    role: "installer",
    required: true,
    expectedSize: optionalPositiveInt(macos.arm64?.contentLength),
    expectedSha256: optionalSha256(macos.arm64?.sha256 || latestChecksums["Codex-mac-arm64.dmg"]),
  });

  addItem(items, {
    id: "mac-intel",
    sourceKey: "latest/mac-intel",
    stageRelativeKey: "mac-intel",
    aliasKeys: [withSecondaryPrefix("latest/mac-intel", secondaryPrefix)],
    filename: "Codex-mac-x64.dmg",
    contentType: "application/x-apple-diskimage",
    role: "installer",
    required: true,
    expectedSize: optionalPositiveInt(macos.x64?.contentLength),
    expectedSha256: optionalSha256(macos.x64?.sha256 || latestChecksums["Codex-mac-x64.dmg"]),
  });

  const armZipBasename = mirrorEnclosureBasename(
    manifest,
    macos.arm64?.appcast,
    "arm64",
  );
  const x64ZipBasename = mirrorEnclosureBasename(manifest, macos.x64?.appcast, "x64");
  if (armZipBasename) {
    const basename = armZipBasename;
    addItem(items, {
      id: "mac-arm64-zip",
      sourceKey: `latest/mac/arm64/${basename}`,
      stageRelativeKey: `mac/arm64/${basename}`,
      aliasKeys: [withSecondaryPrefix(`latest/mac/arm64/${basename}`, secondaryPrefix)],
      filename: basename,
      contentType: "application/octet-stream",
      role: "archive",
      required: true,
      expectedSize: optionalPositiveInt(macos.arm64?.appcast?.enclosureLength),
      expectedSha256: optionalSha256(latestChecksums[basename]),
    });
  }
  if (x64ZipBasename) {
    const basename = x64ZipBasename;
    addItem(items, {
      id: "mac-x64-zip",
      sourceKey: `latest/mac/intel/${basename}`,
      stageRelativeKey: `mac/intel/${basename}`,
      aliasKeys: [withSecondaryPrefix(`latest/mac/intel/${basename}`, secondaryPrefix)],
      filename: basename,
      contentType: "application/octet-stream",
      role: "archive",
      required: true,
      expectedSize: optionalPositiveInt(macos.x64?.appcast?.enclosureLength),
      expectedSha256: optionalSha256(latestChecksums[basename]),
    });
  }

  const armExpectedDeltas = addDeltas(
    items,
    macos.arm64?.appcast?.deltas || [],
    "arm64",
    latestChecksums,
    secondaryPrefix,
  );
  const x64ExpectedDeltas = addDeltas(
    items,
    macos.x64?.appcast?.deltas || [],
    "intel",
    latestChecksums,
    secondaryPrefix,
  );

  const expectedChecksums = {};
  for (const [entryName, rawSha] of Object.entries(latestChecksums)) {
    const validSha = optionalSha256(rawSha);
    if (entryName && validSha) {
      expectedChecksums[entryName] = validSha;
    }
  }
  const pinnedManifestSha = optionalSha256(options.manifestSha256);
  if (pinnedManifestSha) {
    expectedChecksums["release-manifest.json"] = pinnedManifestSha;
  }

  addItem(items, {
    id: "checksums",
    sourceKey: "latest/checksums",
    stageRelativeKey: "checksums",
    aliasKeys: [withSecondaryPrefix("latest/checksums", secondaryPrefix)],
    filename: "SHA256SUMS.txt",
    contentType: "text/plain; charset=utf-8",
    role: "checksums",
    required: true,
    expectedManifestSha256: pinnedManifestSha,
    expectedChecksums: Object.keys(expectedChecksums).length > 0 ? expectedChecksums : undefined,
  });

  addItem(items, {
    id: "appcast-arm64",
    sourceKey: "latest/appcast.xml",
    stageRelativeKey: "appcast.xml",
    aliasKeys: [withSecondaryPrefix("latest/appcast.xml", secondaryPrefix)],
    filename: "appcast.xml",
    contentType: "application/xml",
    cacheControl: SHORT_CACHE_CONTROL,
    role: "appcast",
    required: true,
    expectedAppcast: armZipBasename
      ? {
          publicBaseUrl,
          mirrorDir: "arm64",
          zipBasename: armZipBasename,
          version: String(macos.arm64?.appcast?.version || ""),
          shortVersionString: String(macos.arm64?.appcast?.shortVersionString || ""),
          enclosureLength: optionalPositiveInt(macos.arm64?.appcast?.enclosureLength),
          edSignature: String(
            macos.arm64?.appcast?.enclosureSignature || macos.arm64?.appcast?.edSignature || "",
          ),
          deltaBasenames: armExpectedDeltas.map((entry) => entry.basename),
          deltas: armExpectedDeltas,
        }
      : undefined,
  });

  addItem(items, {
    id: "appcast-x64",
    sourceKey: "latest/appcast-x64.xml",
    stageRelativeKey: "appcast-x64.xml",
    aliasKeys: [withSecondaryPrefix("latest/appcast-x64.xml", secondaryPrefix)],
    filename: "appcast-x64.xml",
    contentType: "application/xml",
    cacheControl: SHORT_CACHE_CONTROL,
    role: "appcast",
    required: true,
    expectedAppcast: x64ZipBasename
      ? {
          publicBaseUrl,
          mirrorDir: "intel",
          zipBasename: x64ZipBasename,
          version: String(macos.x64?.appcast?.version || ""),
          shortVersionString: String(macos.x64?.appcast?.shortVersionString || ""),
          enclosureLength: optionalPositiveInt(macos.x64?.appcast?.enclosureLength),
          edSignature: String(
            macos.x64?.appcast?.enclosureSignature || macos.x64?.appcast?.edSignature || "",
          ),
          deltaBasenames: x64ExpectedDeltas.map((entry) => entry.basename),
          deltas: x64ExpectedDeltas,
        }
      : undefined,
  });

  const pinnedManifestText =
    typeof options.manifestText === "string" ? options.manifestText : undefined;
  addItem(items, {
    id: "manifest",
    sourceKey: "latest/manifest",
    stageRelativeKey: "manifest",
    aliasKeys: [withSecondaryPrefix("latest/manifest", secondaryPrefix)],
    filename: "release-manifest.json",
    contentType: "application/json",
    role: "manifest",
    required: true,
    ...(pinnedManifestText !== undefined
      ? {
          inlineText: pinnedManifestText,
          expectedSize: utf8(pinnedManifestText).byteLength,
          expectedSha256: optionalSha256(options.manifestSha256),
        }
      : {}),
  });

  const latestMacPrefix = withSecondaryPrefix("latest/mac/", secondaryPrefix);
  return {
    releaseTag,
    items,
    staleAliasKeys,
    keepLatestMacKeys: items
      .flatMap((item) => item.aliasKeys)
      .filter((key) => key.startsWith(latestMacPrefix)),
  };
}

function optionalPositiveInt(value) {
  const num = Number(value);
  return Number.isInteger(num) && num > 0 ? num : undefined;
}

function optionalSha256(value) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(trimmed) ? trimmed : undefined;
}

function withSecondaryPrefix(key, prefix) {
  const clean = cleanPrefix(prefix);
  const cleanKey = String(key || "").replace(/^\/+/, "");
  return clean ? `${clean}/${cleanKey}` : cleanKey;
}

function validateArchiveBasename(value, extension, label) {
  const basename = String(value || "");
  if (
    !basename ||
    basename.includes("/") ||
    basename.includes("\\") ||
    basename.includes("..") ||
    /[\x00-\x1f\x7f]/.test(basename) ||
    !basename.endsWith(`.${extension}`)
  ) {
    throw new NonRetryableMirrorError(`Invalid ${label} basename: ${JSON.stringify(basename)}.`);
  }
  return basename;
}

function mirrorEnclosureBasename(manifest, appcast, archiveArch) {
  const explicit = appcast?.mirrorEnclosureBasename;
  if (explicit) {
    return validateArchiveBasename(explicit, "zip", `macOS ${archiveArch} mirror enclosure`);
  }

  if (Number(manifest?.schemaVersion || 0) >= 5) {
    throw new NonRetryableMirrorError(
      `Schema-5 manifest is missing macOS ${archiveArch} mirrorEnclosureBasename.`,
    );
  }

  const shortVersion = appcast?.shortVersionString;
  if (!shortVersion) {
    return "";
  }
  return validateArchiveBasename(
    `Codex-darwin-${archiveArch}-${shortVersion}.zip`,
    "zip",
    `legacy macOS ${archiveArch} mirror enclosure`,
  );
}

function deltaUrlBasename(rawUrl, mirrorDir) {
  const value = String(rawUrl || "");
  if (!value) {
    return "";
  }
  let pathname = "";
  try {
    pathname = new URL(value).pathname;
  } catch {
    pathname = value.split(/[?#]/, 1)[0];
  }
  const rawSegment = pathname.split("/").pop() || "";
  if (/%2f|%5c/i.test(rawSegment)) {
    throw new NonRetryableMirrorError(
      `Invalid macOS ${mirrorDir} delta URL segment: ${JSON.stringify(rawSegment)}.`,
    );
  }
  try {
    return decodeURIComponent(rawSegment);
  } catch {
    throw new NonRetryableMirrorError(
      `Malformed percent-encoding in macOS ${mirrorDir} delta URL: ${JSON.stringify(value)}.`,
    );
  }
}

function addDeltas(items, deltas, mirrorDir, latestChecksums = {}, secondaryPrefix = "") {
  const expectedDeltas = [];
  for (const delta of deltas) {
    const basename = validateArchiveBasename(
      delta.basename || deltaUrlBasename(delta.url, mirrorDir),
      "delta",
      `macOS ${mirrorDir} delta`,
    );
    const deltaAttrs = delta?.attributes && typeof delta.attributes === "object" ? delta.attributes : {};
    const expectedLength = optionalPositiveInt(delta.length ?? deltaAttrs.length);
    expectedDeltas.push({
      basename,
      length: expectedLength,
      edSignature: String(deltaAttrs["sparkle:edSignature"] || delta.edSignature || ""),
      deltaFrom: String(deltaAttrs["sparkle:deltaFrom"] || delta.deltaFrom || ""),
      version: String(deltaAttrs["sparkle:version"] || delta.version || ""),
      os: String(deltaAttrs["sparkle:os"] || delta.os || ""),
    });
    addItem(items, {
      id: `mac-${mirrorDir}-delta-${basename}`,
      sourceKey: `latest/mac/${mirrorDir}/${basename}`,
      stageRelativeKey: `mac/${mirrorDir}/${basename}`,
      aliasKeys: [withSecondaryPrefix(`latest/mac/${mirrorDir}/${basename}`, secondaryPrefix)],
      filename: basename,
      contentType: "application/octet-stream",
      role: "delta",
      required: true,
      expectedSize: expectedLength,
      expectedSha256: optionalSha256(latestChecksums[basename]),
    });
  }
  return expectedDeltas;
}

function addItem(items, item) {
  const normalized = {
    cacheControl: DEFAULT_CACHE_CONTROL,
    ...item,
  };
  for (const key of Object.keys(normalized)) {
    if (normalized[key] === undefined) {
      delete normalized[key];
    }
  }
  items.push(normalized);
}

async function lookupR2ChecksumForItem(env, item) {
  const candidateNames = itemChecksumCandidateNames(item);
  if (!env?.GLOBAL_R2 || candidateNames.length === 0) {
    return "";
  }
  const checksumsObj = await env.GLOBAL_R2.get("latest/checksums");
  if (!checksumsObj) {
    return "";
  }
  if (typeof checksumsObj.size === "number" && checksumsObj.size > 4 * 1024 * 1024) {
    return "";
  }
  try {
    const checksumsText = await readR2ObjectStrictText(checksumsObj);
    const parsed = parseChecksumsMap(checksumsText);
    if (!parsed) {
      return "";
    }
    const lookup = resolveItemChecksumFromMap(parsed, item);
    if (lookup.conflict) {
      return "";
    }
    return optionalSha256(lookup.digest) || "";
  } catch {
    return "";
  }
}

export async function uploadObjectToStage(env, item, options = {}) {
  const s3 = createS3Client(env);

  if (item.inlineText !== undefined) {
    const inlineBytes = utf8(item.inlineText);
    const computedSha256 = await sha256Hex(inlineBytes);
    if (item.expectedSha256 && computedSha256 !== item.expectedSha256) {
      throw new NonRetryableMirrorError(
        `Pinned manifest SHA-256 mismatch for ${item.id}: expected ${item.expectedSha256}, got ${computedSha256}.`,
      );
    }
    const existing = await s3.headObject(item.stageKey);
    if (
      !options.forceUpload &&
      existing?.contentLength === inlineBytes.byteLength &&
      Boolean(existing.syncSha256) &&
      existing.syncSha256 === computedSha256 &&
      (await aliasBodyMatchesExpectedBytes(s3, item.stageKey, inlineBytes))
    ) {
      return {
        id: item.id,
        sourceKey: item.sourceKey,
        stageKey: item.stageKey,
        size: inlineBytes.byteLength,
        sha256: computedSha256,
        skipped: true,
        reason: "stage object already exists with matching size and digest",
      };
    }
    await s3.putObject(item.stageKey, inlineBytes, { ...item, syncSha256: computedSha256 });
    const verified = await s3.headObject(item.stageKey);
    if (
      !verified ||
      verified.contentLength !== inlineBytes.byteLength ||
      !(await aliasBodyMatchesExpectedBytes(s3, item.stageKey, inlineBytes))
    ) {
      throw new Error(
        `Secondary stage verification failed for ${item.stageKey}: expected ${inlineBytes.byteLength}, got ${verified?.contentLength ?? "missing"}.`,
      );
    }
    return {
      id: item.id,
      sourceKey: item.sourceKey,
      stageKey: item.stageKey,
      size: inlineBytes.byteLength,
      sha256: computedSha256,
      uploaded: true,
    };
  }

  assertR2Binding(env);
  const source = await headR2Object(env, item.sourceKey);
  if (!source) {
    if (item.required) {
      throw new NonRetryableMirrorError(`R2 source object is missing: ${item.sourceKey}`);
    }
    return { id: item.id, sourceKey: item.sourceKey, skipped: true, reason: "source missing" };
  }

  if (item.expectedSize !== undefined && source.size !== item.expectedSize) {
    throw new Error(
      `R2 source object ${item.sourceKey} size (${source.size}) does not match manifest expected size (${item.expectedSize}); R2 may have updated mid-sync.`,
    );
  }

  const requiresContentValidation = Boolean(
    item.expectedManifestSha256 ||
      item.expectedChecksums ||
      item.expectedAppcast ||
      item.role === "checksums" ||
      item.role === "appcast",
  );
  const singlePutMaxBytes = parseBytes(
    options.singlePutMaxBytes ?? env.SECONDARY_SYNC_SINGLE_PUT_MAX_BYTES,
    DEFAULT_SINGLE_PUT_MAX_BYTES,
    0,
  );
  const partSize = parseBytes(
    options.partSizeBytes ?? env.SECONDARY_SYNC_PART_SIZE_BYTES,
    DEFAULT_PART_SIZE_BYTES,
    options.minPartSizeBytes ?? 5 * 1024 * 1024,
  );
  const effectiveExpectedSha256 =
    item.expectedSha256 ||
    (!requiresContentValidation && source.size > singlePutMaxBytes
      ? await lookupR2ChecksumForItem(env, item)
      : "");
  const effectiveItem =
    effectiveExpectedSha256 && !item.expectedSha256
      ? { ...item, expectedSha256: effectiveExpectedSha256 }
      : item;

  const existing = await s3.headObject(item.stageKey);
  if (
    !options.forceUpload &&
    !requiresContentValidation &&
    existing?.contentLength === source.size &&
    !existing.fromListFallback &&
    Boolean(existing.syncSha256) &&
    (!existing.bodySha256 || existing.bodySha256 === existing.syncSha256) &&
    (!effectiveExpectedSha256 || existing.syncSha256 === effectiveExpectedSha256)
  ) {
    return {
      id: item.id,
      sourceKey: item.sourceKey,
      stageKey: item.stageKey,
      size: source.size,
      sha256: existing.syncSha256,
      skipped: true,
      reason: "stage object already exists with matching size",
    };
  }

  let computedSha256 = "";
  let validatedMetadataBytes = null;
  if (requiresContentValidation || source.size <= singlePutMaxBytes) {
    if (requiresContentValidation && source.size > 4 * 1024 * 1024) {
      throw new NonRetryableMirrorError(
        `Metadata object ${item.sourceKey} exceeds 4 MiB safety limit (${source.size} bytes).`,
      );
    }
    const data = await readR2ObjectRange(env, item.sourceKey, 0, source.size, source.etag);
    computedSha256 = await sha256Hex(data);
    if (effectiveExpectedSha256 && computedSha256 !== effectiveExpectedSha256) {
      throw new Error(
        `R2 object ${item.sourceKey} SHA-256 mismatch: expected ${effectiveExpectedSha256}, got ${computedSha256}.`,
      );
    }
    if (requiresContentValidation) {
      validatedMetadataBytes = new Uint8Array(data).slice();
    }
    if (item.expectedManifestSha256 || item.expectedChecksums) {
      const checksumsText = decodeStrictUtf8(data);
      const requiredMap = {
        ...(item.expectedChecksums || {}),
        ...(item.expectedManifestSha256
          ? { "release-manifest.json": item.expectedManifestSha256.toLowerCase() }
          : {}),
      };
      if (!checksumsMatchesExpected(checksumsText, requiredMap)) {
        throw new Error(
          `R2 ${item.sourceKey} does not match expected release checksums; R2 may have updated mid-sync.`,
        );
      }
    }
    if (item.expectedAppcast) {
      let appcastText = "";
      try {
        appcastText = decodeStrictUtf8(data);
      } catch {
        throw new Error(`R2 ${item.sourceKey} contains invalid UTF-8 bytes.`);
      }
      if (!appcastMatchesExpected(appcastText, item.expectedAppcast)) {
        throw new Error(
          `R2 ${item.sourceKey} does not match manifest appcast (${item.expectedAppcast.zipBasename}); R2 may have updated mid-sync.`,
        );
      }
    }
    await s3.putObject(item.stageKey, data, { ...effectiveItem, syncSha256: computedSha256 });
  } else {
    computedSha256 = await multipartUploadFromR2(
      env,
      s3,
      effectiveItem,
      source.size,
      partSize,
      source.etag,
    );
  }

  const verified = await s3.headObject(item.stageKey);
  if (
    !verified ||
    verified.contentLength !== source.size ||
    (!verified.fromListFallback && verified.syncSha256 && verified.syncSha256 !== computedSha256) ||
    (verified.bodySha256 && verified.bodySha256 !== computedSha256)
  ) {
    throw new Error(
      `Secondary stage verification failed for ${item.stageKey}: expected ${source.size}, got ${verified?.contentLength ?? "missing"}.`,
    );
  }
  if (
    validatedMetadataBytes &&
    !(await aliasBodyMatchesExpectedBytes(s3, item.stageKey, validatedMetadataBytes))
  ) {
    throw new Error(`Secondary stage content verification failed for ${item.stageKey}.`);
  }
  if (!validatedMetadataBytes && (verified.fromListFallback || !verified.syncSha256)) {
    const stageDigest = verified.bodySha256
      ? { byteLength: verified.contentLength, sha256: verified.bodySha256 }
      : await s3.streamObjectDigest(item.stageKey);
    if (stageDigest.byteLength !== source.size || stageDigest.sha256 !== computedSha256) {
      throw new Error(
        `Secondary stage SHA-256 verification failed for ${item.stageKey}: expected ${computedSha256}, got ${stageDigest.sha256}.`,
      );
    }
  }

  return {
    id: item.id,
    sourceKey: item.sourceKey,
    stageKey: item.stageKey,
    size: source.size,
    sha256: computedSha256,
    uploaded: true,
  };
}

export async function commitObjectToAliases(env, item, options = {}) {
  const keepBackup = Boolean(options.keepBackup);
  const groupKeepBackup = keepBackup || item.aliasKeys.length > 1;
  const committed = [];
  try {
    for (const aliasKey of item.aliasKeys) {
      const result = await commitSingleAlias(env, item.stageKey, aliasKey, {
        keepBackup: groupKeepBackup,
        expectedManifestSha256: options.expectedManifestSha256,
        instanceId: options.instanceId,
        stagePrefix: options.stagePrefix,
        force: Boolean(options.force),
        itemExpectedSha256: item.expectedSha256 || "",
        itemExpectedManifestSha256: item.expectedManifestSha256 || "",
        itemExpectedChecksums: item.expectedChecksums || null,
        itemExpectedAppcast: item.expectedAppcast || null,
      });
      committed.push(result);
    }
    if (!keepBackup && groupKeepBackup) {
      await cleanupRollbackBackups(env, committed, {
        expectedManifestSha256: options.expectedManifestSha256,
        instanceId: options.instanceId,
      });
    }
  } catch (error) {
    if (groupKeepBackup && !isSupersededError(error)) {
      const candidates = [...committed];
      const seen = new Set(candidates.map((entry) => entry.aliasKey));
      for (const aliasKey of item.aliasKeys) {
        if (seen.has(aliasKey)) {
          continue;
        }
        const { backupKey, stateKey } = aliasBackupKeys(
          item.stageKey,
          aliasKey,
          options.stagePrefix,
        );
        candidates.push({
          aliasKey,
          stageKey: item.stageKey,
          backupKey,
          stateKey,
          hadExisting: true,
          optionalIfNoState: true,
        });
      }
      try {
        await rollbackCommittedAliases(env, candidates, {
          expectedManifestSha256: options.expectedManifestSha256,
          instanceId: options.instanceId,
          stagePrefix: options.stagePrefix,
        });
      } catch (rollbackErr) {
        if (isSupersededError(rollbackErr)) {
          throw rollbackErr;
        }
      }
    }
    throw error;
  }

  return {
    id: item.id,
    stageKey: item.stageKey,
    aliases: committed.map((entry) => ({ key: entry.aliasKey, size: entry.size })),
    size: committed[0]?.size ?? 0,
  };
}

const BATCH_RESTORED_CHECKPOINT_NAME = "_batch_restored.json";
const BATCH_COMMITTED_CHECKPOINT_NAME = "_batch_committed.json";
const SPARKLE_XML_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle";

function switchoverCommittedKeyForStage(stagePrefix) {
  const clean = cleanPrefix(stagePrefix);
  return clean ? `${clean}/backups/${BATCH_COMMITTED_CHECKPOINT_NAME}` : "";
}

export async function readSwitchoverCommittedCheckpoint(env, stagePrefix, s3Override = null) {
  const key = switchoverCommittedKeyForStage(stagePrefix);
  if (!key) {
    return null;
  }
  const s3 = s3Override || createS3Client(env);
  return readJsonStateOrNull(s3, key);
}

function isPublishedManifestStateDoc(manifestStDoc, liveSecondaryManifestSha, effectivePublishedManifestSha = "") {
  const pubSha = String(effectivePublishedManifestSha || liveSecondaryManifestSha || "").toLowerCase();
  if (!manifestStDoc || !pubSha) {
    return false;
  }
  const targetSha = String(manifestStDoc.targetManifestSha256 || "").toLowerCase();
  const backupSha = String(manifestStDoc.backupSha256 || "").toLowerCase();
  return Boolean(
    manifestStDoc.restored !== true &&
      manifestStDoc.backupVerified !== false &&
      targetSha &&
      targetSha === pubSha &&
      (liveSecondaryManifestSha === pubSha ||
        manifestStDoc.hadExisting === false ||
        (manifestStDoc.backupVerified === true && backupSha && backupSha !== pubSha)),
  );
}

async function hasStagePublishedLiveManifest(env, s3, stagePrefix) {
  const cleanStage = cleanPrefix(stagePrefix);
  if (!cleanStage) {
    return { published: false, manifestStateKey: "", manifestStateDoc: null };
  }
  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env?.SECONDARY_S3_PREFIX || "");
  const manifestDet = aliasBackupKeys("", manifestAliasKey, cleanStage);
  const manifestStDoc = await readJsonStateOrNull(s3, manifestDet.stateKey);
  if (!manifestStDoc) {
    return { published: false, manifestStateKey: manifestDet.stateKey, manifestStateDoc: null };
  }
  let liveManifestSha = "";
  try {
    const liveBytes = await s3.getObjectBytes(manifestAliasKey);
    decodeStrictUtf8(liveBytes);
    liveManifestSha = await sha256Hex(liveBytes);
  } catch (err) {
    if (err?.code === "ERR_INVALID_UTF8" || isS3NotFoundError(err)) {
      return { published: false, manifestStateKey: manifestDet.stateKey, manifestStateDoc: manifestStDoc };
    }
    throw err;
  }
  const targetSha = String(manifestStDoc.targetManifestSha256 || "").toLowerCase();
  const published = Boolean(
    liveManifestSha &&
      targetSha &&
      liveManifestSha === targetSha &&
      manifestStDoc.restored !== true &&
      (manifestStDoc.backupVerified === true || manifestStDoc.hadExisting === false),
  );
  return {
    published,
    manifestStateKey: manifestDet.stateKey,
    manifestStateDoc: manifestStDoc,
  };
}

export async function verifyPriorSwitchoverCheckpoint(env, source, plan, options = {}) {
  if (!plan?.stagePrefix || !hasS3Env(env)) {
    return null;
  }
  const s3 = createS3Client(env);
  const priorCommitted = await readSwitchoverCommittedCheckpoint(env, plan.stagePrefix, s3);
  const stagePublished =
    !priorCommitted || priorCommitted.completed !== true
      ? await hasStagePublishedLiveManifest(env, s3, plan.stagePrefix)
      : { published: false, manifestStateDoc: null };
  if (priorCommitted?.completed !== true && !stagePublished.published) {
    return null;
  }

  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env?.SECONDARY_S3_PREFIX || "");
  let liveMatches = false;
  if (
    !priorCommitted?.manifestSha256 ||
    String(priorCommitted.manifestSha256).toLowerCase() === String(source.manifestSha256 || "").toLowerCase()
  ) {
    let secondaryManifest = null;
    try {
      secondaryManifest = await s3.getObjectText(manifestAliasKey);
    } catch (err) {
      if (err?.code !== "ERR_INVALID_UTF8" && !isS3NotFoundError(err)) {
        throw err;
      }
    }
    if (
      secondaryManifest === source.manifestText &&
      (await secondaryAliasesMatchPlan(env, s3, plan, source.manifestSha256, manifestAliasKey))
    ) {
      liveMatches = true;
    }
  }

  if (liveMatches && !options.force) {
    if (priorCommitted?.completed === true) {
      return priorCommitted;
    }
    return recordSwitchoverCommittedCheckpoint(
      env,
      plan.stagePrefix,
      [],
      {
        releaseTag: source.releaseTag,
        manifestSha256: source.manifestSha256,
        instanceId: options.instanceId || "",
        committedEpoch: stagePublished.manifestStateDoc?.ownerEpoch || 0,
        supersededBackupDirs: stagePublished.manifestStateDoc?.supersededBackupDirs || [],
        skipStageScan: true,
      },
      s3,
    );
  }

  const assertInvalidationOwner =
    options.instanceId || source?.manifestSha256
      ? () =>
          verifySourceManifestCurrent(env, source?.manifestSha256 || "", {
            instanceId: options.instanceId || "",
            s3,
            requirePointer: Boolean(options.instanceId),
          })
      : null;
  if (assertInvalidationOwner) {
    await assertInvalidationOwner();
  }
  const cpKey = switchoverCommittedKeyForStage(plan.stagePrefix);
  const backupsPrefix = `${cleanPrefix(plan.stagePrefix)}/backups/`;
  const preservedEpoch = Math.max(
    Number.isSafeInteger(priorCommitted?.committedEpoch) ? priorCommitted.committedEpoch : 0,
    Number.isSafeInteger(stagePublished.manifestStateDoc?.ownerEpoch)
      ? stagePublished.manifestStateDoc.ownerEpoch
      : 0,
  );
  const preservedDirs = [
    ...new Set([
      ...(Array.isArray(priorCommitted?.supersededBackupDirs)
        ? priorCommitted.supersededBackupDirs
        : []),
      ...(Array.isArray(stagePublished.manifestStateDoc?.supersededBackupDirs)
        ? stagePublished.manifestStateDoc.supersededBackupDirs
        : []),
    ]),
  ];
  if (preservedEpoch > 0) {
    await advanceCommittedEpochLedger(env, s3, preservedEpoch, {
      manifestSha256:
        priorCommitted?.manifestSha256 ||
        stagePublished.manifestStateDoc?.targetManifestSha256 ||
        source?.manifestSha256 ||
        "",
      releaseTag: priorCommitted?.releaseTag || source?.releaseTag || "",
    });
  }
  await s3.putObject(
    cpKey,
    utf8(
      JSON.stringify({
        completed: false,
        priorRunSuperseded: true,
        ...(preservedEpoch > 0 ? { committedEpoch: preservedEpoch } : {}),
        supersededBackupDirs: preservedDirs,
        invalidatedAt: new Date().toISOString(),
      }),
    ),
    {
      filename: BATCH_COMMITTED_CHECKPOINT_NAME,
      contentType: "application/json",
      cacheControl: "no-store",
      beforeAttempt: assertInvalidationOwner,
    },
  );
  const leftover = await s3.listObjects(backupsPrefix);
  for (const obj of leftover) {
    if (!obj?.key || obj.key === backupsPrefix || obj.key === cpKey) {
      continue;
    }
    await s3.deleteObject(obj.key, { beforeAttempt: assertInvalidationOwner });
  }
  return null;
}

export async function recordSwitchoverCommittedCheckpoint(
  env,
  stagePrefix,
  committedAliases = [],
  meta = {},
  s3Override = null,
) {
  const key = switchoverCommittedKeyForStage(stagePrefix);
  if (!key) {
    return null;
  }
  const s3 = s3Override || createS3Client(env);
  const hasFence = Boolean(meta?.manifestSha256 || meta?.instanceId);
  let ownerEpoch =
    Number.isSafeInteger(meta?.committedEpoch) && meta.committedEpoch > 0 ? meta.committedEpoch : 0;
  const assertCheckpointOwner = hasFence
    ? async () => {
        const res = await verifySourceManifestCurrent(env, meta.manifestSha256 || "", {
          instanceId: meta.instanceId || "",
          s3,
          requirePointer: Boolean(meta.instanceId),
        });
        if (res?.ownerEpoch > 0) {
          ownerEpoch = res.ownerEpoch;
        }
      }
    : null;
  if (assertCheckpointOwner) {
    await assertCheckpointOwner();
  }
  const existingDoc = await readJsonStateOrNull(s3, key);
  if (
    existingDoc?.completed === true &&
    (committedAliases.length === 0 ||
      (Array.isArray(existingDoc.entries) && existingDoc.entries.length > 0))
  ) {
    return existingDoc;
  }
  const cleanCurrentStage = cleanPrefix(stagePrefix);
  const currentBackupsDir = `${cleanCurrentStage}/backups/`;
  const supersededSet = new Set(
    Array.isArray(meta?.supersededBackupDirs) ? meta.supersededBackupDirs : [],
  );
  for (const prevDir of existingDoc?.supersededBackupDirs || []) {
    if (prevDir && prevDir !== currentBackupsDir) {
      supersededSet.add(prevDir);
    }
  }
  if (Number.isSafeInteger(existingDoc?.committedEpoch) && existingDoc.committedEpoch > ownerEpoch) {
    ownerEpoch = existingDoc.committedEpoch;
  }
  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env?.SECONDARY_S3_PREFIX || "");
  const manifestDet = aliasBackupKeys("", manifestAliasKey, cleanCurrentStage);
  const manifestStDoc = await readJsonStateOrNull(s3, manifestDet.stateKey);
  if (manifestStDoc) {
    for (const stDir of manifestStDoc.supersededBackupDirs || []) {
      if (stDir && stDir !== currentBackupsDir) {
        supersededSet.add(stDir);
      }
    }
    if (Number.isSafeInteger(manifestStDoc.ownerEpoch) && manifestStDoc.ownerEpoch > ownerEpoch) {
      ownerEpoch = manifestStDoc.ownerEpoch;
    }
  }
  if (!existingDoc?.completed && !meta?.skipStageScan) {
    const otherDirs = await collectOtherBackupDirs(env, s3, cleanCurrentStage, ownerEpoch);
    for (const dir of otherDirs) {
      if (dir && dir !== currentBackupsDir) {
        supersededSet.add(dir);
      }
    }
  }
  const { skipStageScan: _skipStageScan, ...publicMeta } = meta || {};
  const payload = {
    completed: true,
    entries:
      committedAliases.length > 0
        ? committedAliases.map((entry) => ({
            aliasKey: entry.aliasKey,
            backupKey: entry.backupKey,
            stateKey: entry.stateKey,
            size: entry.size ?? 0,
            hadExisting: Boolean(entry.hadExisting),
          }))
        : Array.isArray(existingDoc?.entries)
          ? existingDoc.entries
          : [],
    supersededBackupDirs: [...supersededSet],
    ...publicMeta,
    ...(ownerEpoch > 0 ? { committedEpoch: ownerEpoch } : {}),
    completedAt: new Date().toISOString(),
  };
  if (ownerEpoch > 0) {
    await advanceCommittedEpochLedger(env, s3, ownerEpoch, {
      manifestSha256: publicMeta.manifestSha256 || "",
      releaseTag: publicMeta.releaseTag || "",
      instanceId: publicMeta.instanceId || "",
    });
  }
  await s3.putObject(key, utf8(JSON.stringify(payload)), {
    filename: BATCH_COMMITTED_CHECKPOINT_NAME,
    contentType: "application/json",
    cacheControl: "no-store",
    beforeAttempt: assertCheckpointOwner,
  });
  return payload;
}

export function aliasBackupKeys(stageKey, aliasKey, stagePrefixOverride = "") {
  const resolvedStagePrefix = cleanPrefix(stagePrefixOverride);
  if (resolvedStagePrefix) {
    const safeAlias = `${safeKeySegment(aliasKey).slice(0, 72)}-${fnv1a(aliasKey)}`;
    return {
      backupKey: `${resolvedStagePrefix}/backups/${safeAlias}${ALIAS_ROLLBACK_SUFFIX}`,
      stateKey: `${resolvedStagePrefix}/backups/${safeAlias}.state.json`,
      batchCheckpointKey: `${resolvedStagePrefix}/backups/${BATCH_RESTORED_CHECKPOINT_NAME}`,
      perInstance: true,
    };
  }
  return {
    backupKey: `${aliasKey}${ALIAS_ROLLBACK_SUFFIX}`,
    stateKey: `${aliasKey}${ALIAS_ROLLBACK_SUFFIX}.state.json`,
    batchCheckpointKey: "",
    perInstance: false,
  };
}

async function buildKnownAliasMapForStage(env, stagePrefix) {
  const map = new Map();
  const secondaryPrefix = env?.SECONDARY_S3_PREFIX || "";
  const baseAliases = [
    "latest/win-x64",
    "latest/win",
    "latest/win-arm64",
    "latest/mac-arm64",
    "latest/mac-intel",
    "latest/appcast.xml",
    "latest/appcast-x64.xml",
    "latest/checksums",
    "latest/manifest",
  ];
  for (const raw of baseAliases) {
    const aliasKey = withSecondaryPrefix(raw, secondaryPrefix);
    const { backupKey } = aliasBackupKeys("", aliasKey, stagePrefix);
    map.set(backupKey, aliasKey);
  }
  try {
    if (env?.GLOBAL_R2) {
      const manifestObj = await env.GLOBAL_R2.get("latest/manifest");
      if (manifestObj) {
        const manifest = parseJsonAllowingBom(await readR2ObjectStrictText(manifestObj));
        const plan = buildObjectPlan(manifest, deriveReleaseTag(manifest) || "codex-app-recovery", {
          secondaryPrefix,
          publicBaseUrl: env.PUBLIC_BASE_URL || "",
        });
        for (const item of plan.items) {
          for (const aliasKey of item.aliasKeys) {
            const { backupKey } = aliasBackupKeys("", aliasKey, stagePrefix);
            map.set(backupKey, aliasKey);
          }
        }
      }
    }
  } catch {
    // Best-effort R2 plan augmentation when inferring unreadable .state.json backup owners.
  }
  return map;
}

function stagePrefixFromBackupKey(backupKey) {
  const key = String(backupKey || "");
  const marker = "/backups/";
  const index = key.lastIndexOf(marker);
  return index === -1 ? "" : key.slice(0, index);
}

function resolveBatchCheckpointKey(env, entries, stagePrefixOverride = "") {
  const resolvedStagePrefix = cleanPrefix(
    stagePrefixOverride ||
      entries.map((entry) => stagePrefixFromBackupKey(entry?.backupKey)).find(Boolean) ||
      "",
  );
  if (resolvedStagePrefix) {
    return {
      stagePrefix: resolvedStagePrefix,
      checkpointKey: `${resolvedStagePrefix}/backups/${BATCH_RESTORED_CHECKPOINT_NAME}`,
    };
  }
  if (!entries.length) {
    return { stagePrefix: "", checkpointKey: "" };
  }
  const digest = fnv1a(
    entries
      .map((entry) => `${entry.aliasKey}=>${entry.backupKey}`)
      .sort()
      .join("\n"),
  );
  return {
    stagePrefix: "",
    checkpointKey: `${effectiveStageRoot(env)}/rollback-checkpoints/${digest}.json`,
  };
}

async function writeRollbackState(s3, stateKey, payload, beforeAttempt = null) {
  await s3.putObject(stateKey, utf8(JSON.stringify(payload)), {
    filename: "rollback-state.json",
    contentType: "application/json",
    cacheControl: "no-store",
    beforeAttempt,
  });
}

function isS3NotFoundError(error) {
  if (typeof error?.httpStatus === "number") {
    return error.httpStatus === 404;
  }
  return /^S3 [A-Z ]+ .+ failed with HTTP 404(?:[:.]|$)/.test(String(error?.message || ""));
}

async function readJsonStateOrNull(s3, key) {
  try {
    const raw = await s3.getObjectText(key);
    return JSON.parse(raw);
  } catch (error) {
    if (isS3NotFoundError(error)) {
      return null;
    }
    throw error;
  }
}

function bytesEqual(left, right) {
  if (!(left instanceof Uint8Array) || !(right instanceof Uint8Array)) {
    return false;
  }
  if (left.byteLength !== right.byteLength) {
    return false;
  }
  for (let i = 0; i < left.byteLength; i += 1) {
    if (left[i] !== right[i]) {
      return false;
    }
  }
  return true;
}

function backupSealKey(backupKey) {
  return backupKey ? `${backupKey}.seal.json` : "";
}

function matchesRecordedBackup(headObj, state) {
  if (!headObj || !state || state.backupVerified !== true) {
    return false;
  }
  const ignoreSync = Boolean(state.ignoreSyncHeader);
  if (
    !ignoreSync &&
    !headObj.fromListFallback &&
    headObj.syncSha256 &&
    headObj.bodySha256 &&
    headObj.syncSha256 !== headObj.bodySha256
  ) {
    return false;
  }
  if (typeof state.backupSize === "number" && headObj.contentLength !== state.backupSize) {
    return false;
  }
  const recEtag = stripEtagQuotes(state.backupEtag);
  const curEtag = stripEtagQuotes(headObj.etag);
  if (recEtag && recEtag !== "copied" && curEtag && curEtag !== recEtag) {
    return false;
  }
  const recSha = String(state.backupSha256 || "").trim().toLowerCase();
  if (
    !ignoreSync &&
    recSha &&
    !headObj.fromListFallback &&
    headObj.syncSha256 &&
    headObj.syncSha256 !== recSha
  ) {
    return false;
  }
  if (recSha && headObj.bodySha256) {
    return headObj.bodySha256 === recSha;
  }
  if (ignoreSync) {
    return false;
  }
  if (recSha && !headObj.fromListFallback && headObj.syncSha256) {
    return headObj.syncSha256 === recSha;
  }
  if (recEtag && recEtag !== "copied" && curEtag) {
    return curEtag === recEtag;
  }
  return false;
}

async function verifyObjectMatchesRecordedBackup(s3, key, state, headObjOverride = null) {
  if (!state || state.backupVerified !== true) {
    return false;
  }
  const headObj = headObjOverride || (await s3.headObject(key));
  if (!headObj) {
    return false;
  }
  if (typeof state.backupSize === "number" && headObj.contentLength !== state.backupSize) {
    return false;
  }
  if (matchesRecordedBackup(headObj, state)) {
    return true;
  }
  const recSha = String(state.backupSha256 || "").trim().toLowerCase();
  if (recSha) {
    if (headObj.bodySha256) {
      return headObj.bodySha256.toLowerCase() === recSha;
    }
    const streamed = await s3.streamObjectDigest(key);
    if (typeof state.backupSize === "number" && streamed.byteLength !== state.backupSize) {
      return false;
    }
    return streamed.sha256 === recSha;
  }
  const recEtag = stripEtagQuotes(state.backupEtag);
  const curEtag = stripEtagQuotes(headObj.etag);
  if (recEtag && recEtag !== "copied" && curEtag) {
    return curEtag === recEtag;
  }
  return false;
}

async function verifyRawByteCopy(
  s3,
  sourceKey,
  destinationKey,
  source,
  verified,
  copyResultEtag = "",
  expectedShaOverride = "",
) {
  if (!verified || verified.contentLength !== source.contentLength) {
    return { ok: false, sha256: "" };
  }
  const cleanCopyEtag = stripEtagQuotes(copyResultEtag);
  const cleanCopySingleEtag =
    cleanCopyEtag && cleanCopyEtag !== "copied" ? normalizeSinglePartEtag(copyResultEtag) : "";
  const cleanDstAnyEtag = stripEtagQuotes(verified.etag);
  if (
    cleanCopyEtag &&
    cleanCopyEtag !== "copied" &&
    cleanDstAnyEtag &&
    cleanDstAnyEtag !== cleanCopyEtag
  ) {
    return { ok: false, sha256: "" };
  }
  const cleanSrcEtag = normalizeSinglePartEtag(source.etag);
  const cleanDstEtag = normalizeSinglePartEtag(verified.etag);
  if (cleanSrcEtag && cleanCopySingleEtag && cleanSrcEtag !== cleanCopySingleEtag) {
    return { ok: false, sha256: "" };
  }
  if (cleanSrcEtag && cleanDstEtag && cleanSrcEtag !== cleanDstEtag) {
    return { ok: false, sha256: "" };
  }
  let srcSha = String(expectedShaOverride || source.bodySha256 || "").trim().toLowerCase();
  if (!srcSha) {
    const srcStream = await s3.streamObjectDigest(sourceKey);
    if (srcStream.byteLength !== source.contentLength) {
      return { ok: false, sha256: "" };
    }
    srcSha = srcStream.sha256.toLowerCase();
  }
  let dstSha = String(verified.bodySha256 || "").trim().toLowerCase();
  if (!dstSha) {
    const dstStream = await s3.streamObjectDigest(destinationKey);
    if (dstStream.byteLength !== verified.contentLength) {
      return { ok: false, sha256: "" };
    }
    dstSha = dstStream.sha256.toLowerCase();
  }
  return {
    ok: Boolean(srcSha && dstSha && srcSha === dstSha),
    sha256: dstSha,
  };
}

function isMetadataTextAlias(aliasKey) {
  const key = String(aliasKey || "");
  return (
    key === "latest/manifest" ||
    key.endsWith("/latest/manifest") ||
    key === "latest/checksums" ||
    key.endsWith("/latest/checksums") ||
    key.endsWith(".xml")
  );
}

async function aliasBodyMatchesExpectedBytes(s3, aliasKey, expectedBytes) {
  try {
    const actualBytes = await s3.getObjectBytes(aliasKey);
    if (!bytesEqual(actualBytes, expectedBytes)) {
      return false;
    }
    decodeStrictUtf8(actualBytes);
    return true;
  } catch (error) {
    if (error?.code === "ERR_INVALID_UTF8" || isS3NotFoundError(error)) {
      return false;
    }
    throw error;
  }
}

async function writeBackupSeal(s3, sealKey, payload, beforeAttempt = null) {
  if (!sealKey) {
    return;
  }
  await s3.putObject(sealKey, utf8(JSON.stringify(payload)), {
    filename: "rollback-seal.json",
    contentType: "application/json",
    cacheControl: "no-store",
    beforeAttempt,
  });
}

async function collectOtherBackupDirs(env, s3, currentStagePrefix = "", callerEpoch = 0) {
  const cleanCurrent = cleanPrefix(currentStagePrefix);
  const currentBackupsDir = cleanCurrent ? `${cleanCurrent}/backups/` : "";
  const stageRoot = `${effectiveStageRoot(env)}/`;
  if (!stageRoot || stageRoot === "/" || !hasS3Env(env)) {
    return [];
  }
  let activeOwnerInstanceId = "";
  try {
    const pointerRaw = await s3.getObjectText(activeSyncPointerKey(env));
    const pointerDoc = parseJsonAllowingBom(pointerRaw);
    const currentInstanceSeg = cleanCurrent ? cleanCurrent.split("/").pop() : "";
    if (pointerDoc?.instanceId && pointerDoc.instanceId !== currentInstanceSeg) {
      activeOwnerInstanceId = safeKeySegment(pointerDoc.instanceId);
    }
  } catch (err) {
    if (!isS3NotFoundError(err) && err?.code !== "ERR_INVALID_UTF8") {
      throw err;
    }
  }
  const byDir = new Map();
  const listed = await s3.listObjects(stageRoot);
  for (const obj of listed) {
    if (!obj?.key || (currentBackupsDir && obj.key.startsWith(currentBackupsDir))) {
      continue;
    }
    const idx = obj.key.lastIndexOf("/backups/");
    if (idx !== -1) {
      const dir = obj.key.slice(0, idx + "/backups/".length);
      if (dir === currentBackupsDir) {
        continue;
      }
      if (activeOwnerInstanceId && dir.startsWith(stageRoot)) {
        const rest = dir.slice(stageRoot.length).split("/");
        if (rest.length >= 2 && rest[1] === activeOwnerInstanceId) {
          continue;
        }
      }
      if (!byDir.has(dir)) {
        byDir.set(dir, []);
      }
      byDir.get(dir).push(obj.key);
    }
  }
  if (callerEpoch <= 0) {
    return [...byDir.keys()];
  }
  const eligible = [];
  for (const [dir, keys] of byDir.entries()) {
    let hasNewerEpoch = false;
    for (const k of keys) {
      if (k.endsWith(".state.json") || k.endsWith(".seal.json")) {
        const doc = await readJsonStateOrNull(s3, k);
        const ep = Math.max(
          Number.isSafeInteger(doc?.ownerEpoch) ? doc.ownerEpoch : 0,
          Number.isSafeInteger(doc?.committedEpoch) ? doc.committedEpoch : 0,
        );
        if (ep > callerEpoch) {
          hasNewerEpoch = true;
          break;
        }
      }
    }
    if (!hasNewerEpoch) {
      eligible.push(dir);
    }
  }
  return eligible;
}

async function createVerifiedAliasBackup(
  s3,
  aliasKey,
  existing,
  backupKey,
  stateKey,
  assertStillOwner,
  stageKey = "",
  backupOptions = {},
) {
  const {
    targetManifestSha256 = "",
    forceVerifyBody = false,
    supersededBackupDirs = null,
    getOwnerEpoch = null,
  } = backupOptions;
  const sealKey = backupSealKey(backupKey);
  await assertStillOwner();
  const initialEpoch = typeof getOwnerEpoch === "function" ? getOwnerEpoch() : 0;
  if (sealKey) {
    await s3.deleteObject(sealKey, { beforeAttempt: assertStillOwner });
  }
  await writeRollbackState(
    s3,
    stateKey,
    {
      aliasKey,
      stageKey,
      backupKey,
      stateKey,
      hadExisting: true,
      backupVerified: false,
      ...(initialEpoch > 0 ? { ownerEpoch: initialEpoch } : {}),
      ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
      ...(Array.isArray(supersededBackupDirs) ? { supersededBackupDirs } : {}),
      restored: false,
    },
    assertStillOwner,
  );
  await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
  const existingContradicts = Boolean(
    !existing.fromListFallback &&
      existing.syncSha256 &&
      existing.bodySha256 &&
      existing.syncSha256 !== existing.bodySha256,
  );
  const backupCopy = await s3.copyObject(aliasKey, backupKey, {
    expectedSize: existing.contentLength,
    expectedSyncSha256: existingContradicts ? "" : existing.syncSha256,
    expectedEtag: existing.etag,
    disableHeadShortcut: existingContradicts || forceVerifyBody,
    beforeMutate: assertStillOwner,
  });
  const verifiedBackup = await s3.headObject(backupKey);
  const verifiedContradicts = Boolean(
    verifiedBackup &&
      !verifiedBackup.fromListFallback &&
      verifiedBackup.syncSha256 &&
      verifiedBackup.bodySha256 &&
      verifiedBackup.syncSha256 !== verifiedBackup.bodySha256,
  );
  let resolvedSha = "";
  let ignoreSyncHeader = false;
  if (existingContradicts || verifiedContradicts || forceVerifyBody) {
    const rawCheck = await verifyRawByteCopy(
      s3,
      aliasKey,
      backupKey,
      existing,
      verifiedBackup,
      backupCopy?.copyEtag,
    );
    if (!rawCheck.ok) {
      try {
        await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
      } catch {
        // Best-effort cleanup; stateKey retains backupVerified=false and no seal exists.
      }
      throw new Error(`Backup verification failed for ${backupKey} before switching ${aliasKey}.`);
    }
    resolvedSha = rawCheck.sha256;
    ignoreSyncHeader = Boolean(
      existingContradicts ||
        verifiedContradicts ||
        (!verifiedBackup.fromListFallback &&
          verifiedBackup.syncSha256 &&
          verifiedBackup.syncSha256 !== resolvedSha) ||
        (!existing.fromListFallback && existing.syncSha256 && existing.syncSha256 !== resolvedSha),
    );
  } else {
    if (
      !(await verifyPostCopy(
        s3,
        backupKey,
        verifiedBackup,
        existing,
        backupCopy?.copyEtag,
        existing.bodySha256 || "",
      ))
    ) {
      try {
        await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
      } catch {
        // Best-effort cleanup; stateKey retains backupVerified=false and no seal exists.
      }
      throw new Error(`Backup verification failed for ${backupKey} before switching ${aliasKey}.`);
    }
    resolvedSha =
      verifiedBackup.bodySha256 ||
      existing.bodySha256 ||
      (!verifiedBackup.fromListFallback && verifiedBackup.syncSha256) ||
      (!existing.fromListFallback && existing.syncSha256) ||
      "";
    if (!resolvedSha) {
      const streamed = await s3.streamObjectDigest(backupKey);
      if (streamed.byteLength !== verifiedBackup.contentLength) {
        throw new Error(`Backup digest length mismatch for ${backupKey}.`);
      }
      resolvedSha = streamed.sha256;
    }
  }
  await assertStillOwner();
  const finalEpoch = typeof getOwnerEpoch === "function" ? getOwnerEpoch() : initialEpoch;
  const sealPayload = {
    aliasKey,
    stageKey,
    backupKey,
    stateKey,
    hadExisting: true,
    backupVerified: true,
    backupSize: verifiedBackup.contentLength,
    backupEtag: verifiedBackup.etag || backupCopy?.copyEtag || "",
    backupSha256: resolvedSha,
    ...(ignoreSyncHeader ? { ignoreSyncHeader: true } : {}),
    ...(finalEpoch > 0 ? { ownerEpoch: finalEpoch } : {}),
    ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
    ...(Array.isArray(supersededBackupDirs) ? { supersededBackupDirs } : {}),
  };
  await writeBackupSeal(s3, sealKey, sealPayload, assertStillOwner);
  await writeRollbackState(
    s3,
    stateKey,
    {
      ...sealPayload,
      restored: false,
    },
    assertStillOwner,
  );
}

async function adoptAliasBackupFromOrphan(
  s3,
  aliasKey,
  adopted,
  backupKey,
  stateKey,
  assertStillOwner,
  stageKey = "",
  targetManifestSha256 = "",
  supersededBackupDirs = null,
  getOwnerEpoch = null,
) {
  const sealKey = backupSealKey(backupKey);
  await assertStillOwner();
  const initialEpoch = typeof getOwnerEpoch === "function" ? getOwnerEpoch() : 0;
  if (sealKey) {
    await s3.deleteObject(sealKey, { beforeAttempt: assertStillOwner });
  }
  await writeRollbackState(
    s3,
    stateKey,
    {
      aliasKey,
      stageKey,
      backupKey,
      stateKey,
      hadExisting: true,
      backupVerified: false,
      fromOrphanAdoption: true,
      ...(initialEpoch > 0 ? { ownerEpoch: initialEpoch } : {}),
      ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
      ...(Array.isArray(supersededBackupDirs) ? { supersededBackupDirs } : {}),
      restored: false,
    },
    assertStillOwner,
  );
  await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
  const adoptedHead = await s3.headObject(adopted.backupKey);
  if (!adoptedHead) {
    throw new Error(`Adopted rollback backup disappeared: ${adopted.backupKey}`);
  }
  const recSha = String(adopted.sealDoc?.backupSha256 || "").trim().toLowerCase();
  const sourceIgnoreSync = Boolean(
    adopted.sealDoc?.ignoreSyncHeader ||
      (!adoptedHead.fromListFallback &&
        adoptedHead.syncSha256 &&
        ((adoptedHead.bodySha256 && adoptedHead.syncSha256 !== adoptedHead.bodySha256) ||
          (recSha && adoptedHead.syncSha256 !== recSha))),
  );
  const adoptCopy = await s3.copyObject(adopted.backupKey, backupKey, {
    expectedSize: adoptedHead.contentLength,
    expectedSyncSha256: sourceIgnoreSync ? "" : adoptedHead.syncSha256,
    expectedEtag: adoptedHead.etag,
    disableHeadShortcut: sourceIgnoreSync,
    beforeMutate: assertStillOwner,
  });
  const verifiedAdopted = await s3.headObject(backupKey);
  const ignoreSync = Boolean(
    sourceIgnoreSync ||
      (verifiedAdopted &&
        !verifiedAdopted.fromListFallback &&
        verifiedAdopted.syncSha256 &&
        ((verifiedAdopted.bodySha256 &&
          verifiedAdopted.syncSha256 !== verifiedAdopted.bodySha256) ||
          (recSha && verifiedAdopted.syncSha256 !== recSha))),
  );
  const adoptVerifyOk = ignoreSync
    ? (
        await verifyRawByteCopy(
          s3,
          adopted.backupKey,
          backupKey,
          adoptedHead,
          verifiedAdopted,
          adoptCopy?.copyEtag,
          recSha,
        )
      ).ok
    : await verifyPostCopy(
        s3,
        backupKey,
        verifiedAdopted,
        adoptedHead,
        adoptCopy?.copyEtag,
        recSha,
      );
  if (!adoptVerifyOk) {
    throw new Error(
      `Verification failed while adopting orphan backup ${adopted.backupKey} -> ${backupKey}.`,
    );
  }
  await assertStillOwner();
  const finalEpoch = typeof getOwnerEpoch === "function" ? getOwnerEpoch() : initialEpoch;
  const adoptedPayload = {
    aliasKey,
    stageKey,
    backupKey,
    stateKey,
    hadExisting: true,
    backupVerified: true,
    fromOrphanAdoption: true,
    backupSize: verifiedAdopted.contentLength,
    backupEtag: verifiedAdopted.etag || adoptCopy?.copyEtag || adopted.sealDoc.backupEtag || "",
    backupSha256: adopted.sealDoc.backupSha256,
    ...(ignoreSync ? { ignoreSyncHeader: true } : {}),
    ...(finalEpoch > 0 ? { ownerEpoch: finalEpoch } : {}),
    ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
    ...(Array.isArray(supersededBackupDirs) ? { supersededBackupDirs } : {}),
  };
  await writeBackupSeal(s3, sealKey, adoptedPayload, assertStillOwner);
  await writeRollbackState(
    s3,
    stateKey,
    {
      ...adoptedPayload,
      restored: false,
    },
    assertStillOwner,
  );
}

async function adoptOrphanBaseline(
  s3,
  aliasKey,
  adopted,
  backupKey,
  stateKey,
  assertStillOwner,
  stageKey = "",
  targetManifestSha256 = "",
  supersededBackupDirs = null,
  getOwnerEpoch = null,
) {
  const sealKey = backupSealKey(backupKey);
  if (adopted.hadExisting === false) {
    await assertStillOwner();
    const epoch = typeof getOwnerEpoch === "function" ? getOwnerEpoch() : 0;
    if (sealKey) {
      await s3.deleteObject(sealKey, { beforeAttempt: assertStillOwner });
    }
    await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
    await writeRollbackState(
      s3,
      stateKey,
      {
        aliasKey,
        stageKey,
        backupKey,
        stateKey,
        hadExisting: false,
        absentBaselineVerified: true,
        fromOrphanAdoption: true,
        ...(epoch > 0 ? { ownerEpoch: epoch } : {}),
        ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
        ...(Array.isArray(supersededBackupDirs) ? { supersededBackupDirs } : {}),
        restored: false,
      },
      assertStillOwner,
    );
    return false;
  }
  await adoptAliasBackupFromOrphan(
    s3,
    aliasKey,
    adopted,
    backupKey,
    stateKey,
    assertStillOwner,
    stageKey,
    targetManifestSha256,
    supersededBackupDirs,
    getOwnerEpoch,
  );
  return true;
}

// IHEP 网关的服务端 COPY 只在目标 key 不存在时成功，覆盖已存在的 key 必定返回
// InternalError/502，所以别名只能先删后拷。删除会让已发布的别名短暂消失，因此
// 先把旧对象复制成 .rollback 备份，复制或校验失败时还原；keepBackup=true 时保留
// .rollback 直至整组一致性单元全部提交成功后再统一清理。
export async function commitSingleAlias(env, stageKey, aliasKey, options = {}) {
  const keepBackup = Boolean(options.keepBackup);
  const forceOverwrite = Boolean(options.force);
  const metadataAlias = isMetadataTextAlias(aliasKey);
  const s3 = createS3Client(env);
  const hasOwnershipFence = Boolean(options.expectedManifestSha256 || options.instanceId);
  let currentOwnerEpoch = 0;
  const getOwnerEpoch = () => currentOwnerEpoch;
  const assertStillOwner = async () => {
    if (hasOwnershipFence) {
      const res = await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
        instanceId: options.instanceId,
        s3,
        requirePointer: Boolean(options.instanceId),
      });
      if (res?.ownerEpoch > 0) {
        currentOwnerEpoch = res.ownerEpoch;
      }
    }
  };

  await assertStillOwner();

  const source = await s3.headObject(stageKey);
  if (!source) {
    throw new Error(`Cannot commit missing stage object: ${stageKey}`);
  }
  let expectedMetadataBytes = null;
  if (metadataAlias) {
    expectedMetadataBytes = await s3.getObjectBytes(stageKey);
    const metadataText = decodeStrictUtf8(expectedMetadataBytes);
    if (options.itemExpectedSha256) {
      const stagedSha = await sha256Hex(expectedMetadataBytes);
      if (stagedSha !== String(options.itemExpectedSha256).toLowerCase()) {
        throw new Error(
          `Staged metadata ${stageKey} SHA-256 mismatch before commit (expected ${options.itemExpectedSha256}, got ${stagedSha}).`,
        );
      }
    }
    if (options.itemExpectedManifestSha256 || options.itemExpectedChecksums) {
      const requiredMap = {
        ...(options.itemExpectedChecksums || {}),
        ...(options.itemExpectedManifestSha256
          ? { "release-manifest.json": String(options.itemExpectedManifestSha256).toLowerCase() }
          : {}),
      };
      if (!checksumsMatchesExpected(metadataText, requiredMap)) {
        throw new Error(`Staged checksums ${stageKey} failed validation before commit.`);
      }
    }
    if (options.itemExpectedAppcast && !appcastMatchesExpected(metadataText, options.itemExpectedAppcast)) {
      throw new Error(`Staged appcast ${stageKey} failed validation before commit.`);
    }
  } else if (options.itemExpectedSha256) {
    const expectedBinSha = String(options.itemExpectedSha256).toLowerCase();
    if (
      (!source.fromListFallback && source.syncSha256 && source.syncSha256 !== expectedBinSha) ||
      (source.bodySha256 && source.bodySha256 !== expectedBinSha)
    ) {
      throw new Error(`Staged binary ${stageKey} SHA-256 mismatch before commit.`);
    }
    if (source.fromListFallback || !source.syncSha256) {
      const stStream = source.bodySha256
        ? { byteLength: source.contentLength, sha256: source.bodySha256 }
        : await s3.streamObjectDigest(stageKey);
      if (stStream.byteLength !== source.contentLength || stStream.sha256 !== expectedBinSha) {
        throw new Error(`Staged binary ${stageKey} streamed SHA-256 mismatch before commit.`);
      }
    }
  }

  const { backupKey, stateKey, batchCheckpointKey } = aliasBackupKeys(
    stageKey,
    aliasKey,
    options.stagePrefix,
  );
  const sealKey = backupSealKey(backupKey);
  const priorSwitchover = options.stagePrefix
    ? await readSwitchoverCommittedCheckpoint(env, options.stagePrefix, s3)
    : null;
  const ledgerDocForCommit = hasS3Env(env) ? await readCommittedEpochLedger(env, s3) : null;
  const knownMaxCommittedEpoch = Math.max(
    Number.isSafeInteger(ledgerDocForCommit?.committedEpoch) ? ledgerDocForCommit.committedEpoch : 0,
    Number.isSafeInteger(priorSwitchover?.committedEpoch) ? priorSwitchover.committedEpoch : 0,
  );
  if (batchCheckpointKey) {
    await s3.deleteObject(batchCheckpointKey, { beforeAttempt: assertStillOwner });
  }
  let priorState = await readJsonStateOrNull(s3, stateKey);
  let sealDoc =
    !priorState || priorState.backupVerified === undefined
      ? await readJsonStateOrNull(s3, sealKey)
      : null;
  const priorArtifactEpoch = Math.max(
    Number.isSafeInteger(priorState?.ownerEpoch) ? priorState.ownerEpoch : 0,
    Number.isSafeInteger(sealDoc?.ownerEpoch) ? sealDoc.ownerEpoch : 0,
  );
  if (
    knownMaxCommittedEpoch > 0 &&
    priorArtifactEpoch > 0 &&
    priorArtifactEpoch <= knownMaxCommittedEpoch
  ) {
    if (sealKey) {
      await s3.deleteObject(sealKey, { beforeAttempt: assertStillOwner });
    }
    await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
    await s3.deleteObject(stateKey, { beforeAttempt: assertStillOwner });
    priorState = null;
    sealDoc = null;
  }
  const existing = await s3.headObject(aliasKey);
  let existingAlreadyEqualsStage = false;
  if (existing) {
    if (metadataAlias) {
      existingAlreadyEqualsStage = await aliasBodyMatchesExpectedBytes(
        s3,
        aliasKey,
        expectedMetadataBytes,
      );
    } else {
      existingAlreadyEqualsStage = matchesExpectedTarget(existing, {
        expectedSize: source.contentLength,
        expectedSyncSha256: source.syncSha256,
        expectedEtag: source.etag,
      });
      if (!existingAlreadyEqualsStage && existing.contentLength === source.contentLength) {
        const selfContradiction = Boolean(
          (!source.fromListFallback &&
            source.syncSha256 &&
            source.bodySha256 &&
            source.syncSha256 !== source.bodySha256) ||
            (!existing.fromListFallback &&
              existing.syncSha256 &&
              existing.bodySha256 &&
              existing.syncSha256 !== existing.bodySha256),
        );
        const cleanSrcEtag = normalizeSinglePartEtag(source.etag);
        const cleanDstEtag = normalizeSinglePartEtag(existing.etag);
        const etagConflict = Boolean(cleanSrcEtag && cleanDstEtag && cleanSrcEtag !== cleanDstEtag);
        const shaConflict = Boolean(
          !source.fromListFallback &&
            source.syncSha256 &&
            !existing.fromListFallback &&
            existing.syncSha256 &&
            source.syncSha256 !== existing.syncSha256,
        );
        if (
          !selfContradiction &&
          !etagConflict &&
          !shaConflict &&
          !(cleanSrcEtag && cleanDstEtag) &&
          !(!source.fromListFallback && source.syncSha256 && !existing.fromListFallback && existing.syncSha256)
        ) {
          let srcSha = source.bodySha256 || (!source.fromListFallback && source.syncSha256) || "";
          if (!srcSha) {
            const stStream = await s3.streamObjectDigest(stageKey);
            if (stStream.byteLength === source.contentLength) {
              srcSha = stStream.sha256;
            }
          }
          let dstSha =
            existing.bodySha256 || (!existing.fromListFallback && existing.syncSha256) || "";
          if (!dstSha) {
            const exStream = await s3.streamObjectDigest(aliasKey);
            if (exStream.byteLength === source.contentLength) {
              dstSha = exStream.sha256;
            }
          }
          existingAlreadyEqualsStage = Boolean(
            srcSha && dstSha && srcSha.toLowerCase() === dstSha.toLowerCase(),
          );
        }
      }
    }
  }
  const targetManifestSha256 = options.expectedManifestSha256 || "";
  const isManifestAlias =
    aliasKey === withSecondaryPrefix("latest/manifest", env?.SECONDARY_S3_PREFIX || "");
  const stageHasOrMayHaveSyncStamp = Boolean(source.syncSha256 || source.fromListFallback);
  const missingSyncStamp = Boolean(
    existing &&
      !existing.fromListFallback &&
      !existing.syncSha256 &&
      stageHasOrMayHaveSyncStamp,
  );
  const canSkipCopy = !forceOverwrite && !missingSyncStamp && existingAlreadyEqualsStage;
  const bestEffortRecordManifestLedger = async () => {
    if (isManifestAlias && currentOwnerEpoch > 0) {
      try {
        await advanceCommittedEpochLedger(env, s3, currentOwnerEpoch, {
          manifestSha256: targetManifestSha256,
          instanceId: options.instanceId || "",
        });
      } catch {
        // Checkpoint and cleanup also persist committed-state.json before removing guards.
      }
    }
  };
  if (priorSwitchover?.completed === true && canSkipCopy) {
    await bestEffortRecordManifestLedger();
    return {
      aliasKey,
      stageKey,
      backupKey,
      stateKey,
      size: source.contentLength,
      hadExisting: false,
    };
  }
  const manifestSupersededDirs =
    isManifestAlias && options.stagePrefix
      ? await collectOtherBackupDirs(env, s3, options.stagePrefix, currentOwnerEpoch)
      : null;
  let hadExisting = false;

  if (priorState !== null) {
    hadExisting = Boolean(priorState.hadExisting);
    const verifRecord =
      priorState.backupVerified === true
        ? priorState
        : priorState.backupVerified === false
          ? null
          : sealDoc?.backupVerified === true
            ? sealDoc
            : null;
    if (priorState.restored === true) {
      if (hadExisting) {
        const existingBackup = await s3.headObject(backupKey);
        const backupValid = Boolean(
          existingBackup &&
            (verifRecord
              ? await verifyObjectMatchesRecordedBackup(s3, backupKey, verifRecord, existingBackup)
              : priorState.backupVerified !== false &&
                existing &&
                matchesExpectedTarget(existingBackup, {
                  expectedSize: existing.contentLength,
                  expectedSyncSha256: existing.syncSha256,
                  expectedEtag: existing.etag,
                })),
        );
        if (!backupValid) {
          const adopted = await findUnrestoredStageBackupForAlias(
            env,
            s3,
            aliasKey,
            options.stagePrefix,
          );
          if (adopted) {
            hadExisting = await adoptOrphanBaseline(
              s3,
              aliasKey,
              adopted,
              backupKey,
              stateKey,
              assertStillOwner,
              stageKey,
              targetManifestSha256,
              manifestSupersededDirs,
              getOwnerEpoch,
            );
          } else if (existing) {
            await createVerifiedAliasBackup(
              s3,
              aliasKey,
              existing,
              backupKey,
              stateKey,
              assertStillOwner,
              stageKey,
              {
                targetManifestSha256,
                forceVerifyBody: forceOverwrite,
                supersededBackupDirs: manifestSupersededDirs,
                getOwnerEpoch,
              },
            );
          } else {
            throw new Error(
              `Cannot recommit ${aliasKey}: prior rollback backup ${backupKey} is missing or unverified and live alias is missing.`,
            );
          }
        } else {
          let resolvedSha =
            verifRecord?.backupSha256 ||
            existingBackup.bodySha256 ||
            (!existingBackup.fromListFallback && existingBackup.syncSha256) ||
            "";
          if (!resolvedSha) {
            resolvedSha = (await s3.streamObjectDigest(backupKey)).sha256;
          }
          const staleSync = Boolean(
            verifRecord?.ignoreSyncHeader ||
              (!existingBackup.fromListFallback &&
                existingBackup.syncSha256 &&
                existingBackup.syncSha256 !== resolvedSha.toLowerCase()),
          );
          await assertStillOwner();
          const verifiedPayload = {
            aliasKey,
            stageKey,
            backupKey,
            stateKey,
            hadExisting: true,
            backupVerified: true,
            backupSize: existingBackup.contentLength,
            backupEtag: verifRecord?.backupEtag || existingBackup.etag || "",
            backupSha256: resolvedSha,
            ...(staleSync ? { ignoreSyncHeader: true } : {}),
            ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
            ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
            ...(Array.isArray(manifestSupersededDirs)
              ? { supersededBackupDirs: manifestSupersededDirs }
              : {}),
          };
          await writeBackupSeal(s3, sealKey, verifiedPayload, assertStillOwner);
          await writeRollbackState(
            s3,
            stateKey,
            {
              ...verifiedPayload,
              restored: false,
            },
            assertStillOwner,
          );
        }
      } else {
        const adopted = await findUnrestoredStageBackupForAlias(
          env,
          s3,
          aliasKey,
          options.stagePrefix,
        );
        if (adopted) {
          hadExisting = await adoptOrphanBaseline(
            s3,
            aliasKey,
            adopted,
            backupKey,
            stateKey,
            assertStillOwner,
            stageKey,
            targetManifestSha256,
            manifestSupersededDirs,
            getOwnerEpoch,
          );
        } else {
          await assertStillOwner();
          await writeRollbackState(
            s3,
            stateKey,
            {
              aliasKey,
              stageKey,
              backupKey,
              stateKey,
              hadExisting: false,
              absentBaselineVerified: true,
              ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
              ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
              ...(Array.isArray(manifestSupersededDirs)
                ? { supersededBackupDirs: manifestSupersededDirs }
                : {}),
              restored: false,
            },
            assertStillOwner,
          );
        }
      }
    } else if (hadExisting) {
      const existingBackup = await s3.headObject(backupKey);
      const backupValid = Boolean(
        existingBackup &&
          (priorState.backupVerified === false
            ? false
            : verifRecord
              ? await verifyObjectMatchesRecordedBackup(s3, backupKey, verifRecord, existingBackup)
              : !existing
                ? existingBackup.contentLength > 0
                : matchesExpectedTarget(existingBackup, {
                    expectedSize: existing.contentLength,
                    expectedSyncSha256: existing.syncSha256,
                    expectedEtag: existing.etag,
                  })),
      );
      if (!backupValid) {
        const adopted = await findUnrestoredStageBackupForAlias(
          env,
          s3,
          aliasKey,
          options.stagePrefix,
        );
        if (adopted) {
          hadExisting = await adoptOrphanBaseline(
            s3,
            aliasKey,
            adopted,
            backupKey,
            stateKey,
            assertStillOwner,
            stageKey,
            targetManifestSha256,
            manifestSupersededDirs,
            getOwnerEpoch,
          );
        } else if (existing) {
          await createVerifiedAliasBackup(
            s3,
            aliasKey,
            existing,
            backupKey,
            stateKey,
            assertStillOwner,
            stageKey,
            {
              targetManifestSha256,
              forceVerifyBody: forceOverwrite,
              supersededBackupDirs: manifestSupersededDirs,
              getOwnerEpoch,
            },
          );
        } else {
          try {
            await s3.deleteObject(backupKey, { beforeAttempt: assertStillOwner });
          } catch {
            // Best-effort cleanup of invalid backup.
          }
          throw new Error(
            `Missing or unverified rollback backup ${backupKey} and missing live alias ${aliasKey} while retrying commit.`,
          );
        }
      } else if (!verifRecord) {
        let resolvedSha =
          existingBackup.bodySha256 ||
          (!existingBackup.fromListFallback && existingBackup.syncSha256) ||
          "";
        if (!resolvedSha) {
          resolvedSha = (await s3.streamObjectDigest(backupKey)).sha256;
        }
        const staleSync = Boolean(
          !existingBackup.fromListFallback &&
            existingBackup.syncSha256 &&
            existingBackup.syncSha256 !== resolvedSha.toLowerCase(),
        );
        await assertStillOwner();
        const verifiedPayload = {
          aliasKey,
          stageKey,
          backupKey,
          stateKey,
          hadExisting: true,
          backupVerified: true,
          backupSize: existingBackup.contentLength,
          backupEtag: existingBackup.etag || "",
          backupSha256: resolvedSha,
          ...(staleSync ? { ignoreSyncHeader: true } : {}),
          ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
          ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
          ...(Array.isArray(manifestSupersededDirs)
            ? { supersededBackupDirs: manifestSupersededDirs }
            : {}),
        };
        await writeBackupSeal(s3, sealKey, verifiedPayload, assertStillOwner);
        await writeRollbackState(
          s3,
          stateKey,
          {
            ...verifiedPayload,
            restored: false,
          },
          assertStillOwner,
        );
      }
    }

    if (canSkipCopy) {
      await assertStillOwner();
      await bestEffortRecordManifestLedger();
      if (!keepBackup) {
        if (hadExisting) {
          await s3.deleteObject(backupKey);
          if (sealKey) {
            await s3.deleteObject(sealKey);
          }
        }
        await s3.deleteObject(stateKey);
      }
      return {
        aliasKey,
        stageKey,
        backupKey,
        stateKey,
        size: source.contentLength,
        hadExisting,
      };
    }
    if (existing) {
      await s3.deleteObject(aliasKey, { beforeAttempt: assertStillOwner });
    }
  } else {
    const preExistingBackup = await s3.headObject(backupKey);
    const existingVerifiedAsBackup = Boolean(
      existing &&
        preExistingBackup &&
        matchesExpectedTarget(preExistingBackup, {
          expectedSize: existing.contentLength,
          expectedSyncSha256: existing.syncSha256,
          expectedEtag: existing.etag,
        }),
    );
    const sealedBackupMatches = Boolean(
      preExistingBackup &&
        sealDoc?.backupVerified === true &&
        (await verifyObjectMatchesRecordedBackup(s3, backupKey, sealDoc, preExistingBackup)),
    );
    const perInstanceSealedMatch = Boolean(
      sealedBackupMatches &&
        (!sealDoc?.aliasKey || sealDoc.aliasKey === aliasKey) &&
        ((backupKey.includes("/backups/") && (!sealDoc?.stageKey || sealDoc.stageKey === stageKey)) ||
          (sealDoc?.stageKey && sealDoc.stageKey === stageKey)),
    );
    const reusePreExistingBackup = Boolean(
      preExistingBackup &&
        preExistingBackup.contentLength > 0 &&
        (!existing ||
          existingVerifiedAsBackup ||
          perInstanceSealedMatch ||
          (existingAlreadyEqualsStage && sealedBackupMatches)),
    );

    if (reusePreExistingBackup) {
      hadExisting = true;
      let resolvedSha =
        sealDoc?.backupSha256 ||
        preExistingBackup.bodySha256 ||
        (!preExistingBackup.fromListFallback && preExistingBackup.syncSha256) ||
        "";
      if (!resolvedSha) {
        const streamed = await s3.streamObjectDigest(backupKey);
        if (streamed.byteLength !== preExistingBackup.contentLength) {
          throw new Error(`Backup digest length mismatch for ${backupKey}.`);
        }
        resolvedSha = streamed.sha256;
      }
      const staleSync = Boolean(
        sealDoc?.ignoreSyncHeader ||
          (!preExistingBackup.fromListFallback &&
            preExistingBackup.syncSha256 &&
            preExistingBackup.syncSha256 !== resolvedSha.toLowerCase()),
      );
      await assertStillOwner();
      const verifiedPayload = {
        aliasKey,
        stageKey,
        backupKey,
        stateKey,
        hadExisting: true,
        backupVerified: true,
        backupSize: preExistingBackup.contentLength,
        backupEtag: sealDoc?.backupEtag || preExistingBackup.etag || "",
        backupSha256: resolvedSha,
        ...(staleSync ? { ignoreSyncHeader: true } : {}),
        ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
        ...(targetManifestSha256 || sealDoc?.targetManifestSha256
          ? { targetManifestSha256: targetManifestSha256 || sealDoc.targetManifestSha256 }
          : {}),
        ...(Array.isArray(manifestSupersededDirs)
          ? { supersededBackupDirs: manifestSupersededDirs }
          : {}),
      };
      await writeBackupSeal(s3, sealKey, verifiedPayload, assertStillOwner);
      await writeRollbackState(
        s3,
        stateKey,
        {
          ...verifiedPayload,
          restored: false,
        },
        assertStillOwner,
      );
      if (canSkipCopy) {
        await assertStillOwner();
        await bestEffortRecordManifestLedger();
        if (!keepBackup) {
          await s3.deleteObject(backupKey);
          if (sealKey) {
            await s3.deleteObject(sealKey);
          }
          await s3.deleteObject(stateKey);
        }
        return {
          aliasKey,
          stageKey,
          backupKey,
          stateKey,
          size: source.contentLength,
          hadExisting: true,
        };
      }
      if (existing) {
        await s3.deleteObject(aliasKey, { beforeAttempt: assertStillOwner });
      }
    } else {
      const adopted = await findUnrestoredStageBackupForAlias(
        env,
        s3,
        aliasKey,
        options.stagePrefix,
      );
      if (adopted) {
        hadExisting = await adoptOrphanBaseline(
          s3,
          aliasKey,
          adopted,
          backupKey,
          stateKey,
          assertStillOwner,
          stageKey,
          targetManifestSha256,
          manifestSupersededDirs,
          getOwnerEpoch,
        );
        if (canSkipCopy) {
          await assertStillOwner();
          await bestEffortRecordManifestLedger();
          if (!keepBackup) {
            if (hadExisting) {
              await s3.deleteObject(backupKey);
              if (sealKey) {
                await s3.deleteObject(sealKey);
              }
            }
            await s3.deleteObject(stateKey);
          }
          return {
            aliasKey,
            stageKey,
            backupKey,
            stateKey,
            size: source.contentLength,
            hadExisting,
          };
        }
        if (existing) {
          await s3.deleteObject(aliasKey, { beforeAttempt: assertStillOwner });
        }
      } else if (existing) {
        hadExisting = true;
        await createVerifiedAliasBackup(
          s3,
          aliasKey,
          existing,
          backupKey,
          stateKey,
          assertStillOwner,
          stageKey,
          {
            targetManifestSha256,
            forceVerifyBody: forceOverwrite,
            supersededBackupDirs: manifestSupersededDirs,
            getOwnerEpoch,
          },
        );
        if (canSkipCopy) {
          await assertStillOwner();
          await bestEffortRecordManifestLedger();
          if (!keepBackup) {
            await s3.deleteObject(backupKey);
            if (sealKey) {
              await s3.deleteObject(sealKey);
            }
            await s3.deleteObject(stateKey);
          }
          return {
            aliasKey,
            stageKey,
            backupKey,
            stateKey,
            size: source.contentLength,
            hadExisting: true,
          };
        }
        await s3.deleteObject(aliasKey, { beforeAttempt: assertStillOwner });
      } else {
        hadExisting = false;
        await assertStillOwner();
        await writeRollbackState(
          s3,
          stateKey,
          {
            aliasKey,
            stageKey,
            backupKey,
            stateKey,
            hadExisting: false,
            absentBaselineVerified: true,
            ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
            ...(targetManifestSha256 ? { targetManifestSha256 } : {}),
            ...(Array.isArray(manifestSupersededDirs)
              ? { supersededBackupDirs: manifestSupersededDirs }
              : {}),
            restored: false,
          },
          assertStillOwner,
        );
      }
    }
  }

  try {
    const aliasCopy = await s3.copyObject(stageKey, aliasKey, {
      expectedSize: source.contentLength,
      expectedSyncSha256: options.itemExpectedSha256 || source.syncSha256,
      expectedEtag: source.etag,
      disableHeadShortcut: forceOverwrite || metadataAlias || missingSyncStamp,
      beforeMutate: assertStillOwner,
    });
    await assertStillOwner();
    const verified = await s3.headObject(aliasKey);
    if (
      !(await verifyPostCopy(
        s3,
        aliasKey,
        verified,
        source,
        aliasCopy?.copyEtag,
        options.itemExpectedSha256 ||
          (!source.fromListFallback && source.syncSha256) ||
          source.bodySha256 ||
          "",
      ))
    ) {
      throw new Error(
        `Secondary alias verification failed for ${aliasKey}: expected size=${source.contentLength} sha256=${source.syncSha256 || "n/a"}, got size=${verified?.contentLength ?? "missing"} sha256=${verified?.syncSha256 || "n/a"}.`,
      );
    }
    if (
      metadataAlias &&
      !(await aliasBodyMatchesExpectedBytes(s3, aliasKey, expectedMetadataBytes))
    ) {
      throw new Error(`Secondary metadata alias body verification failed for ${aliasKey}.`);
    }
  } catch (error) {
    if (!isSupersededError(error)) {
      try {
        await assertStillOwner();
        if (hadExisting) {
          await restoreAliasFromBackup(s3, aliasKey, backupKey, {
            keepBackupUntilBatchDone: keepBackup,
            stateKey,
            stageKey,
            beforeMutate: assertStillOwner,
          });
        } else {
          try {
            await s3.deleteObject(aliasKey, { beforeAttempt: assertStillOwner });
            if (keepBackup) {
              await writeRollbackState(
                s3,
                stateKey,
                {
                  aliasKey,
                  stageKey,
                  backupKey,
                  stateKey,
                  hadExisting: false,
                  ...(currentOwnerEpoch > 0 ? { ownerEpoch: currentOwnerEpoch } : {}),
                  restored: true,
                },
                assertStillOwner,
              );
            } else {
              await s3.deleteObject(stateKey);
            }
          } catch (cleanupErr) {
            if (isSupersededError(cleanupErr)) {
              throw cleanupErr;
            }
          }
        }
      } catch (ownerOrRestoreErr) {
        if (isSupersededError(ownerOrRestoreErr)) {
          throw ownerOrRestoreErr;
        }
      }
    }
    throw error;
  }

  await bestEffortRecordManifestLedger();
  if (!keepBackup) {
    if (hadExisting) {
      await s3.deleteObject(backupKey);
      if (sealKey) {
        await s3.deleteObject(sealKey);
      }
    }
    await s3.deleteObject(stateKey);
  }

  return {
    aliasKey,
    stageKey,
    backupKey,
    stateKey,
    size: source.contentLength,
    hadExisting,
  };
}

export async function rollbackCommittedAliases(env, committedAliases, options = {}) {
  const s3 = createS3Client(env);
  let currentRollbackOwnerEpoch = 0;
  const checkOwner = async () => {
    if (options.expectedManifestSha256 || options.instanceId) {
      const res = await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
        instanceId: options.instanceId,
        s3,
        requirePointer: Boolean(options.instanceId),
      });
      if (res?.ownerEpoch > 0) {
        currentRollbackOwnerEpoch = res.ownerEpoch;
      }
    }
  };
  try {
    await checkOwner();
  } catch (error) {
    if (isSupersededError(error)) {
      return { restored: [], skippedSuperseded: true };
    }
    throw error;
  }

  const discoveryErrors = [];
  const extraCleanupEntries = [];
  let maxCommittedEpochForRollback = 0;
  let latestSwitchoverTsForRollback = 0;
  try {
    const epochSummary = await computeGlobalCommittedEpochState(env, s3);
    maxCommittedEpochForRollback = epochSummary.maxCommittedEpoch;
    latestSwitchoverTsForRollback = epochSummary.latestCompletedSwitchoverTs;
  } catch (epochScanErr) {
    discoveryErrors.push(epochScanErr);
  }

  const isOwnRecordSuperseded = (stateDoc, sealDoc = null) => {
    const recEpoch = Math.max(
      Number.isSafeInteger(stateDoc?.ownerEpoch) ? stateDoc.ownerEpoch : 0,
      Number.isSafeInteger(sealDoc?.ownerEpoch) ? sealDoc.ownerEpoch : 0,
    );
    return maxCommittedEpochForRollback > 0 && recEpoch > 0 && recEpoch <= maxCommittedEpochForRollback;
  };

  const rawEntries = [];
  for (const entry of committedAliases) {
    if (entry?.optionalIfNoState && entry.stateKey) {
      let state = null;
      try {
        state = await readJsonStateOrNull(s3, entry.stateKey);
      } catch (optStateErr) {
        discoveryErrors.push(optStateErr);
      }
      if (state) {
        if (isOwnRecordSuperseded(state)) {
          extraCleanupEntries.push({
            aliasKey: state.aliasKey || entry.aliasKey || "",
            backupKey: entry.backupKey || state.backupKey || "",
            stateKey: entry.stateKey,
          });
          continue;
        }
        rawEntries.push({
          ...entry,
          stageKey: state.stageKey || entry.stageKey || "",
          hadExisting: Boolean(state.hadExisting),
          optionalIfNoState: false,
        });
        continue;
      }
      if (entry.backupKey) {
        try {
          const seal = await readJsonStateOrNull(s3, backupSealKey(entry.backupKey));
          if (seal && isOwnRecordSuperseded(null, seal)) {
            extraCleanupEntries.push({
              aliasKey: entry.aliasKey || "",
              backupKey: entry.backupKey,
              stateKey: entry.stateKey || "",
            });
            continue;
          }
          const backupHead = await s3.headObject(entry.backupKey);
          if (backupHead) {
            rawEntries.push({
              ...entry,
              hadExisting: true,
              optionalIfNoState: false,
            });
          }
        } catch (headErr) {
          discoveryErrors.push(headErr);
        }
      }
    } else {
      if (entry?.stateKey) {
        try {
          const state = await readJsonStateOrNull(s3, entry.stateKey);
          if (state && isOwnRecordSuperseded(state)) {
            extraCleanupEntries.push(entry);
            continue;
          }
        } catch (stErr) {
          discoveryErrors.push(stErr);
        }
      }
      rawEntries.push(entry);
    }
  }

  const entries = [...rawEntries];
  const seenAliases = new Set(entries.map((entry) => entry.aliasKey));
  const { stagePrefix, checkpointKey } = resolveBatchCheckpointKey(
    env,
    entries,
    options.stagePrefix,
  );

  if (stagePrefix) {
    // Never undo a switchover that already recorded _batch_committed.json or published latest/manifest; fail closed if unreadable.
    const switchoverCommitted = await readSwitchoverCommittedCheckpoint(env, stagePrefix, s3);
    if (switchoverCommitted?.completed === true) {
      for (const savedEntry of switchoverCommitted.entries || []) {
        if (savedEntry?.backupKey) {
          await s3.deleteObject(savedEntry.backupKey);
          await s3.deleteObject(backupSealKey(savedEntry.backupKey));
        }
        if (savedEntry?.stateKey) {
          await s3.deleteObject(savedEntry.stateKey);
        }
      }
      return { restored: [], skippedAlreadyCommitted: true };
    }
    const ownPublished = await hasStagePublishedLiveManifest(env, s3, stagePrefix);
    if (ownPublished.published) {
      let persistedCp = null;
      try {
        if (ownPublished.manifestStateDoc?.ownerEpoch > 0) {
          await advanceCommittedEpochLedger(env, s3, ownPublished.manifestStateDoc.ownerEpoch, {
            manifestSha256:
              options.expectedManifestSha256 ||
              ownPublished.manifestStateDoc?.targetManifestSha256 ||
              "",
            instanceId: options.instanceId || "",
          });
        }
        persistedCp = await recordSwitchoverCommittedCheckpoint(
          env,
          stagePrefix,
          [],
          {
            manifestSha256: options.expectedManifestSha256 || ownPublished.manifestStateDoc?.targetManifestSha256 || "",
            instanceId: options.instanceId || "",
            committedEpoch: ownPublished.manifestStateDoc?.ownerEpoch || 0,
            supersededBackupDirs: ownPublished.manifestStateDoc?.supersededBackupDirs || [],
            skipStageScan: true,
          },
          s3,
        );
      } catch {
        // Keep manifestStateKey intact if _batch_committed.json cannot be persisted yet.
      }
      try {
        const ownBackupObjs = await s3.listObjects(`${stagePrefix}/backups/`);
        const cpKey = switchoverCommittedKeyForStage(stagePrefix);
        for (const obj of ownBackupObjs) {
          if (
            !obj?.key ||
            obj.key === `${stagePrefix}/backups/` ||
            obj.key === cpKey ||
            (!persistedCp?.completed && obj.key === ownPublished.manifestStateKey)
          ) {
            continue;
          }
          await s3.deleteObject(obj.key, { beforeAttempt: checkOwner });
        }
      } catch {
        // Best-effort cleanup of already-published stage backups.
      }
      return { restored: [], skippedAlreadyCommitted: true };
    }

    let backupObjects = [];
    try {
      backupObjects = await s3.listObjects(`${stagePrefix}/backups/`);
    } catch (listErr) {
      discoveryErrors.push(listErr);
    }
    const supersededOwnBackupKeys = new Set();
    for (const object of backupObjects) {
      if (
        !object.key ||
        !object.key.endsWith(".state.json") ||
        object.key.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`) ||
        object.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`)
      ) {
        continue;
      }
      try {
        const state = await readJsonStateOrNull(s3, object.key);
        const derivedBkKey =
          state?.backupKey ||
          `${object.key.slice(0, -".state.json".length)}${ALIAS_ROLLBACK_SUFFIX}`;
        if (state && isOwnRecordSuperseded(state)) {
          supersededOwnBackupKeys.add(derivedBkKey);
          extraCleanupEntries.push({
            aliasKey: state.aliasKey || "",
            backupKey: derivedBkKey,
            stateKey: object.key,
          });
          continue;
        }
        if (state?.aliasKey && !seenAliases.has(state.aliasKey)) {
          seenAliases.add(state.aliasKey);
          entries.push({
            aliasKey: state.aliasKey,
            stageKey: state.stageKey || "",
            backupKey: derivedBkKey,
            stateKey: object.key,
            hadExisting: Boolean(state.hadExisting),
          });
        }
      } catch (stateReadErr) {
        discoveryErrors.push(stateReadErr);
      }
    }

    const coveredBackupKeys = new Set([
      ...entries.map((entry) => entry.backupKey).filter(Boolean),
      ...supersededOwnBackupKeys,
    ]);
    const unmatchedRollbacks = backupObjects.filter(
      (object) =>
        object.key &&
        object.key.endsWith(ALIAS_ROLLBACK_SUFFIX) &&
        !coveredBackupKeys.has(object.key),
    );
    if (unmatchedRollbacks.length > 0) {
      let stageCandidateKeys = [];
      let stageListFailed = false;
      try {
        const listedStageObjs = await s3.listObjects(`${stagePrefix}/objects/`);
        stageCandidateKeys = listedStageObjs
          .map((item) => item.key)
          .filter((key) => Boolean(key) && !key.endsWith("/"));
      } catch (stageListErr) {
        discoveryErrors.push(stageListErr);
        stageListFailed = true;
      }
      const knownAliasMap = await buildKnownAliasMapForStage(env, stagePrefix);
      for (const rbObj of unmatchedRollbacks) {
        try {
          const rbSeal = await readJsonStateOrNull(s3, backupSealKey(rbObj.key));
          if (rbSeal && isOwnRecordSuperseded(null, rbSeal)) {
            extraCleanupEntries.push({
              aliasKey: rbSeal.aliasKey || "",
              backupKey: rbObj.key,
              stateKey: `${rbObj.key.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`,
            });
            continue;
          }
          const rbTs = rbObj.lastModified instanceof Date ? rbObj.lastModified.getTime() : 0;
          if (
            !rbSeal &&
            latestSwitchoverTsForRollback > 0 &&
            rbTs > 0 &&
            rbTs < latestSwitchoverTsForRollback
          ) {
            continue;
          }
        } catch (sealErr) {
          discoveryErrors.push(sealErr);
          continue;
        }
        const inferredAlias = knownAliasMap.get(rbObj.key);
        if (inferredAlias && !seenAliases.has(inferredAlias)) {
          seenAliases.add(inferredAlias);
          entries.push({
            aliasKey: inferredAlias,
            backupKey: rbObj.key,
            stateKey: `${rbObj.key.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`,
            hadExisting: true,
            stageCandidateKeys,
            requireMissingStateProof: true,
            stageListFailed,
          });
        }
      }
    }
  }

  try {
    await reconcileOrphanBackupsForRollback(
      env,
      s3,
      stagePrefix,
      entries,
      seenAliases,
      extraCleanupEntries,
    );
  } catch (orphanErr) {
    discoveryErrors.push(orphanErr);
  }

  if (checkpointKey) {
    let checkpoint = null;
    try {
      checkpoint = await readJsonStateOrNull(s3, checkpointKey);
    } catch (cpReadErr) {
      discoveryErrors.push(cpReadErr);
    }
    if (checkpoint?.completed === true) {
      const cpCompletedTs = checkpoint.completedAt ? Date.parse(checkpoint.completedAt) : 0;
      const cpSuperseded =
        isOwnRecordSuperseded(checkpoint) ||
        (!checkpoint.ownerEpoch &&
          latestSwitchoverTsForRollback > 0 &&
          Number.isFinite(cpCompletedTs) &&
          cpCompletedTs > 0 &&
          cpCompletedTs < latestSwitchoverTsForRollback);
      if (cpSuperseded) {
        for (const savedEntry of checkpoint.entries || []) {
          if (savedEntry) {
            extraCleanupEntries.push(savedEntry);
          }
        }
        await s3.deleteObject(checkpointKey, { beforeAttempt: checkOwner });
        checkpoint = null;
      }
    }
    if (checkpoint?.completed === true) {
      for (const savedEntry of checkpoint.entries || []) {
        if (!savedEntry?.aliasKey) {
          continue;
        }
        const existingEntry = entries.find((item) => item.aliasKey === savedEntry.aliasKey);
        if (!existingEntry) {
          seenAliases.add(savedEntry.aliasKey);
          entries.push(savedEntry);
        } else if (savedEntry.backupVerified === true && existingEntry.backupVerified !== true) {
          existingEntry.backupVerified = true;
          existingEntry.backupSize = savedEntry.backupSize;
          existingEntry.backupEtag = savedEntry.backupEtag;
          existingEntry.backupSha256 = savedEntry.backupSha256;
          if (savedEntry.ignoreSyncHeader === true) {
            existingEntry.ignoreSyncHeader = true;
          }
        }
      }
      let anyRecommittedAfterCheckpoint = false;
      let cpVerifyFailed = false;
      let driftWithoutBackupError = null;
      for (const entry of entries) {
        try {
          const state = entry.stateKey ? await readJsonStateOrNull(s3, entry.stateKey) : null;
          if (state && state.restored === false) {
            anyRecommittedAfterCheckpoint = true;
            break;
          }
          if (!entry.hadExisting) {
            await s3.deleteObject(entry.aliasKey, { beforeAttempt: checkOwner });
            if (await s3.headObject(entry.aliasKey)) {
              cpVerifyFailed = true;
            }
          } else {
            const verifRec =
              state?.backupVerified === true
                ? state
                : entry?.backupVerified === true
                  ? entry
                  : null;
            if (verifRec) {
              const ok = await verifyObjectMatchesRecordedBackup(s3, entry.aliasKey, verifRec);
              if (!ok) {
                cpVerifyFailed = true;
                if (!entry.backupKey || !(await s3.headObject(entry.backupKey))) {
                  driftWithoutBackupError = new Error(
                    `Restored alias ${entry.aliasKey} drifted after backup ${entry.backupKey || "n/a"} was removed.`,
                  );
                }
              }
            } else {
              const live = await s3.headObject(entry.aliasKey);
              if (!live) {
                cpVerifyFailed = true;
              }
            }
          }
        } catch (verifyErr) {
          discoveryErrors.push(verifyErr);
          cpVerifyFailed = true;
        }
      }
      if (driftWithoutBackupError && !anyRecommittedAfterCheckpoint) {
        throw driftWithoutBackupError;
      }
      const allCpCleanup = [...entries, ...extraCleanupEntries];
      if (!anyRecommittedAfterCheckpoint && !cpVerifyFailed && discoveryErrors.length === 0) {
        for (const entry of allCpCleanup) {
          if (entry.backupKey) {
            await s3.deleteObject(entry.backupKey);
            await s3.deleteObject(backupSealKey(entry.backupKey));
          }
          if (entry.stateKey) {
            await s3.deleteObject(entry.stateKey);
          }
        }
        await s3.deleteObject(checkpointKey, {
          beforeAttempt: () =>
            assertNoRollbackArtifactsRemain(s3, allCpCleanup, stagePrefix, checkpointKey),
        });
        return {
          restored: Array.isArray(checkpoint.restored)
            ? checkpoint.restored
            : entries.map((entry) => entry.aliasKey),
        };
      }
      if (anyRecommittedAfterCheckpoint) {
        await s3.deleteObject(checkpointKey);
      }
    }
  }

  if (entries.length === 0) {
    if (discoveryErrors.length > 0) {
      throw discoveryErrors[0];
    }
    for (const staleEntry of extraCleanupEntries) {
      if (staleEntry?.backupKey) {
        await s3.deleteObject(staleEntry.backupKey, { beforeAttempt: checkOwner });
        await s3.deleteObject(backupSealKey(staleEntry.backupKey), { beforeAttempt: checkOwner });
      }
      if (staleEntry?.stateKey) {
        await s3.deleteObject(staleEntry.stateKey, { beforeAttempt: checkOwner });
      }
    }
    return { restored: [] };
  }

  const effectiveCheckpointKey =
    checkpointKey || resolveBatchCheckpointKey(env, entries, stagePrefix).checkpointKey;

  const restored = [];
  const verifiedEntryRecords = new Map();
  const rollbackErrors = [];
  for (const entry of [...entries].reverse()) {
    try {
      await checkOwner();
    } catch (error) {
      if (isSupersededError(error)) {
        return { restored, skippedSuperseded: true };
      }
      throw error;
    }
    try {
      if (entry.hadExisting) {
        const outcome = await restoreAliasFromBackup(s3, entry.aliasKey, entry.backupKey, {
          rethrow: true,
          keepBackupUntilBatchDone: true,
          stateKey: entry.stateKey,
          stageKey: entry.stageKey || "",
          stageCandidateKeys: entry.stageCandidateKeys || null,
          requireMissingStateProof: Boolean(entry.requireMissingStateProof),
          stageListFailed: Boolean(entry.stageListFailed),
          beforeMutate: checkOwner,
        });
        if (outcome?.verifiedMeta) {
          verifiedEntryRecords.set(entry.aliasKey, outcome.verifiedMeta);
        }
        if (!outcome?.skippedUnverified) {
          restored.push(entry.aliasKey);
        }
      } else {
        await s3.deleteObject(entry.aliasKey, { beforeAttempt: checkOwner });
        const stillLive = await s3.headObject(entry.aliasKey);
        if (stillLive) {
          throw new Error(`Rollback delete verification failed: ${entry.aliasKey} still exists.`);
        }
        if (entry.stateKey) {
          await writeRollbackState(
            s3,
            entry.stateKey,
            {
              aliasKey: entry.aliasKey,
              stageKey: entry.stageKey || "",
              backupKey: entry.backupKey,
              stateKey: entry.stateKey,
              hadExisting: false,
              ...(currentRollbackOwnerEpoch > 0 ? { ownerEpoch: currentRollbackOwnerEpoch } : {}),
              restored: true,
            },
            checkOwner,
          );
        }
        restored.push(entry.aliasKey);
      }
    } catch (entryError) {
      if (isSupersededError(entryError)) {
        return { restored, skippedSuperseded: true };
      }
      rollbackErrors.push(entryError);
    }
  }

  if (rollbackErrors.length > 0 || discoveryErrors.length > 0) {
    throw rollbackErrors[0] || discoveryErrors[0];
  }

  if (effectiveCheckpointKey) {
    await s3.putObject(
      effectiveCheckpointKey,
      utf8(
        JSON.stringify({
          completed: true,
          ...(currentRollbackOwnerEpoch > 0 ? { ownerEpoch: currentRollbackOwnerEpoch } : {}),
          restored,
          entries: entries.map((entry) => {
            const vMeta = verifiedEntryRecords.get(entry.aliasKey);
            return {
              aliasKey: entry.aliasKey,
              stageKey: entry.stageKey || "",
              backupKey: entry.backupKey,
              stateKey: entry.stateKey,
              hadExisting: Boolean(entry.hadExisting),
              ...(vMeta
                ? {
                    backupVerified: true,
                    backupSize: vMeta.backupSize,
                    backupEtag: vMeta.backupEtag,
                    backupSha256: vMeta.backupSha256,
                    ...(vMeta.ignoreSyncHeader ? { ignoreSyncHeader: true } : {}),
                  }
                : {}),
            };
          }),
          completedAt: new Date().toISOString(),
        }),
      ),
      {
        filename: BATCH_RESTORED_CHECKPOINT_NAME,
        contentType: "application/json",
        cacheControl: "no-store",
        beforeAttempt: checkOwner,
      },
    );
  }

  const allCleanupEntries = [...entries, ...extraCleanupEntries];
  for (const entry of allCleanupEntries) {
    if (entry.backupKey) {
      await s3.deleteObject(entry.backupKey);
      await s3.deleteObject(backupSealKey(entry.backupKey));
    }
    if (entry.stateKey) {
      await s3.deleteObject(entry.stateKey);
    }
  }
  if (effectiveCheckpointKey) {
    await s3.deleteObject(effectiveCheckpointKey, {
      beforeAttempt: () =>
        assertNoRollbackArtifactsRemain(s3, allCleanupEntries, stagePrefix, effectiveCheckpointKey),
    });
  }
  return { restored };
}

function rollbackArtifactRemainError(message) {
  const err = new Error(message);
  err.code = "ERR_ROLLBACK_ARTIFACTS_REMAIN";
  return err;
}

function isBackupDocSuperseded(
  docEpoch,
  dir,
  maxCommittedEpoch,
  legacySupersededDirs,
  ts = 0,
  latestCompletedSwitchoverTs = 0,
) {
  if (docEpoch > 0 && maxCommittedEpoch > 0) {
    return docEpoch <= maxCommittedEpoch;
  }
  if (dir && legacySupersededDirs.has(dir)) {
    return true;
  }
  if (docEpoch === 0 && latestCompletedSwitchoverTs > 0 && ts > 0 && ts < latestCompletedSwitchoverTs) {
    return true;
  }
  return false;
}

async function computeGlobalCommittedEpochState(env, s3, cleanExclude = "", listedOverride = null) {
  if (!hasS3Env(env)) {
    return {
      maxCommittedEpoch: 0,
      latestCompletedSwitchoverTs: 0,
      legacySupersededDirs: new Set(),
      byDir: new Map(),
      liveSecondaryManifestSha: "",
      effectivePublishedManifestSha: "",
    };
  }
  const stageRoot = `${effectiveStageRoot(env)}/`;
  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env.SECONDARY_S3_PREFIX || "");
  let liveSecondaryManifestSha = "";
  try {
    const liveManifestBytes = await s3.getObjectBytes(manifestAliasKey);
    liveSecondaryManifestSha = await sha256Hex(liveManifestBytes);
  } catch (manifestErr) {
    if (!isS3NotFoundError(manifestErr)) {
      throw manifestErr;
    }
  }
  let effectivePublishedManifestSha = liveSecondaryManifestSha;
  if (!effectivePublishedManifestSha && cleanExclude) {
    const exclManifestKeys = aliasBackupKeys("", manifestAliasKey, cleanExclude);
    const exclState = await readJsonStateOrNull(s3, exclManifestKeys.stateKey);
    const exclSeal =
      !exclState || exclState.backupVerified === undefined
        ? await readJsonStateOrNull(s3, backupSealKey(exclManifestKeys.backupKey))
        : null;
    const exclVerif =
      exclState?.backupVerified === true
        ? exclState
        : exclState?.backupVerified === false
          ? null
          : exclSeal?.backupVerified === true
            ? exclSeal
            : null;
    if (exclVerif?.backupSha256) {
      effectivePublishedManifestSha = String(exclVerif.backupSha256).toLowerCase();
    }
  }

  let maxCommittedEpoch = 0;
  const ledgerDoc = await readCommittedEpochLedger(env, s3);
  if (
    Number.isSafeInteger(ledgerDoc?.committedEpoch) &&
    ledgerDoc.committedEpoch > maxCommittedEpoch
  ) {
    maxCommittedEpoch = ledgerDoc.committedEpoch;
  }

  const excludeBackupsDir = cleanExclude ? `${cleanExclude}/backups/` : "";
  const objects = listedOverride || (await s3.listObjects(stageRoot));
  const byDir = new Map();
  for (const obj of objects) {
    if (!obj?.key) {
      continue;
    }
    const idx = obj.key.lastIndexOf("/backups/");
    if (idx === -1) {
      continue;
    }
    const dir = obj.key.slice(0, idx + "/backups/".length);
    if (!byDir.has(dir)) {
      byDir.set(dir, []);
    }
    byDir.get(dir).push(obj);
  }

  let latestCompletedSwitchoverTs = 0;
  const legacySupersededDirs = new Set();
  for (const [dir, dirObjs] of byDir.entries()) {
    const committedObj = dirObjs.find((o) => o.key === `${dir}${BATCH_COMMITTED_CHECKPOINT_NAME}`);
    if (committedObj) {
      const committedDoc = await readJsonStateOrNull(s3, committedObj.key);
      if (committedDoc?.completed === true || committedDoc?.priorRunSuperseded === true) {
        if (committedDoc.completed === true) {
          legacySupersededDirs.add(dir);
          const docTs = committedDoc.completedAt ? Date.parse(committedDoc.completedAt) : Number.NaN;
          const objTs =
            committedObj.lastModified instanceof Date ? committedObj.lastModified.getTime() : 0;
          const effectiveTs = Number.isFinite(docTs) ? Math.max(docTs, objTs) : objTs;
          if (effectiveTs > latestCompletedSwitchoverTs) {
            latestCompletedSwitchoverTs = effectiveTs;
          }
        }
        for (const supDir of committedDoc.supersededBackupDirs || []) {
          if (supDir) {
            legacySupersededDirs.add(supDir);
          }
        }
        if (
          Number.isSafeInteger(committedDoc.committedEpoch) &&
          committedDoc.committedEpoch > maxCommittedEpoch
        ) {
          maxCommittedEpoch = committedDoc.committedEpoch;
        }
        if (committedDoc.completed === true) {
          continue;
        }
      }
    }
    if (effectivePublishedManifestSha && dir !== excludeBackupsDir) {
      const dirStagePrefix = dir.slice(0, -"/backups/".length);
      const manifestStKey = aliasBackupKeys("", manifestAliasKey, dirStagePrefix).stateKey;
      if (dirObjs.some((o) => o.key === manifestStKey)) {
        const manifestStDoc = await readJsonStateOrNull(s3, manifestStKey);
        if (
          isPublishedManifestStateDoc(
            manifestStDoc,
            liveSecondaryManifestSha,
            effectivePublishedManifestSha,
          )
        ) {
          legacySupersededDirs.add(dir);
          for (const supDir of manifestStDoc.supersededBackupDirs || []) {
            if (supDir) {
              legacySupersededDirs.add(supDir);
            }
          }
          if (
            Number.isSafeInteger(manifestStDoc.ownerEpoch) &&
            manifestStDoc.ownerEpoch > maxCommittedEpoch
          ) {
            maxCommittedEpoch = manifestStDoc.ownerEpoch;
          }
          let dirMaxTs = 0;
          for (const dObj of dirObjs) {
            const t = dObj.lastModified instanceof Date ? dObj.lastModified.getTime() : 0;
            if (t > dirMaxTs) {
              dirMaxTs = t;
            }
          }
          if (dirMaxTs > latestCompletedSwitchoverTs) {
            latestCompletedSwitchoverTs = dirMaxTs;
          }
        }
      }
    }
  }

  return {
    maxCommittedEpoch,
    latestCompletedSwitchoverTs,
    legacySupersededDirs,
    byDir,
    liveSecondaryManifestSha,
    effectivePublishedManifestSha,
  };
}

async function listVerifiedUnrestoredOrphanBackups(env, s3, excludeStagePrefix = "") {
  if (!hasS3Env(env)) {
    return new Map();
  }
  const cleanExclude = cleanPrefix(excludeStagePrefix);
  const excludeBackupsDir = cleanExclude ? `${cleanExclude}/backups/` : "";
  const {
    maxCommittedEpoch,
    latestCompletedSwitchoverTs,
    legacySupersededDirs,
    byDir,
  } = await computeGlobalCommittedEpochState(env, s3, cleanExclude);

  const considerCandidate = (bestMap, cand) => {
    const prev = bestMap.get(cand.aliasKey);
    if (!prev) {
      bestMap.set(cand.aliasKey, cand);
      return;
    }
    if (cand.hadExisting === false && prev.hadExisting !== false) {
      if (cand.ts === 0 || prev.ts === 0 || cand.ts <= prev.ts) {
        bestMap.set(cand.aliasKey, cand);
      }
      return;
    }
    if (cand.hadExisting !== false && prev.hadExisting === false) {
      if (cand.ts > 0 && prev.ts > 0 && cand.ts < prev.ts) {
        bestMap.set(cand.aliasKey, cand);
      }
      return;
    }
    if (cand.ts > 0 && (prev.ts === 0 || cand.ts < prev.ts)) {
      bestMap.set(cand.aliasKey, cand);
      return;
    }
    if (cand.ts > 0 && cand.ts === prev.ts && !cand.fromOrphanAdoption && prev.fromOrphanAdoption) {
      bestMap.set(cand.aliasKey, cand);
    }
  };

  const bestByAlias = new Map();
  for (const [dir, dirObjs] of byDir.entries()) {
    if (dir === excludeBackupsDir) {
      continue;
    }
    const keySet = new Set(dirObjs.map((o) => o.key));
    const restoredKey = `${dir}${BATCH_RESTORED_CHECKPOINT_NAME}`;
    if (keySet.has(restoredKey)) {
      const restoredDoc = await readJsonStateOrNull(s3, restoredKey);
      if (restoredDoc?.completed === true) {
        continue;
      }
    }
    for (const obj of dirObjs) {
      if (obj.key.endsWith(ALIAS_ROLLBACK_SUFFIX)) {
        const ts = obj.lastModified instanceof Date ? obj.lastModified.getTime() : 0;
        const bkKey = obj.key;
        const stKey = `${bkKey.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`;
        const slKey = backupSealKey(bkKey);
        const stDoc = keySet.has(stKey) ? await readJsonStateOrNull(s3, stKey) : null;
        if (stDoc?.restored === true || stDoc?.backupVerified === false) {
          continue;
        }
        const slDoc =
          stDoc?.backupVerified === true
            ? stDoc
            : keySet.has(slKey)
              ? await readJsonStateOrNull(s3, slKey)
              : null;
        if (!slDoc || slDoc.backupVerified !== true || !slDoc.aliasKey || slDoc.hadExisting === false) {
          continue;
        }
        const docEpoch = Math.max(
          Number.isSafeInteger(slDoc.ownerEpoch) ? slDoc.ownerEpoch : 0,
          Number.isSafeInteger(stDoc?.ownerEpoch) ? stDoc.ownerEpoch : 0,
        );
        if (
          isBackupDocSuperseded(
            docEpoch,
            dir,
            maxCommittedEpoch,
            legacySupersededDirs,
            ts,
            latestCompletedSwitchoverTs,
          )
        ) {
          continue;
        }
        const valid = await verifyObjectMatchesRecordedBackup(s3, bkKey, slDoc);
        if (!valid) {
          continue;
        }
        considerCandidate(bestByAlias, {
          aliasKey: slDoc.aliasKey,
          backupKey: bkKey,
          stateKey: stKey,
          hadExisting: true,
          fromOrphanAdoption: Boolean(slDoc.fromOrphanAdoption || stDoc?.fromOrphanAdoption),
          sealDoc: slDoc,
          ts,
        });
      } else if (
        obj.key.endsWith(".state.json") &&
        obj.key !== `${dir}${BATCH_COMMITTED_CHECKPOINT_NAME}` &&
        obj.key !== `${dir}${BATCH_RESTORED_CHECKPOINT_NAME}`
      ) {
        const ts = obj.lastModified instanceof Date ? obj.lastModified.getTime() : 0;
        const stDoc = await readJsonStateOrNull(s3, obj.key);
        if (!stDoc || stDoc.hadExisting !== false || stDoc.restored === true || !stDoc.aliasKey) {
          continue;
        }
        const docEpoch = Number.isSafeInteger(stDoc.ownerEpoch) ? stDoc.ownerEpoch : 0;
        if (
          isBackupDocSuperseded(
            docEpoch,
            dir,
            maxCommittedEpoch,
            legacySupersededDirs,
            ts,
            latestCompletedSwitchoverTs,
          )
        ) {
          continue;
        }
        considerCandidate(bestByAlias, {
          aliasKey: stDoc.aliasKey,
          backupKey: "",
          stateKey: obj.key,
          hadExisting: false,
          fromOrphanAdoption: Boolean(stDoc.fromOrphanAdoption),
          sealDoc: null,
          ts,
        });
      }
    }
  }
  return bestByAlias;
}

async function findUnrestoredStageBackupForAlias(env, s3, aliasKey, currentStagePrefix = "") {
  const byAlias = await listVerifiedUnrestoredOrphanBackups(env, s3, currentStagePrefix);
  return byAlias.get(aliasKey) || null;
}

async function reconcileOrphanBackupsForRollback(
  env,
  s3,
  currentStagePrefix = "",
  entries = [],
  seenAliases = new Set(),
  extraCleanupEntries = [],
) {
  const byAlias = await listVerifiedUnrestoredOrphanBackups(env, s3, currentStagePrefix);
  for (const [aliasKey, cand] of byAlias.entries()) {
    const existingIdx = entries.findIndex((item) => item?.aliasKey === aliasKey);
    if (cand.hadExisting === false) {
      if (existingIdx !== -1) {
        const cur = entries[existingIdx];
        extraCleanupEntries.push(cur);
        if (cand.stateKey && cand.stateKey !== cur?.stateKey) {
          extraCleanupEntries.push({
            aliasKey,
            backupKey: "",
            stateKey: cand.stateKey,
            hadExisting: false,
          });
        }
        entries[existingIdx] = {
          aliasKey,
          backupKey: "",
          stateKey: cur?.stateKey || cand.stateKey,
          hadExisting: false,
        };
      } else {
        seenAliases.add(aliasKey);
        entries.push({
          aliasKey,
          backupKey: "",
          stateKey: cand.stateKey,
          hadExisting: false,
        });
      }
      continue;
    }
    if (existingIdx !== -1) {
      const cur = entries[existingIdx];
      const curState = cur.stateKey ? await readJsonStateOrNull(s3, cur.stateKey) : null;
      const curSeal =
        cur.backupKey && (!curState || curState.backupVerified === undefined)
          ? await readJsonStateOrNull(s3, backupSealKey(cur.backupKey))
          : null;
      const curHasVerifiedBackup = Boolean(
        (curState?.backupVerified === true ||
          (curState?.backupVerified !== false && curSeal?.backupVerified === true)) &&
          cur.backupKey &&
          (await s3.headObject(cur.backupKey)),
      );
      if (!curHasVerifiedBackup) {
        extraCleanupEntries.push(cur);
        entries[existingIdx] = {
          aliasKey,
          backupKey: cand.backupKey,
          stateKey: cand.stateKey,
          hadExisting: true,
        };
      }
      continue;
    }
    const live = await s3.headObject(aliasKey);
    if (!live || !(await verifyObjectMatchesRecordedBackup(s3, aliasKey, cand.sealDoc, live))) {
      seenAliases.add(aliasKey);
      entries.push({
        aliasKey,
        backupKey: cand.backupKey,
        stateKey: cand.stateKey,
        hadExisting: true,
      });
    }
  }
}

async function isWorkflowInstanceStrictlyActive(env, stageRoot, key, cache) {
  if (!env?.SECONDARY_MIRROR_WORKFLOW || !key.startsWith(stageRoot)) {
    return false;
  }
  const rest = key.slice(stageRoot.length).split("/");
  const instanceId = rest.length >= 2 ? rest[1] : "";
  if (!instanceId) {
    return false;
  }
  if (cache.has(instanceId)) {
    return cache.get(instanceId);
  }
  const inst = await getWorkflowIfExists(env, instanceId);
  if (!inst) {
    cache.set(instanceId, false);
    return false;
  }
  let status;
  try {
    status = await inst.status();
  } catch (error) {
    if (isWorkflowNotFoundError(error)) {
      cache.set(instanceId, false);
      return false;
    }
    throw error;
  }
  const active = isActiveWorkflowState(normalizeWorkflowState(status));
  cache.set(instanceId, active);
  return active;
}

async function readActiveOwnerPointerSafe(env, s3) {
  try {
    const raw = await s3.getObjectText(activeSyncPointerKey(env));
    return parseJsonAllowingBom(raw);
  } catch (err) {
    if (isS3NotFoundError(err) || err?.code === "ERR_INVALID_UTF8") {
      return null;
    }
    throw err;
  }
}

async function isActiveSuccessorInstance(env, stageRoot, key, activePointer, minEpoch, cache) {
  const strictlyActive = await isWorkflowInstanceStrictlyActive(env, stageRoot, key, cache);
  if (!strictlyActive) {
    return false;
  }
  const rest = key.slice(stageRoot.length).split("/");
  const instanceSeg = rest.length >= 2 ? rest[1] : "";
  if (!instanceSeg) {
    return false;
  }
  if (activePointer?.instanceId) {
    if (safeKeySegment(activePointer.instanceId) !== instanceSeg) {
      return false;
    }
    const ptrEpoch = Number.isSafeInteger(activePointer.epoch) ? activePointer.epoch : 0;
    if (minEpoch > 0 && ptrEpoch > 0 && ptrEpoch <= minEpoch) {
      return false;
    }
  } else if (minEpoch > 0) {
    return false;
  }
  return true;
}

async function assertNoSupersededBackupsRemain(env, s3, keepStagePrefix, committedDoc = null) {
  if (!hasS3Env(env)) {
    return;
  }
  const stageRoot = `${effectiveStageRoot(env)}/`;
  const cleanKeep = cleanPrefix(keepStagePrefix);
  const explicitSuperseded = new Set(committedDoc?.supersededBackupDirs || []);
  const committedEpoch = Math.max(
    Number.isSafeInteger(committedDoc?.committedEpoch) ? committedDoc.committedEpoch : 0,
    Number.isSafeInteger(committedDoc?.ownerEpoch) ? committedDoc.ownerEpoch : 0,
  );
  if (committedEpoch > 0) {
    try {
      const ledgerDoc = await advanceCommittedEpochLedger(env, s3, committedEpoch, {
        manifestSha256:
          committedDoc?.manifestSha256 || committedDoc?.targetManifestSha256 || "",
        releaseTag: committedDoc?.releaseTag || "",
      });
      const ledgerEpoch = Number.isSafeInteger(ledgerDoc?.committedEpoch)
        ? ledgerDoc.committedEpoch
        : 0;
      if (ledgerEpoch < committedEpoch) {
        throw rollbackArtifactRemainError(
          `Committed epoch ledger (${ledgerEpoch}) has not persisted ${committedEpoch} before checkpoint removal.`,
        );
      }
    } catch (ledgerErr) {
      if (ledgerErr?.code === "ERR_ROLLBACK_ARTIFACTS_REMAIN") {
        throw ledgerErr;
      }
      throw rollbackArtifactRemainError(
        `Cannot persist committed epoch ledger before checkpoint removal: ${ledgerErr.message}`,
      );
    }
  }
  const activeCache = new Map();
  let activePointer = null;
  let listed;
  try {
    activePointer = await readActiveOwnerPointerSafe(env, s3);
    listed = await s3.listObjects(stageRoot);
  } catch (err) {
    throw rollbackArtifactRemainError(
      `Cannot verify superseded backups before checkpoint removal: ${err.message}`,
    );
  }
  for (const obj of listed) {
    if (
      !obj?.key ||
      obj.key === activeSyncPointerKey(env) ||
      obj.key === committedStateLedgerKey(env) ||
      !obj.key.includes("/backups/") ||
      obj.key.endsWith("/") ||
      obj.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) ||
      obj.key.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`) ||
      (cleanKeep && (obj.key === cleanKeep || obj.key.startsWith(`${cleanKeep}/`)))
    ) {
      continue;
    }
    const idx = obj.key.lastIndexOf("/backups/");
    const dir = idx === -1 ? "" : obj.key.slice(0, idx + "/backups/".length);
    if (dir && explicitSuperseded.has(dir) && committedEpoch === 0) {
      throw rollbackArtifactRemainError(
        `Superseded backup artifact ${obj.key} remained before checkpoint removal.`,
      );
    }
    if (committedEpoch > 0) {
      try {
        const stKey = obj.key.endsWith(`${ALIAS_ROLLBACK_SUFFIX}.seal.json`)
          ? `${obj.key.slice(0, -`${ALIAS_ROLLBACK_SUFFIX}.seal.json`.length)}.state.json`
          : obj.key.endsWith(ALIAS_ROLLBACK_SUFFIX)
            ? `${obj.key.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`
            : obj.key.endsWith(".state.json")
              ? obj.key
              : "";
        if (stKey) {
          const stDoc = await readJsonStateOrNull(s3, stKey);
          const slKey = `${stKey.slice(0, -".state.json".length)}${ALIAS_ROLLBACK_SUFFIX}.seal.json`;
          const slDoc = !stDoc ? await readJsonStateOrNull(s3, slKey) : null;
          const docEpoch = Math.max(
            Number.isSafeInteger(stDoc?.ownerEpoch) ? stDoc.ownerEpoch : 0,
            Number.isSafeInteger(slDoc?.ownerEpoch) ? slDoc.ownerEpoch : 0,
          );
          if (docEpoch > committedEpoch) {
            continue;
          }
        }
      } catch (docReadErr) {
        throw rollbackArtifactRemainError(
          `Cannot inspect backup epoch for ${obj.key} before checkpoint removal: ${docReadErr.message}`,
        );
      }
    }
    let isActive = false;
    try {
      isActive = await isActiveSuccessorInstance(
        env,
        stageRoot,
        obj.key,
        activePointer,
        committedEpoch,
        activeCache,
      );
    } catch (statusErr) {
      throw rollbackArtifactRemainError(
        `Cannot verify workflow status for ${obj.key} before checkpoint removal: ${statusErr.message}`,
      );
    }
    if (!isActive) {
      throw rollbackArtifactRemainError(
        `Inactive orphan backup artifact ${obj.key} remained before checkpoint removal.`,
      );
    }
  }
}

async function purgeSupersededStageBackups(
  env,
  s3,
  keepStagePrefix = "",
  beforeMutate = null,
) {
  if (!hasS3Env(env)) {
    return [];
  }
  const stageRoot = `${effectiveStageRoot(env)}/`;
  const cleanKeep = cleanPrefix(keepStagePrefix);
  const activeCache = new Map();
  const purged = [];
  if (beforeMutate) {
    await beforeMutate();
  }
  const activePointer = await readActiveOwnerPointerSafe(env, s3);
  const keepEpoch = Number.isSafeInteger(activePointer?.epoch) ? activePointer.epoch : 0;
  const objects = await s3.listObjects(stageRoot);
  for (const obj of objects) {
    if (
      !obj?.key ||
      obj.key === activeSyncPointerKey(env) ||
      obj.key === committedStateLedgerKey(env)
    ) {
      continue;
    }
    if (cleanKeep && (obj.key === cleanKeep || obj.key.startsWith(`${cleanKeep}/`))) {
      continue;
    }
    if (!obj.key.includes("/backups/")) {
      continue;
    }
    if (
      await isActiveSuccessorInstance(
        env,
        stageRoot,
        obj.key,
        activePointer,
        keepEpoch,
        activeCache,
      )
    ) {
      continue;
    }
    await s3.deleteObject(obj.key, { beforeAttempt: beforeMutate });
    purged.push(obj.key);
  }
  if (beforeMutate) {
    await beforeMutate();
  }
  const afterPointer = await readActiveOwnerPointerSafe(env, s3);
  const after = await s3.listObjects(stageRoot);
  for (const obj of after) {
    if (
      !obj?.key ||
      !obj.key.includes("/backups/") ||
      obj.key.endsWith("/") ||
      (cleanKeep && (obj.key === cleanKeep || obj.key.startsWith(`${cleanKeep}/`)))
    ) {
      continue;
    }
    if (
      await isActiveSuccessorInstance(
        env,
        stageRoot,
        obj.key,
        afterPointer,
        keepEpoch,
        activeCache,
      )
    ) {
      continue;
    }
    throw new Error(`Superseded backup artifact ${obj.key} remained after switchover purge.`);
  }
  return purged;
}

async function assertNoRollbackArtifactsRemain(s3, entries, stagePrefix, checkpointKey) {
  for (const entry of entries) {
    if (entry?.backupKey && (await s3.headObject(entry.backupKey))) {
      throw rollbackArtifactRemainError(
        `Rollback backup ${entry.backupKey} reappeared before checkpoint removal.`,
      );
    }
    if (entry?.backupKey && (await s3.headObject(backupSealKey(entry.backupKey)))) {
      throw rollbackArtifactRemainError(
        `Rollback seal ${backupSealKey(entry.backupKey)} remained before checkpoint removal.`,
      );
    }
    if (entry?.stateKey && (await s3.headObject(entry.stateKey))) {
      throw rollbackArtifactRemainError(
        `Rollback state ${entry.stateKey} remained before checkpoint removal.`,
      );
    }
  }
  if (stagePrefix) {
    const remaining = await s3.listObjects(`${stagePrefix}/backups/`);
    const unexpected = remaining.find(
      (item) =>
        item.key &&
        item.key !== `${stagePrefix}/backups/` &&
        item.key !== checkpointKey,
    );
    if (unexpected) {
      throw rollbackArtifactRemainError(
        `Unexpected object ${unexpected.key} remained under ${stagePrefix}/backups/ before checkpoint removal.`,
      );
    }
  }
}

export async function cleanupRollbackBackups(env, committedAliases, options = {}) {
  const s3 = createS3Client(env);
  const resolvedStagePrefix = cleanPrefix(
    options.stagePrefix ||
      committedAliases.map((entry) => stagePrefixFromBackupKey(entry?.backupKey)).find(Boolean) ||
      "",
  );
  if (resolvedStagePrefix) {
    await recordSwitchoverCommittedCheckpoint(
      env,
      resolvedStagePrefix,
      committedAliases,
      {
        manifestSha256: options.expectedManifestSha256 || "",
        instanceId: options.instanceId || "",
      },
      s3,
    );
  }
  const deleted = [];
  for (const entry of committedAliases) {
    const isPerInstanceBackup = String(entry.backupKey || "").includes("/backups/");
    if (!isPerInstanceBackup && (options.expectedManifestSha256 || options.instanceId)) {
      await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
        instanceId: options.instanceId,
        s3,
        requirePointer: Boolean(options.instanceId),
      });
    }
    await s3.deleteObject(entry.backupKey);
    deleted.push(entry.backupKey);
    if (entry.backupKey) {
      await s3.deleteObject(backupSealKey(entry.backupKey));
      deleted.push(backupSealKey(entry.backupKey));
    }
    if (entry.stateKey) {
      await s3.deleteObject(entry.stateKey);
      deleted.push(entry.stateKey);
    }
  }
  if (options.purgeSupersededOrphans && resolvedStagePrefix) {
    const assertPurgeOwner =
      options.expectedManifestSha256 || options.instanceId
        ? () =>
            verifySourceManifestCurrent(env, options.expectedManifestSha256, {
              instanceId: options.instanceId,
              s3,
              requirePointer: Boolean(options.instanceId),
            })
        : null;
    const purgedOrphans = await purgeSupersededStageBackups(
      env,
      s3,
      resolvedStagePrefix,
      assertPurgeOwner,
    );
    deleted.push(...purgedOrphans);
  }
  return { deleted };
}

async function restoreAliasFromBackup(
  s3,
  aliasKey,
  backupKey,
  {
    rethrow = false,
    keepBackupUntilBatchDone = false,
    stateKey = "",
    stageKey = "",
    stageCandidateKeys = null,
    requireMissingStateProof = false,
    stageListFailed = false,
    beforeMutate = null,
  } = {},
) {
  try {
    const sealKey = backupSealKey(backupKey);
    let prior = null;
    let sealDoc = null;
    let priorStateReadErr = null;
    if (stateKey) {
      try {
        prior = await readJsonStateOrNull(s3, stateKey);
      } catch (readErr) {
        priorStateReadErr = readErr;
      }
    }
    if (sealKey && (!prior || prior.backupVerified === undefined)) {
      try {
        sealDoc = await readJsonStateOrNull(s3, sealKey);
      } catch (sealErr) {
        if (!priorStateReadErr) {
          priorStateReadErr = sealErr;
        }
      }
    }
    const verifRecord =
      prior?.backupVerified === true
        ? prior
        : prior?.backupVerified === false
          ? null
          : sealDoc?.backupVerified === true
            ? sealDoc
            : null;
    if (prior?.restored === true && !priorStateReadErr) {
      const liveNow = await s3.headObject(aliasKey);
      if (
        liveNow &&
        (verifRecord
          ? await verifyObjectMatchesRecordedBackup(s3, aliasKey, verifRecord, liveNow)
          : false)
      ) {
        return {
          restored: false,
          alreadyRestored: true,
          verifiedMeta: {
            backupSize: verifRecord.backupSize,
            backupEtag: verifRecord.backupEtag || "",
            backupSha256: verifRecord.backupSha256 || "",
            ...(verifRecord.ignoreSyncHeader ? { ignoreSyncHeader: true } : {}),
          },
        };
      }
    }
    if (prior && prior.backupVerified === false) {
      try {
        await s3.deleteObject(backupKey, { beforeAttempt: beforeMutate });
        if (sealKey) {
          await s3.deleteObject(sealKey, { beforeAttempt: beforeMutate });
        }
      } catch {
        // Best-effort cleanup of unverified backup while leaving live alias untouched.
      }
      if (keepBackupUntilBatchDone) {
        await writeRollbackState(
          s3,
          stateKey,
          {
            ...prior,
            restored: true,
          },
          beforeMutate,
        );
      } else if (stateKey) {
        await s3.deleteObject(stateKey, { beforeAttempt: beforeMutate });
      }
      return { restored: false, skippedUnverified: true };
    }
    const backup = await s3.headObject(backupKey);
    if (!backup) {
      if (priorStateReadErr) {
        throw priorStateReadErr;
      }
      if (rethrow) {
        throw new Error(`Missing rollback backup object ${backupKey} while restoring ${aliasKey}.`);
      }
      return { restored: false };
    }
    const liveAlias = await s3.headObject(aliasKey);
    if (priorStateReadErr && liveAlias) {
      throw priorStateReadErr;
    }
    if (!verifRecord && !priorStateReadErr && liveAlias) {
      if (!keepBackupUntilBatchDone) {
        try {
          await s3.deleteObject(backupKey, { beforeAttempt: beforeMutate });
        } catch {
          // Best-effort cleanup of unverified backup while preserving live alias.
        }
      }
      return { restored: false, skippedUnverified: true };
    }
    if (
      verifRecord &&
      !(await verifyObjectMatchesRecordedBackup(s3, backupKey, verifRecord, backup))
    ) {
      throw new Error(
        `Rollback backup ${backupKey} failed recorded metadata verification for ${aliasKey}.`,
      );
    }
    if (
      verifRecord &&
      liveAlias &&
      (await verifyObjectMatchesRecordedBackup(s3, aliasKey, verifRecord, liveAlias))
    ) {
      const recShaAlready = String(verifRecord.backupSha256 || "").trim().toLowerCase();
      const alreadyIgnoreSync = Boolean(
        verifRecord.ignoreSyncHeader ||
          (!liveAlias.fromListFallback &&
            liveAlias.syncSha256 &&
            recShaAlready &&
            liveAlias.syncSha256 !== recShaAlready),
      );
      const alreadyMeta = {
        backupSize: verifRecord.backupSize,
        backupEtag: verifRecord.backupEtag || liveAlias.etag || "",
        backupSha256: verifRecord.backupSha256 || "",
        ...(alreadyIgnoreSync ? { ignoreSyncHeader: true } : {}),
      };
      if (stateKey) {
        await writeRollbackState(
          s3,
          stateKey,
          {
            aliasKey,
            stageKey,
            backupKey,
            stateKey,
            hadExisting: true,
            backupVerified: true,
            ...alreadyMeta,
            restored: true,
          },
          beforeMutate,
        );
      }
      if (!keepBackupUntilBatchDone) {
        await s3.deleteObject(backupKey);
        if (sealKey) {
          await s3.deleteObject(sealKey);
        }
        if (stateKey) {
          await s3.deleteObject(stateKey);
        }
      }
      return { restored: false, alreadyRestored: true, verifiedMeta: alreadyMeta };
    }
    if (beforeMutate) {
      await beforeMutate();
    }
    await s3.deleteObject(aliasKey, { beforeAttempt: beforeMutate });
    const recSha = String(verifRecord?.backupSha256 || "").trim().toLowerCase();
    const sourceIgnoreSync = Boolean(
      verifRecord?.ignoreSyncHeader ||
        (!backup.fromListFallback &&
          backup.syncSha256 &&
          ((backup.bodySha256 && backup.syncSha256 !== backup.bodySha256) ||
            (recSha && backup.syncSha256 !== recSha))),
    );
    const restoreCopy = await s3.copyObject(backupKey, aliasKey, {
      expectedSize: backup.contentLength,
      expectedSyncSha256: sourceIgnoreSync ? "" : backup.syncSha256,
      expectedEtag: backup.etag,
      disableHeadShortcut: sourceIgnoreSync,
      beforeMutate,
    });
    const verified = await s3.headObject(aliasKey);
    const ignoreBackupSyncHeader = Boolean(
      sourceIgnoreSync ||
        (verified &&
          !verified.fromListFallback &&
          verified.syncSha256 &&
          ((verified.bodySha256 && verified.syncSha256 !== verified.bodySha256) ||
            (recSha && verified.syncSha256 !== recSha))),
    );
    let rawRestoredSha = "";
    if (ignoreBackupSyncHeader) {
      const rawCheck = await verifyRawByteCopy(
        s3,
        backupKey,
        aliasKey,
        backup,
        verified,
        restoreCopy?.copyEtag,
        recSha,
      );
      if (!rawCheck.ok) {
        throw new Error(`Rollback verification failed after restoring ${backupKey} -> ${aliasKey}.`);
      }
      rawRestoredSha = rawCheck.sha256;
    } else if (
      !(await verifyPostCopy(
        s3,
        aliasKey,
        verified,
        backup,
        restoreCopy?.copyEtag,
        recSha || backup.bodySha256 || "",
      ))
    ) {
      throw new Error(`Rollback verification failed after restoring ${backupKey} -> ${aliasKey}.`);
    }
    let resolvedSha =
      recSha ||
      rawRestoredSha ||
      verified.bodySha256 ||
      backup.bodySha256 ||
      (!verified.fromListFallback && verified.syncSha256) ||
      (!backup.fromListFallback && backup.syncSha256) ||
      "";
    if (!resolvedSha) {
      resolvedSha = (await s3.streamObjectDigest(aliasKey)).sha256;
    }
    const verifiedMeta = {
      backupSize: backup.contentLength,
      backupEtag: verified.etag || restoreCopy?.copyEtag || backup.etag || "",
      backupSha256: resolvedSha,
      ...(ignoreBackupSyncHeader ? { ignoreSyncHeader: true } : {}),
    };
    if (stateKey) {
      await writeRollbackState(
        s3,
        stateKey,
        {
          aliasKey,
          stageKey,
          backupKey,
          stateKey,
          hadExisting: true,
          backupVerified: true,
          ...verifiedMeta,
          restored: true,
        },
        beforeMutate,
      );
    }
    if (!keepBackupUntilBatchDone) {
      await s3.deleteObject(backupKey);
      if (sealKey) {
        await s3.deleteObject(sealKey);
      }
      if (stateKey) {
        await s3.deleteObject(stateKey);
      }
    }
    return { restored: true, verifiedMeta };
  } catch (restoreError) {
    if (isSupersededError(restoreError)) {
      throw restoreError;
    }
    // 备份留在原处，供下一次重试还原。
    console.error(
      JSON.stringify({
        event: "secondary_alias_restore_failed",
        aliasKey,
        backupKey,
        error: restoreError.message,
      }),
    );
    if (rethrow) {
      throw restoreError;
    }
  }
}

export async function cleanupStageObjects(env, items, stagePrefixOverride = "", options = {}) {
  if (stagePrefixOverride && typeof stagePrefixOverride === "object") {
    options = stagePrefixOverride;
    stagePrefixOverride = options.stagePrefix || "";
  }
  const s3 = createS3Client(env);
  const deleted = [];
  for (const item of items) {
    await s3.deleteObject(item.stageKey);
    deleted.push(item.stageKey);
  }
  const stagePrefix = cleanPrefix(stagePrefixOverride || stagePrefixFromItems(items));
  if (stagePrefix) {
    let retainedUnrestoredBackups = Boolean(options.preserveBackups);
    if (!options.preserveBackups) {
      let backupObjects = null;
      try {
        backupObjects = await s3.listObjects(`${stagePrefix}/backups/`);
      } catch (listErr) {
        if (options.switchoverComplete) {
          throw listErr;
        }
        retainedUnrestoredBackups = true;
      }
      if (backupObjects !== null) {
        const committedCheckpointKey = switchoverCommittedKeyForStage(stagePrefix);
        let committedDoc = await readSwitchoverCommittedCheckpoint(env, stagePrefix, s3);
        const isCommittedSwitchover =
          Boolean(options.switchoverComplete) || Boolean(committedDoc?.completed);
        if (isCommittedSwitchover) {
          const manifestAliasKey = withSecondaryPrefix(
            "latest/manifest",
            env?.SECONDARY_S3_PREFIX || "",
          );
          const manifestDet = aliasBackupKeys("", manifestAliasKey, stagePrefix);
          if (!committedDoc?.completed && options.switchoverComplete) {
            try {
              committedDoc = await recordSwitchoverCommittedCheckpoint(
                env,
                stagePrefix,
                [],
                {
                  manifestSha256: options.expectedManifestSha256 || "",
                  instanceId: options.instanceId || "",
                  skipStageScan: true,
                },
                s3,
              );
            } catch {
              // Best-effort checkpoint persist during failure cleanup; manifest state is preserved below.
            }
          }
          const keysToDelete = new Set();
          for (const leftover of backupObjects) {
            if (
              leftover.key &&
              leftover.key !== `${stagePrefix}/backups/` &&
              leftover.key !== committedCheckpointKey
            ) {
              keysToDelete.add(leftover.key);
            }
          }
          for (const entry of committedDoc?.entries || []) {
            if (entry?.backupKey) {
              keysToDelete.add(entry.backupKey);
              keysToDelete.add(backupSealKey(entry.backupKey));
            }
            if (entry?.stateKey) {
              keysToDelete.add(entry.stateKey);
            }
          }
          for (const item of items) {
            for (const aliasKey of item.aliasKeys || []) {
              const det = aliasBackupKeys(item.stageKey, aliasKey, stagePrefix);
              if (det.perInstance) {
                keysToDelete.add(det.backupKey);
                keysToDelete.add(backupSealKey(det.backupKey));
                keysToDelete.add(det.stateKey);
              }
            }
          }
          keysToDelete.delete(committedCheckpointKey);
          if (!committedDoc?.completed) {
            keysToDelete.delete(manifestDet.stateKey);
            retainedUnrestoredBackups = true;
          }
          for (const key of keysToDelete) {
            await s3.deleteObject(key);
            deleted.push(key);
          }
          const committedCheckEntries = [...(committedDoc?.entries || [])];
          for (const item of items) {
            for (const aliasKey of item.aliasKeys || []) {
              const det = aliasBackupKeys(item.stageKey, aliasKey, stagePrefix);
              if (det.perInstance) {
                committedCheckEntries.push({
                  aliasKey,
                  backupKey: det.backupKey,
                  stateKey: det.stateKey,
                });
              }
            }
          }
          if (committedCheckpointKey && committedDoc?.completed) {
            try {
              await s3.deleteObject(committedCheckpointKey, {
                beforeAttempt: async () => {
                  await assertNoRollbackArtifactsRemain(
                    s3,
                    committedCheckEntries,
                    stagePrefix,
                    committedCheckpointKey,
                  );
                  await assertNoSupersededBackupsRemain(env, s3, stagePrefix, committedDoc);
                },
              });
              deleted.push(committedCheckpointKey);
            } catch (delCommittedErr) {
              if (delCommittedErr?.code === "ERR_ROLLBACK_ARTIFACTS_REMAIN") {
                retainedUnrestoredBackups = true;
              } else {
                throw delCommittedErr;
              }
            }
          }
        } else {
          const hasPriorSupersededGuard = Boolean(committedDoc?.priorRunSuperseded);
          const stateCache = new Map();
          const getStateSafe = async (stateKey) => {
            if (stateCache.has(stateKey)) {
              return stateCache.get(stateKey);
            }
            try {
              const parsed = await readJsonStateOrNull(s3, stateKey);
              stateCache.set(stateKey, { ok: true, state: parsed });
              return { ok: true, state: parsed };
            } catch {
              stateCache.set(stateKey, { ok: false, state: null });
              return { ok: false, state: null };
            }
          };
          const deletableKeys = [];
          for (const leftover of backupObjects) {
            const key = leftover.key;
            if (!key || key === `${stagePrefix}/backups/`) {
              continue;
            }
            if (key.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`)) {
              continue;
            }
            if (hasPriorSupersededGuard && key === committedCheckpointKey) {
              continue;
            }
            let stateKey = "";
            if (key.endsWith(`${ALIAS_ROLLBACK_SUFFIX}.seal.json`)) {
              stateKey = `${key.slice(0, -`${ALIAS_ROLLBACK_SUFFIX}.seal.json`.length)}.state.json`;
            } else if (key.endsWith(ALIAS_ROLLBACK_SUFFIX)) {
              stateKey = `${key.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`;
            } else if (key.endsWith(".state.json")) {
              stateKey = key;
            }
            if (stateKey) {
              const { ok, state } = await getStateSafe(stateKey);
              if (!ok || !state || state.restored !== true) {
                retainedUnrestoredBackups = true;
                continue;
              }
            }
            deletableKeys.push(key);
          }
          for (const key of deletableKeys) {
            await s3.deleteObject(key);
            deleted.push(key);
          }
          const checkpointKey = `${stagePrefix}/backups/${BATCH_RESTORED_CHECKPOINT_NAME}`;
          let restoredDoc = null;
          try {
            restoredDoc = await readJsonStateOrNull(s3, checkpointKey);
          } catch {
            retainedUnrestoredBackups = true;
          }
          if (!retainedUnrestoredBackups && restoredDoc?.completed === true) {
            for (const entry of restoredDoc.entries || []) {
              if (entry?.stateKey) {
                const { ok, state } = await getStateSafe(entry.stateKey);
                if (!ok || (state && state.restored !== true)) {
                  retainedUnrestoredBackups = true;
                  continue;
                }
              }
              if (entry?.backupKey) {
                await s3.deleteObject(entry.backupKey);
                deleted.push(entry.backupKey);
                await s3.deleteObject(backupSealKey(entry.backupKey));
                deleted.push(backupSealKey(entry.backupKey));
              }
              if (entry?.stateKey) {
                await s3.deleteObject(entry.stateKey);
                deleted.push(entry.stateKey);
              }
            }
            for (const entry of restoredDoc.entries || []) {
              if (entry?.backupKey && (await s3.headObject(entry.backupKey))) {
                retainedUnrestoredBackups = true;
                break;
              }
              if (entry?.backupKey && (await s3.headObject(backupSealKey(entry.backupKey)))) {
                retainedUnrestoredBackups = true;
                break;
              }
              if (entry?.stateKey && (await s3.headObject(entry.stateKey))) {
                retainedUnrestoredBackups = true;
                break;
              }
            }
          }
          const checkEntries = [...(restoredDoc?.entries || [])];
          for (const item of items) {
            for (const aliasKey of item.aliasKeys || []) {
              const det = aliasBackupKeys(item.stageKey, aliasKey, stagePrefix);
              if (det.perInstance) {
                checkEntries.push({
                  aliasKey,
                  backupKey: det.backupKey,
                  stateKey: det.stateKey,
                });
              }
            }
          }
          if (
            !retainedUnrestoredBackups &&
            (restoredDoc !== null || backupObjects.some((entry) => entry.key === checkpointKey))
          ) {
            try {
              await s3.deleteObject(checkpointKey, {
                beforeAttempt: async () => {
                  for (const entry of checkEntries) {
                    if (entry?.backupKey && (await s3.headObject(entry.backupKey))) {
                      throw rollbackArtifactRemainError(
                        `Rollback backup ${entry.backupKey} reappeared before checkpoint removal.`,
                      );
                    }
                    if (entry?.backupKey && (await s3.headObject(backupSealKey(entry.backupKey)))) {
                      throw rollbackArtifactRemainError(
                        `Rollback seal ${backupSealKey(entry.backupKey)} remained before checkpoint removal.`,
                      );
                    }
                    if (entry?.stateKey && (await s3.headObject(entry.stateKey))) {
                      throw rollbackArtifactRemainError(
                        `Rollback state ${entry.stateKey} remained before checkpoint removal.`,
                      );
                    }
                  }
                  const rem = await s3.listObjects(`${stagePrefix}/backups/`);
                  const unexp = rem.find(
                    (it) =>
                      it.key &&
                      it.key !== `${stagePrefix}/backups/` &&
                      it.key !== checkpointKey &&
                      !(hasPriorSupersededGuard && it.key === committedCheckpointKey),
                  );
                  if (unexp) {
                    throw rollbackArtifactRemainError(
                      `Unexpected object ${unexp.key} remained under ${stagePrefix}/backups/ before checkpoint removal.`,
                    );
                  }
                },
              });
              deleted.push(checkpointKey);
            } catch (delCpErr) {
              if (delCpErr?.code === "ERR_ROLLBACK_ARTIFACTS_REMAIN") {
                retainedUnrestoredBackups = true;
              } else {
                throw delCpErr;
              }
            }
          }
          if (hasPriorSupersededGuard && committedCheckpointKey) {
            if (retainedUnrestoredBackups) {
              retainedUnrestoredBackups = true;
            } else {
              try {
                await s3.deleteObject(committedCheckpointKey, {
                  beforeAttempt: async () => {
                    await assertNoRollbackArtifactsRemain(
                      s3,
                      checkEntries,
                      stagePrefix,
                      committedCheckpointKey,
                    );
                    await assertNoSupersededBackupsRemain(env, s3, stagePrefix, committedDoc);
                  },
                });
                deleted.push(committedCheckpointKey);
              } catch (delPriorCpErr) {
                if (delPriorCpErr?.code === "ERR_ROLLBACK_ARTIFACTS_REMAIN") {
                  retainedUnrestoredBackups = true;
                } else {
                  throw delPriorCpErr;
                }
              }
            }
          }
        }
      }
      if (!retainedUnrestoredBackups) {
        await s3.deleteObject(`${stagePrefix}/backups/`);
        deleted.push(`${stagePrefix}/backups/`);
      }
    }
    await s3.deleteObject(`${stagePrefix}/objects/`);
    deleted.push(`${stagePrefix}/objects/`);
    if (!retainedUnrestoredBackups) {
      await s3.deleteObject(`${stagePrefix}/`);
      deleted.push(`${stagePrefix}/`);
    }
  }
  return { deleted };
}

export async function deleteStaleAliasObjects(env, keys, options = {}) {
  const s3 = createS3Client(env);
  const checkOwner = async () => {
    if (options.expectedManifestSha256 || options.instanceId) {
      await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
        instanceId: options.instanceId,
        s3,
        requirePointer: Boolean(options.instanceId),
      });
    }
  };
  const deleted = [];
  for (const key of keys) {
    await s3.deleteObject(key, { beforeAttempt: checkOwner });
    deleted.push(key);
  }
  return { deleted };
}

function stagePrefixFromKey(stageKey) {
  const key = String(stageKey || "");
  const marker = "/objects/";
  const index = key.lastIndexOf(marker);
  return index === -1 ? "" : key.slice(0, index);
}

function stagePrefixFromItems(items) {
  return stagePrefixFromKey(items[0]?.stageKey || "");
}

export async function pruneStaleLatestMacObjects(env, keepKeys, options = {}) {
  const s3 = createS3Client(env);
  if (options.expectedManifestSha256 || options.instanceId) {
    await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
      instanceId: options.instanceId,
      s3,
      requirePointer: Boolean(options.instanceId),
    });
  }
  const graceDays = parseNonNegativeInteger(
    options.graceDays ?? env.SECONDARY_SYNC_PRUNE_GRACE_DAYS,
    DEFAULT_PRUNE_GRACE_DAYS,
  );
  const cutoff = Date.now() - graceDays * 86400 * 1000;
  const keep = new Set(keepKeys);
  const listPrefix = withSecondaryPrefix("latest/mac/", env.SECONDARY_S3_PREFIX || "");
  const objects = await s3.listObjects(listPrefix);
  const pruned = [];

  for (const object of objects) {
    if (!object.key || object.key.endsWith("/")) {
      continue;
    }
    if (keep.has(object.key)) {
      continue;
    }
    if (!object.lastModified || Number.isNaN(object.lastModified.getTime())) {
      continue;
    }
    if (object.lastModified.getTime() >= cutoff) {
      continue;
    }
    await s3.deleteObject(object.key, {
      beforeAttempt: async () => {
        if (options.expectedManifestSha256 || options.instanceId) {
          await verifySourceManifestCurrent(env, options.expectedManifestSha256, {
            instanceId: options.instanceId,
            s3,
            requirePointer: Boolean(options.instanceId),
          });
        }
      },
    });
    pruned.push(object.key);
  }

  return { pruned, graceDays };
}

export async function pruneAbandonedStageObjects(env, keepStagePrefix = "", options = {}) {
  const s3 = createS3Client(env);
  const stageRoot = `${effectiveStageRoot(env)}/`;
  const pointerKey = activeSyncPointerKey(env);
  const ledgerKey = committedStateLedgerKey(env);
  const graceHours = parseNonNegativeInteger(
    options.graceHours ?? env.SECONDARY_SYNC_STAGE_GRACE_HOURS,
    DEFAULT_STAGE_GRACE_HOURS,
  );
  const cutoff = Date.now() - graceHours * 60 * 60 * 1000;
  const activeInstanceCache = new Map();
  const backupDirRetainCache = new Map();
  const deleted = [];
  const aborted = [];

  const skippedBackupsPrefixes = new Set();
  const deferredCheckpoints = [];
  const deferredMarkers = [];
  const listedStageObjects = await s3.listObjects(stageRoot);
  const legacySupersededDirs = new Set();
  const publishedManifestGuardKeys = new Set();
  let maxCommittedEpoch = 0;
  try {
    const ledgerDoc = await readCommittedEpochLedger(env, s3);
    if (
      Number.isSafeInteger(ledgerDoc?.committedEpoch) &&
      ledgerDoc.committedEpoch > maxCommittedEpoch
    ) {
      maxCommittedEpoch = ledgerDoc.committedEpoch;
    }
  } catch {
    // Ignore transient ledger read error during pre-scan; backup retention fails closed.
  }
  const manifestAliasKey = withSecondaryPrefix("latest/manifest", env.SECONDARY_S3_PREFIX || "");
  let liveManifestSha = "";
  try {
    const liveBytes = await s3.getObjectBytes(manifestAliasKey);
    liveManifestSha = await sha256Hex(liveBytes);
  } catch {
    // Ignore missing or unreadable live manifest during pruning pre-scan.
  }
  const listedKeySet = new Set(listedStageObjects.map((o) => o?.key).filter(Boolean));
  for (const obj of listedStageObjects) {
    if (!obj?.key) {
      continue;
    }
    if (obj.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`)) {
      try {
        const doc = await readJsonStateOrNull(s3, obj.key);
        if (doc?.completed === true || doc?.priorRunSuperseded === true) {
          for (const supDir of doc.supersededBackupDirs || []) {
            if (supDir) {
              legacySupersededDirs.add(supDir);
            }
          }
          if (Number.isSafeInteger(doc.committedEpoch) && doc.committedEpoch > maxCommittedEpoch) {
            maxCommittedEpoch = doc.committedEpoch;
          }
        }
      } catch {
        // Ignore unreadable checkpoint during pre-scan; deferredCheckpoints handles retention.
      }
      continue;
    }
    if (liveManifestSha && obj.key.endsWith(".state.json") && obj.key.includes("/backups/")) {
      const idx = obj.key.lastIndexOf("/backups/");
      const dirStagePrefix = obj.key.slice(0, idx);
      const manifestStKey = aliasBackupKeys("", manifestAliasKey, dirStagePrefix).stateKey;
      if (obj.key === manifestStKey) {
        try {
          const stDoc = await readJsonStateOrNull(s3, obj.key);
          if (isPublishedManifestStateDoc(stDoc, liveManifestSha)) {
            const dirCpKey = `${dirStagePrefix}/backups/${BATCH_COMMITTED_CHECKPOINT_NAME}`;
            if (!listedKeySet.has(dirCpKey)) {
              publishedManifestGuardKeys.add(obj.key);
            }
            for (const supDir of stDoc.supersededBackupDirs || []) {
              if (supDir) {
                legacySupersededDirs.add(supDir);
              }
            }
            if (Number.isSafeInteger(stDoc.ownerEpoch) && stDoc.ownerEpoch > maxCommittedEpoch) {
              maxCommittedEpoch = stDoc.ownerEpoch;
            }
          }
        } catch {
          // Ignore unreadable state during pre-scan; backup retention preserves it safely.
        }
      }
    }
  }
  for (const object of listedStageObjects) {
    if (object.key === pointerKey || object.key === ledgerKey) {
      continue;
    }
    const backupsIdx = object.key ? object.key.lastIndexOf("/backups/") : -1;
    const objBackupsPrefix =
      backupsIdx === -1 ? "" : object.key.slice(0, backupsIdx + "/backups/".length);
    if (!isAbandonedStageEntry(object.key, object.lastModified, keepStagePrefix, cutoff)) {
      if (objBackupsPrefix && object.key !== objBackupsPrefix) {
        skippedBackupsPrefixes.add(objBackupsPrefix);
      }
      continue;
    }
    if (await belongsToActiveWorkflow(env, stageRoot, object.key, activeInstanceCache)) {
      if (objBackupsPrefix && object.key !== objBackupsPrefix) {
        skippedBackupsPrefixes.add(objBackupsPrefix);
      }
      continue;
    }
    if (publishedManifestGuardKeys.has(object.key)) {
      deferredCheckpoints.push(object.key);
      continue;
    }
    if (
      await isUnrestoredStageBackupObject(
        s3,
        object.key,
        backupDirRetainCache,
        maxCommittedEpoch,
        legacySupersededDirs,
        publishedManifestGuardKeys,
      )
    ) {
      if (objBackupsPrefix) {
        skippedBackupsPrefixes.add(objBackupsPrefix);
      }
      continue;
    }
    if (
      object.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) ||
      object.key.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`) ||
      object.key.includes("/rollback-checkpoints/")
    ) {
      deferredCheckpoints.push(object.key);
      continue;
    }
    if (object.key.endsWith("/")) {
      deferredMarkers.push(object.key);
      continue;
    }
    await s3.deleteObject(object.key);
    deleted.push(object.key);
  }
  for (const cpKey of deferredCheckpoints) {
    const cpBackupsIdx = cpKey.lastIndexOf("/backups/");
    const cpBackupsPrefix =
      cpBackupsIdx !== -1 ? cpKey.slice(0, cpBackupsIdx + "/backups/".length) : "";
    const cpStagePrefix = cpBackupsIdx !== -1 ? cpKey.slice(0, cpBackupsIdx) : "";
    let cpDoc = null;
    try {
      cpDoc = await readJsonStateOrNull(s3, cpKey);
    } catch {
      if (cpBackupsPrefix) {
        skippedBackupsPrefixes.add(cpBackupsPrefix);
      }
      continue;
    }
    const isCommittedGuard =
      cpKey.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) ||
      publishedManifestGuardKeys.has(cpKey);
    if (cpDoc && !publishedManifestGuardKeys.has(cpKey)) {
      let recordedBackupRemains = false;
      try {
        for (const entry of cpDoc.entries || []) {
          if (entry?.backupKey && (await s3.headObject(entry.backupKey))) {
            recordedBackupRemains = true;
            break;
          }
          if (entry?.backupKey && (await s3.headObject(backupSealKey(entry.backupKey)))) {
            recordedBackupRemains = true;
            break;
          }
          if (entry?.stateKey && (await s3.headObject(entry.stateKey))) {
            recordedBackupRemains = true;
            break;
          }
        }
        if (!recordedBackupRemains) {
          const cpEpoch = Math.max(
            Number.isSafeInteger(cpDoc.committedEpoch) ? cpDoc.committedEpoch : 0,
            Number.isSafeInteger(cpDoc.ownerEpoch) ? cpDoc.ownerEpoch : 0,
          );
          if (cpEpoch === 0) {
            for (const supDir of cpDoc.supersededBackupDirs || []) {
              if (!supDir) {
                continue;
              }
              if (skippedBackupsPrefixes.has(supDir)) {
                recordedBackupRemains = true;
                break;
              }
              const supRem = await s3.listObjects(supDir);
              if (supRem.some((item) => item.key && item.key !== supDir)) {
                recordedBackupRemains = true;
                break;
              }
            }
          }
        }
      } catch {
        if (cpBackupsPrefix) {
          skippedBackupsPrefixes.add(cpBackupsPrefix);
        }
        continue;
      }
      if (recordedBackupRemains) {
        if (cpBackupsPrefix) {
          skippedBackupsPrefixes.add(cpBackupsPrefix);
        }
        continue;
      }
    }
    if (cpBackupsIdx !== -1) {
      if (skippedBackupsPrefixes.has(cpBackupsPrefix)) {
        continue;
      }
      try {
        const remaining = await s3.listObjects(cpBackupsPrefix);
        if (!remaining.some((entry) => entry.key === cpKey)) {
          continue;
        }
        const hasRemainingBackups = remaining.some(
          (entry) =>
            entry.key &&
            entry.key !== cpBackupsPrefix &&
            entry.key !== cpKey &&
            !entry.key.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) &&
            !entry.key.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`),
        );
        if (hasRemainingBackups) {
          skippedBackupsPrefixes.add(cpBackupsPrefix);
          continue;
        }
      } catch {
        skippedBackupsPrefixes.add(cpBackupsPrefix);
        continue;
      }
    }
    if (isCommittedGuard) {
      try {
        await s3.deleteObject(cpKey, {
          beforeAttempt: () => assertNoSupersededBackupsRemain(env, s3, cpStagePrefix, cpDoc),
        });
        deleted.push(cpKey);
      } catch (guardErr) {
        if (cpBackupsPrefix) {
          skippedBackupsPrefixes.add(cpBackupsPrefix);
        }
        if (guardErr?.code !== "ERR_ROLLBACK_ARTIFACTS_REMAIN") {
          throw guardErr;
        }
      }
      continue;
    }
    await s3.deleteObject(cpKey);
    deleted.push(cpKey);
  }
  for (const markerKey of deferredMarkers) {
    const markerBackupsIdx = markerKey.lastIndexOf("/backups/");
    if (
      markerBackupsIdx !== -1 &&
      skippedBackupsPrefixes.has(markerKey.slice(0, markerBackupsIdx + "/backups/".length))
    ) {
      continue;
    }
    await s3.deleteObject(markerKey);
    deleted.push(markerKey);
  }

  for (const upload of await s3.listMultipartUploads(stageRoot)) {
    if (!isAbandonedStageEntry(upload.key, upload.initiated, keepStagePrefix, cutoff)) {
      continue;
    }
    if (await belongsToActiveWorkflow(env, stageRoot, upload.key, activeInstanceCache)) {
      continue;
    }
    await s3.abortMultipartUpload(upload.key, upload.uploadId);
    aborted.push({ key: upload.key, uploadId: upload.uploadId });
  }

  return { deleted, aborted, graceHours };
}

async function isUnrestoredStageBackupObject(
  s3,
  key,
  backupDirRetainCache = new Map(),
  maxCommittedEpoch = 0,
  legacySupersededDirs = new Set(),
  publishedManifestGuardKeys = new Set(),
) {
  if (!key || !key.includes("/backups/")) {
    return false;
  }
  const backupsMarker = "/backups/";
  const backupsIdx = key.lastIndexOf(backupsMarker);
  const backupsPrefix = `${key.slice(0, backupsIdx + backupsMarker.length)}`;
  if (backupDirRetainCache.has(backupsPrefix)) {
    const cached = backupDirRetainCache.get(backupsPrefix);
    if (cached.retain) {
      return true;
    }
    if (!key.endsWith("/") && (!cached.keys || !cached.keys.has(key))) {
      cached.retain = true;
      return true;
    }
    return false;
  }
  try {
    const entries = await s3.listObjects(backupsPrefix);
    const listedKeys = new Set(entries.map((item) => item.key).filter(Boolean));
    if (!key.endsWith("/") && !listedKeys.has(key)) {
      backupDirRetainCache.set(backupsPrefix, { retain: true, keys: null });
      return true;
    }
    const committedKey = `${backupsPrefix}${BATCH_COMMITTED_CHECKPOINT_NAME}`;
    let dirCommittedCompleted = false;
    if (listedKeys.has(committedKey)) {
      const committed = await readJsonStateOrNull(s3, committedKey);
      if (committed?.completed === true) {
        dirCommittedCompleted = true;
      }
    }
    const dirHasPublishedGuard = entries.some(
      (item) => item?.key && publishedManifestGuardKeys.has(item.key),
    );
    let retainAllInDir = false;
    for (const item of entries) {
      const k = item.key;
      if (
        !k ||
        k === backupsPrefix ||
        k.endsWith(`/${BATCH_RESTORED_CHECKPOINT_NAME}`) ||
        k.endsWith(`/${BATCH_COMMITTED_CHECKPOINT_NAME}`) ||
        publishedManifestGuardKeys.has(k)
      ) {
        continue;
      }
      const stateKey = k.endsWith(`${ALIAS_ROLLBACK_SUFFIX}.seal.json`)
        ? `${k.slice(0, -`${ALIAS_ROLLBACK_SUFFIX}.seal.json`.length)}.state.json`
        : k.endsWith(ALIAS_ROLLBACK_SUFFIX)
          ? `${k.slice(0, -ALIAS_ROLLBACK_SUFFIX.length)}.state.json`
          : k.endsWith(".state.json")
            ? k
            : "";
      if (!stateKey) {
        continue;
      }
      const state = listedKeys.has(stateKey) ? await readJsonStateOrNull(s3, stateKey) : null;
      const sealKey = `${stateKey.slice(0, -".state.json".length)}${ALIAS_ROLLBACK_SUFFIX}.seal.json`;
      const seal =
        !state && listedKeys.has(sealKey) ? await readJsonStateOrNull(s3, sealKey) : null;
      const docEpoch = Math.max(
        Number.isSafeInteger(state?.ownerEpoch) ? state.ownerEpoch : 0,
        Number.isSafeInteger(seal?.ownerEpoch) ? seal.ownerEpoch : 0,
      );
      if (docEpoch > 0 && maxCommittedEpoch > 0) {
        if (docEpoch <= maxCommittedEpoch) {
          continue;
        }
      } else if (
        dirCommittedCompleted ||
        dirHasPublishedGuard ||
        legacySupersededDirs.has(backupsPrefix)
      ) {
        continue;
      }
      if (!state || state.restored !== true) {
        retainAllInDir = true;
        break;
      }
    }
    backupDirRetainCache.set(backupsPrefix, { retain: retainAllInDir, keys: listedKeys });
    return retainAllInDir;
  } catch {
    backupDirRetainCache.set(backupsPrefix, { retain: true, keys: null });
    return true;
  }
}

async function belongsToActiveWorkflow(env, stageRoot, key, cache) {
  if (!env?.SECONDARY_MIRROR_WORKFLOW || !key.startsWith(stageRoot)) {
    return false;
  }
  const rest = key.slice(stageRoot.length).split("/");
  // Staging keys follow <stageRoot><safeTag>/<safeInstanceId>/objects/<name>.
  const instanceId = rest.length >= 2 ? rest[1] : "";
  if (!instanceId) {
    return false;
  }
  if (cache.has(instanceId)) {
    return cache.get(instanceId);
  }
  try {
    const inst = await getWorkflowIfExists(env, instanceId);
    if (!inst) {
      cache.set(instanceId, false);
      return false;
    }
    const status = await inst.status();
    const active = isActiveWorkflowState(normalizeWorkflowState(status));
    cache.set(instanceId, active);
    return active;
  } catch (error) {
    if (isWorkflowNotFoundError(error)) {
      cache.set(instanceId, false);
      return false;
    }
    // Fail safe on transient Workflow RPC errors without caching permanent false.
    return true;
  }
}

function isAbandonedStageEntry(key, timestamp, keepStagePrefix, cutoff) {
  if (!key || !timestamp || Number.isNaN(timestamp.getTime())) {
    return false;
  }
  const keepPrefix = cleanPrefix(keepStagePrefix);
  if (keepPrefix && (key === keepPrefix || key.startsWith(`${keepPrefix}/`))) {
    return false;
  }
  return timestamp.getTime() < cutoff;
}

export function decoratePlanWithStage(plan, instanceId, env = {}) {
  const safeTag = safeKeySegment(plan.releaseTag);
  const safeInstance = safeKeySegment(instanceId);
  const stagePrefix = effectiveStageRoot(env);
  const fullStagePrefix = `${stagePrefix}/${safeTag}/${safeInstance}`;
  return {
    ...plan,
    stagePrefix: fullStagePrefix,
    items: plan.items.map((item) => ({
      ...item,
      stageKey: `${fullStagePrefix}/objects/${flatStageName(item)}`,
    })),
  };
}

function flatStageName(item) {
  const label = safeKeySegment(item.id).slice(0, 72);
  return `${label}-${fnv1a(item.stageRelativeKey)}`;
}

export function commitOrder(items) {
  return [...items].sort((left, right) => {
    const rank = roleRank(left.role) - roleRank(right.role);
    if (rank !== 0) {
      return rank;
    }
    return left.id.localeCompare(right.id);
  });
}

function roleRank(role) {
  switch (role) {
    case "installer":
      return 10;
    case "archive":
      return 20;
    case "delta":
      return 21;
    case "checksums":
      return 90;
    case "appcast":
      return 40;
    case "manifest":
      return 100;
    default:
      return 50;
  }
}

async function multipartUploadFromR2(env, s3, item, size, partSize, expectedR2Etag = "") {
  const hasher = createIncrementalSha256();
  const uploadMetadata = item.expectedSha256 ? { ...item, syncSha256: item.expectedSha256 } : item;
  const uploadId = await s3.createMultipartUpload(item.stageKey, uploadMetadata);
  const parts = [];
  try {
    const totalParts = Math.ceil(size / partSize);
    for (let partNumber = 1; partNumber <= totalParts; partNumber += 1) {
      const offset = (partNumber - 1) * partSize;
      const length = Math.min(partSize, size - offset);
      const data = await readR2ObjectRange(env, item.sourceKey, offset, length, expectedR2Etag);
      hasher.update(new Uint8Array(data));
      const etag = await s3.uploadPart(item.stageKey, uploadId, partNumber, data);
      parts.push({ partNumber, etag });
    }
    const computedSha256 = hasher.digestHex();
    if (item.expectedSha256 && computedSha256 !== item.expectedSha256) {
      throw new Error(
        `R2 multipart object ${item.sourceKey} SHA-256 mismatch: expected ${item.expectedSha256}, got ${computedSha256}.`,
      );
    }
    await s3.completeMultipartUpload(item.stageKey, uploadId, parts);
    return computedSha256;
  } catch (error) {
    try {
      await s3.abortMultipartUpload(item.stageKey, uploadId);
    } catch (abortError) {
      console.error(
        JSON.stringify({
          event: "secondary_multipart_abort_failed",
          key: item.stageKey,
          uploadId,
          error: abortError.message,
        }),
      );
    }
    throw error;
  }
}

function r2ObjectEtag(object) {
  return String(object?.etag || object?.httpEtag || "").replace(/^W\//, "").replace(/^"|"$/g, "");
}

async function headR2Object(env, key) {
  const object = await env.GLOBAL_R2.head(key);
  if (!object) {
    return null;
  }
  return { size: object.size, etag: r2ObjectEtag(object) };
}

async function readR2ObjectRange(env, key, offset, length, expectedEtag = "") {
  const retryBaseDelayMs = parseNonNegativeInteger(
    env.SECONDARY_S3_RETRY_BASE_DELAY_MS,
    DEFAULT_S3_RETRY_BASE_DELAY_MS,
  );
  const retryMaxDelayMs = parseNonNegativeInteger(
    env.SECONDARY_S3_RETRY_MAX_DELAY_MS,
    DEFAULT_S3_RETRY_MAX_DELAY_MS,
  );
  let lastError = null;

  for (let attempt = 1; attempt <= DEFAULT_R2_MAX_ATTEMPTS; attempt += 1) {
    try {
      const options = {};
      if (length > 0) {
        options.range = { offset, length };
      }
      if (expectedEtag) {
        options.onlyIf = { etagMatches: expectedEtag };
      }
      const object = await env.GLOBAL_R2.get(
        key,
        Object.keys(options).length > 0 ? options : undefined,
      );
      if (!object) {
        throw new NonRetryableMirrorError(`R2 object disappeared while syncing: ${key}`);
      }
      if (expectedEtag) {
        const actualEtag = r2ObjectEtag(object);
        if (typeof object.arrayBuffer !== "function" || (actualEtag && actualEtag !== expectedEtag)) {
          throw new NonRetryableMirrorError(
            `R2 object ${key} changed mid-transfer (expected ETag ${expectedEtag}, got ${actualEtag || "precondition-failed"}).`,
          );
        }
      }
      const buffer = await object.arrayBuffer();
      if (length > 0 && buffer.byteLength !== length) {
        throw new Error(
          `R2 range read for ${key} [${offset}, +${length}) returned ${buffer.byteLength} bytes.`,
        );
      }
      return buffer;
    } catch (error) {
      if (error instanceof NonRetryableMirrorError || attempt >= DEFAULT_R2_MAX_ATTEMPTS) {
        throw error;
      }
      lastError = error;
      await sleepMs(computeRetryDelayMs(attempt, retryBaseDelayMs, retryMaxDelayMs));
    }
  }

  throw lastError || new Error(`Failed reading R2 object ${key}.`);
}

export function createS3Client(env) {
  return new S3Client({
    endpoint: requiredEnv(env, "SECONDARY_S3_ENDPOINT"),
    bucket: requiredEnv(env, "SECONDARY_S3_BUCKET"),
    region: env.SECONDARY_S3_REGION || "auto",
    accessKeyId: requiredEnv(env, "SECONDARY_S3_ACCESS_KEY_ID"),
    secretAccessKey: requiredEnv(env, "SECONDARY_S3_SECRET_ACCESS_KEY"),
    maxAttempts: parsePositiveInteger(env.SECONDARY_S3_MAX_ATTEMPTS, DEFAULT_S3_MAX_ATTEMPTS),
    retryBaseDelayMs: parseNonNegativeInteger(
      env.SECONDARY_S3_RETRY_BASE_DELAY_MS,
      DEFAULT_S3_RETRY_BASE_DELAY_MS,
    ),
    retryMaxDelayMs: parseNonNegativeInteger(
      env.SECONDARY_S3_RETRY_MAX_DELAY_MS,
      DEFAULT_S3_RETRY_MAX_DELAY_MS,
    ),
    requestTimeoutMs: parseNonNegativeInteger(
      env.SECONDARY_S3_REQUEST_TIMEOUT_MS,
      DEFAULT_S3_REQUEST_TIMEOUT_MS,
    ),
    copyTimeoutMs: parseNonNegativeInteger(
      env.SECONDARY_S3_COPY_TIMEOUT_MS,
      DEFAULT_S3_COPY_TIMEOUT_MS,
    ),
  });
}

export class S3Client {
  constructor(options) {
    this.endpoint = options.endpoint;
    this.bucket = options.bucket;
    this.region = options.region || "auto";
    this.accessKeyId = options.accessKeyId;
    this.secretAccessKey = options.secretAccessKey;
    this.maxAttempts = parsePositiveInteger(options.maxAttempts, DEFAULT_S3_MAX_ATTEMPTS);
    this.retryBaseDelayMs = parseNonNegativeInteger(
      options.retryBaseDelayMs,
      DEFAULT_S3_RETRY_BASE_DELAY_MS,
    );
    this.retryMaxDelayMs = parseNonNegativeInteger(
      options.retryMaxDelayMs,
      DEFAULT_S3_RETRY_MAX_DELAY_MS,
    );
    this.requestTimeoutMs = parseNonNegativeInteger(
      options.requestTimeoutMs,
      DEFAULT_S3_REQUEST_TIMEOUT_MS,
    );
    this.copyTimeoutMs = parseNonNegativeInteger(
      options.copyTimeoutMs,
      DEFAULT_S3_COPY_TIMEOUT_MS,
    );
  }

  async headObject(key) {
    const response = await this.request({ method: "HEAD", key, expectOk: false });
    if (response.status === 404) {
      return null;
    }
    if (response.status === 403) {
      const listed = await this.findObjectByKey(key);
      if (listed) {
        return {
          key,
          contentLength: listed.size,
          etag: listed.etag || "",
          syncSha256: "",
          fromListFallback: true,
          lastModified: listed.lastModified,
        };
      }
      const probe = await this.request({
        method: "GET",
        key,
        headers: { range: "bytes=0-0" },
        expectOk: false,
        operation: "GET PROBE",
        targetLabel: key,
      });
      if (probe.status === 404) {
        await cancelResponseBody(probe);
        return null;
      }
      if (probe.status === 416) {
        const probeSha = (probe.headers.get(SYNC_SHA256_HEADER) || "").trim().toLowerCase();
        await cancelResponseBody(probe);
        return {
          key,
          contentLength: 0,
          etag: probe.headers.get("etag") || "",
          syncSha256: probeSha,
          fromListFallback: !probeSha && !probe.headers.get("etag"),
          lastModified: parseHttpDate(probe.headers.get("last-modified")),
        };
      }
      await assertOk(probe, "GET PROBE", key);
      const contentRange = probe.headers.get("content-range") || "";
      const rangeMatch = /\/(\d+)\s*$/.exec(contentRange);
      const probeSha = (probe.headers.get(SYNC_SHA256_HEADER) || "").trim().toLowerCase();
      const probeEtag = probe.headers.get("etag") || "";
      let probedLength = rangeMatch
        ? Number.parseInt(rangeMatch[1], 10)
        : probe.status === 206
          ? Number.NaN
          : Number.parseInt(probe.headers.get("content-length") || "", 10);
      let bodySha256 = "";
      if (probe.status === 206 && !rangeMatch) {
        await cancelResponseBody(probe);
        const streamed = await this.streamObjectDigest(key);
        probedLength = streamed.byteLength;
        bodySha256 = streamed.sha256;
      } else if (probe.status === 200 && !rangeMatch && !probeSha && !probeEtag) {
        const streamed = await streamResponseDigest(probe);
        probedLength = streamed.byteLength;
        bodySha256 = streamed.sha256;
      } else if (!Number.isFinite(probedLength)) {
        const streamed = await streamResponseDigest(probe);
        probedLength = streamed.byteLength;
        if (probe.status === 200 && !rangeMatch) {
          bodySha256 = streamed.sha256;
        }
      } else {
        await cancelResponseBody(probe);
      }
      return {
        key,
        contentLength: probedLength,
        etag: probeEtag,
        syncSha256: probeSha,
        bodySha256,
        fromListFallback: !probeSha,
        lastModified: parseHttpDate(probe.headers.get("last-modified")),
      };
    }
    await assertOk(response, "HEAD", key);
    const syncSha256 = (response.headers.get(SYNC_SHA256_HEADER) || "").trim().toLowerCase();
    const contentLength = Number.parseInt(response.headers.get("content-length") || "0", 10);
    if (contentLength === 0) {
      const listed = await this.findObjectByKey(key);
      if (listed && listed.size > 0) {
        return {
          key,
          contentLength: listed.size,
          etag: response.headers.get("etag") || listed.etag || "",
          syncSha256,
          fromListFallback: !syncSha256,
          lastModified: listed.lastModified,
        };
      }
    }
    return {
      key,
      contentLength,
      etag: response.headers.get("etag") || "",
      syncSha256,
      lastModified: parseHttpDate(response.headers.get("last-modified")),
    };
  }

  async findObjectByKey(key) {
    const objects = await this.listObjects(key);
    return objects.find((object) => object.key === key) || null;
  }

  async streamObjectDigest(key) {
    const response = await this.request({ method: "GET", key, expectOk: false });
    if (response.status === 404) {
      await cancelResponseBody(response);
      const notFoundErr = new Error(`S3 GET ${key} failed with HTTP 404.`);
      notFoundErr.httpStatus = 404;
      throw notFoundErr;
    }
    await assertOk(response, "GET", key);
    return streamResponseDigest(response);
  }

  async getObjectBytes(key) {
    const response = await this.request({ method: "GET", key, expectOk: false });
    if (response.status === 404) {
      await cancelResponseBody(response);
      const notFoundErr = new Error(`S3 GET ${key} failed with HTTP 404.`);
      notFoundErr.httpStatus = 404;
      throw notFoundErr;
    }
    await assertOk(response, "GET", key);
    return new Uint8Array(await response.arrayBuffer());
  }

  async getObjectText(key) {
    return decodeStrictUtf8(await this.getObjectBytes(key));
  }

  async putObject(key, body, metadata) {
    return this.request({
      method: "PUT",
      key,
      headers: objectMetadataHeaders(metadata),
      body,
      operation: "PUT",
      targetLabel: key,
      beforeAttempt: metadata?.beforeAttempt || null,
    });
  }

  async createMultipartUpload(key, metadata) {
    const targetLabel = `${key}?uploads`;
    const response = await this.request({
      method: "POST",
      key,
      query: [["uploads", ""]],
      headers: objectMetadataHeaders(metadata),
      operation: "POST",
      targetLabel,
    });
    const xml = decodeStrictUtf8(await response.arrayBuffer());
    const root = parseS3XmlRoot(xml, "InitiateMultipartUploadResult", "POST", targetLabel);
    const uploadId = xmlElementText(root, "UploadId");
    if (!uploadId) {
      throw new Error(`S3 create multipart response for ${key} did not include UploadId.`);
    }
    return uploadId;
  }

  async uploadPart(key, uploadId, partNumber, body) {
    const response = await this.request({
      method: "PUT",
      key,
      query: [
        ["partNumber", String(partNumber)],
        ["uploadId", uploadId],
      ],
      body,
      operation: "PUT",
      targetLabel: `${key} part ${partNumber}`,
    });
    const etag = response.headers.get("etag");
    if (!etag) {
      throw new Error(`S3 upload part response for ${key} part ${partNumber} did not include ETag.`);
    }
    return etag;
  }

  async completeMultipartUpload(key, uploadId, parts) {
    const body = completeMultipartXml(parts);
    const targetLabel = `${key}?uploadId=${uploadId}`;
    const response = await this.request({
      method: "POST",
      key,
      query: [["uploadId", uploadId]],
      headers: {
        "content-type": "application/xml",
      },
      body,
      operation: "POST",
      targetLabel,
    });
    const xml = decodeStrictUtf8(await response.arrayBuffer());
    parseS3XmlRoot(xml, "CompleteMultipartUploadResult", "COMPLETE MULTIPART", targetLabel);
    return xml;
  }

  async abortMultipartUpload(key, uploadId) {
    const response = await this.request({
      method: "DELETE",
      key,
      query: [["uploadId", uploadId]],
      expectOk: false,
      operation: "DELETE",
      targetLabel: `${key}?uploadId=${uploadId}`,
    });
    if (response.status === 404) {
      return response;
    }
    await assertOk(response, "DELETE", `${key}?uploadId=${uploadId}`);
    return response;
  }

  async listMultipartUploads(prefix) {
    const uploads = [];
    let keyMarker = "";
    let uploadIdMarker = "";
    do {
      const query = [
        ["uploads", ""],
        ["prefix", prefix],
      ];
      if (keyMarker) {
        query.push(["key-marker", keyMarker]);
      }
      if (uploadIdMarker) {
        query.push(["upload-id-marker", uploadIdMarker]);
      }
      const response = await this.request({
        method: "GET",
        key: "",
        query,
        operation: "LIST MULTIPART",
        targetLabel: prefix,
      });
      const xml = decodeStrictUtf8(await response.arrayBuffer());
      const parsedPage = parseS3ListMultipartXml(xml, prefix);
      uploads.push(...parsedPage.uploads);
      keyMarker = parsedPage.nextKeyMarker;
      uploadIdMarker = parsedPage.nextUploadIdMarker;
    } while (keyMarker);
    return uploads;
  }

  async copyObject(
    sourceKey,
    destinationKey,
    {
      expectedSize,
      expectedSyncSha256 = "",
      expectedEtag = "",
      disableHeadShortcut = false,
      beforeMutate = null,
    } = {},
  ) {
    const attempts = Math.max(1, Math.min(this.maxAttempts, DEFAULT_S3_COPY_MAX_ATTEMPTS));
    const expectation = { expectedSize, expectedSyncSha256, expectedEtag };
    const targetLabel = `${sourceKey} -> ${destinationKey}`;
    let lastError = null;
    let forceOverwriteOnRetry = false;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      if (attempt > 1) {
        const existingDest = await this.headObject(destinationKey);
        if (existingDest) {
          if (
            !disableHeadShortcut &&
            !forceOverwriteOnRetry &&
            expectedSize !== undefined &&
            matchesExpectedTarget(existingDest, expectation)
          ) {
            return { copyEtag: existingDest.etag || "" };
          }
          await this.deleteObject(destinationKey, { beforeAttempt: beforeMutate });
        }
        forceOverwriteOnRetry = false;
      }

      try {
        const response = await this.request({
          method: "PUT",
          key: destinationKey,
          headers: {
            "x-amz-copy-source": `/${encodeRfc3986(this.bucket)}/${encodeKeyPath(sourceKey)}`,
          },
          operation: "COPY",
          targetLabel,
          maxAttempts: 1,
          timeoutMs: this.copyTimeoutMs,
          beforeAttempt: beforeMutate,
        });
        const xml = decodeStrictUtf8(await response.arrayBuffer());
        const copyRoot = parseS3XmlRoot(xml, "CopyObjectResult", "COPY", targetLabel);
        return { response, copyEtag: xmlElementText(copyRoot, "ETag") };
      } catch (error) {
        if (isSupersededError(error)) {
          throw error;
        }
        lastError = error;
        // Never use post-error HEAD shortcut if COPY explicitly returned a 200 XML <Error>.
        const isExplicitXmlError = String(error?.message || "").includes("(200 XML ");
        if (isExplicitXmlError) {
          forceOverwriteOnRetry = true;
        }
        if (!isRetryableCopyError(error) || attempt >= attempts) {
          if (!disableHeadShortcut && expectedSize !== undefined && !isExplicitXmlError) {
            try {
              const existingDest = await this.headObject(destinationKey);
              if (existingDest && matchesExpectedTarget(existingDest, expectation)) {
                return { copyEtag: existingDest.etag || "" };
              }
            } catch {
              // Keep original COPY error if post-failure HEAD also fails.
            }
          }
          throw error;
        }
        const delayMs = computeRetryDelayMs(attempt, this.retryBaseDelayMs, this.retryMaxDelayMs);
        console.warn(
          JSON.stringify({
            event: "secondary_s3_copy_retry",
            target: targetLabel,
            attempt,
            maxAttempts: attempts,
            delayMs,
            error: error instanceof Error ? error.message : String(error),
          }),
        );
        await sleepMs(delayMs);
      }
    }

    throw lastError || new Error(`S3 COPY ${targetLabel} failed.`);
  }

  async deleteObject(key, { beforeAttempt = null } = {}) {
    const response = await this.request({
      method: "DELETE",
      key,
      expectOk: false,
      operation: "DELETE",
      targetLabel: key,
      beforeAttempt,
    });
    if (response.status === 404) {
      return response;
    }
    await assertOk(response, "DELETE", key);
    return response;
  }

  async listObjects(prefix) {
    const objects = [];
    let continuationToken = "";
    do {
      const query = [
        ["list-type", "2"],
        ["prefix", prefix],
      ];
      if (continuationToken) {
        query.push(["continuation-token", continuationToken]);
      }
      const response = await this.request({
        method: "GET",
        key: "",
        query,
        operation: "LIST",
        targetLabel: prefix,
      });
      const xml = decodeStrictUtf8(await response.arrayBuffer());
      const parsedPage = parseS3ListBucketXml(xml, prefix);
      for (const entry of parsedPage.objects) {
        objects.push(entry);
      }
      continuationToken = parsedPage.nextContinuationToken;
    } while (continuationToken);
    return objects;
  }

  async request({
    method,
    key = "",
    query = [],
    headers = {},
    body,
    expectOk = true,
    operation = method,
    targetLabel = key || this.bucket,
    maxAttempts = this.maxAttempts,
    timeoutMs = this.requestTimeoutMs,
    beforeAttempt = null,
  }) {
    const endpoint = new URL(this.endpoint);
    const canonicalUri = canonicalS3Uri(endpoint, this.bucket, key);
    const canonicalQuery = canonicalQueryString(query);
    const target = `${endpoint.protocol}//${endpoint.host}${canonicalUri}${
      canonicalQuery ? `?${canonicalQuery}` : ""
    }`;
    const attempts = Math.max(1, maxAttempts);

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      if (beforeAttempt) {
        await beforeAttempt();
      }
      const now = new Date();
      const amzDate = formatAmzDate(now);
      const dateStamp = amzDate.slice(0, 8);
      const credentialScope = `${dateStamp}/${this.region}/s3/aws4_request`;
      const signedHeadersMap = normalizeHeaders({
        ...headers,
        host: endpoint.host,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD",
        "x-amz-date": amzDate,
      });
      const signedHeaderNames = Object.keys(signedHeadersMap).sort();
      const canonicalHeaders = signedHeaderNames
        .map((name) => `${name}:${signedHeadersMap[name]}\n`)
        .join("");
      const signedHeaders = signedHeaderNames.join(";");
      const canonicalRequest = [
        method,
        canonicalUri,
        canonicalQuery,
        canonicalHeaders,
        signedHeaders,
        "UNSIGNED-PAYLOAD",
      ].join("\n");
      const stringToSign = [
        "AWS4-HMAC-SHA256",
        amzDate,
        credentialScope,
        await sha256Hex(canonicalRequest),
      ].join("\n");
      const signingKey = await signingKeyBytes(this.secretAccessKey, dateStamp, this.region, "s3");
      const signature = toHex(await hmac(signingKey, stringToSign));
      const authorization = `AWS4-HMAC-SHA256 Credential=${this.accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

      const requestHeaders = new Headers();
      for (const [name, value] of Object.entries(signedHeadersMap)) {
        if (name !== "host") {
          requestHeaders.set(name, value);
        }
      }
      requestHeaders.set("authorization", authorization);

      let response;
      try {
        response = await fetch(target, {
          method,
          headers: requestHeaders,
          body,
          ...(timeoutMs > 0 ? { signal: AbortSignal.timeout(timeoutMs) } : {}),
        });
      } catch (error) {
        if (isSupersededError(error)) {
          throw error;
        }
        if (attempt < attempts) {
          const delayMs = computeRetryDelayMs(attempt, this.retryBaseDelayMs, this.retryMaxDelayMs);
          console.warn(
            JSON.stringify({
              event: "secondary_s3_request_retry",
              operation,
              target: targetLabel,
              attempt,
              maxAttempts: attempts,
              delayMs,
              error: error instanceof Error ? error.message : String(error),
            }),
          );
          await sleepMs(delayMs);
          continue;
        }
        throw error;
      }

      if (isRetryableS3Status(response.status) && attempt < attempts) {
        const delayMs = computeRetryDelayMs(attempt, this.retryBaseDelayMs, this.retryMaxDelayMs);
        await cancelResponseBody(response);
        console.warn(
          JSON.stringify({
            event: "secondary_s3_request_retry",
            operation,
            target: targetLabel,
            attempt,
            maxAttempts: attempts,
            delayMs,
            status: response.status,
          }),
        );
        await sleepMs(delayMs);
        continue;
      }

      if (expectOk) {
        await assertOk(response, operation, targetLabel);
      }
      return response;
    }

    throw new Error(`S3 ${operation} ${targetLabel} exhausted ${attempts} attempts.`);
  }
}

async function streamResponseDigest(response) {
  const hasher = createIncrementalSha256();
  let byteLength = 0;
  if (!response?.body) {
    return { byteLength: 0, sha256: hasher.digestHex() };
  }
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      if (value && value.byteLength > 0) {
        byteLength += value.byteLength;
        hasher.update(value);
      }
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // Ignore lock release errors on closed streams.
    }
  }
  return { byteLength, sha256: hasher.digestHex() };
}

function matchesExpectedTarget(
  target,
  { expectedSize, expectedSyncSha256 = "", expectedEtag = "" } = {},
) {
  if (!target || (expectedSize !== undefined && target.contentLength !== expectedSize)) {
    return false;
  }
  if (
    !target.fromListFallback &&
    target.syncSha256 &&
    target.bodySha256 &&
    target.syncSha256 !== target.bodySha256
  ) {
    return false;
  }
  const rawSrcEtag = stripEtagQuotes(expectedEtag);
  const rawDstEtag = stripEtagQuotes(target.etag);
  const cleanSrcEtag = normalizeSinglePartEtag(expectedEtag);
  const cleanDstEtag = normalizeSinglePartEtag(target.etag);
  if (cleanSrcEtag && cleanDstEtag && cleanSrcEtag !== cleanDstEtag) {
    return false;
  }
  if (cleanSrcEtag && rawDstEtag && rawDstEtag.includes("-")) {
    return false;
  }
  if (rawSrcEtag.includes("-") && rawDstEtag.includes("-") && rawSrcEtag !== rawDstEtag) {
    return false;
  }
  if (expectedSyncSha256) {
    const expectedLower = expectedSyncSha256.toLowerCase();
    if (target.bodySha256 && target.bodySha256 !== expectedLower) {
      return false;
    }
    if (!target.fromListFallback && target.syncSha256) {
      return target.syncSha256 === expectedLower;
    }
    if (target.bodySha256) {
      return target.bodySha256 === expectedLower;
    }
    return Boolean(cleanSrcEtag && cleanDstEtag && cleanSrcEtag === cleanDstEtag);
  }
  return Boolean(cleanSrcEtag && cleanDstEtag && cleanSrcEtag === cleanDstEtag);
}

function stripEtagQuotes(etag) {
  return String(etag || "")
    .trim()
    .replace(/^W\//, "")
    .replace(/^"|"$/g, "");
}

function isPostCopyVerified(verified, source, copyResultEtag = "") {
  if (!verified || verified.contentLength !== source.contentLength) {
    return false;
  }
  if (
    !source.fromListFallback &&
    source.syncSha256 &&
    source.bodySha256 &&
    source.syncSha256 !== source.bodySha256
  ) {
    return false;
  }
  if (
    !verified.fromListFallback &&
    verified.syncSha256 &&
    verified.bodySha256 &&
    verified.syncSha256 !== verified.bodySha256
  ) {
    return false;
  }
  const cleanCopyEtag = stripEtagQuotes(copyResultEtag);
  const cleanCopySingleEtag =
    cleanCopyEtag && cleanCopyEtag !== "copied" ? normalizeSinglePartEtag(copyResultEtag) : "";
  const cleanDstAnyEtag = stripEtagQuotes(verified.etag);
  if (
    cleanCopyEtag &&
    cleanCopyEtag !== "copied" &&
    cleanDstAnyEtag &&
    cleanDstAnyEtag !== cleanCopyEtag
  ) {
    return false;
  }
  const cleanSrcEtag = normalizeSinglePartEtag(source.etag);
  const cleanDstEtag = normalizeSinglePartEtag(verified.etag);
  if (cleanSrcEtag && cleanCopySingleEtag && cleanSrcEtag !== cleanCopySingleEtag) {
    return false;
  }
  if (cleanSrcEtag && cleanDstEtag && cleanSrcEtag !== cleanDstEtag) {
    return false;
  }
  if (!source.fromListFallback && source.syncSha256) {
    const srcSha = source.syncSha256.toLowerCase();
    if (verified.bodySha256 && verified.bodySha256 !== srcSha) {
      return false;
    }
    if (!verified.fromListFallback && verified.syncSha256) {
      return verified.syncSha256 === srcSha;
    }
    if (verified.bodySha256) {
      return verified.bodySha256 === srcSha;
    }
  }
  if (source.bodySha256 && verified.bodySha256) {
    return verified.bodySha256 === source.bodySha256.toLowerCase();
  }
  if (cleanSrcEtag && cleanDstEtag) {
    return cleanSrcEtag === cleanDstEtag;
  }
  return false;
}

async function verifyPostCopy(
  s3,
  destinationKey,
  verified,
  source,
  copyResultEtag = "",
  knownSourceSha256 = "",
) {
  if (!verified || verified.contentLength !== source.contentLength) {
    return false;
  }
  if (
    !source.fromListFallback &&
    source.syncSha256 &&
    source.bodySha256 &&
    source.syncSha256 !== source.bodySha256
  ) {
    return false;
  }
  if (
    !verified.fromListFallback &&
    verified.syncSha256 &&
    verified.bodySha256 &&
    verified.syncSha256 !== verified.bodySha256
  ) {
    return false;
  }
  const cleanCopyEtag = stripEtagQuotes(copyResultEtag);
  const cleanCopySingleEtag =
    cleanCopyEtag && cleanCopyEtag !== "copied" ? normalizeSinglePartEtag(copyResultEtag) : "";
  const cleanDstAnyEtag = stripEtagQuotes(verified.etag);
  if (
    cleanCopyEtag &&
    cleanCopyEtag !== "copied" &&
    cleanDstAnyEtag &&
    cleanDstAnyEtag !== cleanCopyEtag
  ) {
    return false;
  }
  const cleanSrcEtag = normalizeSinglePartEtag(source.etag);
  const cleanDstEtag = normalizeSinglePartEtag(verified.etag);
  if (cleanSrcEtag && cleanCopySingleEtag && cleanSrcEtag !== cleanCopySingleEtag) {
    return false;
  }
  if (cleanSrcEtag && cleanDstEtag && cleanSrcEtag !== cleanDstEtag) {
    return false;
  }
  const expectedSha = String(
    knownSourceSha256 || source.bodySha256 || (!source.fromListFallback && source.syncSha256) || "",
  )
    .trim()
    .toLowerCase();
  if (expectedSha && source.bodySha256 && source.bodySha256 !== expectedSha) {
    return false;
  }
  if (expectedSha && !source.fromListFallback && source.syncSha256 && source.syncSha256 !== expectedSha) {
    return false;
  }
  if (expectedSha && verified.bodySha256) {
    return verified.bodySha256 === expectedSha;
  }
  if (expectedSha && !verified.fromListFallback && verified.syncSha256) {
    return verified.syncSha256 === expectedSha;
  }
  if (isPostCopyVerified(verified, source, copyResultEtag)) {
    return true;
  }
  let srcSha = expectedSha;
  if (!srcSha && source.key) {
    const srcStream = await s3.streamObjectDigest(source.key);
    if (srcStream.byteLength !== source.contentLength) {
      return false;
    }
    srcSha = srcStream.sha256;
  }
  let dstSha = verified.bodySha256 || (!verified.fromListFallback && verified.syncSha256) || "";
  if (!dstSha && destinationKey) {
    const dstStream = await s3.streamObjectDigest(destinationKey);
    if (dstStream.byteLength !== source.contentLength) {
      return false;
    }
    dstSha = dstStream.sha256;
  }
  return Boolean(srcSha && dstSha && srcSha.toLowerCase() === dstSha.toLowerCase());
}

function parseChecksumsMap(checksumsText) {
  const entries = new Map();
  const lines = String(checksumsText || "").split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }
    const match = /^([0-9a-fA-F]{64})\s+\*?(.+)$/.exec(line);
    if (!match || entries.has(match[2])) {
      return null;
    }
    entries.set(match[2], match[1].toLowerCase());
  }
  return entries.size > 0 ? entries : null;
}

function checksumsMatchesExpected(checksumsText, expectedMap = {}) {
  const requiredEntries = Object.entries(expectedMap || {}).filter(([, sha]) => Boolean(sha));
  if (requiredEntries.length === 0) {
    return Boolean(parseChecksumsMap(checksumsText));
  }
  const parsed = parseChecksumsMap(checksumsText);
  if (!parsed) {
    return false;
  }
  for (const [name, expectedSha] of requiredEntries) {
    if (parsed.get(name) !== String(expectedSha).toLowerCase()) {
      return false;
    }
  }
  return true;
}

const XML_NAMED_ENTITIES = {
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  amp: "&",
};

function isValidXml10CodePoint(cp) {
  return (
    cp === 0x09 ||
    cp === 0x0a ||
    cp === 0x0d ||
    (cp >= 0x20 && cp <= 0xd7ff) ||
    (cp >= 0xe000 && cp <= 0xfffd) ||
    (cp >= 0x10000 && cp <= 0x10ffff)
  );
}

function hasInvalidXml10Chars(textValue) {
  for (let idx = 0; idx < textValue.length; ) {
    const cp = textValue.codePointAt(idx);
    if (cp === undefined || !isValidXml10CodePoint(cp)) {
      return true;
    }
    if (cp <= 0xffff) {
      const codeUnit = textValue.charCodeAt(idx);
      if (codeUnit >= 0xd800 && codeUnit <= 0xdfff) {
        return true;
      }
      idx += 1;
    } else {
      idx += 2;
    }
  }
  return false;
}

function decodeXmlStrict(value) {
  const str = String(value);
  if (hasInvalidXml10Chars(str)) {
    return null;
  }
  let out = "";
  let i = 0;
  while (i < str.length) {
    const amp = str.indexOf("&", i);
    if (amp === -1) {
      out += str.slice(i);
      break;
    }
    out += str.slice(i, amp);
    const semi = str.indexOf(";", amp + 1);
    if (semi === -1) {
      return null;
    }
    const token = str.slice(amp + 1, semi);
    if (token.startsWith("#x")) {
      const hex = token.slice(2);
      if (!/^[0-9a-fA-F]+$/.test(hex)) {
        return null;
      }
      const cp = Number.parseInt(hex, 16);
      if (!isValidXml10CodePoint(cp)) {
        return null;
      }
      out += String.fromCodePoint(cp);
    } else if (token.startsWith("#")) {
      const dec = token.slice(1);
      if (!/^[0-9]+$/.test(dec)) {
        return null;
      }
      const cp = Number.parseInt(dec, 10);
      if (!isValidXml10CodePoint(cp)) {
        return null;
      }
      out += String.fromCodePoint(cp);
    } else if (Object.prototype.hasOwnProperty.call(XML_NAMED_ENTITIES, token)) {
      out += XML_NAMED_ENTITIES[token];
    } else {
      return null;
    }
    i = semi + 1;
  }
  return out;
}

function splitXmlQName(qname) {
  const parts = qname.split(":");
  if (parts.length === 1) {
    return /^([A-Za-z_][A-Za-z0-9_.-]*)$/.test(parts[0])
      ? { prefix: "", localName: parts[0] }
      : null;
  }
  if (parts.length === 2) {
    return /^[A-Za-z_][A-Za-z0-9_.-]*$/.test(parts[0]) &&
      /^[A-Za-z_][A-Za-z0-9_.-]*$/.test(parts[1])
      ? { prefix: parts[0], localName: parts[1] }
      : null;
  }
  return null;
}

function parseXmlStartTag(rawTagContent, parentNsScope) {
  if (!rawTagContent || !/^[A-Za-z_:]/.test(rawTagContent)) {
    return null;
  }
  const selfClosing = rawTagContent.endsWith("/");
  const body = selfClosing ? rawTagContent.slice(0, -1) : rawTagContent;
  const nameMatch = /^([A-Za-z_:][A-Za-z0-9_.:-]*)([\s\S]*)$/.exec(body);
  if (!nameMatch) {
    return null;
  }
  const name = nameMatch[1];
  const parsedElemQName = splitXmlQName(name);
  if (!parsedElemQName || parsedElemQName.prefix === "xmlns") {
    return null;
  }
  const rest = nameMatch[2];
  const rawAttrs = [];
  const seenRawNames = new Set();
  let index = 0;
  while (index < rest.length) {
    let wsCount = 0;
    while (index < rest.length && /[\x20\x09\x0d\x0a]/.test(rest[index])) {
      index += 1;
      wsCount += 1;
    }
    if (index >= rest.length) {
      break;
    }
    if (wsCount === 0) {
      return null;
    }
    const attrNameMatch = /^([A-Za-z_:][A-Za-z0-9_.:-]*)[\x20\x09\x0d\x0a]*=[\x20\x09\x0d\x0a]*/.exec(
      rest.slice(index),
    );
    if (!attrNameMatch) {
      return null;
    }
    const attrName = attrNameMatch[1];
    if (seenRawNames.has(attrName)) {
      return null;
    }
    seenRawNames.add(attrName);
    index += attrNameMatch[0].length;
    const quote = rest[index];
    if (quote !== '"' && quote !== "'") {
      return null;
    }
    index += 1;
    const closeQuote = rest.indexOf(quote, index);
    if (closeQuote === -1) {
      return null;
    }
    const rawVal = rest.slice(index, closeQuote);
    if (rawVal.includes("<")) {
      return null;
    }
    const decodedVal = decodeXmlStrict(rawVal);
    if (decodedVal === null) {
      return null;
    }
    rawAttrs.push({ attrName, decodedVal });
    index = closeQuote + 1;
  }

  const nsScope = new Map(parentNsScope);
  for (const { attrName, decodedVal } of rawAttrs) {
    if (attrName === "xmlns") {
      nsScope.set("", decodedVal);
    } else if (attrName.startsWith("xmlns:")) {
      const prefix = attrName.slice(6);
      if (!/^[A-Za-z_][A-Za-z0-9_.-]*$/.test(prefix) || prefix === "xmlns" || !decodedVal) {
        return null;
      }
      if (prefix === "xml" && decodedVal !== "http://www.w3.org/XML/1998/namespace") {
        return null;
      }
      nsScope.set(prefix, decodedVal);
    }
  }

  const elemNsUri = parsedElemQName.prefix ? nsScope.get(parsedElemQName.prefix) : nsScope.get("") || "";
  if (parsedElemQName.prefix && !elemNsUri) {
    return null;
  }

  const attrs = {};
  const nsAttrs = new Map();
  for (const { attrName, decodedVal } of rawAttrs) {
    attrs[attrName] = decodedVal;
    if (attrName === "xmlns" || attrName.startsWith("xmlns:")) {
      continue;
    }
    const parsedAttrQName = splitXmlQName(attrName);
    if (!parsedAttrQName) {
      return null;
    }
    let attrNsUri = "";
    if (parsedAttrQName.prefix) {
      attrNsUri = nsScope.get(parsedAttrQName.prefix) || "";
      if (!attrNsUri) {
        return null;
      }
    }
    const expandedKey = `${attrNsUri}|${parsedAttrQName.localName}`;
    if (nsAttrs.has(expandedKey)) {
      return null;
    }
    nsAttrs.set(expandedKey, decodedVal);
  }

  return {
    name,
    nsUri: elemNsUri,
    localName: parsedElemQName.localName,
    attrs,
    nsAttrs,
    nsScope,
    selfClosing,
  };
}

function parseAppcastXmlRoot(rawXml) {
  const xml = stripOptionalUtf8Bom(rawXml);
  if (hasInvalidXml10Chars(xml)) {
    return null;
  }
  const baseNsScope = new Map([["xml", "http://www.w3.org/XML/1998/namespace"]]);
  const stack = [];
  let root = null;
  let i = 0;
  while (i < xml.length) {
    const lt = xml.indexOf("<", i);
    if (lt === -1) {
      const trailing = xml.slice(i);
      if (trailing.includes("]]>")) {
        return null;
      }
      if (stack.length > 0) {
        const decodedTrailing = decodeXmlStrict(trailing);
        if (decodedTrailing === null) {
          return null;
        }
        stack[stack.length - 1].textChunks.push(decodedTrailing);
      } else if (!/^[\x20\x09\x0d\x0a]*$/.test(trailing)) {
        return null;
      }
      break;
    }
    if (lt > i) {
      const chunk = xml.slice(i, lt);
      if (chunk.includes("]]>")) {
        return null;
      }
      if (stack.length > 0) {
        const decodedChunk = decodeXmlStrict(chunk);
        if (decodedChunk === null) {
          return null;
        }
        stack[stack.length - 1].textChunks.push(decodedChunk);
      } else if (!/^[\x20\x09\x0d\x0a]*$/.test(chunk)) {
        return null;
      }
    }
    if (xml.startsWith("<!--", lt)) {
      const end = xml.indexOf("-->", lt + 4);
      if (end === -1 || xml.slice(lt + 4, end).includes("--") || xml[end - 1] === "-") {
        return null;
      }
      i = end + 3;
      continue;
    }
    if (xml.startsWith("<![CDATA[", lt)) {
      const end = xml.indexOf("]]>", lt + 9);
      if (end === -1 || stack.length === 0) {
        return null;
      }
      stack[stack.length - 1].textChunks.push(xml.slice(lt + 9, end));
      i = end + 3;
      continue;
    }
    if (xml.startsWith("<?", lt)) {
      const end = xml.indexOf("?>", lt + 2);
      if (end === -1) {
        return null;
      }
      const piBody = xml.slice(lt + 2, end);
      const piTargetMatch = /^([A-Za-z_][A-Za-z0-9_.-]*)([\s\S]*)$/.exec(piBody);
      if (!piTargetMatch) {
        return null;
      }
      const piTarget = piTargetMatch[1];
      const piRest = piTargetMatch[2];
      if (piRest.length > 0 && !/^[\x20\x09\x0d\x0a]/.test(piRest)) {
        return null;
      }
      if (piTarget.toLowerCase() === "xml") {
        if (lt !== 0 || piTarget !== "xml") {
          return null;
        }
        if (
          !/^[\x20\x09\x0d\x0a]+version[\x20\x09\x0d\x0a]*=[\x20\x09\x0d\x0a]*(?:"1\.0"|'1\.0')(?:[\x20\x09\x0d\x0a]+encoding[\x20\x09\x0d\x0a]*=[\x20\x09\x0d\x0a]*(?:"[Uu][Tt][Ff]-8"|'[Uu][Tt][Ff]-8'))?(?:[\x20\x09\x0d\x0a]+standalone[\x20\x09\x0d\x0a]*=[\x20\x09\x0d\x0a]*(?:"(?:yes|no)"|'(?:yes|no)'))?[\x20\x09\x0d\x0a]*$/.test(
            piRest,
          )
        ) {
          return null;
        }
      }
      i = end + 2;
      continue;
    }
    if (xml.startsWith("<!", lt)) {
      return null;
    }
    if (xml.startsWith("</", lt)) {
      const end = xml.indexOf(">", lt + 2);
      if (end === -1) {
        return null;
      }
      const rawClose = xml.slice(lt + 2, end);
      if (!/^[A-Za-z_:][A-Za-z0-9_.:-]*[\x20\x09\x0d\x0a]*$/.test(rawClose)) {
        return null;
      }
      const closeName = rawClose.replace(/[\x20\x09\x0d\x0a]+$/, "");
      const top = stack.pop();
      if (!top || top.name !== closeName) {
        return null;
      }
      i = end + 1;
      continue;
    }
    let cursor = lt + 1;
    let activeQuote = "";
    while (cursor < xml.length) {
      const ch = xml[cursor];
      if (activeQuote) {
        if (ch === activeQuote) {
          activeQuote = "";
        }
      } else if (ch === '"' || ch === "'") {
        activeQuote = ch;
      } else if (ch === "<") {
        return null;
      } else if (ch === ">") {
        break;
      }
      cursor += 1;
    }
    if (cursor >= xml.length || activeQuote) {
      return null;
    }
    const parentNsScope = stack.length > 0 ? stack[stack.length - 1].nsScope : baseNsScope;
    const parsedTag = parseXmlStartTag(xml.slice(lt + 1, cursor), parentNsScope);
    if (!parsedTag) {
      return null;
    }
    const node = {
      name: parsedTag.name,
      nsUri: parsedTag.nsUri,
      localName: parsedTag.localName,
      attrs: parsedTag.attrs,
      nsAttrs: parsedTag.nsAttrs,
      nsScope: parsedTag.nsScope,
      children: [],
      textChunks: [],
    };
    if (stack.length === 0) {
      if (root !== null) {
        return null;
      }
      root = node;
    } else {
      stack[stack.length - 1].children.push(node);
    }
    if (!parsedTag.selfClosing) {
      stack.push(node);
    }
    i = cursor + 1;
  }
  return stack.length === 0 ? root : null;
}

function appcastMatchesExpected(appcastText, expected) {
  if (!expected?.zipBasename) {
    return true;
  }
  const root = parseAppcastXmlRoot(String(appcastText || ""));
  if (!root || root.nsUri !== "" || root.localName !== "rss") {
    return false;
  }
  if (root.children.length !== 1) {
    return false;
  }
  const channel = root.children[0];
  if (channel.nsUri !== "" || channel.localName !== "channel") {
    return false;
  }
  const items = channel.children.filter(
    (child) => child.nsUri === "" && child.localName === "item",
  );
  if (items.length !== 1) {
    return false;
  }
  if (
    channel.children.some(
      (child) =>
        (child.nsUri === "" && child.localName !== "item" && child.localName === "enclosure") ||
        child.nsUri === SPARKLE_XML_NS ||
        (child.nsUri !== "" && child.localName === "item"),
    )
  ) {
    return false;
  }
  const item = items[0];

  let expectedBaseUrl = "";
  try {
    expectedBaseUrl = normalizePublicBaseUrl(expected.publicBaseUrl || DEFAULT_PUBLIC_BASE_URL);
  } catch {
    return false;
  }

  const versions = item.children.filter(
    (child) => child.nsUri === SPARKLE_XML_NS && child.localName === "version",
  );
  if (expected.version) {
    if (
      versions.length !== 1 ||
      versions[0].children.length !== 0 ||
      versions[0].textChunks.join("") !== expected.version
    ) {
      return false;
    }
  } else if (versions.length > 1) {
    return false;
  }

  const shortVersions = item.children.filter(
    (child) => child.nsUri === SPARKLE_XML_NS && child.localName === "shortVersionString",
  );
  if (expected.shortVersionString) {
    if (
      shortVersions.length !== 1 ||
      shortVersions[0].children.length !== 0 ||
      shortVersions[0].textChunks.join("") !== expected.shortVersionString
    ) {
      return false;
    }
  } else if (shortVersions.length > 1) {
    return false;
  }

  const primaryEnclosures = item.children.filter(
    (child) => child.nsUri === "" && child.localName === "enclosure",
  );
  if (
    primaryEnclosures.length !== 1 ||
    primaryEnclosures[0].children.length !== 0 ||
    item.children.some((child) => child.nsUri !== "" && child.localName === "enclosure")
  ) {
    return false;
  }
  const primaryNode = primaryEnclosures[0];
  const expectedZipUrl = `${expectedBaseUrl}/latest/mac/${expected.mirrorDir}/${encodeRfc3986(expected.zipBasename)}`;
  if (primaryNode.nsAttrs.get("|url") !== expectedZipUrl) {
    return false;
  }
  const primaryAttrVersion = primaryNode.nsAttrs.get(`${SPARKLE_XML_NS}|version`);
  if (primaryAttrVersion !== undefined && (!expected.version || primaryAttrVersion !== expected.version)) {
    return false;
  }
  const primaryAttrShortVersion = primaryNode.nsAttrs.get(`${SPARKLE_XML_NS}|shortVersionString`);
  if (
    primaryAttrShortVersion !== undefined &&
    (!expected.shortVersionString || primaryAttrShortVersion !== expected.shortVersionString)
  ) {
    return false;
  }
  const primaryAttrOs = primaryNode.nsAttrs.get(`${SPARKLE_XML_NS}|os`);
  if (primaryAttrOs !== undefined && primaryAttrOs !== "macos") {
    return false;
  }
  if (
    expected.edSignature &&
    primaryNode.nsAttrs.get(`${SPARKLE_XML_NS}|edSignature`) !== expected.edSignature
  ) {
    return false;
  }
  if (
    expected.enclosureLength !== undefined &&
    String(primaryNode.nsAttrs.get("|length") || "") !== String(expected.enclosureLength)
  ) {
    return false;
  }

  const deltaContainers = item.children.filter(
    (child) => child.nsUri === SPARKLE_XML_NS && child.localName === "deltas",
  );
  if (
    deltaContainers.length > 1 ||
    item.children.some((child) => child.nsUri !== SPARKLE_XML_NS && child.localName === "deltas")
  ) {
    return false;
  }
  const deltaChildren = deltaContainers.length === 1 ? deltaContainers[0].children : [];
  if (
    deltaChildren.some(
      (child) => child.nsUri !== "" || child.localName !== "enclosure" || child.children.length !== 0,
    )
  ) {
    return false;
  }

  const expectedDeltas =
    expected.deltas ||
    (expected.deltaBasenames || []).map((basename) => ({
      basename,
    }));
  if (deltaChildren.length !== expectedDeltas.length) {
    return false;
  }

  const expectedDeltaByUrl = new Map(
    expectedDeltas.map((entry) => [
      `${expectedBaseUrl}/latest/mac/${expected.mirrorDir}/${encodeRfc3986(entry.basename)}`,
      entry,
    ]),
  );
  if (expectedDeltaByUrl.size !== expectedDeltas.length) {
    return false;
  }

  const seenDeltaUrls = new Set();
  for (const deltaNode of deltaChildren) {
    const deltaUrl = deltaNode.nsAttrs.get("|url") || "";
    if (!deltaUrl || seenDeltaUrls.has(deltaUrl)) {
      return false;
    }
    const expectedDelta = expectedDeltaByUrl.get(deltaUrl);
    if (!expectedDelta) {
      return false;
    }
    if (
      expectedDelta.edSignature &&
      deltaNode.nsAttrs.get(`${SPARKLE_XML_NS}|edSignature`) !== expectedDelta.edSignature
    ) {
      return false;
    }
    if (
      expectedDelta.deltaFrom &&
      deltaNode.nsAttrs.get(`${SPARKLE_XML_NS}|deltaFrom`) !== expectedDelta.deltaFrom
    ) {
      return false;
    }
    if (
      expectedDelta.length !== undefined &&
      String(deltaNode.nsAttrs.get("|length") || "") !== String(expectedDelta.length)
    ) {
      return false;
    }
    const deltaAttrVersion = deltaNode.nsAttrs.get(`${SPARKLE_XML_NS}|version`);
    if (expectedDelta.version) {
      if (deltaAttrVersion !== expectedDelta.version) {
        return false;
      }
    } else if (
      deltaAttrVersion !== undefined &&
      (!expected.version || deltaAttrVersion !== expected.version)
    ) {
      return false;
    }
    const deltaAttrShortVersion = deltaNode.nsAttrs.get(`${SPARKLE_XML_NS}|shortVersionString`);
    if (
      deltaAttrShortVersion !== undefined &&
      (!expected.shortVersionString || deltaAttrShortVersion !== expected.shortVersionString)
    ) {
      return false;
    }
    const deltaAttrOs = deltaNode.nsAttrs.get(`${SPARKLE_XML_NS}|os`);
    if (expectedDelta.os) {
      if (deltaAttrOs !== expectedDelta.os) {
        return false;
      }
    } else if (deltaAttrOs !== undefined && deltaAttrOs !== "macos") {
      return false;
    }
    seenDeltaUrls.add(deltaUrl);
  }

  return seenDeltaUrls.size === expectedDeltas.length;
}

function normalizeSinglePartEtag(etag) {
  const cleaned = String(etag || "")
    .trim()
    .replace(/^W\//, "")
    .replace(/^"|"$/g, "");
  if (!cleaned || cleaned.includes("-")) {
    return "";
  }
  return cleaned;
}

function xmlDirectText(node) {
  if (!node || node.children.length > 0) {
    return null;
  }
  return node.textChunks.join("");
}

function xmlElementText(parent, tagName) {
  if (!parent) {
    return "";
  }
  const child = parent.children.find((entry) => entry.name === tagName);
  if (!child) {
    return "";
  }
  const val = xmlDirectText(child);
  if (val === null) {
    throw new Error(`Unexpected nested element inside <${tagName}>.`);
  }
  return val;
}

function parseS3XmlRoot(xml, expectedRootTag, operation, targetLabel) {
  const text = String(xml || "");
  const root = parseAppcastXmlRoot(text);
  if (!root) {
    const code = xmlText(text, "Code") || "MalformedXML";
    const message = xmlText(text, "Message") || text.slice(0, 300) || "invalid or truncated XML";
    throw new Error(`S3 ${operation} ${targetLabel} failed with HTTP 500 (200 XML ${code}): ${message}`);
  }
  if (root.name === "Error" || root.children.some((child) => child.name === "Error")) {
    const errNode = root.name === "Error" ? root : root.children.find((child) => child.name === "Error");
    const code = xmlElementText(errNode, "Code") || "InternalError";
    const message = xmlElementText(errNode, "Message") || text.slice(0, 300) || "S3 XML error";
    throw new Error(`S3 ${operation} ${targetLabel} failed with HTTP 500 (200 XML ${code}): ${message}`);
  }
  if (root.name !== expectedRootTag) {
    throw new Error(
      `S3 ${operation} ${targetLabel} failed with HTTP 500 (200 XML UnexpectedRoot): expected <${expectedRootTag}>, got <${root.name}>`,
    );
  }
  return root;
}

function parseS3IsTruncatedFlag(root, operation, targetLabel) {
  const truncNodes = root.children.filter((child) => child.name === "IsTruncated");
  if (truncNodes.length === 0) {
    return null;
  }
  if (truncNodes.length > 1) {
    throw new Error(`S3 ${operation} ${targetLabel} returned multiple <IsTruncated> elements.`);
  }
  const raw = xmlDirectText(truncNodes[0]);
  const normalized = raw === null ? "" : raw.trim().toLowerCase();
  if (normalized !== "true" && normalized !== "false") {
    throw new Error(
      `S3 ${operation} ${targetLabel} returned invalid <IsTruncated> value: ${JSON.stringify(raw)}.`,
    );
  }
  return normalized === "true";
}

function parseS3ListBucketXml(xml, prefix) {
  const root = parseS3XmlRoot(xml, "ListBucketResult", "LIST", prefix);
  const isTruncated = parseS3IsTruncatedFlag(root, "LIST", prefix);
  const tokenNodes = root.children.filter((child) => child.name === "NextContinuationToken");
  if (tokenNodes.length > 1) {
    throw new Error(`S3 LIST ${prefix} returned multiple <NextContinuationToken> elements.`);
  }
  let nextContinuationToken = "";
  if (tokenNodes.length === 1) {
    const tok = xmlDirectText(tokenNodes[0]);
    if (tok === null) {
      throw new Error(`S3 LIST ${prefix} returned malformed <NextContinuationToken>.`);
    }
    nextContinuationToken = tok;
  }
  if (isTruncated === false) {
    nextContinuationToken = "";
  } else if (isTruncated === true && !nextContinuationToken) {
    throw new Error(`S3 LIST ${prefix} returned IsTruncated=true without NextContinuationToken.`);
  }

  const objects = [];
  for (const contentNode of root.children.filter((child) => child.name === "Contents")) {
    const keyNode = contentNode.children.find((child) => child.name === "Key");
    const sizeNode = contentNode.children.find((child) => child.name === "Size");
    const key = keyNode ? xmlDirectText(keyNode) : null;
    const sizeText = sizeNode ? xmlDirectText(sizeNode) : null;
    if (!key || sizeText === null || !/^(?:0|[1-9][0-9]*)$/.test(sizeText.trim())) {
      throw new Error(`S3 LIST ${prefix} returned malformed <Contents> entry.`);
    }
    const size = Number(sizeText.trim());
    if (!Number.isSafeInteger(size)) {
      throw new Error(`S3 LIST ${prefix} returned non-safe integer <Size>: ${sizeText}.`);
    }
    objects.push({
      key,
      size,
      etag: xmlElementText(contentNode, "ETag"),
      lastModified: parseHttpDate(xmlElementText(contentNode, "LastModified")),
    });
  }
  return { objects, nextContinuationToken };
}

function parseS3ListMultipartXml(xml, prefix) {
  const root = parseS3XmlRoot(xml, "ListMultipartUploadsResult", "LIST MULTIPART", prefix);
  const isTruncated = parseS3IsTruncatedFlag(root, "LIST MULTIPART", prefix);
  let nextKeyMarker = xmlElementText(root, "NextKeyMarker");
  let nextUploadIdMarker = xmlElementText(root, "NextUploadIdMarker");
  if (isTruncated === false) {
    nextKeyMarker = "";
    nextUploadIdMarker = "";
  } else if (isTruncated === true && !nextKeyMarker) {
    throw new Error(`S3 LIST MULTIPART ${prefix} returned IsTruncated=true without NextKeyMarker.`);
  }

  const uploads = [];
  for (const uploadNode of root.children.filter((child) => child.name === "Upload")) {
    const keyNode = uploadNode.children.find((child) => child.name === "Key");
    const idNode = uploadNode.children.find((child) => child.name === "UploadId");
    const key = keyNode ? xmlDirectText(keyNode) : null;
    const uploadId = idNode ? xmlDirectText(idNode) : null;
    if (!key || !uploadId) {
      throw new Error(`S3 LIST MULTIPART ${prefix} returned malformed <Upload> entry.`);
    }
    uploads.push({
      key,
      uploadId,
      initiated: parseHttpDate(xmlElementText(uploadNode, "Initiated")),
    });
  }
  return { uploads, nextKeyMarker, nextUploadIdMarker };
}

function objectMetadataHeaders(metadata) {
  const headers = {
    "cache-control": metadata.cacheControl || DEFAULT_CACHE_CONTROL,
    "content-disposition": `attachment; filename="${metadata.filename}"`,
    "content-type": metadata.contentType || "application/octet-stream",
  };
  if (metadata.syncSha256) {
    headers[SYNC_SHA256_HEADER] = String(metadata.syncSha256).toLowerCase();
  }
  return headers;
}

async function assertOk(response, operation, key) {
  if (response.ok) {
    return;
  }
  let body = "";
  try {
    body = await response.text();
  } catch {
    body = "";
  }
  const err = new Error(
    `S3 ${operation} ${key} failed with HTTP ${response.status}${body ? `: ${body.slice(0, 600)}` : "."}`,
  );
  err.httpStatus = response.status;
  throw err;
}

export function deriveReleaseTag(manifest) {
  const explicitVersion = manifest?.codexVersion || manifest?.derived?.codexVersion || "";
  if (explicitVersion) {
    return `codex-app-${sanitizeTagPart(explicitVersion)}`;
  }

  const windowsAppVersion =
    manifest?.sources?.windows?.appVersion || manifest?.sources?.windows?.architectures?.x64?.appVersion || "";
  const arm = manifest?.sources?.macos?.arm64?.appcast || {};
  const x64 = manifest?.sources?.macos?.x64?.appcast || {};
  if (arm.shortVersionString && arm.shortVersionString === x64.shortVersionString) {
    return `codex-app-${sanitizeTagPart(arm.shortVersionString)}`;
  }
  if (windowsAppVersion) {
    return `codex-app-${sanitizeTagPart(windowsAppVersion)}`;
  }
  return "";
}

export function sanitizeTagPart(value) {
  return String(value)
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function workflowInstanceId(releaseTag, salt = "") {
  const base = `${releaseTag}:${salt}`;
  return `secondary-${fnv1a(base).slice(0, 24)}`;
}

function shouldRestartState(state) {
  return state === "errored" || state === "terminated" || state === "unknown";
}

function isActiveWorkflowState(state) {
  return (
    state === "queued" ||
    state === "running" ||
    state === "waiting" ||
    state === "waitingForPause" ||
    state === "paused"
  );
}

export function normalizeWorkflowState(status) {
  if (!status) {
    return "unknown";
  }
  return status.status || status.state || "unknown";
}

export function isTerminalWorkflowState(state) {
  return state === "complete" || state === "errored" || state === "terminated";
}

function assertAuthorized(request, env) {
  const expected = env.SYNC_AUTH_TOKEN;
  if (!expected) {
    throw new NonRetryableMirrorError("SYNC_AUTH_TOKEN secret is not configured.");
  }
  const actual = request.headers.get("authorization") || "";
  if (actual !== `Bearer ${expected}`) {
    throw new NonRetryableMirrorError("Unauthorized.");
  }
}

function assertWorkflowBinding(env) {
  if (!env.SECONDARY_MIRROR_WORKFLOW) {
    throw new NonRetryableMirrorError("SECONDARY_MIRROR_WORKFLOW binding is not configured.");
  }
}

function assertR2Binding(env) {
  if (!env.GLOBAL_R2) {
    throw new NonRetryableMirrorError("GLOBAL_R2 binding is not configured.");
  }
}

function isWorkflowNotFoundError(error) {
  const status = Number(error?.status || error?.statusCode || 0);
  if (status >= 500) {
    return false;
  }
  if (status === 404) {
    return true;
  }
  const msg = String(error?.message || error || "");
  if (
    /\b(?:HTTP\s+)?5\d\d\b/i.test(msg) ||
    /\b(?:timeout|timed\s*out|unavailable|internal\s+error|bad\s+gateway|rate\s*limit|too\s+many\s+requests)\b/i.test(
      msg,
    )
  ) {
    return false;
  }
  return (
    /\bHTTP\s+404\b/i.test(msg) ||
    /\b(?:not[\s_.-]*found|does[\s_.-]*not[\s_.-]*exist|unknown[\s_.-]*instance)\b/i.test(msg)
  );
}

async function getWorkflowIfExists(env, id) {
  try {
    return await env.SECONDARY_MIRROR_WORKFLOW.get(id);
  } catch (error) {
    if (isWorkflowNotFoundError(error)) {
      return null;
    }
    throw error;
  }
}

async function readJsonBody(request) {
  const text = await request.text();
  if (!text.trim()) {
    return {};
  }
  return JSON.parse(text);
}

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...(init.headers || {}),
    },
  });
}

function requiredEnv(env, name) {
  const value = env[name];
  if (!value) {
    throw new NonRetryableMirrorError(`${name} is not configured.`);
  }
  return value;
}

function parseBytes(value, fallback, minimum) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < minimum) {
    return fallback;
  }
  return parsed;
}

function parseNonNegativeInteger(value, fallback) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return fallback;
  }
  return parsed;
}

function parsePositiveInteger(value, fallback) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < 1) {
    return fallback;
  }
  return parsed;
}

function isRetryableS3Status(status) {
  return status === 408 || status === 429 || (status >= 500 && status !== 501 && status !== 505);
}

function isRetryableCopyError(error) {
  const message = error instanceof Error ? error.message : String(error || "");
  const statusMatch = /failed with HTTP (\d+)/.exec(message);
  if (statusMatch) {
    return isRetryableS3Status(Number.parseInt(statusMatch[1], 10));
  }
  return !message.startsWith("S3 ");
}

function computeRetryDelayMs(attempt, baseDelayMs, maxDelayMs) {
  if (baseDelayMs <= 0) {
    return 0;
  }
  const exponential = Math.min(maxDelayMs, baseDelayMs * 2 ** Math.max(0, attempt - 1));
  return Math.round(exponential * (0.75 + Math.random() * 0.5));
}

async function cancelResponseBody(response) {
  try {
    await response?.body?.cancel();
  } catch {
    // Ignore cancellation errors on broken upstream sockets.
  }
}

function sleepMs(ms) {
  if (ms <= 0) {
    return Promise.resolve();
  }
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function cleanPrefix(prefix) {
  return String(prefix || "")
    .replace(/^\/+|\/+$/g, "")
    .replace(/\/+/g, "/");
}

function safeKeySegment(value) {
  return sanitizeTagPart(value) || "unknown";
}

function canonicalS3Uri(endpoint, bucket, key) {
  const basePath = endpoint.pathname === "/" ? "" : endpoint.pathname.replace(/\/$/, "");
  const bucketPath = encodeRfc3986(bucket);
  const objectPath = key ? `/${encodeKeyPath(key)}` : "";
  return `${basePath}/${bucketPath}${objectPath}`;
}

function canonicalQueryString(params = []) {
  return params
    .map(([key, value]) => [encodeRfc3986(key), encodeRfc3986(value)])
    .sort(([leftKey, leftValue], [rightKey, rightValue]) => {
      if (leftKey === rightKey) {
        return leftValue < rightValue ? -1 : leftValue > rightValue ? 1 : 0;
      }
      return leftKey < rightKey ? -1 : 1;
    })
    .map(([key, value]) => `${key}=${value}`)
    .join("&");
}

function normalizeHeaders(headers) {
  const normalized = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined || value === null || value === "") {
      continue;
    }
    normalized[name.toLowerCase()] = String(value).trim().replace(/\s+/g, " ");
  }
  return normalized;
}

function encodeKeyPath(key) {
  return String(key).split("/").map(encodeRfc3986).join("/");
}

function encodeRfc3986(value) {
  return encodeURIComponent(String(value)).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function formatAmzDate(date) {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

async function signingKeyBytes(secretAccessKey, dateStamp, region, service) {
  const dateKey = await hmac(utf8(`AWS4${secretAccessKey}`), dateStamp);
  const regionKey = await hmac(dateKey, region);
  const serviceKey = await hmac(regionKey, service);
  return hmac(serviceKey, "aws4_request");
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", toBytes(value));
  return toHex(new Uint8Array(digest));
}

// Pure-JS FIPS 180-4 incremental SHA-256 (zero Node.js imports, compatible with
// both workerd without nodejs_compat and Node.js test runners).
const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

export function createIncrementalSha256() {
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const block = new Uint8Array(64);
  const w = new Uint32Array(64);
  let blockLen = 0;
  let totalBytes = 0;

  function compress(chunk, offset) {
    for (let i = 0; i < 16; i += 1) {
      const j = offset + i * 4;
      w[i] =
        ((chunk[j] << 24) | (chunk[j + 1] << 16) | (chunk[j + 2] << 8) | chunk[j + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i += 1) {
      const v1 = w[i - 15];
      const s0 = (((v1 >>> 7) | (v1 << 25)) ^ ((v1 >>> 18) | (v1 << 14)) ^ (v1 >>> 3)) >>> 0;
      const v2 = w[i - 2];
      const s1 = (((v2 >>> 17) | (v2 << 15)) ^ ((v2 >>> 19) | (v2 << 13)) ^ (v2 >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i += 1) {
      const s1 = (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) >>> 0;
      const ch = ((e & f) ^ (~e & g)) >>> 0;
      const temp1 = (hh + s1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const s0 = (((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const temp2 = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }

  return {
    update(bytesInput) {
      const data = toBytes(bytesInput);
      totalBytes += data.byteLength;
      let pos = 0;
      if (blockLen > 0 && blockLen + data.byteLength >= 64) {
        const needed = 64 - blockLen;
        block.set(data.subarray(0, needed), blockLen);
        compress(block, 0);
        blockLen = 0;
        pos = needed;
      }
      while (pos + 64 <= data.byteLength) {
        compress(data, pos);
        pos += 64;
      }
      if (pos < data.byteLength) {
        block.set(data.subarray(pos), blockLen);
        blockLen += data.byteLength - pos;
      }
    },
    digestHex() {
      block[blockLen++] = 0x80;
      if (blockLen > 56) {
        block.fill(0, blockLen, 64);
        compress(block, 0);
        blockLen = 0;
      }
      block.fill(0, blockLen, 56);
      const bitHi = Math.floor((totalBytes * 8) / 0x100000000) >>> 0;
      const bitLo = (totalBytes * 8) >>> 0;
      const view = new DataView(block.buffer);
      view.setUint32(56, bitHi, false);
      view.setUint32(60, bitLo, false);
      compress(block, 0);
      const out = new Uint8Array(32);
      const outView = new DataView(out.buffer);
      for (let i = 0; i < 8; i += 1) {
        outView.setUint32(i * 4, h[i], false);
      }
      return toHex(out);
    },
  };
}

async function hmac(keyBytes, value) {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, toBytes(value));
  return new Uint8Array(signature);
}

function toBytes(value) {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  return utf8(value);
}

function utf8(value) {
  return new TextEncoder().encode(String(value));
}

function toHex(bytes) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function fnv1a(value) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function xmlText(xml, tag) {
  const match = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(xml);
  return match ? decodeXmlText(match[1]) : "";
}

function xmlContents(xml) {
  const entries = [];
  const contentRegex = /<Contents>([\s\S]*?)<\/Contents>/g;
  let match;
  while ((match = contentRegex.exec(xml))) {
    const block = match[1];
    const key = xmlText(block, "Key");
    if (!key) {
      continue;
    }
    entries.push({
      key,
      size: Number.parseInt(xmlText(block, "Size") || "0", 10),
      etag: xmlText(block, "ETag"),
      lastModified: parseHttpDate(xmlText(block, "LastModified")),
    });
  }
  return entries;
}

function xmlMultipartUploads(xml) {
  const entries = [];
  const uploadRegex = /<Upload>([\s\S]*?)<\/Upload>/g;
  let match;
  while ((match = uploadRegex.exec(xml))) {
    const block = match[1];
    const key = xmlText(block, "Key");
    const uploadId = xmlText(block, "UploadId");
    if (!key || !uploadId) {
      continue;
    }
    entries.push({
      key,
      uploadId,
      initiated: parseHttpDate(xmlText(block, "Initiated")),
    });
  }
  return entries;
}

function decodeXmlText(value) {
  return String(value)
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#([0-9]+);/g, (_, dec) => String.fromCodePoint(Number.parseInt(dec, 10)))
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function completeMultipartXml(parts) {
  const body = parts
    .map(
      (part) =>
        `  <Part><PartNumber>${part.partNumber}</PartNumber><ETag>${xmlEscape(part.etag)}</ETag></Part>`,
    )
    .join("\n");
  return `<CompleteMultipartUpload>\n${body}\n</CompleteMultipartUpload>`;
}

function parseHttpDate(value) {
  if (!value) {
    return null;
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}
