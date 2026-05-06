<p align="center">
  <img src="./logo.png" width="220" alt="codex-app-mirror logo">
</p>

<h1 align="center">codex-app-mirror</h1>

<p align="center">
  Mirror official Codex desktop app installers into GitHub Releases.
</p>

<p align="center">
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><img src="https://img.shields.io/github/v/release/Wangnov/codex-app-mirror?logo=github" alt="Latest release"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/actions/workflows/mirror.yml"><img src="https://img.shields.io/github/actions/workflow/status/Wangnov/codex-app-mirror/mirror.yml?branch=main&label=mirror&logo=githubactions" alt="Mirror workflow"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/actions/workflows/mirror.yml"><img src="https://img.shields.io/badge/polling-every%2015%20minutes-2ea44f" alt="15 minute polling"></a>
  <a href="https://apps.microsoft.com/detail/9plm9xgg6vks"><img src="https://img.shields.io/badge/Microsoft%20Store-9PLM9XGG6VKS-0078d4?logo=microsoftstore" alt="Microsoft Store ProductId 9PLM9XGG6VKS"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><img src="https://img.shields.io/badge/Windows-MSIX-0078d4?logo=windows" alt="Windows MSIX"></a>
  <a href="https://github.com/Wangnov/codex-app-mirror/releases/latest"><img src="https://img.shields.io/badge/macOS-arm64%20%7C%20x64-000000?logo=apple" alt="macOS arm64 and x64"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tag-openai--codex-0969da" alt="openai-codex tag">
  <img src="https://img.shields.io/badge/tag-installer--mirror-0969da" alt="installer-mirror tag">
  <img src="https://img.shields.io/badge/tag-msix-0969da" alt="msix tag">
  <img src="https://img.shields.io/badge/tag-github--actions-0969da" alt="github-actions tag">
</p>

<p align="center">
  <a href="#readme-cn">中文</a> · <a href="#readme-en">English</a>
</p>

<p align="center">
  GitHub Release · Microsoft Store MSIX · macOS DMG · checksums · release manifest
</p>

---

<a id="readme-cn"></a>

# 中文

有时候你只是想在一台 Windows 电脑上装 Codex App，但 Microsoft Store 下载链路不配合：商店被裁剪、AppX 服务关了、账号策略卡住，或者 GitHub Actions 里 `winget download` 因为 Store 包需要 Entra ID 认证而不能无人值守运行。

`codex-app-mirror` 做的事情很窄：它不构建、不修改、不重打包 Codex，只把当前官方来源里的 Codex 桌面安装包拉下来，按版本探测结果发布到 GitHub Release。这样你可以从一个稳定的 Release 页面拿到 Windows MSIX 和 macOS DMG，并用随附的校验和核对文件。

## 镜像内容

- Windows x64 MSIX：Microsoft Store ProductId `9PLM9XGG6VKS`
- macOS Apple Silicon DMG：OpenAI Codex App 官方下载地址
- macOS Intel DMG：OpenAI Codex App 官方下载地址
- `SHA256SUMS.txt`：本次 Release 内所有资产的总校验和
- `release-manifest.json`：本次探测到的上游指纹

当前 Windows 包名形如：

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.Msix
```

## 怎么用

打开 [最新 GitHub Release](https://github.com/Wangnov/codex-app-mirror/releases/latest)，下载你的平台对应文件：

- Windows：下载 `OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix`
- Apple Silicon Mac：下载 `Codex-mac-arm64.dmg`
- Intel Mac：下载 `Codex-mac-x64.dmg`

建议同时下载 `SHA256SUMS.txt`，核对文件没有在下载过程中损坏。

## Release Tag

自动发布的 tag 使用这个格式：

```text
codex-app-YYYYMMDD-HHMMSS
```

这个时间是 workflow 发布时的 UTC 时间。例子：

```text
codex-app-20260506-081038
```

## 自动轮询

GitHub Actions 每 15 分钟运行一次 `Mirror Codex App Installers` workflow。

每次运行先做轻量探测：

- Windows：通过 Microsoft Store DisplayCatalog 拿到 `WuCategoryId`，再用 FE3 metadata 解析当前 MSIX moniker 和临时 Microsoft CDN URL
- macOS：对两个 OpenAI DMG URL 做 HEAD 请求，读取 `ETag`、`Last-Modified` 和 `Content-Length`
- 比对：和最新 Release 的 `release-manifest.json` 做稳定字段比较

如果没有新版本，workflow 会在探测阶段结束，不下载安装包，也不发布重复 Release。

如果发现任意平台版本变化，workflow 会下载三个平台的安装包，生成校验和和 manifest，然后发布新的 GitHub Release。

## 手动触发

在 Actions 页面手动运行 `Mirror Codex App Installers`。

可选输入：

- `release_tag`：指定本次 Release tag；不填则自动生成 `codex-app-YYYYMMDD-HHMMSS`
- `force_release`：即使当前上游和最新 Release 完全一致，也强制发布一次

也可以用 GitHub CLI：

```bash
gh workflow run mirror.yml
gh workflow run mirror.yml -f force_release=true
gh workflow run mirror.yml -f release_tag=codex-app-manual-test -f force_release=true
```

## 上游来源

macOS DMG 使用 OpenAI Codex 桌面安装器的官方静态地址：

- `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- `https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg`

Windows MSIX 使用 Microsoft Store metadata 解析：

- DisplayCatalog：查询 ProductId `9PLM9XGG6VKS`
- FE3：获取与当前 Windows Desktop x64 条件匹配的包 metadata
- Microsoft CDN：下载 FE3 返回的临时包 URL

仓库内的解析器是纯 .NET 实现，不依赖 `StoreLib` 这类第三方 Store helper 包。

## 这个仓库不会做什么

- 不修改 Codex 安装包
- 不破解 Microsoft Store 或 OpenAI 的授权逻辑
- 不保留 Microsoft CDN 临时 URL 作为长期下载地址
- 不保证安装包能绕过你本机的 Windows AppX / MSIX 安装策略
- 不替代 OpenAI、Microsoft 或 Microsoft Store 的官方分发渠道

## 仓库标签

推荐 GitHub topics：

```text
openai-codex, codex-app, installer-mirror, msix, microsoft-store, github-actions, macos, windows
```

## 从源码运行

探测当前 Windows MSIX 链接：

```bash
dotnet run --project scripts/store-link -- 9PLM9XGG6VKS x64
```

本地执行一次轮询判断：

```bash
GH_REPO=Wangnov/codex-app-mirror bash scripts/probe-release.sh
```

---

<a id="readme-en"></a>

# English

Sometimes you just want to install the Codex desktop app on Windows, but the Microsoft Store path is not available: the Store has been removed, AppX services are disabled, account policy blocks the download, or an unattended GitHub Actions runner cannot use `winget download` because Store packaged apps require Entra ID authentication.

`codex-app-mirror` keeps the job deliberately narrow. It does not build, modify, or repackage Codex. It downloads the current official installer packages from their upstream sources and publishes them as GitHub Release assets when the upstream fingerprints change.

## Mirrored Assets

- Windows x64 MSIX from Microsoft Store ProductId `9PLM9XGG6VKS`
- macOS Apple Silicon DMG from the official OpenAI Codex App URL
- macOS Intel DMG from the official OpenAI Codex App URL
- `SHA256SUMS.txt` for all assets in the release
- `release-manifest.json` with the upstream fingerprints used by the polling check

The Windows asset is named like this:

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.Msix
```

## Usage

Open the [latest GitHub Release](https://github.com/Wangnov/codex-app-mirror/releases/latest) and download the asset for your platform:

- Windows: `OpenAI.Codex_..._x64__2p2nqsd0c76g0.Msix`
- Apple Silicon Mac: `Codex-mac-arm64.dmg`
- Intel Mac: `Codex-mac-x64.dmg`

Download `SHA256SUMS.txt` as well if you want to verify that the file arrived intact.

## Release Tags

Automated releases use this tag format:

```text
codex-app-YYYYMMDD-HHMMSS
```

The timestamp is UTC at publish time. Example:

```text
codex-app-20260506-081038
```

## Polling

The `Mirror Codex App Installers` workflow runs every 15 minutes.

Each run starts with a lightweight probe:

- Windows: query Microsoft Store DisplayCatalog for ProductId `9PLM9XGG6VKS`, then use FE3 metadata to resolve the current MSIX moniker and temporary Microsoft CDN URL
- macOS: HEAD the two OpenAI DMG URLs and read `ETag`, `Last-Modified`, and `Content-Length`
- Compare: check those stable fields against the latest release's `release-manifest.json`

If nothing changed, the workflow stops after the probe. It does not download installers and does not publish a duplicate release.

If any platform changes, the workflow downloads all three installers, writes checksums and a manifest, and publishes a new GitHub Release.

## Manual Runs

Run `Mirror Codex App Installers` from the Actions tab.

Optional inputs:

- `release_tag`: set an explicit release tag; defaults to `codex-app-YYYYMMDD-HHMMSS`
- `force_release`: publish even when the current upstream fingerprints match the latest release

With GitHub CLI:

```bash
gh workflow run mirror.yml
gh workflow run mirror.yml -f force_release=true
gh workflow run mirror.yml -f release_tag=codex-app-manual-test -f force_release=true
```

## Upstream Sources

macOS DMGs use the official OpenAI Codex desktop app URLs:

- `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- `https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg`

The Windows MSIX is resolved from Microsoft Store metadata:

- DisplayCatalog: query ProductId `9PLM9XGG6VKS`
- FE3: resolve package metadata matching a Windows Desktop x64 device
- Microsoft CDN: download the temporary package URL returned by FE3

The resolver in this repository is implemented directly with .NET and does not depend on third-party Store helper packages such as `StoreLib`.

## Non-Goals

- It does not modify Codex installer packages
- It does not bypass Microsoft Store or OpenAI authorization
- It does not preserve Microsoft CDN temporary URLs as permanent links
- It does not guarantee that your local Windows AppX / MSIX installation policy will accept the package
- It is not a replacement for the official OpenAI, Microsoft, or Microsoft Store distribution channels

## Repository Topics

Suggested GitHub topics:

```text
openai-codex, codex-app, installer-mirror, msix, microsoft-store, github-actions, macos, windows
```

## Run From Source

Probe the current Windows MSIX link:

```bash
dotnet run --project scripts/store-link -- 9PLM9XGG6VKS x64
```

Run the local release probe:

```bash
GH_REPO=Wangnov/codex-app-mirror bash scripts/probe-release.sh
```
