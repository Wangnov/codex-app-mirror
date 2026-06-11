# codex-app-mirror Cloudflare dispatcher

This Worker uses Cloudflare Cron Triggers as the primary 15-minute scheduler for
`codex-app-mirror` and `agents-cli-mirror`. It does not mirror files itself. It
only calls the GitHub Actions `workflow_dispatch` API for the configured mirror
workflows.

GitHub Actions `schedule` remains in the repository as a low-frequency fallback.

## Why this exists

GitHub scheduled workflows can be delayed or skipped during busy periods. A
Cloudflare Cron Trigger gives us a separate scheduler while keeping the existing
GitHub Actions release pipeline unchanged.

## GitHub token

Create a fine-grained personal access token:

- Repository access: `Wangnov/codex-app-mirror` and `Wangnov/agents-cli-mirror`
- Repository permissions: `Actions` -> `Read and write`
- Expiration: 90 or 180 days recommended

Store it as a Cloudflare Worker secret:

```bash
npx wrangler secret put GITHUB_TOKEN
```

Do not put the token in `wrangler.jsonc`, `.dev.vars`, or source code.

## Deploy

```bash
cd cloudflare/github-dispatcher
npm install
npx wrangler login
npx wrangler secret put GITHUB_TOKEN
npx wrangler deploy
```

Cron trigger changes may take several minutes to propagate.

## Local scheduled test

```bash
cd cloudflare/github-dispatcher
npm install
npx wrangler dev --test-scheduled
curl "http://localhost:8787/__scheduled?cron=7,22,37,52+*+*+*+*"
```

The local test will trigger the real GitHub workflow if `GITHUB_TOKEN` is set in
local development secrets.

## Schedule

Cloudflare primary schedule:

```text
7,22,37,52 * * * *
```

That is every 15 minutes in UTC.

GitHub fallback schedule:

```text
11 */6 * * *
```

That is every 6 hours in UTC.
