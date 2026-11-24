# Mirror & Distribution Service Terms · 镜像与分发服务使用条款

Canonical full text / 完整权威服务条款原文：<https://codexapp.agentsmirror.com/terms/>

## Scope & Summary · 适用范围与核心边界

1. **Source Code vs. Hosted Infrastructure · 开源代码与在线基础设施分离**
   - Scripts and configuration in this repository (`the Software`) are licensed under the [MIT License](./LICENSE).
   - Mirrored application installers and signatures belong to OpenAI / Microsoft and are redistributed verbatim.
   - The hosted endpoints under `*.agentsmirror.com` (`codexapp.agentsmirror.com`, `codexapp-r2.agentsmirror.com`) and the mainland China academic/public-interest S3 storage node supported by the **Institute of High Energy Physics, Chinese Academy of Sciences (CAS IHEP)** are **not** licensed under MIT; all network access is governed by the [Terms of Service](https://codexapp.agentsmirror.com/terms/).
   - 本仓库脚本代码适用 [MIT 许可证](./LICENSE)；但 `*.agentsmirror.com` 在线带宽及依托**中国科学院高能物理研究所（IHEP）**运行的国内科研与开源公益存储节点不属于 MIT 授权标的，严格受《镜像与分发服务使用条款》约束。

2. **Public-Interest Protection & Prohibited Commercial Use · 科研公益资源保护与严禁商用寄生**
   - Mainland China mirror storage is public-interest academic/open-source infrastructure provided by **CAS IHEP**. Commercial exploitation, embedding into paid/recharge/VIP managers or API-relay configurators, WeChat password-gated landing pages, e-commerce resale, bundled installers, reverse proxies, abusive polling, and User-Agent spoofing to evade access controls are strictly prohibited.
   - 中国大陆分发节点依托**中国科学院高能物理研究所（IHEP）**科研与开源公益存储运行，严格限定于**纯非商业无偿开源公益用途**。严禁任何收费软件、含账户充值/会员/代充/API 中转推广的管理器或安装器、公众号扫码密码墙、闲鱼/电商发卡倒卖或反向代理占用公益带宽，严禁伪造 `User-Agent` 规避技术访问控制。

3. **Zero-Approval Open-Source Client Policy · 纯非商业开源客户端免审批接入**
   - Purely free, 100% open-source tools with zero commercial/recharge/relay features may consume `https://codexapp.agentsmirror.com/latest/*` without opening an approval issue by displaying clear free-source attribution, polling `/latest/manifest` at intervals of **≥ 30 minutes**, verifying `SHA256SUMS.txt`, and sending:
     `User-Agent: <AppName>/<Version> (+https://github.com/<owner>/<repo>; open-source-noncommercial)`
   - 完全免费开源且不含任何商业变现模块的工具，遵循显著标明免费出处、轮询间隔 ≥30 分钟、核对哈希校验及标准实名 `User-Agent` 规范即可免审批直接接入，详见 <https://codexapp.agentsmirror.com/terms/#open-client-policy>。
