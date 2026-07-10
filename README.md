<p align="center">
  <img src="./assets/status.svg" alt="Codex App Mirror — verified distribution pipeline" width="100%">
</p>

<h1 align="center">Codex App Mirror</h1>

<p align="center">
  <strong>OpenAI Codex 桌面产品（现以 ChatGPT Desktop 品牌分发）的可验证第三方镜像</strong><br>
  Verifiable third-party mirror for the OpenAI Codex desktop product, now distributed under the ChatGPT Desktop brand.
</p>

<p align="center">
  <a href="https://codexapp.agentsmirror.com"><img src="https://img.shields.io/badge/website-codexapp.agentsmirror.com-6366f1" alt="Website"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><img src="https://img.shields.io/github/v/release/Wangnov/codex-app-mirror?display_name=tag&sort=semver&label=latest&color=4f46e5" alt="Latest release"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><img src="https://img.shields.io/endpoint?url=https://codexapp.agentsmirror.com/stats/downloads.json" alt="Installer downloads"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/actions/workflows/mirror.yml"><img src="https://img.shields.io/github/actions/workflow/status/Wangnov/codex-app-mirror/mirror.yml?branch=main&label=mirror&logo=githubactions" alt="Mirror workflow"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Wangnov/codex-app-mirror?color=2563eb" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><b>下载最新版</b></a> ·
  <a href="https://codexapp.agentsmirror.com"><b>国内直连</b></a> ·
  <a href="https://github.com/Wangnov/Codex-App-Manager"><b>Codex App Manager</b></a> ·
  <a href="#readme-cn">中文</a> · <a href="#readme-en">English</a>
</p>

<p align="center">
  🖥️ 不想手动下载？<b><a href="https://github.com/Wangnov/Codex-App-Manager">Codex App Manager</a></b> 提供一键安装、增量更新和干净卸载。<br>
  🖥️ Prefer one click? <b><a href="https://github.com/Wangnov/Codex-App-Manager">Codex App Manager</a></b> installs, updates, and cleanly removes the app for you.
</p>

---

<!-- ⬇ 赞助商 SPONSOR（顶部，中英双语共享） -->
<div align="center">
<table>
  <tr>
    <td align="center" width="170">
      <a href="https://duckcoding.ai"><img src="./assets/sponsor-duckcoding.jpg" alt="DuckCoding" width="108"></a>
    </td>
    <td width="560">
      <b>本项目由 <a href="https://duckcoding.ai">DuckCoding</a> 赞助支持</b><br>
      为 Claude Code / Codex / Gemini CLI 提供按量计费的 API 中转服务。<br>
      <b>Sponsored by <a href="https://duckcoding.ai">DuckCoding</a></b> — a pay-as-you-go API relay for Claude Code / Codex / Gemini CLI.
    </td>
  </tr>
</table>
</div>

---

<a id="readme-cn"></a>

# 中文

## 这是什么

`codex-app-mirror` 镜像 OpenAI Codex 桌面产品的官方 Windows 与 macOS 安装包，为 Microsoft Store 或官方下载不便的用户提供稳定、可校验的下载和更新入口。项目不构建、不修改、不破解、也不重打包应用；发布资产来自 OpenAI 或 Microsoft 的官方分发源。

> [!IMPORTANT]
> OpenAI 已将原 Codex 桌面产品并入 ChatGPT Desktop 品牌；本仓库继续按 macOS `com.openai.codex` 与 Windows `OpenAI.Codex` 的产品身份追踪这条产品线。旧 ChatGPT App 现归为 ChatGPT Classic，不在本镜像范围内。

仓库继续使用 **Codex App Mirror** 这个名称，因为显示名、应用文件名和可执行文件都可能改变，而产品身份与公共下载接口需要保持稳定。当前 macOS 应用外形为 `ChatGPT.app`，并不改变它在本项目中的 Codex 产品血统。

## 下载

推荐使用下列稳定短链。它们始终指向各平台当前可用的最新版，并自动选择合适的下载节点。

| 平台 | 推荐下载 | Release 文件 |
|---|---|---|
| Windows x64 | <https://codexapp.agentsmirror.com/latest/win-x64> | `OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix` |
| Windows ARM64 | <https://codexapp.agentsmirror.com/latest/win-arm64> | `OpenAI.Codex_..._arm64__2p2nqsd0c76g0.Msix` |
| Apple Silicon Mac | <https://codexapp.agentsmirror.com/latest/mac-arm64> | `Codex-mac-arm64.dmg` |
| Intel Mac | <https://codexapp.agentsmirror.com/latest/mac-intel> | `Codex-mac-x64.dmg` |

- [最新 GitHub Release](https://github.com/Wangnov/codex-app-mirror/releases/latest)：查看版本说明和全部资产
- [全部历史版本](https://github.com/Wangnov/codex-app-mirror/releases)：按 release/tag 下载旧版本
- [SHA-256 校验和](https://codexapp.agentsmirror.com/latest/checksums)：验证下载文件完整性
- [Release Manifest](https://codexapp.agentsmirror.com/latest/manifest)：查看来源、身份与上游指纹
- Windows x64 兼容短链：<https://codexapp.agentsmirror.com/latest/win>

如果 Microsoft Store 可正常使用，仍可优先从 [官方商店页面](https://apps.microsoft.com/detail/9plm9xgg6vks)安装。

## 为什么可以信任

| 保证 | 实现方式 |
|---|---|
| **官方来源** | Windows 包由 Microsoft Store metadata 解析；macOS 包与 Sparkle 归档来自 OpenAI 官方源 |
| **字节不变** | 安装包、Sparkle 完整归档和 delta 均不重打包；镜像只改变对外下载位置 |
| **身份门禁** | macOS 校验 `com.openai.codex`、OpenAI Team ID 与 Sparkle 公钥；Windows 锁定 ProductId 与 `OpenAI.Codex` identity |
| **可复核** | 每个 Release 附带 `SHA256SUMS.txt` 与 `release-manifest.json` |
| **稳定接口** | 上游现已使用 `ChatGPT-*` 动态文件名，镜像仍保留 `Codex-*` 稳定文件名和 `latest/*` 短链 |

这里的“原样镜像”指**有效载荷字节不变**，不是复制上游不断变化的文件名。文件名兼容层不会改变文件内容，也不会使 OpenAI 的原始 Sparkle EdDSA 签名失效。

## macOS 增量自动更新

除了手动下载 DMG，本镜像还提供 Sparkle 更新源，供 Codex App Manager 检查新版本并优先下载版本间 delta；没有匹配 delta 时自动回退到完整归档。

- Apple Silicon：<https://codexapp.agentsmirror.com/latest/appcast.xml>
- Intel：<https://codexapp.agentsmirror.com/latest/appcast-x64.xml>

镜像逐字节复制官方归档及其 EdDSA 签名，只把 appcast 中的下载地址改写到镜像。签名覆盖的是归档字节，因此下载地址和镜像文件名的变化不会破坏原始签名。

## 与 Codex App Manager 的关系

本仓库负责“发现、验证和分发”，[Codex App Manager](https://github.com/Wangnov/Codex-App-Manager) 负责用户侧的“安装、更新和卸载”。Manager 使用这里的稳定短链、manifest 和 Sparkle appcast，因此上游展示名称改变时，用户侧不需要追踪临时 URL 或猜测文件名。

➡️ 官网：[codexapp.agentsmirror.com](https://codexapp.agentsmirror.com) · Manager：[Wangnov/Codex-App-Manager](https://github.com/Wangnov/Codex-App-Manager)

## 工作原理

1. **探测**：每 15 分钟读取 Microsoft Store 与 OpenAI appcast 的权威元数据。
2. **验证**：检查产品身份、架构、版本、签名元数据和上游指纹，拒绝不属于 Codex 产品线的包。
3. **发布**：只有上游发生真实变化时才下载资产、计算 SHA-256、生成 manifest 并创建或补全 GitHub Release。
4. **分发**：发布资产同步到镜像存储；同一组 `latest/*` 短链按访问位置选择可用节点。

主调度由 Cloudflare Cron 触发，GitHub Actions 自带定时任务作为兜底。未检测到变化时流程会在轻量探测阶段结束，不重复下载或发版。

## 版本与文件名

Release 使用 Codex 应用内部版本聚合，tag 形如 `codex-app-26.707.31428`。Windows Store 的四段 MSIX 包版本会单独记录在 Release 说明和 manifest 中；不同平台发布时间不一致时，各架构的稳定短链只在对应资产完成验证后推进。

上游当前可能出现 `ChatGPT-<version>-<arch>.dmg`、`ChatGPT-darwin-<arch>-<version>.zip` 等名称；镜像对外继续提供 `Codex-mac-*.dmg` 和 `Codex-darwin-*.zip`，以免破坏 Manager、用户脚本和历史文档。

## Windows 提示“已被系统管理员阻止”

<details>
<summary>展开排查步骤</summary>

如果双击 `.Msix` 时提示“你的系统管理员已阻止此程序”，通常不是下载损坏，而是系统策略禁止从 Microsoft Store 之外安装 MSIX / AppX，或者 App Installer / AppX 部署服务被禁用。

1. 优先尝试 [Microsoft Store 官方页面](https://apps.microsoft.com/detail/9plm9xgg6vks)。
2. 在个人电脑上，确认系统允许安装任意来源应用，并确认 App Installer 可用。
3. 如需查看详细错误，可在管理员终端运行：`Add-AppxPackage -Path .\OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix`。
4. 如果设备由公司或学校管理，请联系管理员放行；本镜像不会绕过本机安装策略。

</details>

## 上游与公共接口

| 用途 | 权威来源或稳定接口 |
|---|---|
| Windows Stable | Microsoft Store ProductId `9PLM9XGG6VKS`，package identity `OpenAI.Codex` |
| macOS Apple Silicon | OpenAI `codex-app-prod/appcast.xml`，bundle ID `com.openai.codex` |
| macOS Intel | OpenAI `codex-app-prod/appcast-x64.xml`，bundle ID `com.openai.codex` |
| 最新下载 | `https://codexapp.agentsmirror.com/latest/*` 下的稳定短链 |
| 完整历史 | [GitHub Releases](https://github.com/Wangnov/codex-app-mirror/releases) |

macOS 的具体安装包 URL 和 basename 从官方 appcast 动态读取，不再根据 `Codex` 或 `ChatGPT` 前缀猜测。Windows 下载 URL 来自 Microsoft Store metadata，并且只作为当次取包入口使用。

## 项目边界

- 不修改或重打包应用安装包
- 不破解 Microsoft Store 或 OpenAI 的授权逻辑
- 不伪造、替换或重新计算 OpenAI 的 Sparkle 签名
- 不把 Microsoft CDN 临时 URL 当作长期下载地址
- 不绕过 Windows AppX / MSIX 安装策略
- 不替代 OpenAI、Microsoft 或 Microsoft Store 的官方分发渠道

## 致谢

- **[LINUX DO](https://linux.do/)** 社区——持续提供下载链路、安装体验和校验结果反馈。
- **中国科学院高能物理研究所（IHEP）**——提供国内镜像存储支持。

## Star History

<p align="center">
  <a href="https://star-history.com/#Wangnov/codex-app-mirror&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Wangnov/codex-app-mirror&type=Date&theme=dark" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Wangnov/codex-app-mirror&type=Date" width="75%" />
    </picture>
  </a>
</p>

## 许可

[MIT](./LICENSE)。本项目是第三方社区镜像，与 OpenAI、Microsoft 无隶属、授权或背书关系。

---

<a id="readme-en"></a>

# English

## What this is

`codex-app-mirror` mirrors the official Windows and macOS installers for the OpenAI Codex desktop product. It provides stable, verifiable download and update endpoints when the Microsoft Store or direct upstream downloads are inconvenient. The project does not build, modify, crack, or repackage the app; every published asset originates from an official OpenAI or Microsoft distribution source.

> [!IMPORTANT]
> OpenAI has merged the former Codex desktop product into the ChatGPT Desktop brand. This repository continues to follow that product lineage by its macOS identity `com.openai.codex` and Windows identity `OpenAI.Codex`. The former standalone ChatGPT App is now referred to as ChatGPT Classic and is outside this mirror's scope.

The repository remains **Codex App Mirror** because display names, app bundles, and executables may change while product identity and public download contracts need to stay stable. The current macOS bundle appears as `ChatGPT.app`; that does not change the Codex product lineage managed here.

## Download

The stable links below always point to the latest validated build available for each platform and automatically select an appropriate delivery node.

| Platform | Recommended download | Release asset |
|---|---|---|
| Windows x64 | <https://codexapp.agentsmirror.com/latest/win-x64> | `OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix` |
| Windows ARM64 | <https://codexapp.agentsmirror.com/latest/win-arm64> | `OpenAI.Codex_..._arm64__2p2nqsd0c76g0.Msix` |
| Apple Silicon Mac | <https://codexapp.agentsmirror.com/latest/mac-arm64> | `Codex-mac-arm64.dmg` |
| Intel Mac | <https://codexapp.agentsmirror.com/latest/mac-intel> | `Codex-mac-x64.dmg` |

- [Latest GitHub Release](https://github.com/Wangnov/codex-app-mirror/releases/latest): release notes and all assets
- [Full release history](https://github.com/Wangnov/codex-app-mirror/releases): previous versions by release/tag
- [SHA-256 checksums](https://codexapp.agentsmirror.com/latest/checksums): verify downloaded files
- [Release manifest](https://codexapp.agentsmirror.com/latest/manifest): inspect source, identity, and upstream fingerprints
- Windows x64 compatibility link: <https://codexapp.agentsmirror.com/latest/win>

If the Microsoft Store works for you, the [official Store listing](https://apps.microsoft.com/detail/9plm9xgg6vks) remains the preferred source.

## Why it is trustworthy

| Guarantee | How it works |
|---|---|
| **Official sources** | Windows packages resolve from Microsoft Store metadata; macOS installers and Sparkle archives come from OpenAI's official feed |
| **Byte-preserving** | Installers, full Sparkle archives, and deltas are never repackaged; only their delivery location changes |
| **Identity gates** | macOS verifies `com.openai.codex`, the OpenAI Team ID, and the Sparkle key; Windows pins the ProductId and `OpenAI.Codex` identity |
| **Auditable** | Every release includes `SHA256SUMS.txt` and `release-manifest.json` |
| **Stable contract** | Upstream now uses dynamic `ChatGPT-*` names while the mirror preserves stable `Codex-*` names and `latest/*` endpoints |

“Verbatim mirror” means the **payload bytes remain unchanged**, not that every changing upstream filename is copied. The filename compatibility layer does not alter archive contents or invalidate OpenAI's original Sparkle EdDSA signatures.

## macOS incremental updates

In addition to manual DMG downloads, the mirror publishes Sparkle feeds used by Codex App Manager. Matching clients receive a version-to-version delta; clients without a suitable delta fall back to the full archive.

- Apple Silicon: <https://codexapp.agentsmirror.com/latest/appcast.xml>
- Intel: <https://codexapp.agentsmirror.com/latest/appcast-x64.xml>

The mirror copies official archives and EdDSA signatures byte-for-byte and only rewrites appcast download URLs. Because the signature covers archive bytes, changing the delivery URL or mirror filename does not invalidate the original signature.

## How Codex App Manager fits in

This repository owns discovery, verification, and distribution. [Codex App Manager](https://github.com/Wangnov/Codex-App-Manager) owns the user-facing install, update, and uninstall experience. It consumes the stable links, manifest, and Sparkle feeds here, so users do not need to track temporary URLs or guess upstream filenames after a display-name change.

➡️ Website: [codexapp.agentsmirror.com](https://codexapp.agentsmirror.com) · Manager: [Wangnov/Codex-App-Manager](https://github.com/Wangnov/Codex-App-Manager)

## How it works

1. **Probe**: read authoritative Microsoft Store metadata and OpenAI appcasts every 15 minutes.
2. **Verify**: validate product identity, architecture, version, signing metadata, and upstream fingerprints; reject packages outside the Codex product lineage.
3. **Publish**: only after a real upstream change, download assets, calculate SHA-256, generate the manifest, and create or complete a GitHub Release.
4. **Deliver**: synchronize release assets to mirror storage and route the same `latest/*` links to an available node based on visitor location.

Cloudflare Cron drives the primary schedule, with GitHub Actions' own schedule as a fallback. When nothing changed, the workflow exits after the lightweight probe and does not redownload or republish assets.

## Versions and filenames

Releases are grouped by the Codex app's internal version, with tags such as `codex-app-26.707.31428`. The four-part Windows Store MSIX version remains recorded separately in the release notes and manifest. When platform rollout times differ, each architecture's stable link advances only after its corresponding asset passes validation.

Upstream may now use names such as `ChatGPT-<version>-<arch>.dmg` and `ChatGPT-darwin-<arch>-<version>.zip`. The mirror continues to expose `Codex-mac-*.dmg` and `Codex-darwin-*.zip` to avoid breaking Manager, user scripts, and existing documentation.

## Windows “blocked by your system administrator”

<details>
<summary>Expand troubleshooting steps</summary>

If double-clicking an `.Msix` reports that the app was blocked by your system administrator, the download is usually not damaged. Windows policy may disallow sideloaded MSIX / AppX packages, or App Installer / AppX Deployment may be disabled.

1. Try the [official Microsoft Store listing](https://apps.microsoft.com/detail/9plm9xgg6vks) first.
2. On a personal PC, confirm that apps from outside the Store are allowed and App Installer is available.
3. For a detailed error, run from an elevated terminal: `Add-AppxPackage -Path .\OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix`.
4. On a work- or school-managed device, ask the administrator to allow installation. This mirror does not bypass local policy.

</details>

## Upstream and public interfaces

| Purpose | Authoritative source or stable interface |
|---|---|
| Windows Stable | Microsoft Store ProductId `9PLM9XGG6VKS`, package identity `OpenAI.Codex` |
| macOS Apple Silicon | OpenAI `codex-app-prod/appcast.xml`, bundle ID `com.openai.codex` |
| macOS Intel | OpenAI `codex-app-prod/appcast-x64.xml`, bundle ID `com.openai.codex` |
| Latest downloads | Stable links under `https://codexapp.agentsmirror.com/latest/*` |
| Full history | [GitHub Releases](https://github.com/Wangnov/codex-app-mirror/releases) |

Specific macOS installer URLs and basenames are read dynamically from the official appcast instead of being guessed from a `Codex` or `ChatGPT` prefix. Windows download URLs resolve from Microsoft Store metadata and are used only as temporary ingestion endpoints.

## Project boundaries

- Does not modify or repackage application installers
- Does not bypass Microsoft Store or OpenAI authorization
- Does not forge, replace, or recompute OpenAI Sparkle signatures
- Does not preserve temporary Microsoft CDN URLs as permanent links
- Does not bypass local Windows AppX / MSIX installation policy
- Does not replace official OpenAI, Microsoft, or Microsoft Store distribution

## Acknowledgements

- **[LINUX DO](https://linux.do/)** community — continued feedback on download availability, installation, and checksums.
- **Institute of High Energy Physics, Chinese Academy of Sciences (IHEP)** — provides mirror storage support in mainland China.

## Star History

<p align="center">
  <a href="https://star-history.com/#Wangnov/codex-app-mirror&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Wangnov/codex-app-mirror&type=Date&theme=dark" />
      <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Wangnov/codex-app-mirror&type=Date" width="75%" />
    </picture>
  </a>
</p>

## License

[MIT](./LICENSE). This is a third-party community mirror and is not affiliated with, authorized by, or endorsed by OpenAI or Microsoft.
