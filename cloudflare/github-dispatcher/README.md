# codex-app-mirror Cloudflare dispatcher

Cloudflare Cron Trigger 主调度实例：每 15 分钟 dispatch `codex-app-mirror` 与
`agents-cli-mirror` 的 `mirror.yml`（GitHub Actions `schedule` 仍作为每 6 小时的
低频兜底）。

**Worker 源码在 [Wangnov/agents-mirror-kit](https://github.com/Wangnov/agents-mirror-kit)
的 `workers/github-dispatcher/`**；本目录只保留这个实例的部署配置
`wrangler.jsonc`（实例名、cron、`DISPATCH_TARGETS`）。

部署的 Worker 必须构建自 CI 校验的同一个 tag：当前是 `v0.2.0`（见
`.github/workflows/ci.yml` 中 `Checkout agents-mirror-kit` 步骤的 `ref`）。部署
前先确认该文件里的 `ref` 没有变，再用相同 tag clone kit 仓库。

## Deploy

```bash
git clone --depth 1 --branch v0.2.0 https://github.com/Wangnov/agents-mirror-kit
cp cloudflare/github-dispatcher/wrangler.jsonc agents-mirror-kit/workers/github-dispatcher/
cd agents-mirror-kit/workers/github-dispatcher
npx wrangler deploy
npx wrangler secret put GITHUB_TOKEN   # 首次部署或换 token 时
```

Worker 部署是手动的（`npx wrangler deploy`），不在任何 GitHub Actions 工作流里
自动执行；改完配置或 kit 版本后需要有人手动重新部署。

## GitHub token

Fine-grained PAT，Repository access 覆盖 `DISPATCH_TARGETS` 中的所有仓库，
权限 `Actions -> Read and write`。只存 Worker secret，不进任何文件。

## Schedule

- Cloudflare 主调度：`7,22,37,52 * * * *`（UTC，每 15 分钟）
- GitHub 兜底：`11 */6 * * *`（UTC，每 6 小时）
