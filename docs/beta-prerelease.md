# Beta GitHub prerelease policy

> 状态：按需发布，服务 [#36](https://github.com/Wangnov/codex-app-mirror/issues/36)。Beta 不是 Stable 镜像通道。

## 发布边界

Beta 快照只发布为 GitHub prerelease：

- 不上传 Cloudflare R2；
- 不上传 secondary S3；
- 不推进 GitHub Latest；
- 不创建或推进任何 shared `latest/*`；
- 不生成可供客户端持续订阅的镜像 Sparkle appcast；
- 不接入 Codex App Manager 的 Stable 更新通道。

发布必须通过手动 workflow `Publish Beta GitHub prerelease` 发起，并同时输入当前 Windows Beta MSIX 四段版本和当前 macOS Beta appcast 版本。workflow 只接受 Microsoft Store 与两个官方 macOS Beta appcast 的当前版本；输入与权威源不一致时失败关闭。

## 上游身份

| 平台 | 权威来源 | 身份门禁 |
|---|---|---|
| Windows | Microsoft Store ProductId `9N8CJ4W95TBZ` | package identity `OpenAI.CodexBeta`；入口 `app/ChatGPT (Beta).exe` |
| macOS Apple Silicon | `https://persistent.oaistatic.com/codex-app-beta/appcast.xml` | bundle ID `com.openai.codex.beta` |
| macOS Intel | `https://persistent.oaistatic.com/codex-app-beta/appcast-x64.xml` | bundle ID `com.openai.codex.beta` |

macOS 两个架构继续固定 OpenAI Team ID `2DC432GLL2` 和 Sparkle 公钥 `mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k=`。DMG 与 Sparkle ZIP 都必须通过代码签名、bundle ID、Team ID 和公钥验证；发布资产保留上游原始字节。

## Release 形态

tag 同时编码两侧权威版本，避免任一平台单独升级时覆盖已有不可变资产：

```text
codex-app-beta-win-<windows-package-version>-mac-<macos-version>
```

每个 prerelease 包含：

- Windows x64 / ARM64 原始 MSIX；
- macOS Apple Silicon / Intel 原始 DMG；
- macOS Apple Silicon / Intel 原始 Sparkle ZIP；
- `release-manifest.json`、平台身份元数据和 SHA-256 校验文件。

二进制资产不可覆盖；同一 tag 重跑时，仅允许校验一致的二进制复用，并对可再生成的 manifest、身份元数据、校验和与说明做幂等更新。
