---

# 使用 GitHub Actions 自动生成、更新和备份 SSL 证书

## 前言
在本教程中，我们将使用 GitHub Actions 自动化生成、更新和备份 SSL 证书。通过配置自动化工作流，你可以确保你的域名始终有有效的 SSL 证书，并且在证书即将到期时自动更新。我们还会介绍如何使用 Dropbox 来备份这些证书。

## 前提条件
1. 拥有一个 [GitHub](https://github.com/) 账号，并且创建了一个仓库。
2. 配置了 [Cloudflare](https://www.cloudflare.com/) DNS 管理，并且拥有 Cloudflare API Token 和 Account ID。
3. 安装了 [Dropbox](https://www.dropbox.com/) 并生成 API Token。

## 步骤一：配置 GitHub 仓库

### 1. 创建 GitHub 仓库
在 GitHub 上创建一个新的仓库。你可以选择创建一个私有仓库，以确保你的配置和数据安全。

### 2. 添加 Secrets
在 GitHub 仓库中，点击 **Settings**，找到 **Secrets and variables** 下的 **Actions**，然后添加以下 Secrets：
- `EMAIL`: 用于注册 acme.sh 的邮箱地址。
- `CF_TOKEN`: Cloudflare API Token，用于 DNS 验证。
- `CF_ACCOUNT_ID`: Cloudflare 账户 ID。
- `RCLONE_CONFIG`: 用于配置 rclone 的配置文件内容。
- `BARK_URL`: 用于发送通知的 Bark URL（可选）。
- `GITHUB_TOKEN`: GitHub 提供的默认令牌，用于推送变更。

## 步骤二：创建 GitHub Actions 工作流

### 1. 自动生成和备份 SSL 证书的工作流

在你的仓库中，创建一个 `.github/workflows/generate_and_backup_ssl.yml` 文件，内容如下：

```yaml
name: Generate and Backup SSL Certificates
on:
  schedule:
    - cron: "35 23 * * *"  # 每天定时执行
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
    name: Generate and Backup SSL Certificates
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install rclone and acme.sh
        run: |
          curl https://rclone.org/install.sh | sudo bash
          curl https://get.acme.sh | sh -s email=$EMAIL

      - name: Configure rclone
        env:
          RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}
        run: |
          mkdir -p ~/.config/rclone
          echo "$RCLONE_CONFIG" > ~/.config/rclone/rclone.conf

      - name: Sync certificates from Dropbox
        run: |
          rclone sync dropbox:$DROPBOX_PATH ./ssl $RCLONE_PARAMS --log-file=rclone_sync.log || exit 1
          echo "SSL Certificates synced from Dropbox."

      - name: Generate SSL Certificates if needed
        env:
          CF_Token: ${{ secrets.CF_TOKEN }}
          CF_Account_ID: ${{ secrets.CF_ACCOUNT_ID }}
        run: |
          check_certificate_validity() {
            cert_path=$1
            if [ -f "$cert_path" ]; then
              if openssl x509 -checkend $(( DAYS_BEFORE_EXPIRY * 86400 )) -noout -in "$cert_path"; then
                echo "Certificate at $cert_path is valid for more than $DAYS_BEFORE_EXPIRY days, skipping renewal..."
                return 0
              else
                return 1
              fi
            else
              return 1
            fi
          }

          issue_and_install_certificate() {
            domain=$1
            cert_type=$2
            cert_path="./ssl/$domain"
            [ "$cert_type" = "RSA" ] && cert_path="$cert_path/rsa"
            cert_file="$cert_path/$domain.cer"
            key_file="$cert_path/$domain.key"
            if ! check_certificate_validity "$cert_file"; then
              issue_output=$($ACME_PATH --issue --dns dns_cf -d "$domain" -d "*.$domain" 2>&1)
              if echo "$issue_output" | grep -q 'Skipping. Next renewal time'; then
                echo "Skipping certificate renewal for $domain as it's not yet due."
              else
                echo "$issue_output"
                if echo "$issue_output" | grep -q 'success'; then
                  $ACME_PATH --installcert -d "$domain" --key-file "$key_file" --fullchain-file "$cert_file" || { echo "Failed to install certificate for $domain"; exit 1; }
                  echo "Generated and installed $cert_type certificate for $domain"
                else
                  echo "Failed to issue certificate for $domain"
                  exit 1
                fi
              fi
            else
              echo "Existing $cert_type certificate for $domain is still valid, no need to generate a new one."
            fi
          }

          while IFS= read -r domain || [ -n "$domain" ]; do
            mkdir -p "./ssl/$domain/rsa"
            issue_and_install_certificate "$domain" "EC"
            issue_and_install_certificate "$domain" "RSA"
          done < cloudflare_domains_list.txt || true

      - name: Validate new certificates
        run: |
          for cert in $(find ./ssl -name "*.cer"); do
            openssl x509 -in "$cert" -noout -text || { echo "Invalid certificate: $cert"; exit 1; }
          done
          echo "All certificates are valid."

      - name: Backup certificates to Dropbox
        run: |
          rclone sync ./ssl dropbox:$DROPBOX_PATH $RCLONE_PARAMS --log-file=rclone_backup.log || exit 1
          echo "SSL Certificates backup to Dropbox completed."

      - name: Backup domain list and rclone config
        run: |
          rclone copy cloudflare_domains_list.txt dropbox:$DROPBOX_PATH $RCLONE_PARAMS --log-file=rclone_domainlist.log || exit 1
          rclone copy ~/.config/rclone dropbox:$DROPBOX_PATH/rclone-config $RCLONE_PARAMS --log-file=rclone_config.log || exit 1
          echo "Domain list and rclone config backup to Dropbox completed."

      - name: Cleanup local certificates
        run: |
          rm -rf ./ssl
          echo "Local SSL certificates cleaned up."

      - name: Update GitHub Secrets
        env:
          CLI_TOKEN: ${{ secrets.CLI_TOKEN }}
          REPO: ${{ github.repository }}
        run: |
          RCLONE_CONFIG=$(cat ~/.config/rclone/rclone.conf)
          echo "${CLI_TOKEN}" | gh auth login --with-token
          gh secret set RCLONE_CONFIG -b"${RCLONE_CONFIG}" --repo "${REPO}" || { echo "Failed to update RCLONE_CONFIG secret"; exit 1; }
          echo "Updated RCLONE_CONFIG secret."
```

### 2. 自动检查和更新 SSL 证书的工作流

创建一个 `.github/workflows/check_ssl_expiry.yml` 文件，内容如下：

```yaml
name: Check SSL Certificate Expiry and Update Certificates
on:
  schedule:
    - cron: "0 1 * * *"  # 每天定时执行
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
  check-and-update-certificates:
    runs-on: ubuntu-latest
    name: Check SSL Certificate Expiry and Update Certificates
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install rclone and acme.sh
        run: |
          curl https://rclone.org/install.sh | sudo bash
          curl https://get.acme.sh | sh -s email=$EMAIL

      - name: Configure rclone
        env:
          RCLONE_CONFIG: ${{ secrets.RCLONE_CONFIG }}
        run: |
          mkdir -p ~/.config/rclone
          echo "$RCLONE_CONFIG" > ~/.config/rclone/rclone.conf

      - name: Sync certificates from Dropbox
        run: |
          rclone sync dropbox:$DROPBOX_PATH ./ssl $RCLONE_PARAMS --log-file=rclone_sync.log || exit 1
          echo "SSL Certificates synced from Dropbox."

      - name: Check certificate expiry and update CHECK_LIST.md
        run: |


          git config --global user.email $EMAIL
          git config --global user.name acme

          check_certificate() {
            cert_file=$1
            if [ -f "$cert_file" ]; then
              expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
              expiry_timestamp=$(date -d "$expiry_date" +%s)
              current_timestamp=$(date +%s)
              days_left=$(( (expiry_timestamp - current_timestamp) / 86400 ))
              echo "$expiry_date|$days_left"
            else
              echo "Not found|0"
            fi
          }

          CURRENT_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
          echo "## Certificate Status (Checked at $CURRENT_TIME)" > CHECK_LIST.md
          echo "| Domain | Expiry Date (EC) | Days Left (EC) | Expiry Date (RSA) | Days Left (RSA) |" >> CHECK_LIST.md
          echo "|--------|-------------------|----------------|--------------------|--------------------|" >> CHECK_LIST.md

          trigger_renewal=false
          expiring_domains=""

          while IFS= read -r domain || [ -n "$domain" ]; do
            {
              ec_result=$(check_certificate "./ssl/$domain/$domain.cer")
              rsa_result=$(check_certificate "./ssl/$domain/rsa/$domain.cer")
              
              IFS='|' read -r ec_expiry ec_days <<< "$ec_result"
              IFS='|' read -r rsa_expiry rsa_days <<< "$rsa_result"

              echo "| $domain | $ec_expiry | $ec_days | $rsa_expiry | $rsa_days |" >> CHECK_LIST.md

              if [ "$ec_days" -lt "$DAYS_BEFORE_EXPIRY" ] || [ "$rsa_days" -lt "$DAYS_BEFORE_EXPIRY" ]; then
                trigger_renewal=true
                expiring_domains="$expiring_domains $domain"
              fi
            } &
          done < cloudflare_domains_list.txt
          wait

          git add CHECK_LIST.md
          git commit -m "Update CHECK_LIST.md with certificate expiry dates and execution time at $CURRENT_TIME"

          if [ "$trigger_renewal" = true ]; then
            echo "Certificates are expiring soon, renewing certificates..."

            renew_certificates() {
              domain=$1
              cert_type=$2
              cert_path="./ssl/$domain"
              [ "$cert_type" = "RSA" ] && cert_path="$cert_path/rsa"
              cert_file="$cert_path/$domain.cer"
              key_file="$cert_path/$domain.key"

              if ! openssl x509 -checkend $((DAYS_BEFORE_EXPIRY * 86400)) -noout -in "$cert_file"; then
                $ACME_PATH --issue --dns dns_cf -d "$domain" -d "*.$domain" || { echo "Failed to issue certificate for $domain"; return 1; }
                $ACME_PATH --installcert -d "$domain" --key-file "$key_file" --fullchain-file "$cert_file" || { echo "Failed to install certificate for $domain"; return 1; }
                echo "Generated and installed $cert_type certificate for $domain"
              else
                echo "Existing $cert_type certificate for $domain is still valid, no need to renew."
              fi
            }

            while IFS= read -r domain || [ -n "$domain" ]; do
              {
                renew_certificates "$domain" "EC"
                renew_certificates "$domain" "RSA"
              } &
            done < cloudflare_domains_list.txt
            wait
            
            BARK_URL="${{ secrets.BARK_URL }}"
            NOTIFICATION_TITLE="SSL证书已更新"
            NOTIFICATION_BODY="以下域名的SSL证书已更新: $expiring_domains"
            curl -X POST "$BARK_URL/$NOTIFICATION_TITLE/$NOTIFICATION_BODY"
          fi

      - name: Push updated CHECK_LIST.md to repository
        uses: ad-m/github-push-action@master
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}

      - name: Backup certificates to Dropbox
        run: |
          rclone sync ./ssl dropbox:$DROPBOX_PATH $RCLONE_PARAMS --log-file=rclone_backup.log || exit 1
          echo "SSL Certificates backup to Dropbox completed."

      - name: Clean up local certificates
        run: |
          rm -rf ./ssl
          echo "Local SSL certificates cleaned up."
```

## 步骤三：验证和运行工作流

1. **添加 `cloudflare_domains_list.txt` 文件**：在仓库根目录下创建一个名为 `cloudflare_domains_list.txt` 的文件，列出你需要为其生成 SSL 证书的域名。每个域名一行。

2. **测试工作流**：手动触发 GitHub Actions 工作流，检查它是否能够成功生成并备份 SSL 证书。你可以在 GitHub Actions 界面中查看详细日志，帮助排查问题。

3. **监控自动更新**：工作流将根据你设置的时间间隔自动检查 SSL 证书的过期情况，并在需要时自动更新证书。

## 结语

通过这个教程，你可以轻松地设置一个自动化的 SSL 证书管理流程。借助 GitHub Actions、Cloudflare 和 Dropbox，你的 SSL 证书将始终保持最新，并且备份也得到了保障。希望这个教程对你有所帮助！如果有任何问题或疑问，欢迎在评论区交流。

--- 
