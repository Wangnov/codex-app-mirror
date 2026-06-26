# Codex App secondary mirror sync

Cloudflare Worker + Workflow that copies the current R2 mirror into the
secondary S3-compatible mirror from Cloudflare's network instead of a GitHub
hosted runner.

## Flow

1. GitHub publishes the Release and finishes the R2 `latest/*` sync.
2. GitHub calls `POST /sync/start` with the release tag.
3. The Workflow reads R2 in ranges and uploads objects to an IHEP staging prefix.
4. It copies staging objects to `latest/*` on IHEP, committing `latest/manifest`
   after installers, Sparkle archives, checksums, and appcasts.
5. It prunes stale `latest/mac/*` Sparkle archives outside the grace window and
   removes staging objects.

## Required secrets

Set these with `wrangler secret put`:

- `SYNC_AUTH_TOKEN`
- `SECONDARY_S3_ENDPOINT`
- `SECONDARY_S3_BUCKET`
- `SECONDARY_S3_ACCESS_KEY_ID`
- `SECONDARY_S3_SECRET_ACCESS_KEY`

GitHub Actions should store the public Worker endpoint in
`CF_SECONDARY_SYNC_URL` and the same bearer token in `CF_SECONDARY_SYNC_TOKEN`.

## Commands

```bash
npm install
npm run check
npm run deploy
```

Start a sync:

```bash
curl -fsS "$CF_SECONDARY_SYNC_URL/sync/start" \
  -H "Authorization: Bearer $CF_SECONDARY_SYNC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"releaseTag":"codex-app-win-...","force":false}'
```

Check status:

```bash
curl -fsS "$CF_SECONDARY_SYNC_URL/sync/status?id=<workflow-instance-id>" \
  -H "Authorization: Bearer $CF_SECONDARY_SYNC_TOKEN"
```
