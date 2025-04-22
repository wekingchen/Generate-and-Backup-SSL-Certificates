---
# 使用 GitHub Actions 自动生成、更新和备份 SSL 证书

## 前言

本教程演示如何使用 GitHub Actions 自动化：

- 定期生成（或续期）SSL 证书（ECC + RSA）
- 在证书有效期低于阈值时自动更新
- 将证书和配置备份到 Dropbox
- 生成证书状态报表并在仓库中提交并推送
- 触发 Bark 通知（可选）

这样就能确保域名始终拥有有效证书，并且一旦证书快到期，就自动续签与备份。

## 前提条件

1. 拥有 GitHub 账号，并创建了目标仓库。
2. 在 Cloudflare 上管理域名，并获取 **API Token** (`CF_TOKEN`) 及 **Account ID** (`CF_ACCOUNT_ID`)。
3. 在 Dropbox 上创建 App，并生成 **API Token**，用于 `rclone`。
4. (可选) 已在设备或手机上安装并配置 Bark，用于接收推送通知。

## 步骤一：配置 GitHub 仓库

1. 创建仓库或在现有仓库中操作。建议使用私有仓库以保护配置。
2. 在仓库 **Settings → Secrets and variables → Actions** 中添加以下 Secrets：
   - `EMAIL`：注册 acme.sh 时使用的邮箱。
   - `CF_TOKEN`：Cloudflare API Token。
   - `CF_ACCOUNT_ID`：Cloudflare 账户 ID。
   - `RCLONE_CONFIG`：完整的 `rclone` 配置内容。
   - `BARK_URL`：Bark 推送地址（可选）。
   - `GITHUB_TOKEN`：GitHub 自动生成的推送令牌。
   - `CLI_TOKEN`：用于 GH CLI 更新 `RCLONE_CONFIG`（可选）。

## 步骤二：创建并优化工作流

### 1. 生成并备份 SSL 证书（`generate_and_backup_ssl.yml`）

```yaml
name: Generate and Backup SSL Certificates
on:
  schedule:
    - cron: "35 23 * * *"
  workflow_dispatch:

env:
  EMAIL: ${{ secrets.EMAIL }}
  CF_TOKEN: ${{ secrets.CF_TOKEN }}
  CF_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
  RCLONE_PARAMS: "--transfers=10 --checkers=10 --stats=1s"
  DROPBOX_PATH: "SSL"
  DAYS_BEFORE_EXPIRY: 30
  ACME_PATH: "/home/runner/.acme.sh/acme.sh"

jobs:
  generate-and-backup:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: 安装 rclone 与 acme.sh
        run: |
          curl https://rclone.org/install.sh | sudo bash
          curl https://get.acme.sh | sh -s email=$EMAIL

      - name: 配置 rclone
        env:
          RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}
        run: |
          mkdir -p ~/.config/rclone
          echo "$RCLONE_CONFIG" > ~/.config/rclone/rclone.conf

      - name: 同步证书与域名列表
        run: |
          set -eo pipefail
          rclone sync dropbox:$DROPBOX_PATH ./ssl $RCLONE_PARAMS --log-file=rclone_sync.log
          rclone copy dropbox:$DROPBOX_PATH/cloudflare_domains_list.txt ./

      - name: 生成（或续期）SSL 证书
        env:
          CF_TOKEN: ${{ secrets.CF_TOKEN }}
          CF_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
        run: |
          set -eo pipefail

          # 检查证书有效期
          check_validity() {
            cert=$1; [ -f "$cert" ] || return 1
            if openssl x509 -checkend $((DAYS_BEFORE_EXPIRY*86400)) -noout -in "$cert"; then
              return 0
            else
              return 1
            fi
          }

          # 签发与安装函数
          issue_install() {
            domain=$1; type=$2; src="$HOME/.acme.sh/$domain$([ "$type" = "EC" ] && echo "_ecc")"
            dest="./ssl/$domain$([ "$type" = "RSA" ] && echo "/rsa")"
            mkdir -p "$dest"
            certf="$dest/fullchain.cer"; keyf="$dest/private.key"
            updated=0

            if ! check_validity "$certf"; then
              echo "→ 生成 $domain 的 $type..."
              $ACME_PATH --issue --force --dns dns_cf -d "$domain" -d "*.$domain" \
                --keylength $([ "$type" = "RSA" ] && echo 2048 || echo ec-256) >/dev/null 2>&1
              if [ -f "$src/fullchain.cer" ]; then
                cp "$src/fullchain.cer" "$certf"; cp "$src/${domain}.key" "$keyf"
                updated=1; echo "✔ $domain $type 已安装"
              else
                echo "✘ 未找到 $domain $type，跳过"
              fi
            else
              echo "— $domain 的 $type 仍有效"
            fi

            [ $updated -eq 1 ] && echo $domain
          }

          # 批量处理
          domains=""
          while read -r d; do
            domains+=" $(issue_install "$d" EC)"
            domains+=" $(issue_install "$d" RSA)"
          done < cloudflare_domains_list.txt

          # 发送 Bark 通知
          domains=$(echo "$domains" | tr ' ' '\n' | sort -u | tr '\n' ' ')
          if [ -n "$domains" ]; then
            body="以下域名已更新： $domains"
            curl -s -X POST "${{ secrets.BARK_URL }}/SSL%20Updated/$(echo $body|sed 's/ /%20/g')"
          fi

      - name: 验证证书
        run: |
          find ./ssl -name fullchain.cer | xargs -n1 openssl x509 -noout -text

      - name: 备份到 Dropbox
        run: |
          rclone sync ssl dropbox:$DROPBOX_PATH $RCLONE_PARAMS --log-file=rclone_backup.log

      - name: 清理工作目录
        run: rm -rf ssl cloudflare_domains_list.txt

      - name: 更新 RCLONE_CONFIG Secret
        env:
          CLI_TOKEN: ${{ secrets.CLI_TOKEN }}
        run: |
          echo "${CLI_TOKEN}" | gh auth login --with-token
          gh secret set RCLONE_CONFIG -b"$(cat ~/.config/rclone/rclone.conf)"
```

**改动亮点**：
- 全局 `set -eo pipefail`，任一步骤出错即终止。
- 统一用 `fullchain.cer`、`private.key` 命名。
- 发证与安装合并在一个函数中，返回更新的域名列表。
- 简化输出与通知逻辑。

### 2. 检查并更新过期证书（`check_ssl_expiry.yml`）

```yaml
name: Check SSL Certificate Expiry and Update Certificates
on:
  schedule:
    - cron: "0 1 * * *"
  workflow_dispatch:

env:
  EMAIL: ${{ secrets.EMAIL }}
  CF_TOKEN: ${{ secrets.CF_TOKEN }}
  CF_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
  RCLONE_PARAMS: "--transfers=10 --checkers=10 --stats=1s"
  DROPBOX_PATH: "SSL"
  DAYS_BEFORE_EXPIRY: 30
  ACME_PATH: "/home/runner/.acme.sh/acme.sh"

jobs:
  check-and-update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: 安装工具
        run: |
          curl https://rclone.org/install.sh | sudo bash
          curl https://get.acme.sh | sh -s email=$EMAIL

      - name: 配置 rclone
        env:
          RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}
        run: |
          mkdir -p ~/.config/rclone
          echo "$RCLONE_CONFIG" > ~/.config/rclone/rclone.conf

      - name: 同步证书与域名
        run: |
          set -eo pipefail
          rclone sync dropbox:$DROPBOX_PATH ./ssl $RCLONE_PARAMS
          rclone copy dropbox:$DROPBOX_PATH/cloudflare_domains_list.txt ./

      - name: 生成 CHECK_LIST.md 并续期
        run: |
          set -eo pipefail
          git config --global user.email "$EMAIL"
          git config --global user.name "acme-bot"

          NOW=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
          echo "## Certificate Status (Checked at $NOW)" > CHECK_LIST.md
          echo "|Domain|EC到期|剩余天数|RSA到期|剩余天数|" >> CHECK_LIST.md
          echo "|-----|-----|--------|-----|--------|" >> CHECK_LIST.md

          trigger=false
          expire_list=""

          check() {
            f="$1/fullchain.cer"
            [ -f "$f" ] || { echo "NOTFOUND|0"; return; }
            d=$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)
            t=$(date -d "$d" +%s)
            n=$(date +%s)
            days=$(( (t-n)/86400 ))
            echo "$d|$days"
          }

          renew() {
            dom=$1; typ=$2
            dir="./ssl/$dom"; [ "$typ" = "RSA" ] && dir+="/rsa"
            f="$dir/fullchain.cer"; k="$dir/private.key"
            if ! openssl x509 -checkend $((DAYS_BEFORE_EXPIRY*86400)) -noout -in "$f"; then
              echo "→ 续期 $dom($typ)..."
              if [ "$typ" = "EC" ]; then
                $ACME_PATH --issue --force --dns dns_cf --ecc -d "$dom" -d "*.$dom"
                $ACME_PATH --installcert --ecc -d "$dom" --key-file "$k" --fullchain-file "$f"
              else
                $ACME_PATH --issue --force --dns dns_cf -d "$dom" -d "*.$dom" --keylength 2048
                $ACME_PATH --installcert -d "$dom" --key-file "$k" --fullchain-file "$f"
              fi
              trigger=true; expire_list+=" $dom"
            fi
          }

          while read -r d; do
            { IFS='|' read ecd ecdays <<< "$(check "./ssl/$d")"; \
              IFS='|' read rsad rsadays <<< "$(check "./ssl/$d/rsa")"; \
              printf "|%s|%s|%s|%s|%s|\n" "$d" "$ecd" "$ecdays" "$rsad" "$rsadays" >> CHECK_LIST.md; \
              if [ "$ecdays" -lt "$DAYS_BEFORE_EXPIRY" ] || [ "$rsadays" -lt "$DAYS_BEFORE_EXPIRY" ]; then
                renew "$d" EC; renew "$d" RSA;
              fi; } &
          done < cloudflare_domains_list.txt
          wait

          if ! git diff --quiet CHECK_LIST.md; then
            git add CHECK_LIST.md; git commit -m "Update CHECK_LIST.md at $NOW"; git push
          fi

          if [ "$trigger" = true ]; then
            curl -s -X POST "${{ secrets.BARK_URL }}/SSL%20Updated/$(echo $expire_list|sed 's/ /%20/g')"
          fi

      - uses: ad-m/github-push-action@master
        if: ${{ success() }}
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}

      - name: 备份到 Dropbox
        run: |
          rclone sync ssl dropbox:$DROPBOX_PATH $RCLONE_PARAMS

      - name: 清理文件
        run: rm -rf ssl cloudflare_domains_list.txt
```

## 步骤三：运行与验证

1. 在仓库根目录创建 `cloudflare_domains_list.txt`，每行一个域名。
2. 手动触发两条 Workflow，观察日志与 Dropbox 备份情况。
3. 检查 `CHECK_LIST.md` 提交历史与 Bark 通知是否正确。

---

