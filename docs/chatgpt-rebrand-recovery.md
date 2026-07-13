# ChatGPT rebrand recovery — Stable P0 implementation contract

> 状态：**Stable P0 已实施**。设计讨论与完整取证见 [#37](https://github.com/Wangnov/codex-app-mirror/issues/37)。Beta（#36）仍不进入 Stable 镜像通道；其 GitHub-only 按需发布边界见 [`beta-prerelease.md`](./beta-prerelease.md)。

## 背景（一句话）

2026-07-09 起上游将 Codex 桌面应用原地并入 ChatGPT 品牌：显示名、文件名前缀、bundle 外形、清单入口全部改为 ChatGPT，但产品身份不变（macOS `com.openai.codex` / Windows `OpenAI.Codex`）。镜像 probe 因"按规则重建上游文件名"而 404 中断。

## 核心纪律

只管理 Codex 产品血统；允许其发行名称、包名、可执行文件随合并改变；**绝不纳管 ChatGPT Classic（`com.openai.chat`）**。文件名不是产品身份。

## 身份矩阵（全部实测于 2026-07-10）

| 通道 | macOS bundle ID | Windows identity | 备注 |
|---|---|---|---|
| Stable | `com.openai.codex` | `OpenAI.Codex`（ProductId `9PLM9XGG6VKS`） | 本契约唯一纳管对象 |
| Beta | `com.openai.codex.beta` | `OpenAI.CodexBeta`（ProductId `9N8CJ4W95TBZ`） | 独立 enhancement |
| ChatGPT Classic | `com.openai.chat` | — | 永不纳管 |

Sparkle EdDSA 公钥（全通道同一把，与合并前一致）：`mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k=`；Team ID：`2DC432GLL2`。

## 契约 1：范围 = Stable P0

- 修复 prod DMG / Sparkle 改名 ingress；
- 增加 macOS 身份门禁（见验收条件）；
- 保持现有 Stable 公共接口（`latest/*`、`Codex-mac-*.dmg`、tag、产品名）；
- 不实现 Beta：`store-link` 等处的身份参数化以"可扩展"为度，不引入 Beta 管道。

## 契约 2：manifest 双字段——源名动态，镜像名保持 Codex ABI

```json
{
  "sourceBasename": "ChatGPT-darwin-arm64-26.707.31428.zip",
  "mirrorEnclosureBasename": "Codex-darwin-arm64-26.707.31428.zip"
}
```

- **ingress**（probe / download）只使用 `sourceUrl` / `sourceBasename`，一律从权威源读取：DMG 与 zip basename 来自 appcast enclosure；MSIX 入口来自 `AppxManifest.xml` 的 `Application@Executable`；包名来自 DisplayCatalog / FE3。**删除所有"按规则重建上游文件名"的代码。**
- **egress**（download 落盘、checksums、Release、appcast、R2 key、secondary-sync）统一读取 `mirrorEnclosureBasename`，不得各自重建。
- delta 保留官方 basename，由 manifest 显式记录（延续现有 `deltas[].basename` / `attributes` 捕获）。
- EdDSA 只签字节，不签 URL / 文件名；镜像 ABI 改名是独立产品决策，不与本修复捆绑。

## 契约 3：shared `latest` 受控协调切换 + 验证前置

- `latest/manifest` + `latest/checksums` + `latest/win-*` + macOS appcast 是**一致性单元**，不允许按平台提前拆开切换。
- R2/S3 不提供多对象事务，而现有客户端会直接读取多个 mutable key；因此本契约不声称这些 key 能严格原子替换。把 manifest 最后上传只能缩短不一致窗口，不能创造原子性。
- 顺序：
  1. 上传不可变对象 + versioned release / 候选 manifest，不移动 shared `latest`；
  2. Manager 兼容版完成并验证：delta、full fallback、新装、运行中退出、Classic 排除、Windows `ChatGPT.exe` 生命周期；
  3. 在受控维护窗口由同一次发布作业协调推进全部 `latest` key，完成后立即从外部逐项验证；
  4. 回滚同样协调回退 mutable key；不可变资产不覆盖、不删除。
- 若未来要求严格原子语义，必须升级为“版本化完整快照 + 客户端只消费单一指针”的协议；不把这项架构改造塞进 Stable P0。
- 例外通道：若为尽快恢复 Windows 用户而提前切 Windows 部分，前置条件是先用**当前已发布 Manager** 在真机完成一次"应用运行中 → 检查更新 → 关闭 → 安装 → 健康检查 → 重启"的完整验证（静态代码推断不作数）。
- 时序事实（支撑上述验证的可行性）：本地 26.623 用户本次升级时旧进程名仍为 `Codex`，现行 graceful-close 有效；缺口从升级后的下一跳开始。

## macOS 身份门禁验收条件（镜像侧）

对 Stable macOS 包（DMG 与 Sparkle zip）：

1. 镜像介质中恰有**一个**顶层 `.app`（不要求名为 `Codex.app`）；
2. `CFBundleIdentifier == com.openai.codex`；
3. Team ID == `2DC432GLL2`；
4. Sparkle 公钥与 pinned 值一致；
5. `com.openai.chat`（Classic）即使签名团队匹配也**明确拒绝**。

## 改动位置索引（实测核对于 2026-07-10 的 `main`）

| 位置 | 现状 | 契约要求 |
|---|---|---|
| `scripts/probe-release.sh` L959-960 | 拼接 `Codex-${ver}-{arch}.dmg` → 404（当前失败点） | DMG URL 从 appcast enclosure 推导 / 读取 |
| `scripts/read-macos-metadata.sh` L91 | 写死 `$volume/Codex.app/Contents/Info.plist`（修完 probe 后必现） | 找唯一 `.app` + 身份门禁 |
| `scripts/download-macos.sh` L90-93 | 重建 zip 保存名 | 读 `mirrorEnclosureBasename` |
| `scripts/build-appcast.sh` L100 | 拼接 enclosure URL | 读 `mirrorEnclosureBasename` |
| `.github/workflows/mirror.yml`（zip key 段） | 拼接 R2 key | 读 `mirrorEnclosureBasename` |
| `cloudflare/secondary-sync/src/core.js` L255 附近 | worker 内重建 basename | 从 manifest 读 |
| `scripts/store-link/Program.cs` L12 | `ProductPrefix = "OpenAI.Codex_"` 常量 | 参数化为按渠道传入精确 Identity（本期只接 Stable） |
| `scripts/prepare-windows-portable.sh` L47 / L71 | 启动器写死 `Codex.exe`（清单入口已是 `ChatGPT.exe`） | 从 `AppxManifest.xml` 读 `Application@Executable` |
| `scripts/test-probe-release*.sh` 等 fixtures | 全部 mock 旧 `Codex-*` URL | 与新 ingress 逻辑同步重写 |

## 参考

- 设计讨论与完整证据链：[#37](https://github.com/Wangnov/codex-app-mirror/issues/37)
- 原始用户诉求（Beta 通道）：[#36](https://github.com/Wangnov/codex-app-mirror/issues/36)
- 下游配套修复：`Wangnov/Codex-App-Manager`（macOS 双名探测 + bundle ID 门禁 + 规范化安装到 `/Applications/Codex.app`；Windows 从 AppxManifest 读入口、按可执行路径过滤进程）
