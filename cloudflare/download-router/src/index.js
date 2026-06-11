const DEFAULT_SECONDARY_COUNTRY_CODES = "CN";
const DEFAULT_SIGNED_URL_TTL_SECONDS = 3600;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (!isAllowedLatestPath(url.pathname)) {
      return new Response("Not found", { status: 404 });
    }

    const country = request.cf?.country || request.headers.get("CF-IPCountry") || "";
    const secondaryCountryCodes = new Set(
      (env.SECONDARY_COUNTRY_CODES || DEFAULT_SECONDARY_COUNTRY_CODES)
        .split(",")
        .map((code) => code.trim().toUpperCase())
        .filter(Boolean),
    );

    if (secondaryCountryCodes.has(country.toUpperCase()) && hasSecondaryS3Config(env)) {
      try {
        const objectKey = objectKeyForPath(url.pathname, env.SECONDARY_S3_PREFIX || "");
        const downloadMetadata = downloadMetadataForPath(url.pathname);
        const signedUrl = await presignS3GetUrl({
          endpoint: env.SECONDARY_S3_ENDPOINT,
          bucket: env.SECONDARY_S3_BUCKET,
          key: objectKey,
          region: env.SECONDARY_S3_REGION || "auto",
          accessKeyId: env.SECONDARY_S3_ACCESS_KEY_ID,
          secretAccessKey: env.SECONDARY_S3_SECRET_ACCESS_KEY,
          expiresInSeconds: ttlSeconds(env.SECONDARY_S3_SIGNED_URL_TTL_SECONDS),
          responseHeaders: downloadMetadata
            ? {
                "response-content-disposition": `attachment; filename="${downloadMetadata.filename}"`,
                "response-content-type": downloadMetadata.contentType,
              }
            : {},
        });

        return redirect(signedUrl);
      } catch (error) {
        console.error(
          JSON.stringify({
            event: "secondary_s3_presign_failed",
            path: url.pathname,
            country,
            error: error instanceof Error ? error.message : String(error),
          }),
        );
      }
    }

    if (!env.GLOBAL_MIRROR_BASE_URL) {
      return new Response("Missing GLOBAL_MIRROR_BASE_URL", { status: 500 });
    }

    return redirect(withPathAndSearch(env.GLOBAL_MIRROR_BASE_URL, url.pathname, url.search).toString(), {
      "X-Mirror-Fallback": "global",
    });
  },
};

function isAllowedLatestPath(pathname) {
  const aliases = new Set([
    "/latest/win",
    "/latest/mac-arm64",
    "/latest/mac-intel",
    "/latest/checksums",
    "/latest/manifest",
    "/latest/appcast.xml",
    "/latest/appcast-x64.xml",
  ]);
  if (aliases.has(pathname)) {
    return true;
  }

  return /^\/latest\/mac\/(arm64|intel)\/[^/]+\.(zip|delta)$/.test(pathname);
}

function hasSecondaryS3Config(env) {
  return Boolean(
    env.SECONDARY_S3_ENDPOINT &&
      env.SECONDARY_S3_BUCKET &&
      env.SECONDARY_S3_ACCESS_KEY_ID &&
      env.SECONDARY_S3_SECRET_ACCESS_KEY,
  );
}

function ttlSeconds(value) {
  const parsed = Number.parseInt(value || DEFAULT_SIGNED_URL_TTL_SECONDS, 10);
  if (!Number.isFinite(parsed)) {
    return DEFAULT_SIGNED_URL_TTL_SECONDS;
  }
  return Math.min(Math.max(parsed, 1), 604800);
}

function redirect(location, extraHeaders = {}) {
  return new Response(null, {
    status: 302,
    headers: {
      Location: location,
      "Cache-Control": "private, no-store",
      ...extraHeaders,
    },
  });
}

function withPathAndSearch(baseUrl, pathname, search) {
  const target = new URL(baseUrl);
  const basePath = target.pathname === "/" ? "" : target.pathname.replace(/\/$/, "");
  target.pathname = `${basePath}${pathname}`;
  target.search = search;
  return target;
}

function objectKeyForPath(pathname, prefix) {
  const cleanPrefix = prefix.replace(/^\/+|\/+$/g, "");
  const cleanPath = pathname.replace(/^\/+/, "");
  return cleanPrefix ? `${cleanPrefix}/${cleanPath}` : cleanPath;
}

function downloadMetadataForPath(pathname) {
  const name = pathname.replace(/^\/+/, "").split("/").pop();
  const metadata = {
    "mac-arm64": {
      filename: "Codex-mac-arm64.dmg",
      contentType: "application/x-apple-diskimage",
    },
    "mac-intel": {
      filename: "Codex-mac-x64.dmg",
      contentType: "application/x-apple-diskimage",
    },
    win: {
      filename: "Codex-Windows-x64.msix",
      contentType: "application/vnd.ms-appx",
    },
    checksums: {
      filename: "SHA256SUMS.txt",
      contentType: "text/plain; charset=utf-8",
    },
    manifest: {
      filename: "release-manifest.json",
      contentType: "application/json",
    },
  };
  return metadata[name] || null;
}

async function presignS3GetUrl(options) {
  const endpointUrl = new URL(options.endpoint);
  const now = new Date();
  const amzDate = formatAmzDate(now);
  const dateStamp = amzDate.slice(0, 8);
  const credentialScope = `${dateStamp}/${options.region}/s3/aws4_request`;
  const signedHeaders = "host";
  const canonicalUri = canonicalS3Uri(endpointUrl, options.bucket, options.key);

  const queryParams = [
    ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
    ["X-Amz-Credential", `${options.accessKeyId}/${credentialScope}`],
    ["X-Amz-Date", amzDate],
    ["X-Amz-Expires", String(options.expiresInSeconds)],
    ["X-Amz-SignedHeaders", signedHeaders],
    ...Object.entries(options.responseHeaders || {}),
  ];
  const canonicalQuery = canonicalQueryString(queryParams);
  const canonicalHeaders = `host:${endpointUrl.host}\n`;
  const canonicalRequest = [
    "GET",
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const canonicalRequestHash = await sha256Hex(canonicalRequest);
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    canonicalRequestHash,
  ].join("\n");
  const signingKey = await signingKeyBytes(options.secretAccessKey, dateStamp, options.region, "s3");
  const signature = toHex(await hmac(signingKey, stringToSign));

  endpointUrl.pathname = canonicalUri;
  endpointUrl.search = `${canonicalQuery}&X-Amz-Signature=${signature}`;
  return endpointUrl.toString();
}

function canonicalS3Uri(endpointUrl, bucket, key) {
  const basePath = endpointUrl.pathname === "/" ? "" : endpointUrl.pathname.replace(/\/$/, "");
  const encodedKey = key.split("/").map(encodeRfc3986).join("/");
  return `${basePath}/${encodeRfc3986(bucket)}/${encodedKey}`;
}

function canonicalQueryString(params) {
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

function encodeRfc3986(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
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
  const digest = await crypto.subtle.digest("SHA-256", utf8(value));
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
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, utf8(value));
  return new Uint8Array(signature);
}

function utf8(value) {
  return new TextEncoder().encode(value);
}

function toHex(bytes) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
