# AGENTS.md

Canonical agent guide for `codex-app-mirror`. Both Codex and Claude Code load
this file (`CLAUDE.md` in this repo is just `@AGENTS.md`).

## What this repo does

`codex-app-mirror` mirrors the official OpenAI Codex desktop installers to
GitHub Releases, plus a Cloudflare-backed CDN and a Sparkle appcast for
macOS incremental updates. It is the update backend for the downstream
`Wangnov/Codex-App-Manager` desktop client.

## What it never does

- **Verbatim redistribution only.** Installers, Sparkle archives, and their
  EdDSA signatures are copied byte-for-byte from the official source. The
  code **never builds, modifies, or re-signs** any package. Only the
  `enclosure` URL in the Sparkle appcast is rewritten to point at the mirror;
  the signed bytes are untouched, so the original signature stays valid.
- **Never manages ChatGPT Classic** (`com.openai.chat`). Only the Codex
  product lineage (`com.openai.codex` / `OpenAI.Codex` and their Beta
  variants) is in scope, even though upstream file/display names changed
  after the ChatGPT rebrand. See `docs/chatgpt-rebrand-recovery.md` for the
  full contract (manifest fields `sourceBasename` vs
  `mirrorEnclosureBasename`, identity gates, etc.) before touching any
  probe/download/publish script.

## Channels: `stable | beta | linux-preview`

These are strictly separate and must not leak into each other:

- **stable**: Windows MSIX (x64 required, ARM64 optional) + macOS DMG/Sparkle
  (arm64 + x64). Published to GitHub Release *and* synced to R2/S3, advances
  `latest/*` short links and the Sparkle appcast.
- **beta**: GitHub-only prerelease, manually triggered
  (`Publish Beta GitHub prerelease` workflow). Never uploads to R2/S3, never
  advances GitHub Latest or any `latest/*` key, never produces a
  subscribable appcast. See `docs/beta-prerelease.md`.
- **linux-preview**: unified ChatGPT desktop app for Ubuntu/Debian (DEB) and
  Fedora (RPM), x64 + arm64. GitHub-only prerelease
  (`codex-app-linux-preview-<version>`); never touches CDN/`latest/*`.
  Verifies OpenAI APT/RPM repo signatures and package SHA-256 before
  publishing.

## Publishing pipeline & consistency contract

`mirror.yml` runs: **probe → compare against the latest release manifest →
download only if changed → checksum + manifest + appcast → publish Release →
sync to R2 → trigger secondary S3 sync**. No upstream change means no
download and no duplicate release.

`latest/manifest`, `latest/checksums`, `latest/win-*`, and the macOS appcasts
are one **consistency unit** — R2/S3 have no cross-object transactions, so
they are never switched over per-platform. Read
`docs/chatgpt-rebrand-recovery.md` §"契约 3" before changing anything that
writes to a `latest/*` key; it also documents the maintenance-window
procedure and rollback order.

## Local test commands (mirrors `.github/workflows/ci.yml`)

Run from the repo root:

```bash
bash -n scripts/*.sh                      # shell syntax check
actionlint                                # workflow lint (installed separately)
scripts/test-*.sh                         # every fixture test, e.g.:
scripts/test-probe-release.sh
scripts/test-build-appcast.sh
scripts/test-download-macos.sh
scripts/test-prepare-windows-portable.sh
scripts/test-sync-secondary-s3.sh
# ...and the rest of scripts/test-*.sh (see ci.yml `validate` job for the full list)
node cloudflare/download-router/validate-config.mjs   # needs .mirror-kit checked out (see below)
npm ci --prefix cloudflare/secondary-sync && npm run check --prefix cloudflare/secondary-sync
dotnet build scripts/store-link/StoreLink.csproj --configuration Release
```

macOS-only job (`macos-identity`, runs on `macos-latest` in CI):

```bash
scripts/test-read-macos-metadata.sh
```

`download-windows.ps1` is validated with the PowerShell parser (see
`ci.yml`); a bare `pwsh -c "... ParseFile(...)"` reproduces it if `pwsh` is
available locally.

## Where Worker sources live / pinned kit tag

The Cloudflare Worker code for the download router and the GitHub dispatcher
lives in a separate repo, **`Wangnov/agents-mirror-kit`**, not here. This
repo only keeps the per-instance deploy config (`wrangler.jsonc`) under
`cloudflare/download-router/` and `cloudflare/github-dispatcher/`.
`cloudflare/secondary-sync/` is the one Worker whose source *is* local.

CI checks out the kit at a **pinned tag** (currently `v0.2.0`, see
`Checkout agents-mirror-kit` step in `ci.yml`, `mirror.yml`, `stats.yml`) to
`.mirror-kit/` and runs `cloudflare/download-router/validate-config.mjs`
against it, and the kit's own worker code for the dispatcher. Any deployed
Worker must be built from that same tag — check `ci.yml`'s `ref:` before
deploying, and update every workflow file (not just one) plus
`cloudflare/github-dispatcher/README.md` together when the pinned tag
changes.

**Worker deploys are manual** (`npx wrangler deploy`), never part of a
GitHub Actions workflow. After bumping the pinned kit tag or changing a
`wrangler.jsonc`, someone has to redeploy by hand.

## Secrets

Secrets (GitHub tokens, S3/R2 credentials, sync auth tokens) are set with
`wrangler secret put` or GitHub Actions repo/environment secrets. They never
go into any file in this repo, including `wrangler.jsonc` — see the
`## Required secrets` section of each `cloudflare/*/README.md` for the exact
names expected.

## Known dependency thresholds

- `cloudflare/secondary-sync`'s `wrangler` devDependency must stay at
  **`wrangler@4.131.0` or newer** (currently pinned `^4.135.0`). Below that,
  `wrangler`'s transitive `miniflare` → `sharp` resolves to `sharp < 0.35.4`,
  which is Dependabot alert-severity `high` (GHSA for `sharp`'s libvips
  heap overflow). `wrangler@4.130.0` still resolves `sharp@0.35.2`;
  `4.131.0` is the first release that resolves `sharp@0.35.4`. Re-check
  `npm ls sharp --prefix cloudflare/secondary-sync` after any future
  `wrangler` version change (up or down) to confirm `sharp` stays
  `>= 0.35.4`.

## PR / commit conventions

- English, Conventional Commits style (`fix(scope): ...`, `feat: ...`,
  `docs: ...`, `ci: ...`), matching `git log`.
- `mirror.yml` runs on a 15-minute Cloudflare Cron dispatch in production
  plus a 6-hour GitHub Actions `schedule` fallback — treat changes to probe
  logic, the release manifest schema, or `latest/*` writers as
  production-sensitive; prefer a PR and let CI (`ci.yml`) pass before
  merging.
- Do not hand-edit generated fixtures under `scripts/test-*.sh` without
  running them; they assert byte-for-byte behavior against recorded mocks.
