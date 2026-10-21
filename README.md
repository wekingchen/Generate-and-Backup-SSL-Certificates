# 使用 GitHub Actions 自动生成和备份 SSL 证书

本仓库通过 GitHub Actions、[acme.sh](https://github.com/acmesh-official/acme.sh)、Cloudflare DNS 和 Dropbox 管理 Let's Encrypt 证书，继续支持 **ECC (EC P-256)** 与 **RSA 2048** 两种格式。

## 两条工作流

> **临时暂停说明（2026-10-21）**：两条生产工作流的定时触发暂未恢复，仅保留手动运行入口；下表的 UTC 时间是计划恢复后的原定时间。离线与 Staging 测试完成、完成受控生产验证后，才单独恢复定时执行。


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

原有 `EC_issue.log`、`RSA_issue.log` 文件命名不变。不会自动删除已从域名列表移除的历史备份。

`CHECK_LIST.md` 仍采用原来的五列表格：域名、EC 到期时间、EC 剩余天数、RSA 到期时间、RSA 剩余天数。不会改变表格列名和排列顺序。

## 配置

在仓库 **Settings → Secrets and variables → Actions** 中配置：

| Secret | 用途 |
| --- | --- |
| `EMAIL` | acme.sh 注册邮箱和报表提交身份 |
| `CF_TOKEN`、`CF_ACCOUNT_ID` | Cloudflare DNS-01 验证 |
| `RCLONE_CONFIG` | Dropbox 的完整 rclone 配置 |
| `CLI_TOKEN` | 使用 GitHub CLI 更新 `RCLONE_CONFIG` Secret |
| `BARK_URL` | 可选，Bark 推送地址 |

不要把私钥、rclone 配置、Cloudflare Token 或 Dropbox Token 提交到公开仓库。`GITHUB_TOKEN` 由 Actions 自动提供，不应手动创建同名 Secret。

## 证书生命周期与异常处理

- 只有当证书无效、缺失，或者距离到期不足续签阈值（目前为 30 天）时才申请新证书。
- 检查证书和私钥是否匹配、证书是否覆盖根域名与通配符域名、有效期是否足够。
- 每个域名、每种算法单独处理。一个失败时继续处理其他证书；有效的现有证书不得被失败的候选文件替换。
- 即使个别域名失败，也先完成已经校验成功的证书备份，最后才将工作流标记为失败。
- 域名列表为空、证书目录异常或总体验证失败时，拒绝回写 Dropbox，防止误覆盖。
- 触发 Let's Encrypt 429 时，以日志中的 `retry after` 为准，不应立即手动反复重跑。当前版本不额外改动 Dropbox 数据结构来保存持久冷却状态。
- 到期检查任务不负责续签；剩余 30 天内显示警告，证书缺失或仅剩 7 天及以下显示严重异常。

工作流中的证书状态、失败原因和总结尽量使用中文；acme.sh 的底层错误只在必要时展示末尾上下文。

## 验证与恢复运行

1. 在独立分支静态验证 YAML 与 Shell 脚本，不通过生产 ACME 接口测试异常路径。
2. 确认 Dropbox 路径、文件名和 `CHECK_LIST.md` 格式与现有数据兼容。
3. 在限额恢复后，选择受控的生产验证窗口，先确认当前旧证书仍可用。
4. 验证签发、证书和私钥匹配、Dropbox 回写、健康检查报表与 Bark 通知，再恢复每日定时执行。

如需删除某个域名的 Dropbox 历史证书，请先确认相关服务不再使用；更改域名列表本身不会自动清理历史备份。
