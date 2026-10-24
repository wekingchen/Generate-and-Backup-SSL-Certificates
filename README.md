# 使用 GitHub Actions 自动生成和备份 SSL 证书

本仓库通过 GitHub Actions、[acme.sh](https://github.com/acmesh-official/acme.sh)、Cloudflare DNS 和 Dropbox 管理支持多个 CA 的公开信任证书，继续支持 **ECC (EC P-256)** 与 **RSA 2048** 两种格式。

## 两条工作流

> **运行策略（2026-10-22）**：每天按 Dropbox 的最新域名清单动态检查 EC/RSA 双证书；有足够有效期的证书跳过。若某项进入 429 冷却，会如实展示待重试与临期风险，并使用已配置的 ZeroSSL 在满足条件时受控应急。CI 的成功只代表离线逻辑通过，日常运行仍以实际 Actions 和证书检查报表为准。


| 工作流 | 作用 | 定时（UTC） |
| --- | --- | --- |
| [Generate and Backup SSL Certificates](.github/workflows/generate_and_backup_ssl.yml) | 读取现有证书，必要时续签、校验、备份到 Dropbox，并通过 Bark 汇报 | 每天 23:35 |
| [Check SSL Certificate Expiry](.github/workflows/check_ssl_expiry.yml) | 只读取 Dropbox 中的证书、更新仓库的 `CHECK_LIST.md`，报告临期和异常，不再重复签发或回写证书 | 每天 01:00 |

> GitHub 的定时工作流可能延迟执行。两条工作流使用同一并发组，避免同时操作证书。

## Dropbox 读取、写入和输出格式（保持兼容）

现有的 `rclone` 连接名仍为 `dropbox`，根路径仍为 `dropbox:SSL`：

- 从 `dropbox:SSL` 同步证书到工作目录 `./ssl`。
- 从 `dropbox:SSL/cloudflare_domains_list.txt` 单独读取域名列表，每行一个域名。
- 证书管理工作流完成签发和校验后，仍使用原来的 `rclone sync ssl dropbox:SSL` 回写证书。
- 仍将 rclone 配置备份到 `dropbox:SSL/rclone-config`，并在有相应权限时更新 `RCLONE_CONFIG` Secret。
- 到期检查工作流只读取 Dropbox；它不再重复上传未修改的证书目录，避免两个独立流程竞争写入。

证书路径保持不变：

| 类型 | 完整证书链 | 私钥 | CA（如果提供） |
| --- | --- | --- | --- |
| ECC | `SSL/<域名>/fullchain.cer` | `SSL/<域名>/private.key` | `SSL/<域名>/ca.cer` |
| RSA | `SSL/<域名>/rsa/fullchain.cer` | `SSL/<域名>/rsa/private.key` | `SSL/<域名>/rsa/ca.cer` |

原有 `EC_issue.log`、`RSA_issue.log` 文件命名不变。`fullchain.cer`、`private.key` 和可选 `ca.cer` 均先暂存，安装失败时回滚原有文件；如果新证书没有 `ca.cer`，会清理对应旧 CA 文件，避免混用。不会自动删除已从域名列表移除的历史备份。

`CHECK_LIST.md` 继续采用原来的五列表格与域名顺序，但标题和列名均使用中文；日期按**北京时间（UTC+8）**显示，例如 `2026年11月11日 07:11:51`。证书缺失时显示“未找到”，剩余天数仍为数字。仅改变 GitHub 报表的可读性，不改变 Dropbox 中的证书与备份格式。

## 配置

在仓库 **Settings → Secrets and variables → Actions** 中配置：

| Secret | 用途 |
| --- | --- |
| `EMAIL` | acme.sh 注册邮箱和报表提交身份 |
| `CF_TOKEN`、`CF_ACCOUNT_ID` | Cloudflare DNS-01 验证 |
| `RCLONE_CONFIG` | Dropbox 的完整 rclone 配置 |
| `CLI_TOKEN` | 使用 GitHub CLI 更新 `RCLONE_CONFIG` Secret |
| `BARK_URL` | 可选，Bark 推送地址 |
| `ZEROSSL_EAB_KID`、`ZEROSSL_EAB_HMAC_KEY` | ZeroSSL 的 ACME 外部账户绑定凭证，启用备用 CA 前必须配齐 |
| `GOOGLE_EAB_KID`、`GOOGLE_EAB_HMAC_KEY` | Google Public CA EAB，仅供一次性手动接入试验；一次注册后不能重复使用 |

不要把私钥、rclone 配置、Cloudflare Token 或 Dropbox Token 提交到公开仓库。`GITHUB_TOKEN` 由 Actions 自动提供，不应手动创建同名 Secret。

## 多 CA 签发策略（2026-10-22）

现有 Let's Encrypt 默认签发完全不变。两种算法、动态域名清单、证书有效期检查、Dropbox `rclone` 读写命令和目录格式不变。

| CA | 日常默认 | 手动选择 | 自动备用 |
| --- | --- | --- | --- |
| Let's Encrypt (`letsencrypt`) | 是 | 支持 | 不适用 |
| ZeroSSL (`zerossl`) | 否 | 配好 EAB 后支持 | **仅设置仓库变量后启用** |
| Google Public CA (`google`) | 否 | 单次受控试验 | **禁止自动切换** |

1. 在 GitHub Actions 的 `Run workflow` 中选择 `auto`（默认）、`letsencrypt`、`zerossl` 或 `google`。已有证书仍有效时自动跳过，选择 CA 不会强制签发。
2. 若希望启用 ZeroSSL 备用，先在 [ZeroSSL 控制台](https://zerossl.com/documentation/acme) 生成 ACME EAB 凭证，分别保存到仓库 Secrets `ZEROSSL_EAB_KID` / `ZEROSSL_EAB_HMAC_KEY`，随后在仓库 Settings → Secrets and variables → Actions → **Variables** 新建 `SSL_FALLBACK_CA=zerossl`。未设置或为 `off` 时完全不自动切换。
3. `auto` 模式默认只对 Let's Encrypt 明确的 **HTTP 5xx 服务异常**尝试 ZeroSSL。发生 **429 限额**时优先遵守 `Retry-After` 或原日志修改时间起 34 小时冷却；**仅当证书剩余不超过 7 天（含缺失/过期），且预计冷却尚需超过 24 小时**，才允许应急申请一张 ZeroSSL 证书。对同一个 429 冷却窗口最多应急尝试一次，失败后会在既有 `EC_issue.log` / `RSA_issue.log` 中保留原始 429 记录和尝试标记，防止下轮反复申请。DNS-01、CAA 限制及未分类错误均不触发自动切换。每个域名的 EC/RSA 仍各最多处理一次，但应急/服务故障切换会增加实际 CA 发单次数。
4. 凭证设置完成后，先从 [SSL CA 接入预检查](.github/workflows/ssl_ca_readiness.yml) 手动选择 CA 并填写一个根域名。此流程只检查 EAB Secrets 是否存在、ACME 目录是否能访问，以及直接查询到的 CAA 信息；**不会签发证书、访问 Dropbox 或向 Bark 推送，也不能替代真实 DNS-01 验证**。
5. 如果 DNS 上已经存在 CAA 限制，必须检查根域名与通配符签发权限：Let's Encrypt 通常使用 `letsencrypt.org`，ZeroSSL 通常使用 `sectigo.com`，Google Public CA 使用 `pki.goog`。必要时调整 `issue` 与 `issuewild`，没有 CAA 限制的域名不必为多 CA 特意添加记录。最终以 CA 的 CAA 校验结果为准。
6. **Google Public CA 不能简单地在每日临时 GitHub Runner 上反复用同一 EAB 注册**：Google 的 EAB 仅能注册一次 ACME 账户。当前 `google` 选项用于手动接入试验；每次新 Runner 在未持久化原 ACME 账户密钥的情况下需要新 EAB。正式长期使用前，还必须完成**安全持久化 ACME 账户密钥及恢复测试**。本项目目前不在 Dropbox 额外保存账户密钥，也不会偷偷启用 Google 的每日签发或自动备用。Google Cloud 的 Public CA EAB 可参考[官方文档](https://cloud.google.com/certificate-manager/docs/public-ca-tutorial)。

**安全边界：** 不会把 EAB、ACME 账户私钥写入仓库或 Bark；签发成功之后才替换原有证书，私钥与证书必须匹配；即使备用 CA 失败也不会覆盖现有有效证书。CA 实际来源会出现在 Actions 中文摘要与 Bark 通知中。

## 证书生命周期与异常处理

- 只有当证书无效、缺失，或者距离到期不足续签阈值（目前为 30 天）时才申请新证书。
- 检查证书和私钥是否匹配、证书是否覆盖根域名与通配符域名、有效期是否足够。
- 每个域名、每种算法单独处理。一个失败时继续处理其他证书；有效的现有证书不得被失败的候选文件替换。
- 即使个别域名失败，也先完成已经校验成功的证书备份，最后才将工作流标记为失败；待重试证书如果缺失/过期或只剩 7 天及以下，会产生明确的高风险状态，不会被绿色结果掩盖。
- 域名列表为空、证书目录异常或总体验证失败时，拒绝回写 Dropbox，防止误覆盖。
- 不再使用固定 2 张或 12 张上限。每次读取 Dropbox 中最新的 `cloudflare_domains_list.txt`，忽略空行与注释、规范化大小写、过滤不合法域名并去重，每个有效域名最多尝试 EC 与 RSA 各一次。由此每轮实际签发请求自然不超过 `有效域名数 × 2`，且仅在证书需要更新、未处于 429 冷却期时才发起请求。
- 遇到 Let's Encrypt 429 时，优先解析原有 `EC_issue.log` / `RSA_issue.log` 中的 `retry after` 并在到期前跳过；无有效重试时间时，按照原始日志修改时间至少退避约 34 小时。只有证书已接近过期/不存在，且预计等待超过 24 小时，才允许一轮 ZeroSSL 应急。应急失败后保留原始日志和冷却时间，并在**原有日志内**记录同一冷却窗口已经尝试过；不会为此新增 Dropbox 文件。
- 回写前通过 `.github/scripts/guard_dropbox_deletions.sh` 比较 Dropbox 远端文件清单与本地同步副本；发现可能误删的文件或远端列表读取失败时停止备份，原 `rclone sync` 写入命令保持不变。签发后使用 `.github/scripts/verify_inventory.sh` 和 `.github/scripts/verify_certificate.sh` 核实双算法清单、根域名、通配符 SAN、证书与私钥匹配、可信证书链和有效期；缺失项会被报告并使最终任务失败，但其他有效证书仍可备份。
- 到期检查任务不负责续签；剩余 30 天内显示警告，证书缺失或仅剩 7 天及以下显示严重异常。

工作流中的证书状态、失败原因和总结尽量使用中文；acme.sh 的底层错误只在必要时展示末尾上下文。

## Bark 结果通知

- 继续使用已有的 `BARK_URL` Secret（形如 `https://你的Bark服务器/设备Key`）；采用 Bark 官方支持的 JSON POST，不需要重新配置密钥。
- 通知标题与正文全部中文，按域名汇总本轮实际签发的 EC/RSA 证书类型，显示已备份证书数量、已跳过的有效证书数量、429 冷却待重试项、本轮检查域名数和签发请求数。
- **只有证书备份真正成功**才使用“已签发并备份”；签发部分失败、证书校验失败、Dropbox 备份异常或 GitHub Secret 更新失败时分别提示实际状态，避免误报成功。
- Bark 消息统一归入“SSL 证书管理”分组，点击可跳转到当前 GitHub Actions 运行页面；时间以北京时间显示。
- SSL 通知请求固定携带 `isArchive: "1"` 和数值型 `ttl: 21600`：按 Bark 官方规则，消息保存至历史记录，并在 **6 小时后自动过期清理**（支持的 Bark 客户端还会移除通知中心对应条目）。这由 Bark 客户端执行，不需要新增 GitHub 定时任务；此前已经推送的消息不会被追溯设置有效期。
- **没有新证书、没有失败且没有待重试项目时不推送**；有 429 待重试即使尚未临期，也发出可识别的限流提示；证书缺失/临期则明确告警。Bark 只有 HTTP 成功且返回 JSON `code=200` 才判定推送成功；未配置 `BARK_URL` 时跳过。
- 修改通知规则后可使用离线测试 `.github/tests/test_notify_bark.sh` 核对格式与服务端返回码，无须连接 Bark、实际签发或写入 Dropbox。
- 多 CA 选择、EAB 账户注册、HTTP 5xx 回退、429 普通冷却与临期应急、跨运行防重复等逻辑由 `.github/tests/test_multi_ca.sh` 在离线环境模拟验证。ZeroSSL EC 通配符证书已在独立生产验收中成功签发；**应急 429 切换本身仍只通过离线模拟验证**。

## 运行环境和凭证安全

- 工作流在必要的步骤内注入 Cloudflare Token，不再将其放在工作流的全局环境；证书签发工作流默认使用 `contents: read` 权限。
- rclone 从官方 Release 安装固定版本 `1.75.2`，使用 SHA-256 `349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702` 校验，避免退回发行版较旧的软件包；acme.sh 锁定 `3.1.6` 及提交 `807da6498377ee5e0cf43a78091f46f12dc59a89`。升级前均需检查官方发布来源并通过离线与依赖安装冒烟测试。
- Google Public CA 的 EAB 绑定只用于手动试验；在 ACME 账户密钥能安全恢复之前，不能作为定时备用 CA。
- 证书校验任务只负责检查与更新报表，不向 Dropbox 回写证书。报表若发现私钥、域名或可信链校验失败，会标记为「校验失败」，并按严重异常处理。

## 验证结果与运维

- 2026-10-21：Dropbox 只读审计核对 6 个域名、12 张 EC/RSA 证书；保留原目录与文件命名。
- 2026-10-21：Let's Encrypt Staging DNS-01、单张正式 EC 证书、Dropbox 写回后回读均已通过验收。
- 2026-10-22：主分支健康检查成功并更新 `CHECK_LIST.md`；ZeroSSL EC 通配符独立生产验收成功。
- 每日自动续签持续启用；若部分证书失败，应先检查中文汇总、429 重试时间与 Dropbox 备份步骤，不要反复手动运行。
- 修改续签脚本时，使用 [Offline SSL Renewal Regression Tests](.github/workflows/ssl_offline_tests.yml) 验证离线异常场景；除续签和 Bark 测试外，也会执行 `.github/tests/test_verify_inventory.sh`、`.github/tests/test_backup_guard.sh`、`.github/tests/test_workflow_contract.sh`，模拟证书链、三文件回滚、远端删除保护及校验 GitHub Actions YAML 和固定 Dropbox 路径；另外使用无生产密钥的 CI 环境安装并验证固定版本的 rclone/acme.sh。测试不会调用真实 ACME 签发、Bark 或 Dropbox。

域名列表由用户在 Dropbox 手动维护：新增或删除有效域名后，下次运行会自动识别新的去重数量。比如 6 个域名最多对应 12 个检查对象，增加为 10 个域名就最多对应 20 个检查对象；这不是保证每次都会申请 20 张，只有进入续签窗口的证书才申请。不同域名或算法失败仍按既有机制报告，成功证书仍经验证后备份。

如需删除某个域名的 Dropbox 历史证书，请先确认相关服务不再使用；更改域名列表本身不会自动清理历史备份。
