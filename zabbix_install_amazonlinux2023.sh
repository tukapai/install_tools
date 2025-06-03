#!/bin/bash
set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_section() {
  echo "===== $1 ====="
}

################################################
#  参考例：スクリプト実行前に環境変数を設定が必要
#  export ZABBIX_DB_PASS=zabbix_password123
#  export MYSQL_ROOT_PASSWORD=root_password123
################################################

# 必須環境変数のリスト
required_vars=(
  ZABBIX_DB_PASS
  MYSQL_ROOT_PASSWORD
)

log_section "Check Export Variables"

# チェック処理
missing_vars=()
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    missing_vars+=("$var")
  fi
done

# 未設定の変数があればエラー表示して終了
if [ ${#missing_vars[@]} -ne 0 ]; then
  log_error "The following environment variables are missing:"
  for var in "${missing_vars[@]}"; do
    log_error "  - $var"
  done
  exit 1
fi

log_info "All required environment variables are set."

log_section "Start Zabbix installation"

# リポジトリの登録処理
log_info "Install Zabbix repository"

set +euo pipefail
rpm -Uvh https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm
dnf clean all

set -euo pipefail

# パッケージインストールの実行
log_info "Install Zabbix server, frontend, agent"

dnf install -y zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-sql-scripts zabbix-agent

log_info "Create initial database"

# データベースの設定

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP DATABASE IF EXISTS zabbix;
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
DROP USER IF EXISTS 'zabbix'@'localhost';
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY "${ZABBIX_DB_PASS}";
GRANT ALL PRIVILEGES ON zabbix.* TO zabbix@localhost;
SET global log_bin_trust_function_creators = 1;
quit
EOF

log_info "Import initial schema and data"

zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p"${ZABBIX_DB_PASS}" zabbix

log_info "Disable log_bin_trust_function_creators"

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF

# ZabbixServerの設定
log_info "Configure the database for Zabbix server"
log_info "Edit file /etc/zabbix/zabbix_server.conf"
sudo sed -i 's/^DBPassword=.*/DBPassword=${ZABBIX_DB_PASS}/' /etc/zabbix/zabbix_server.conf

# プロセス再起動
log_info "Start Zabbix server and agent processes"
systemctl restart zabbix-server zabbix-agent httpd php-fpm
systemctl enable zabbix-server zabbix-agent httpd php-fpm

log_info "Zabbix server Install and Setting completed!"
