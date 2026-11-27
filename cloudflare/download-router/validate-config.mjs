// CI guard: run this mirror's real wrangler.jsonc (ROUTE_CONFIG + access policy
// + split TTL + extended analytics) and Cloudflare Zone rules against the pinned
// kit download-router worker. Requires agents-mirror-kit checked out at .mirror-kit.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const wrangler = JSON.parse(
  readFileSync(new URL("./wrangler.jsonc", import.meta.url), "utf8"),
);
const redirectRule = JSON.parse(
  readFileSync(new URL("../zone-rules/codexapp-r2-redirect.json", import.meta.url), "utf8"),
);
const wafRule = JSON.parse(
  readFileSync(new URL("../zone-rules/agentsmirror-waf-block.json", import.meta.url), "utf8"),
);
const cacheBypassRule = JSON.parse(
  readFileSync(new URL("../zone-rules/codexapp-r2-cache-bypass.json", import.meta.url), "utf8"),
);

const vars = wrangler.vars || {};
const routeConfig = vars.ROUTE_CONFIG;
assert.ok(routeConfig && routeConfig.aliases, "wrangler.jsonc must define vars.ROUTE_CONFIG.aliases");
assert.ok(Array.isArray(vars.BLOCKED_UA_SUBSTRINGS) && vars.BLOCKED_UA_SUBSTRINGS.length > 0, "wrangler.jsonc must define vars.BLOCKED_UA_SUBSTRINGS");
assert.ok(Array.isArray(vars.BLOCKED_REFERER_HOSTS) && vars.BLOCKED_REFERER_HOSTS.length > 0, "wrangler.jsonc must define vars.BLOCKED_REFERER_HOSTS");

// Guard against overly broad substrings or explicitly exempted open-source / low-impact clients.
for (const forbiddenOrExempt of [
  "manager",
  "updater",
  "installer",
  "setup",
  "codex",
  "claude",
  "mirror",
  "curl",
  "xingmang-ai-manager",
  "codex2api",
  "copilotbridgenative",
  "yuluogptsetup",
  "xiaojiassistant",
  "chatgptlauncher-codexinstaller",
  "kjhassistant",
  "c2a agent studio",
  "codestudio lite",
  "winipptchannelchecker",
  "netdisk;p2sp",
  "quarkpc",
  "ciyuan",
  "codex-desktop-zh",
  "pimpmyclaude",
]) {
  assert.ok(
    !vars.BLOCKED_UA_SUBSTRINGS.includes(forbiddenOrExempt),
    `BLOCKED_UA_SUBSTRINGS must not include generic or exempt token: ${forbiddenOrExempt}`,
  );
}

// Validate codexapp-r2 Single Redirect Rule stays 1:1 aligned with BLOCKED_UA_SUBSTRINGS and within 4KB.
assert.equal(redirectRule.enabled, true, "redirect rule must be enabled");
assert.equal(redirectRule.action, "redirect", "redirect rule must use redirect action");
assert.equal(redirectRule.ref, "codexapp_r2_unauthorized_ua_redirect", "redirect rule must declare explicit ref");
const utf8Bytes = (s) => Buffer.byteLength(s, "utf8");
assert.ok(utf8Bytes(redirectRule.expression) < 4096, `redirect rule expression exceeds 4096 bytes: ${utf8Bytes(redirectRule.expression)}`);
assert.ok(
  redirectRule.expression.includes('http.host eq "codexapp-r2.agentsmirror.com"'),
  "redirect rule must target codexapp-r2.agentsmirror.com without /latest/ prefix to close %2F bypass",
);
assert.ok(
  !redirectRule.expression.includes('starts_with(http.request.uri.path, "/latest/")'),
  "redirect rule must not restrict to /latest/ prefix on codexapp-r2 (prevents %2F encoded path bypass)",
);
assert.ok(
  redirectRule.expression.includes('not starts_with(http.request.uri.path, "/stats/")'),
  "redirect rule must exclude /stats/* paths",
);
assert.equal(
  redirectRule.action_parameters?.from_value?.target_url?.value,
  "https://codexapp.agentsmirror.com/latest/manifest?mirror_policy=r2",
  "redirect rule must target constant allowed alias with ?mirror_policy=r2 loop breaker",
);
assert.equal(redirectRule.action_parameters?.from_value?.preserve_query_string, false);
assert.equal(redirectRule.action_parameters?.from_value?.status_code, 307);

const ruleUaMatches = [...redirectRule.expression.matchAll(/lower\(http\.user_agent\) contains "([^"]+)"/g)].map(
  (m) => m[1],
);
assert.deepEqual(
  ruleUaMatches,
  vars.BLOCKED_UA_SUBSTRINGS,
  "codexapp-r2 redirect rule UA list must stay 1:1 aligned with BLOCKED_UA_SUBSTRINGS",
);

// Validate Edge WAF Custom Rule offloads extreme-quota pollers and backend proxies before Worker invocation.
assert.equal(wafRule.enabled, true, "WAF rule must be enabled");
assert.equal(wafRule.ref, "codexapp_mirror_backend_proxy_block");
assert.equal(wafRule.action, "block");
assert.ok(utf8Bytes(wafRule.expression) < 4096, `WAF rule expression exceeds 4096 bytes: ${utf8Bytes(wafRule.expression)}`);
for (const wafUa of ["kakou/", "auto-gateway-codex", "codexdownloadproxy", "hermes-cron"]) {
  assert.ok(
    wafRule.expression.includes(`lower(http.user_agent) contains "${wafUa}"`),
    `WAF rule must offload '${wafUa}' at Cloudflare Edge`,
  );
  assert.ok(
    vars.BLOCKED_UA_SUBSTRINGS.includes(wafUa),
    `WAF-blocked UA '${wafUa}' must also exist in Worker BLOCKED_UA_SUBSTRINGS as defense-in-depth`,
  );
}
for (const edgeOnlyToken of ["yumebox", "awariobot", "15.235.198.243", "2402:1f00:8000:800::2245"]) {
  assert.ok(
    wafRule.expression.includes(edgeOnlyToken),
    `WAF rule must include edge-blocked scraper/proxy token '${edgeOnlyToken}'`,
  );
}

// Validate Cache Bypass Rule on codexapp-r2 prevents Cloudflare Free-plan (>512MiB) cache fill from stripping HTTP Range on .zip archives and installer aliases, without matching metadata/stats/delta paths.
assert.equal(cacheBypassRule.enabled, true, "cache bypass rule must be enabled");
assert.equal(cacheBypassRule.ref, "codexapp_r2_large_binary_cache_bypass");
assert.equal(cacheBypassRule.action, "set_cache_settings");
assert.equal(cacheBypassRule.action_parameters?.cache, false);
assert.ok(utf8Bytes(cacheBypassRule.expression) < 4096, `cache bypass rule expression exceeds 4096 bytes: ${utf8Bytes(cacheBypassRule.expression)}`);
assert.ok(
  cacheBypassRule.expression.includes('http.host eq "codexapp-r2.agentsmirror.com"'),
  "cache bypass rule must target codexapp-r2.agentsmirror.com",
);
for (const [aliasPath, aliasSpec] of Object.entries(routeConfig.aliases)) {
  if (aliasSpec.category === "installer") {
    assert.ok(
      cacheBypassRule.expression.includes(`"${aliasPath}"`),
      `cache bypass rule must cover installer alias '${aliasPath}'`,
    );
  } else {
    assert.ok(
      !cacheBypassRule.expression.includes(`"${aliasPath}"`),
      `cache bypass rule must not match metadata alias '${aliasPath}'`,
    );
  }
}
assert.ok(
  cacheBypassRule.expression.includes('ends_with(http.request.uri.path, ".zip")'),
  "cache bypass rule must cover full Sparkle .zip archives",
);
assert.ok(
  !cacheBypassRule.expression.includes(".delta"),
  "cache bypass rule must not match Sparkle .delta paths",
);

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

async function run(path, { country = "US", method = "GET", secondary = false, headers = {}, envOverrides = {} } = {}) {
  const downloads = analytics();
  const abuse = analytics();
  const env = {
    ...vars,
    DOWNLOAD_ANALYTICS: downloads,
    ABUSE_ANALYTICS: abuse,
    ABUSE_SAMPLE_RATE: "1",
    ...(secondary ? SECONDARY : {}),
    ...envOverrides,
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

// Sparkle full archive and delta patterns: both must route cleanly, and CN HEAD must sign HEAD method.
{
  const zipRes = await run("/latest/mac/arm64/Codex-darwin-arm64-2.0.0.zip", { headers: { "User-Agent": "ChatGPT/26.1117 Sparkle" } });
  assert.equal(zipRes.status, 302);
  assert.deepEqual(zipRes.points[0].blobs.slice(0, 3), ["global", "US", "update-full"]);

  const deltaRes = await run("/latest/mac/arm64/Codex-1.2.3-arm64.delta", { headers: { "User-Agent": "ChatGPT/26.1117 Sparkle" } });
  assert.equal(deltaRes.status, 302);
  assert.deepEqual(deltaRes.points[0].blobs.slice(0, 3), ["global", "US", "update-delta"]);

  const cnGet = await run("/latest/win-x64", { country: "CN", secondary: true, method: "GET" });
  const cnHead = await run("/latest/win-x64", { country: "CN", secondary: true, method: "HEAD" });
  assert.equal(cnGet.status, 302);
  assert.equal(cnHead.status, 302);
  assert.equal(cnHead.points.length, 0);
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

// Exempted / harmless / open-source clients pass cleanly with 302.
for (const allowedUa of [
  "xingmang-ai-manager/0.2.24",
  "codex2api",
  "CopilotBridgeNative/1.5.6",
  "YuluoGptSetup/2.0",
  "XiaojiAssistant-CodexInstaller/1",
  "ChatGPTLauncher-CodexInstaller/1",
  "KJHAssistant/1.20.0",
  "C2A Agent Studio/1.0",
  "CodeStudio Lite/0.1.0",
  "WinIpptChannelChecker/1.0",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) QuarkPC/7.4.0",
  "netdisk;P2SP;3.0.20.138",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
  "",
]) {
  const r = await run("/latest/win-x64", { headers: allowedUa ? { "User-Agent": allowedUa } : {} });
  assert.equal(r.status, 302, `expected UA to be allowed: '${allowedUa}'`);
}

// Verified high-harm commercial parasites & scrapers (including CJK ByteString) receive 403 JSON.
for (const blockedUa of [
  "Kakou/0.5.55",
  asLatin1ByteString("Mozilla/5.0 越途AI智枢/1.9.0 Electron/43.2.0"),
  "YueTuNexus/1.3.5",
  "funtoolkit/0.1",
  "NiceCodeTools/1.3.40",
  "AUTO-Gateway-Codex-Mirror/1.0",
  "autogateway-desktop/1.2.0",
  "CCSwitchPro-ResourceWorker/1.0",
  "RelayAutoConfig/1.0",
  "RelayAssistant/0.1 (+Windows)",
  "yaoyao-chatgpt/0.1",
  "yaoyao-claude/0.1",
  "CodexDownloadProxy/1.0",
  "yihaogpt-tools",
  "Mozilla/5.0 Hermes-Cron/1.0",
  "TianyuLink-Installer/0.4",
  "PojiaManager-Updater/1.0 (Windows; +https://codexapp.agentsmirror.com)",
]) {
  const r = await run("/latest/win-x64", {
    country: "CN",
    secondary: true,
    headers: { "User-Agent": blockedUa },
  });
  assert.equal(r.status, 403, `expected UA to be blocked: '${blockedUa}'`);
  assert.equal(r.res.headers.get("X-Mirror-Policy"), "client-not-authorized");
  const body = await r.res.json();
  assert.equal(body.error, "client_not_authorized");
  assert.ok(JSON.stringify(body).includes("IHEP"), "Codex 403 JSON must retain CAS IHEP attribution");
  assert.equal(r.points.length, 0);
  assert.equal(r.abuse.length, 1);
}

// Loop-breaker target from codexapp-r2 Single Redirect Rule terminates in 403 even if BLOCK_MODE=shadow.
{
  const bounced = await run("/latest/manifest?mirror_policy=r2", {
    headers: { "User-Agent": "funtoolkit/0.1" },
    envOverrides: { BLOCK_MODE: "shadow" },
  });
  assert.equal(bounced.status, 403);
  assert.equal(bounced.abuse.length, 1);
  assert.equal(bounced.abuse[0].blobs[0], "blocked-r2-redirect");
}

// Hotlink Referer redirects back to official home page.
{
  const r = await run("/latest/win-x64", { headers: { Referer: "https://gpt.dqtx.cc/guide" } });
  assert.equal(r.status, 302);
  assert.equal(r.location, "https://codexapp.agentsmirror.com/");
  assert.equal(r.abuse.length, 1);
}

console.log("download-router config and zone rules validated against kit worker");
