# codex-app-mirror Cloudflare dispatcher

Cloudflare Cron Trigger 主调度实例：每 15 分钟 dispatch `codex-app-mirror` 与
`agents-cli-mirror` 的 `mirror.yml`（GitHub Actions `schedule` 仍作为每 6 小时的
低频兜底）。

**Worker 源码在 [Wangnov/agents-mirror-kit](https://github.com/Wangnov/agents-mirror-kit)
的 `workers/github-dispatcher/`**；本目录只保留这个实例的部署配置
`wrangler.jsonc`（实例名、cron、`DISPATCH_TARGETS`）。

## Deploy

```bash
git clone --depth 1 --branch v0.1.0 https://github.com/Wangnov/agents-mirror-kit
cp cloudflare/github-dispatcher/wrangler.jsonc agents-mirror-kit/workers/github-dispatcher/
cd agents-mirror-kit/workers/github-dispatcher
npx wrangler deploy
npx wrangler secret put GITHUB_TOKEN   # 首次部署或换 token 时
```

## GitHub token

Fine-grained PAT，Repository access 覆盖 `DISPATCH_TARGETS` 中的所有仓库，
权限 `Actions -> Read and write`。只存 Worker secret，不进任何文件。

## Schedule

- Cloudflare 主调度：`7,22,37,52 * * * *`（UTC，每 15 分钟）
- GitHub 兜底：`11 */6 * * *`（UTC，每 6 小时）
