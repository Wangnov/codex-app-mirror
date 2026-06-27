const DEFAULT_PART_SIZE_BYTES = 16 * 1024 * 1024;
const DEFAULT_SINGLE_PUT_MAX_BYTES = 32 * 1024 * 1024;
const DEFAULT_CACHE_CONTROL = "public, max-age=600, s-maxage=86400";
const SHORT_CACHE_CONTROL = "public, max-age=600";
const DEFAULT_STAGE_PREFIX = "staging/secondary-sync";
const DEFAULT_PRUNE_GRACE_DAYS = 1;

export class NonRetryableMirrorError extends Error {
  constructor(message) {
    super(message);
    this.name = "NonRetryableMirrorError";
  }
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
    const plan = buildObjectPlan(source.manifest, source.releaseTag);
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

export async function startSync(env, params = {}) {
  assertWorkflowBinding(env);
  const source = await discoverSourceManifest(env, params.releaseTag || "");
  const force = Boolean(params.force);
  const instanceId =
    params.instanceId ||
    workflowInstanceId(source.releaseTag, params.idSalt || source.manifestSha256 || "");

  const payload = {
    releaseTag: source.releaseTag,
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
    return {
      ok: true,
      id: instance.id,
      state: normalizeWorkflowState(status),
      status,
      releaseTag: source.releaseTag,
      created: true,
    };
  } catch (error) {
    const existing = await getWorkflowIfExists(env, instanceId);
    if (!existing) {
      throw error;
    }

    const status = await existing.status();
    const state = normalizeWorkflowState(status);
    if (force || shouldRestartState(state)) {
      await existing.restart();
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
  const source = await discoverSourceManifest(env, params.releaseTag || "");
  const s3 = createS3Client(env);
  let secondaryManifest = null;
  try {
    secondaryManifest = await s3.getObjectText("latest/manifest");
  } catch (error) {
    if (!String(error.message || "").includes("HTTP 404")) {
      console.error(
        JSON.stringify({
          event: "secondary_manifest_read_failed",
          error: error.message,
        }),
      );
    }
  }

  if (secondaryManifest === source.manifestText && !params.force) {
    return {
      ok: true,
      skipped: true,
      reason: "secondary manifest already matches R2 latest/manifest",
      releaseTag: source.releaseTag,
    };
  }

  return startSync(env, {
    releaseTag: source.releaseTag,
    force: Boolean(params.force),
    idSalt: `${source.manifestSha256}-${Date.now()}`,
  });
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

export async function discoverSourceManifest(env, releaseTagOverride = "") {
  assertR2Binding(env);
  const manifestObject = await env.GLOBAL_R2.get("latest/manifest");
  if (!manifestObject) {
    throw new NonRetryableMirrorError("R2 latest/manifest is missing.");
  }
  const manifestText = await manifestObject.text();
  const manifest = JSON.parse(manifestText);
  const releaseTag = releaseTagOverride || deriveReleaseTag(manifest);
  if (!releaseTag) {
    throw new NonRetryableMirrorError("Could not derive release tag from manifest.");
  }
  return {
    releaseTag,
    manifest,
    manifestText,
    manifestSha256: await sha256Hex(manifestText),
  };
}

export function buildObjectPlan(manifest, releaseTag) {
  const windows = manifest?.sources?.windows || {};
  const macos = manifest?.sources?.macos || {};
  const items = [];
  const staleAliasKeys = [];

  addItem(items, {
    id: "win-x64",
    sourceKey: "latest/win-x64",
    stageRelativeKey: "win-x64",
    aliasKeys: ["latest/win-x64", "latest/win"],
    filename: "Codex-Windows-x64.msix",
    contentType: "application/vnd.ms-appx",
    role: "installer",
    required: true,
  });

  if (windows.architectures?.arm64?.downloadable === true) {
    addItem(items, {
      id: "win-arm64",
      sourceKey: "latest/win-arm64",
      stageRelativeKey: "win-arm64",
      aliasKeys: ["latest/win-arm64"],
      filename: "Codex-Windows-arm64.msix",
      contentType: "application/vnd.ms-appx",
      role: "installer",
      required: true,
    });
  } else {
    staleAliasKeys.push("latest/win-arm64");
  }

  addItem(items, {
    id: "mac-arm64",
    sourceKey: "latest/mac-arm64",
    stageRelativeKey: "mac-arm64",
    aliasKeys: ["latest/mac-arm64"],
    filename: "Codex-mac-arm64.dmg",
    contentType: "application/x-apple-diskimage",
    role: "installer",
    required: true,
  });

  addItem(items, {
    id: "mac-intel",
    sourceKey: "latest/mac-intel",
    stageRelativeKey: "mac-intel",
    aliasKeys: ["latest/mac-intel"],
    filename: "Codex-mac-x64.dmg",
    contentType: "application/x-apple-diskimage",
    role: "installer",
    required: true,
  });

  const armShortVersion = macos.arm64?.appcast?.shortVersionString;
  const x64ShortVersion = macos.x64?.appcast?.shortVersionString;
  if (armShortVersion) {
    const basename = `Codex-darwin-arm64-${armShortVersion}.zip`;
    addItem(items, {
      id: "mac-arm64-zip",
      sourceKey: `latest/mac/arm64/${basename}`,
      stageRelativeKey: `mac/arm64/${basename}`,
      aliasKeys: [`latest/mac/arm64/${basename}`],
      filename: basename,
      contentType: "application/octet-stream",
      role: "archive",
      required: true,
    });
  }
  if (x64ShortVersion) {
    const basename = `Codex-darwin-x64-${x64ShortVersion}.zip`;
    addItem(items, {
      id: "mac-x64-zip",
      sourceKey: `latest/mac/intel/${basename}`,
      stageRelativeKey: `mac/intel/${basename}`,
      aliasKeys: [`latest/mac/intel/${basename}`],
      filename: basename,
      contentType: "application/octet-stream",
      role: "archive",
      required: true,
    });
  }

  addDeltas(items, macos.arm64?.appcast?.deltas || [], "arm64");
  addDeltas(items, macos.x64?.appcast?.deltas || [], "intel");

  addItem(items, {
    id: "checksums",
    sourceKey: "latest/checksums",
    stageRelativeKey: "checksums",
    aliasKeys: ["latest/checksums"],
    filename: "SHA256SUMS.txt",
    contentType: "text/plain; charset=utf-8",
    role: "checksums",
    required: true,
  });

  addItem(items, {
    id: "appcast-arm64",
    sourceKey: "latest/appcast.xml",
    stageRelativeKey: "appcast.xml",
    aliasKeys: ["latest/appcast.xml"],
    filename: "appcast.xml",
    contentType: "application/xml",
    cacheControl: SHORT_CACHE_CONTROL,
    role: "appcast",
    required: true,
  });

  addItem(items, {
    id: "appcast-x64",
    sourceKey: "latest/appcast-x64.xml",
    stageRelativeKey: "appcast-x64.xml",
    aliasKeys: ["latest/appcast-x64.xml"],
    filename: "appcast-x64.xml",
    contentType: "application/xml",
    cacheControl: SHORT_CACHE_CONTROL,
    role: "appcast",
    required: true,
  });

  addItem(items, {
    id: "manifest",
    sourceKey: "latest/manifest",
    stageRelativeKey: "manifest",
    aliasKeys: ["latest/manifest"],
    filename: "release-manifest.json",
    contentType: "application/json",
    role: "manifest",
    required: true,
  });

  return {
    releaseTag,
    items,
    staleAliasKeys,
    keepLatestMacKeys: items
      .flatMap((item) => item.aliasKeys)
      .filter((key) => key.startsWith("latest/mac/")),
  };
}

function addDeltas(items, deltas, mirrorDir) {
  for (const delta of deltas) {
    const basename = delta.basename || String(delta.url || "").split("/").pop();
    if (!basename) {
      throw new NonRetryableMirrorError("Manifest delta entry is missing basename/url.");
    }
    addItem(items, {
      id: `mac-${mirrorDir}-delta-${basename}`,
      sourceKey: `latest/mac/${mirrorDir}/${basename}`,
      stageRelativeKey: `mac/${mirrorDir}/${basename}`,
      aliasKeys: [`latest/mac/${mirrorDir}/${basename}`],
      filename: basename,
      contentType: "application/octet-stream",
      role: "delta",
      required: true,
    });
  }
}

function addItem(items, item) {
  items.push({
    cacheControl: DEFAULT_CACHE_CONTROL,
    ...item,
  });
}

export async function uploadObjectToStage(env, item, options = {}) {
  assertR2Binding(env);
  const source = await headR2Object(env, item.sourceKey);
  if (!source) {
    if (item.required) {
      throw new NonRetryableMirrorError(`R2 source object is missing: ${item.sourceKey}`);
    }
    return { id: item.id, sourceKey: item.sourceKey, skipped: true, reason: "source missing" };
  }

  const s3 = createS3Client(env);
  const existing = await s3.headObject(item.stageKey);
  if (!options.forceUpload && existing?.contentLength === source.size) {
    return {
      id: item.id,
      sourceKey: item.sourceKey,
      stageKey: item.stageKey,
      size: source.size,
      skipped: true,
      reason: "stage object already exists with matching size",
    };
  }

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

  if (source.size <= singlePutMaxBytes) {
    const data = await readR2ObjectRange(env, item.sourceKey, 0, source.size);
    await s3.putObject(item.stageKey, data, item);
  } else {
    await multipartUploadFromR2(env, s3, item, source.size, partSize);
  }

  const verified = await s3.headObject(item.stageKey);
  if (!verified || verified.contentLength !== source.size) {
    throw new Error(
      `Secondary stage verification failed for ${item.stageKey}: expected ${source.size}, got ${verified?.contentLength ?? "missing"}.`,
    );
  }

  return {
    id: item.id,
    sourceKey: item.sourceKey,
    stageKey: item.stageKey,
    size: source.size,
    uploaded: true,
  };
}

export async function commitObjectToAliases(env, item) {
  const s3 = createS3Client(env);
  const source = await s3.headObject(item.stageKey);
  if (!source) {
    throw new Error(`Cannot commit missing stage object: ${item.stageKey}`);
  }

  const aliases = [];
  for (const aliasKey of item.aliasKeys) {
    await s3.copyObject(item.stageKey, aliasKey);
    const verified = await s3.headObject(aliasKey);
    if (!verified || verified.contentLength !== source.contentLength) {
      throw new Error(
        `Secondary alias verification failed for ${aliasKey}: expected ${source.contentLength}, got ${verified?.contentLength ?? "missing"}.`,
      );
    }
    aliases.push({ key: aliasKey, size: verified.contentLength });
  }

  return {
    id: item.id,
    stageKey: item.stageKey,
    aliases,
    size: source.contentLength,
  };
}

export async function cleanupStageObjects(env, items) {
  const s3 = createS3Client(env);
  const deleted = [];
  for (const item of items) {
    await s3.deleteObject(item.stageKey);
    deleted.push(item.stageKey);
  }
  const stagePrefix = stagePrefixFromItems(items);
  if (stagePrefix) {
    for (const marker of [`${stagePrefix}/objects/`, `${stagePrefix}/`]) {
      await s3.deleteObject(marker);
      deleted.push(marker);
    }
  }
  return { deleted };
}

export async function deleteStaleAliasObjects(env, keys) {
  const s3 = createS3Client(env);
  const deleted = [];
  for (const key of keys) {
    await s3.deleteObject(key);
    deleted.push(key);
  }
  return { deleted };
}

function stagePrefixFromItems(items) {
  const first = items[0]?.stageKey || "";
  const marker = "/objects/";
  const index = first.indexOf(marker);
  return index === -1 ? "" : first.slice(0, index);
}

export async function pruneStaleLatestMacObjects(env, keepKeys, options = {}) {
  const s3 = createS3Client(env);
  const graceDays = parseNonNegativeInteger(
    options.graceDays ?? env.SECONDARY_SYNC_PRUNE_GRACE_DAYS,
    DEFAULT_PRUNE_GRACE_DAYS,
  );
  const cutoff = Date.now() - graceDays * 86400 * 1000;
  const keep = new Set(keepKeys);
  const objects = await s3.listObjects("latest/mac/");
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
    await s3.deleteObject(object.key);
    pruned.push(object.key);
  }

  return { pruned, graceDays };
}

export function decoratePlanWithStage(plan, instanceId, env = {}) {
  const safeTag = safeKeySegment(plan.releaseTag);
  const safeInstance = safeKeySegment(instanceId);
  const stagePrefix = cleanPrefix(env.SECONDARY_SYNC_STAGE_PREFIX || DEFAULT_STAGE_PREFIX);
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
      return 30;
    case "appcast":
      return 40;
    case "manifest":
      return 100;
    default:
      return 50;
  }
}

async function multipartUploadFromR2(env, s3, item, size, partSize) {
  const uploadId = await s3.createMultipartUpload(item.stageKey, item);
  const parts = [];
  try {
    const totalParts = Math.ceil(size / partSize);
    for (let partNumber = 1; partNumber <= totalParts; partNumber += 1) {
      const offset = (partNumber - 1) * partSize;
      const length = Math.min(partSize, size - offset);
      const data = await readR2ObjectRange(env, item.sourceKey, offset, length);
      const etag = await s3.uploadPart(item.stageKey, uploadId, partNumber, data);
      parts.push({ partNumber, etag });
    }
    await s3.completeMultipartUpload(item.stageKey, uploadId, parts);
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

async function headR2Object(env, key) {
  const object = await env.GLOBAL_R2.head(key);
  if (!object) {
    return null;
  }
  return { size: object.size };
}

async function readR2ObjectRange(env, key, offset, length) {
  const options =
    length > 0
      ? {
          range: { offset, length },
        }
      : undefined;
  const object = await env.GLOBAL_R2.get(key, options);
  if (!object) {
    throw new Error(`R2 object disappeared while syncing: ${key}`);
  }
  return object.arrayBuffer();
}

export function createS3Client(env) {
  return new S3Client({
    endpoint: requiredEnv(env, "SECONDARY_S3_ENDPOINT"),
    bucket: requiredEnv(env, "SECONDARY_S3_BUCKET"),
    region: env.SECONDARY_S3_REGION || "auto",
    accessKeyId: requiredEnv(env, "SECONDARY_S3_ACCESS_KEY_ID"),
    secretAccessKey: requiredEnv(env, "SECONDARY_S3_SECRET_ACCESS_KEY"),
  });
}

export class S3Client {
  constructor(options) {
    this.endpoint = options.endpoint;
    this.bucket = options.bucket;
    this.region = options.region || "auto";
    this.accessKeyId = options.accessKeyId;
    this.secretAccessKey = options.secretAccessKey;
  }

  async headObject(key) {
    const response = await this.request({ method: "HEAD", key, expectOk: false });
    if (response.status === 404) {
      return null;
    }
    if (response.status === 403) {
      const listed = await this.findObjectByKey(key);
      if (!listed) {
        return null;
      }
      return {
        key,
        contentLength: listed.size,
        etag: "",
        lastModified: listed.lastModified,
      };
    }
    await assertOk(response, "HEAD", key);
    const contentLength = Number.parseInt(response.headers.get("content-length") || "0", 10);
    if (contentLength === 0) {
      const listed = await this.findObjectByKey(key);
      if (listed && listed.size > 0) {
        return {
          key,
          contentLength: listed.size,
          etag: response.headers.get("etag") || "",
          lastModified: listed.lastModified,
        };
      }
    }
    return {
      key,
      contentLength,
      etag: response.headers.get("etag") || "",
      lastModified: parseHttpDate(response.headers.get("last-modified")),
    };
  }

  async findObjectByKey(key) {
    const objects = await this.listObjects(key);
    return objects.find((object) => object.key === key) || null;
  }

  async getObjectText(key) {
    const response = await this.request({ method: "GET", key, expectOk: false });
    if (response.status === 404) {
      throw new Error(`S3 GET ${key} failed with HTTP 404.`);
    }
    await assertOk(response, "GET", key);
    return response.text();
  }

  async putObject(key, body, metadata) {
    const response = await this.request({
      method: "PUT",
      key,
      headers: objectMetadataHeaders(metadata),
      body,
    });
    await assertOk(response, "PUT", key);
    return response;
  }

  async createMultipartUpload(key, metadata) {
    const response = await this.request({
      method: "POST",
      key,
      query: [["uploads", ""]],
      headers: objectMetadataHeaders(metadata),
    });
    await assertOk(response, "POST", `${key}?uploads`);
    const xml = await response.text();
    const uploadId = xmlText(xml, "UploadId");
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
    });
    await assertOk(response, "PUT", `${key} part ${partNumber}`);
    const etag = response.headers.get("etag");
    if (!etag) {
      throw new Error(`S3 upload part response for ${key} part ${partNumber} did not include ETag.`);
    }
    return etag;
  }

  async completeMultipartUpload(key, uploadId, parts) {
    const body = completeMultipartXml(parts);
    const response = await this.request({
      method: "POST",
      key,
      query: [["uploadId", uploadId]],
      headers: {
        "content-type": "application/xml",
      },
      body,
    });
    await assertOk(response, "POST", `${key}?uploadId=${uploadId}`);
    return response;
  }

  async abortMultipartUpload(key, uploadId) {
    const response = await this.request({
      method: "DELETE",
      key,
      query: [["uploadId", uploadId]],
      expectOk: false,
    });
    if (response.status === 404) {
      return response;
    }
    await assertOk(response, "DELETE", `${key}?uploadId=${uploadId}`);
    return response;
  }

  async copyObject(sourceKey, destinationKey) {
    const response = await this.request({
      method: "PUT",
      key: destinationKey,
      headers: {
        "x-amz-copy-source": `/${encodeRfc3986(this.bucket)}/${encodeKeyPath(sourceKey)}`,
      },
    });
    await assertOk(response, "COPY", `${sourceKey} -> ${destinationKey}`);
    return response;
  }

  async deleteObject(key) {
    const response = await this.request({ method: "DELETE", key, expectOk: false });
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
      });
      await assertOk(response, "LIST", prefix);
      const xml = await response.text();
      for (const entry of xmlContents(xml)) {
        objects.push(entry);
      }
      continuationToken = xmlText(xml, "NextContinuationToken");
    } while (continuationToken);
    return objects;
  }

  async request({ method, key = "", query = [], headers = {}, body, expectOk = true }) {
    const endpoint = new URL(this.endpoint);
    const now = new Date();
    const amzDate = formatAmzDate(now);
    const dateStamp = amzDate.slice(0, 8);
    const credentialScope = `${dateStamp}/${this.region}/s3/aws4_request`;
    const canonicalUri = canonicalS3Uri(endpoint, this.bucket, key);
    const canonicalQuery = canonicalQueryString(query);
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

    const target = `${endpoint.protocol}//${endpoint.host}${canonicalUri}${
      canonicalQuery ? `?${canonicalQuery}` : ""
    }`;
    const response = await fetch(target, {
      method,
      headers: requestHeaders,
      body,
    });

    if (expectOk) {
      await assertOk(response, method, key || this.bucket);
    }
    return response;
  }
}

function objectMetadataHeaders(metadata) {
  return {
    "cache-control": metadata.cacheControl || DEFAULT_CACHE_CONTROL,
    "content-disposition": `attachment; filename="${metadata.filename}"`,
    "content-type": metadata.contentType || "application/octet-stream",
  };
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
  throw new Error(
    `S3 ${operation} ${key} failed with HTTP ${response.status}${body ? `: ${body.slice(0, 600)}` : "."}`,
  );
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

async function getWorkflowIfExists(env, id) {
  try {
    return await env.SECONDARY_MIRROR_WORKFLOW.get(id);
  } catch {
    return null;
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
      lastModified: parseHttpDate(xmlText(block, "LastModified")),
    });
  }
  return entries;
}

function decodeXmlText(value) {
  return String(value)
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
