#!/usr/bin/env bash
#
# vps-init-helper — setup.sh
#
# Single-file bootstrap for a fresh Debian 12 / Ubuntu LTS VPS.
# Installs: nginx, MySQL/PostgreSQL/MongoDB (interactive selection), Docker,
# nvm + Node.js LTS + PM2, htop + misc tools, ufw, fail2ban, a new sudo user.
#
# Safe to re-run (idempotent) — this is intentional, so the same script can
# be run again on a brand new VPS to recreate the stack during migration.
#
# Usage: sudo bash setup.sh
#
set -euo pipefail

# ============================================================
# Globals
# ============================================================

OUTPUT_DIR="/root/vps-init-helper"
STATE_DIR="$OUTPUT_DIR/state"
SCRIPTS_DIR="$OUTPUT_DIR/scripts"
REPORT_FILE="$OUTPUT_DIR/install-report.md"
SECURITY_FILE="$OUTPUT_DIR/security.md"
MIGRATION_FILE="$OUTPUT_DIR/migration.md"
NVM_VERSION="v0.40.1"

INSTALLED_ITEMS=()
SELECTED_DBS=()
NEW_USER=""
SSH_PORT="22"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
CLIENT_NAME=""
MYSQL_UNIT=""
TELEGRAM_ENABLED="no"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
CF_IP_LOCK="no"
MONIT_INSTALLED="no"
LOGWATCH_INSTALLED="no"
AIDE_INSTALLED="no"
LYNIS_SCORE="N/A"

COLOR_RESET='\033[0m'
COLOR_INFO='\033[0;32m'
COLOR_WARN='\033[0;33m'
COLOR_ERROR='\033[0;31m'
COLOR_STEP='\033[1;36m'

# ============================================================
# Logging
# ============================================================

log_info()  { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
log_error() { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2; }
log_step()  { echo -e "\n${COLOR_STEP}==> $*${COLOR_RESET}"; }

trap 'log_error "Setup gagal di baris $LINENO. Cek pesan error di atas, lalu jalankan ulang setup.sh (aman diulang)."' ERR

# ============================================================
# Core helpers
# ============================================================

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Script ini harus dijalankan sebagai root. Coba: sudo bash setup.sh"
    exit 1
  fi
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    log_error "Tidak bisa mendeteksi OS (/etc/os-release tidak ditemukan)."
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="$ID"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$OS_ID" in
    debian)
      if [ "$OS_VERSION_ID" != "12" ]; then
        log_warn "Script ini dites di Debian 12 (bookworm). Terdeteksi Debian $OS_VERSION_ID — melanjutkan dengan risiko sendiri."
      fi
      ;;
    ubuntu)
      log_info "Terdeteksi Ubuntu $OS_VERSION_ID ($OS_CODENAME)."
      ;;
    rocky)
      log_info "Terdeteksi Rocky Linux $OS_VERSION_ID — akan delegasi ke setup-rocky8.sh."
      ;;
    *)
      log_error "OS tidak didukung: $OS_ID. Script ini hanya untuk Debian/Ubuntu/Rocky Linux 8."
      exit 1
      ;;
  esac
}

# Rocky/RHEL-family pakai dnf/firewalld/SELinux, cukup berbeda dari
# apt/ufw Debian-Ubuntu sehingga logikanya ditulis di script terpisah
# (scripts/setup-rocky8.sh) alih-alih dicampur di sini. setup.sh tetap
# jadi satu-satunya entry point: OS dideteksi dulu, baru didelegasikan.
dispatch_to_rocky_if_needed() {
  [ "$OS_ID" = "rocky" ] || return 0

  local self_dir rocky_script
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for rocky_script in "$self_dir/scripts/setup-rocky8.sh" "$self_dir/setup-rocky8.sh"; do
    if [ -f "$rocky_script" ]; then
      log_info "Menjalankan $rocky_script ..."
      chmod +x "$rocky_script"
      exec bash "$rocky_script" "$@"
    fi
  done

  log_error "Terdeteksi Rocky Linux, tapi scripts/setup-rocky8.sh tidak ditemukan di sebelah setup.sh."
  log_error "Untuk Rocky Linux 8, copy setup.sh BESERTA scripts/setup-rocky8.sh (satu folder yang sama) ke VPS, bukan cuma setup.sh sendirian."
  exit 1
}

print_banner() {
  echo -e "${COLOR_STEP}"
  echo "============================================================"
  echo " vps-init-helper — VPS kosong menuju production ready"
  echo "============================================================"
  echo -e "${COLOR_RESET}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_done() { [ -f "$STATE_DIR/$1.done" ]; }
mark_done() { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$1.done"; }

apt_install_if_missing() {
  local pkgs=("$@")
  local to_install=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || to_install+=("$p")
  done
  if [ ${#to_install[@]} -gt 0 ]; then
    apt-get install -y "${to_install[@]}"
  fi
}

detect_ssh_port() {
  local port
  port=$(grep -E "^[[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
  echo "${port:-22}"
}

prompt_password_confirmed() {
  # usage: prompt_password_confirmed VARNAME "Prompt text"
  local -n _outvar="$1"
  local prompt_text="$2"
  local pw1 pw2
  while true; do
    read -rsp "$prompt_text: " pw1; echo
    read -rsp "Ulangi password: " pw2; echo
    if [ "$pw1" != "$pw2" ]; then
      log_warn "Password tidak sama, coba lagi."
      continue
    fi
    if [ -z "$pw1" ]; then
      log_warn "Password tidak boleh kosong."
      continue
    fi
    break
  done
  _outvar="$pw1"
}

# ============================================================
# Steps
# ============================================================

ask_client_info() {
  log_step "Info client/project (untuk laporan)"
  read -rp "Nama client atau project (untuk judul laporan, kosongkan untuk skip): " CLIENT_NAME
}

configure_hostname_timezone() {
  log_step "Hostname & Timezone"
  local new_hostname tz
  read -rp "Set hostname baru? (kosongkan untuk skip, sekarang: $(hostname)): " new_hostname
  if [ -n "$new_hostname" ]; then
    hostnamectl set-hostname "$new_hostname"
    log_info "Hostname diubah ke $new_hostname"
  fi

  read -rp "Set timezone (contoh: Asia/Jakarta, kosongkan untuk skip, sekarang: $(timedatectl show -p Timezone --value)): " tz
  if [ -n "$tz" ]; then
    if timedatectl set-timezone "$tz" 2>/dev/null; then
      log_info "Timezone diubah ke $tz"
    else
      log_warn "Timezone '$tz' tidak valid, dilewati."
    fi
  fi
}

system_update() {
  log_step "Update sistem & install paket dasar"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt_install_if_missing curl wget git unzip gnupg ca-certificates software-properties-common apt-transport-https lsb-release
  INSTALLED_ITEMS+=("System update + paket dasar (curl, wget, git, unzip, gnupg, dll)")
}

setup_swap() {
  log_step "Cek & setup swap"
  if swapon --show | grep -q .; then
    log_info "Swap sudah aktif, dilewati."
    return 0
  fi
  local total_mem_mb
  total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
  if [ "$total_mem_mb" -ge 2048 ]; then
    log_info "RAM cukup besar (${total_mem_mb}MB), swap tidak diperlukan."
    return 0
  fi
  log_info "RAM rendah (${total_mem_mb}MB), membuat swapfile 2G..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  INSTALLED_ITEMS+=("Swapfile 2G (/swapfile)")
}

create_new_user() {
  log_step "Buat user baru (pengganti akses root, opsional)"

  if is_done "user_created"; then
    NEW_USER=$(cat "$STATE_DIR/user_created.done")
    if [ -n "$NEW_USER" ]; then
      log_info "User '$NEW_USER' sudah pernah dibuat sebelumnya, lewati."
      INSTALLED_ITEMS+=("User sudo: $NEW_USER (sudah ada sebelumnya)")
    else
      log_info "Sebelumnya kamu memilih skip pembuatan user baru, tetap dilewati."
      INSTALLED_ITEMS+=("User sudo baru: (tidak dibuat, di-skip)")
    fi
    return 0
  fi

  local username
  echo "Kosongkan untuk skip (tidak buat user baru) — pastikan kamu sudah punya akses non-root+sudo lain ke server ini kalau begitu."
  while true; do
    read -rp "Masukkan username baru (non-root, akan diberi akses sudo, kosongkan untuk skip): " username
    if [ -z "$username" ]; then
      log_warn "Melewati pembuatan user baru. Node.js/PM2 juga akan dilewati (nvm butuh user non-root)."
      mkdir -p "$STATE_DIR"
      : > "$STATE_DIR/user_created.done"
      NEW_USER=""
      INSTALLED_ITEMS+=("User sudo baru: (tidak dibuat, di-skip)")
      return 0
    fi
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      break
    fi
    log_warn "Username tidak valid. Gunakan huruf kecil, angka, underscore, dash (atau kosongkan untuk skip)."
  done

  if id "$username" >/dev/null 2>&1; then
    log_info "User '$username' sudah ada di sistem, hanya memastikan grup sudo & SSH key."
  else
    adduser --disabled-password --gecos "" "$username"
  fi
  usermod -aG sudo "$username"

  local ssh_dir="/home/$username/.ssh"
  mkdir -p "$ssh_dir"
  echo "Tempel SSH PUBLIC KEY kamu (isi file .pub, contoh: ssh-ed25519 AAAA... user@laptop):"
  local pubkey
  read -rp "> " pubkey
  if [ -n "$pubkey" ]; then
    touch "$ssh_dir/authorized_keys"
    echo "$pubkey" >> "$ssh_dir/authorized_keys"
    sort -u -o "$ssh_dir/authorized_keys" "$ssh_dir/authorized_keys"
  else
    log_warn "Tidak ada public key dimasukkan. Kamu HARUS menambahkannya manual sebelum mengikuti security.md (disable password login)."
    touch "$ssh_dir/authorized_keys"
  fi
  chown -R "$username:$username" "$ssh_dir"
  chmod 700 "$ssh_dir"
  chmod 600 "$ssh_dir/authorized_keys"

  NEW_USER="$username"
  mkdir -p "$STATE_DIR"
  echo "$NEW_USER" > "$STATE_DIR/user_created.done"
  INSTALLED_ITEMS+=("User sudo baru: $NEW_USER (SSH key terpasang)")
}

write_notify_telegram_script() {
  mkdir -p "$SCRIPTS_DIR"
  cat > "$SCRIPTS_DIR/notify-telegram.sh" <<'NOTIFY_SCRIPT_EOF'
#!/usr/bin/env bash
# vps-init-helper — notify-telegram.sh
# Sends a message to Telegram using the bot token/chat id saved by setup.sh.
# Silently no-ops if telegram.conf is missing/incomplete so callers (fail2ban,
# Monit, cron jobs) can always invoke this without checking first.
CONF="/root/vps-init-helper/telegram.conf"
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || exit 0
MESSAGE="$*"
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}" >/dev/null
NOTIFY_SCRIPT_EOF
  chmod 700 "$SCRIPTS_DIR/notify-telegram.sh"
}

setup_telegram_alerts() {
  log_step "Notifikasi Telegram (dipakai fail2ban, Monit, logwatch, AIDE)"
  local ans
  read -rp "Aktifkan notifikasi Telegram? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log_info "Notifikasi Telegram dilewati. Modul lain tetap jalan tanpa notifikasi eksternal."
    TELEGRAM_ENABLED="no"
    return 0
  fi

  echo "Buat bot lewat @BotFather di Telegram untuk dapat token, kirim pesan apa saja ke bot"
  echo "itu, lalu buka https://api.telegram.org/bot<token>/getUpdates untuk dapat chat_id."
  read -rp "Telegram bot token: " TELEGRAM_BOT_TOKEN
  read -rp "Telegram chat ID: " TELEGRAM_CHAT_ID

  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log_warn "Token/chat ID kosong, notifikasi Telegram dilewati."
    TELEGRAM_ENABLED="no"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  cat > "$OUTPUT_DIR/telegram.conf" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF
  chmod 600 "$OUTPUT_DIR/telegram.conf"

  write_notify_telegram_script

  if "$SCRIPTS_DIR/notify-telegram.sh" "vps-init-helper: notifikasi Telegram aktif di server $(hostname)."; then
    TELEGRAM_ENABLED="yes"
    INSTALLED_ITEMS+=("Notifikasi Telegram aktif (dipakai fail2ban, Monit, logwatch, AIDE)")
    log_info "Test pesan Telegram terkirim. Cek chat kamu."
  else
    TELEGRAM_ENABLED="yes"
    INSTALLED_ITEMS+=("Notifikasi Telegram dikonfigurasi (test pesan gagal terkirim, cek token/chat ID manual)")
    log_warn "Gagal mengirim test pesan Telegram. Cek token/chat ID. Konfigurasi tetap disimpan."
  fi
}

setup_firewall() {
  log_step "Konfigurasi UFW (firewall)"
  apt_install_if_missing ufw
  SSH_PORT=$(detect_ssh_port)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ufw --force enable >/dev/null
  INSTALLED_ITEMS+=("UFW aktif — port terbuka: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)")
  log_info "UFW aktif. Port terbuka: $SSH_PORT, 80, 443."

  local ans
  read -rp "Batasi port 80/443 hanya dari IP Cloudflare? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if apply_cloudflare_ip_lock; then
      CF_IP_LOCK="yes"
    fi
  fi
}

apply_cloudflare_ip_lock() {
  log_step "Membatasi port 80/443 hanya dari IP Cloudflare"
  local cf_v4 cf_v6
  cf_v4=$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null || true)
  cf_v6=$(curl -fsSL https://www.cloudflare.com/ips-v6 2>/dev/null || true)
  if [ -z "$cf_v4" ]; then
    log_warn "Gagal mengambil daftar IP Cloudflare. Port 80/443 tetap terbuka untuk semua IP."
    return 1
  fi

  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ufw delete allow 443/tcp >/dev/null 2>&1 || true

  local cidr
  while IFS= read -r cidr; do
    if [ -n "$cidr" ]; then
      ufw allow from "$cidr" to any port 80,443 proto tcp comment 'Cloudflare' >/dev/null
    fi
  done <<< "$cf_v4"

  if [ -n "$cf_v6" ]; then
    while IFS= read -r cidr; do
      if [ -n "$cidr" ]; then
        ufw allow from "$cidr" to any port 80,443 proto tcp comment 'Cloudflare' >/dev/null
      fi
    done <<< "$cf_v6"
  fi

  INSTALLED_ITEMS+=("UFW dibatasi — port 80/443 hanya menerima koneksi dari IP Cloudflare")
  log_info "Port 80/443 sekarang hanya menerima koneksi dari IP Cloudflare."
  return 0
}

setup_fail2ban() {
  log_step "Konfigurasi fail2ban"
  apt_install_if_missing fail2ban

  if [ "$TELEGRAM_ENABLED" = "yes" ]; then
    cat > /etc/fail2ban/action.d/telegram.conf <<'F2B_EOF'
[Definition]
actionban = /root/vps-init-helper/scripts/notify-telegram.sh fail2ban: IP <ip> diblokir dari jail <name> di server $(hostname) - percobaan gagal: <failures>
actionunban =
F2B_EOF
  fi

  {
    echo "[DEFAULT]"
    echo "bantime = 1h"
    echo "findtime = 10m"
    echo "maxretry = 5"
    if [ "$TELEGRAM_ENABLED" = "yes" ]; then
      echo "action = %(action_)s"
      echo "         telegram"
    fi
    echo
    echo "[sshd]"
    echo "enabled = true"
    echo "port = ${SSH_PORT}"
    echo "backend = systemd"
  } > /etc/fail2ban/jail.local

  systemctl enable --now fail2ban >/dev/null 2>&1
  systemctl restart fail2ban

  local f2b_note=""
  [ "$TELEGRAM_ENABLED" = "yes" ] && f2b_note=", notifikasi Telegram aktif"
  INSTALLED_ITEMS+=("fail2ban — jail sshd aktif (port $SSH_PORT, maxretry 5, bantime 1h)${f2b_note}")
}

install_nginx() {
  log_step "Install nginx"
  apt_install_if_missing nginx
  systemctl enable --now nginx >/dev/null 2>&1
  local ver
  ver=$(nginx -v 2>&1 | grep -oP '[0-9.]+' | head -1 || echo "?")
  INSTALLED_ITEMS+=("nginx $ver")
}

install_mysql() {
  if is_done "mysql_install"; then
    log_info "MySQL/MariaDB sudah pernah di-setup sebelumnya, lewati."
    INSTALLED_ITEMS+=("MySQL/MariaDB (sudah ada sebelumnya)")
    if systemctl is-active --quiet mysql; then
      MYSQL_UNIT="mysql"
    elif systemctl is-active --quiet mariadb; then
      MYSQL_UNIT="mariadb"
    fi
    return 0
  fi
  log_step "Install MySQL/MariaDB"
  local pkg="mysql-server"
  [ "$OS_ID" = "debian" ] && pkg="default-mysql-server"
  apt_install_if_missing "$pkg"

  if systemctl enable --now mysql >/dev/null 2>&1; then
    MYSQL_UNIT="mysql"
  elif systemctl enable --now mariadb >/dev/null 2>&1; then
    MYSQL_UNIT="mariadb"
  fi

  local mysql_root_password
  prompt_password_confirmed mysql_root_password "Password root MySQL/MariaDB baru"

  local escaped_pw="${mysql_root_password//\'/''}"
  # Dikirim lewat stdin (heredoc), bukan argumen -e, supaya password tidak
  # muncul di `ps`/`/proc/<pid>/cmdline` (bisa dibaca user lokal lain).
  mysql -u root <<SQL 2>/dev/null || log_warn "Sebagian perintah MySQL secure-setup gagal (kemungkinan sudah pernah dijalankan sebelumnya)."
ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_pw}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

  mark_done "mysql_install"
  INSTALLED_ITEMS+=("MySQL/MariaDB — root password sudah diset (SIMPAN sendiri, tidak disimpan script ini)")
  log_info "MySQL root password sudah diset. SIMPAN baik-baik, script ini tidak menyimpannya."
  return 0
}

install_postgresql() {
  if is_done "postgresql_install"; then
    log_info "PostgreSQL sudah pernah di-setup sebelumnya, lewati."
    INSTALLED_ITEMS+=("PostgreSQL (sudah ada sebelumnya)")
    return 0
  fi
  log_step "Install PostgreSQL"
  apt_install_if_missing postgresql postgresql-contrib
  systemctl enable --now postgresql >/dev/null 2>&1

  local pg_password
  prompt_password_confirmed pg_password "Password baru untuk user 'postgres'"
  local escaped_pw="${pg_password//\'/''}"
  # Dikirim lewat stdin, bukan argumen -c, supaya password tidak muncul di
  # `ps`/`/proc/<pid>/cmdline`.
  sudo -u postgres psql >/dev/null <<SQL
ALTER USER postgres WITH PASSWORD '${escaped_pw}';
SQL

  mark_done "postgresql_install"
  INSTALLED_ITEMS+=("PostgreSQL — password user 'postgres' sudah diset (SIMPAN sendiri, tidak disimpan script ini)")
  log_info "Password user 'postgres' sudah diset. SIMPAN baik-baik, script ini tidak menyimpannya."
  return 0
}

install_mongodb() {
  if is_done "mongodb_install"; then
    log_info "MongoDB sudah pernah di-setup sebelumnya, lewati."
    INSTALLED_ITEMS+=("MongoDB (sudah ada sebelumnya)")
    return 0
  fi
  log_step "Install MongoDB"

  local codename repo_component="main" repo_os="$OS_ID"
  # shellcheck disable=SC1091
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  [ "$OS_ID" = "ubuntu" ] && repo_component="multiverse"

  apt_install_if_missing gnupg curl

  if ! curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg; then
    log_warn "Gagal mengambil GPG key MongoDB. Melewati instalasi MongoDB."
    return 1
  fi

  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/${repo_os} ${codename}/mongodb-org/7.0 ${repo_component}" \
    > /etc/apt/sources.list.d/mongodb-org-7.0.list

  if ! apt-get update -y; then
    log_warn "Repo MongoDB tidak tersedia untuk ${repo_os} ${codename}. Melewati instalasi MongoDB."
    rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update -y || true
    return 1
  fi

  if ! apt-get install -y mongodb-org; then
    log_warn "Gagal install paket mongodb-org. Melewati instalasi MongoDB."
    return 1
  fi

  systemctl enable --now mongod >/dev/null 2>&1

  local mongo_password
  prompt_password_confirmed mongo_password "Password untuk MongoDB admin user"
  local bs_squote=$'\\\''
  local escaped_pw="${mongo_password//\'/$bs_squote}"
  local create_user_js="db.getSiblingDB('admin').createUser({user:'admin',pwd:'${escaped_pw}',roles:[{role:'root',db:'admin'}]})"
  # Dikirim lewat stdin (here-string), bukan argumen --eval, supaya password
  # tidak muncul di `ps`/`/proc/<pid>/cmdline`.
  if command_exists mongosh; then
    mongosh --quiet <<< "$create_user_js"
  else
    mongo --quiet <<< "$create_user_js"
  fi

  if ! grep -q "^security:" /etc/mongod.conf; then
    printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
  fi
  systemctl restart mongod

  mark_done "mongodb_install"
  INSTALLED_ITEMS+=("MongoDB — admin user dibuat, authorization aktif (SIMPAN password sendiri)")
  log_info "MongoDB admin user dibuat, authorization diaktifkan. SIMPAN password baik-baik."
  return 0
}

install_minio() {
  if is_done "minio_install"; then
    log_info "MinIO sudah pernah di-setup sebelumnya, lewati."
    INSTALLED_ITEMS+=("MinIO (sudah ada sebelumnya)")
    return 0
  fi
  log_step "Install MinIO (AGPLv3 — Community Edition)"

  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) log_warn "Arsitektur $(uname -m) tidak didukung binary resmi MinIO. Melewati instalasi MinIO."; return 1 ;;
  esac

  if ! curl -fsSL "https://dl.min.io/server/minio/release/linux-${arch}/minio" -o /usr/local/bin/minio; then
    log_warn "Gagal mengunduh binary MinIO. Melewati instalasi MinIO."
    return 1
  fi
  chmod +x /usr/local/bin/minio

  getent group minio-user >/dev/null || groupadd -r minio-user
  id minio-user >/dev/null 2>&1 || useradd -M -r -g minio-user -s /usr/sbin/nologin minio-user

  mkdir -p /var/lib/minio/data
  chown -R minio-user:minio-user /var/lib/minio
  chmod 750 /var/lib/minio/data

  local minio_user minio_password minio_password2
  read -rp "Username root MinIO (kosongkan untuk 'minioadmin'): " minio_user
  minio_user="${minio_user:-minioadmin}"
  while true; do
    read -rsp "Password root MinIO baru (min. 8 karakter): " minio_password; echo
    if [ "${#minio_password}" -lt 8 ]; then
      log_warn "Password minimal 8 karakter (syarat MinIO)."
      continue
    fi
    read -rsp "Ulangi password: " minio_password2; echo
    if [ "$minio_password" != "$minio_password2" ]; then
      log_warn "Password tidak sama, coba lagi."
      continue
    fi
    break
  done

  # EnvironmentFile dibaca systemd (root) sebelum proses drop privilege ke
  # minio-user, jadi chmod 600 root-only sudah cukup (pola sama seperti
  # telegram.conf).
  cat > /etc/default/minio <<EOF
MINIO_ROOT_USER=${minio_user}
MINIO_ROOT_PASSWORD=${minio_password}
MINIO_VOLUMES="/var/lib/minio/data"
MINIO_OPTS="--address :9000 --console-address :9001"
EOF
  chmod 600 /etc/default/minio

  cat > /etc/systemd/system/minio.service <<'MINIO_UNIT_EOF'
[Unit]
Description=MinIO
Documentation=https://docs.min.io
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=/usr/local/bin/minio

[Service]
WorkingDirectory=/usr/local/
User=minio-user
Group=minio-user
EnvironmentFile=-/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
LimitNOFILE=65536
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
MINIO_UNIT_EOF

  systemctl daemon-reload
  systemctl enable --now minio >/dev/null 2>&1

  mark_done "minio_install"
  INSTALLED_ITEMS+=("MinIO (AGPLv3) — API port 9000, Console port 9001, root user: ${minio_user} (password SIMPAN sendiri, tidak disimpan script ini). Port belum dibuka di firewall (default localhost-only, lihat security.md).")
  log_info "MinIO aktif (systemd service 'minio'). Console: http://<ip-server>:9001 — port belum dibuka firewall, lihat security.md."
  return 0
}

install_redis() {
  if is_done "redis_install"; then
    log_info "Redis sudah pernah di-setup sebelumnya, lewati."
    INSTALLED_ITEMS+=("Redis (sudah ada sebelumnya)")
    return 0
  fi
  log_step "Install Redis"
  apt_install_if_missing redis-server
  systemctl enable --now redis-server >/dev/null 2>&1

  local redis_conf="/etc/redis/redis.conf"
  [ -f "$redis_conf" ] || redis_conf="/etc/redis.conf"

  local redis_password
  prompt_password_confirmed redis_password "Password Redis (requirepass) baru"

  sed -i -E '/^\s*requirepass\s+/d' "$redis_conf"
  printf 'requirepass %s\n' "$redis_password" >> "$redis_conf"
  systemctl restart redis-server

  mark_done "redis_install"
  INSTALLED_ITEMS+=("Redis — requirepass sudah diset (SIMPAN sendiri, tidak disimpan script ini), bind 127.0.0.1 (default paket)")
  log_info "Redis aktif, requirepass sudah diset. SIMPAN baik-baik, script ini tidak menyimpannya."
  return 0
}

select_and_install_databases() {
  log_step "Pemilihan database & storage"
  local ans
  read -rp "Install MySQL/MariaDB? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] && SELECTED_DBS+=("mysql")
  read -rp "Install PostgreSQL? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] && SELECTED_DBS+=("postgresql")
  read -rp "Install MongoDB? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] && SELECTED_DBS+=("mongodb")
  read -rp "Install MinIO (S3-compatible object storage, AGPLv3)? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] && SELECTED_DBS+=("minio")
  read -rp "Install Redis? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] && SELECTED_DBS+=("redis")

  if [ ${#SELECTED_DBS[@]} -eq 0 ]; then
    log_info "Tidak ada database/storage dipilih, melewati langkah ini."
    return 0
  fi

  local db
  for db in "${SELECTED_DBS[@]}"; do
    case "$db" in
      mysql)      if ! install_mysql; then log_warn "Instalasi MySQL gagal, lanjut ke langkah berikutnya."; fi ;;
      postgresql) if ! install_postgresql; then log_warn "Instalasi PostgreSQL gagal, lanjut ke langkah berikutnya."; fi ;;
      mongodb)    if ! install_mongodb; then log_warn "Instalasi MongoDB gagal, lanjut ke langkah berikutnya."; fi ;;
      minio)      if ! install_minio; then log_warn "Instalasi MinIO gagal, lanjut ke langkah berikutnya."; fi ;;
      redis)      if ! install_redis; then log_warn "Instalasi Redis gagal, lanjut ke langkah berikutnya."; fi ;;
    esac
  done
}

install_docker() {
  if is_done "docker_install"; then
    log_info "Docker sudah pernah di-install sebelumnya, lewati."
    INSTALLED_ITEMS+=("Docker (sudah ada sebelumnya)")
    usermod -aG docker "$NEW_USER" 2>/dev/null || true
    return 0
  fi
  log_step "Install Docker + Docker Compose"

  apt_install_if_missing ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if ! curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc; then
    log_warn "Gagal mengambil GPG key Docker. Melewati instalasi Docker."
    return 1
  fi
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  if ! apt-get update -y; then
    log_warn "Repo Docker tidak tersedia untuk ${OS_ID} ${OS_CODENAME}. Melewati instalasi Docker."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update -y || true
    return 1
  fi

  if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    log_warn "Gagal install paket Docker. Melewati instalasi Docker."
    return 1
  fi

  systemctl enable --now docker >/dev/null 2>&1
  if [ -n "$NEW_USER" ]; then
    usermod -aG docker "$NEW_USER"
  fi

  mark_done "docker_install"
  local ver
  ver=$(docker --version 2>/dev/null | grep -oP '[0-9.]+' | head -1 || echo "?")
  if [ -n "$NEW_USER" ]; then
    INSTALLED_ITEMS+=("Docker $ver + Compose plugin (user $NEW_USER ditambahkan ke grup docker)")
  else
    INSTALLED_ITEMS+=("Docker $ver + Compose plugin (tidak ada user non-root untuk ditambahkan ke grup docker)")
  fi
  return 0
}

install_node_pm2() {
  if [ -z "$NEW_USER" ]; then
    log_warn "Tidak ada user non-root (pembuatan user di-skip) — Node.js/PM2 dilewati. nvm butuh user non-root untuk diinstall dengan benar; install manual nanti kalau perlu."
    return 1
  fi
  if is_done "node_pm2_install"; then
    log_info "Node.js/PM2 sudah pernah di-install sebelumnya, lewati."
    INSTALLED_ITEMS+=("Node.js/PM2 (sudah ada sebelumnya)")
    return 0
  fi
  log_step "Install nvm + Node.js LTS + PM2 (untuk user $NEW_USER)"

  if ! sudo -u "$NEW_USER" -H bash -lc "
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    nvm install --lts
    nvm alias default 'lts/*'
    npm install -g pm2
  "; then
    log_warn "Gagal install nvm/Node/PM2. Melewati langkah ini."
    return 1
  fi

  local startup_cmd
  startup_cmd=$(sudo -u "$NEW_USER" -H bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    . \"\$NVM_DIR/nvm.sh\"
    pm2 startup systemd -u ${NEW_USER} --hp /home/${NEW_USER}
  " 2>/dev/null | grep '^sudo ' || true)

  if [ -n "$startup_cmd" ]; then
    eval "$startup_cmd" || log_warn "Gagal menjalankan perintah pm2 startup, jalankan manual nanti sebagai user $NEW_USER: pm2 startup"
  else
    log_warn "Tidak bisa auto-setup pm2 startup, jalankan manual nanti sebagai user $NEW_USER: pm2 startup"
  fi

  sudo -u "$NEW_USER" -H bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    . \"\$NVM_DIR/nvm.sh\"
    pm2 save
  " || true

  mark_done "node_pm2_install"
  local node_ver
  node_ver=$(sudo -u "$NEW_USER" -H bash -lc "export NVM_DIR=\$HOME/.nvm; . \$NVM_DIR/nvm.sh; node -v" 2>/dev/null || echo "?")
  INSTALLED_ITEMS+=("Node.js $node_ver (via nvm, user $NEW_USER) + PM2 (pm2 startup + pm2 save dikonfigurasi)")
  return 0
}

install_misc_tools() {
  log_step "Install tools tambahan (htop, tmux, ncdu, net-tools, unattended-upgrades)"
  apt_install_if_missing htop tmux ncdu net-tools unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
  INSTALLED_ITEMS+=("htop, tmux, ncdu, net-tools")
  INSTALLED_ITEMS+=("unattended-upgrades (auto security updates)")
}

monit_alert_action() {
  local message="$1"
  if [ "$TELEGRAM_ENABLED" = "yes" ]; then
    echo "exec \"$SCRIPTS_DIR/notify-telegram.sh ${message}\""
  else
    echo "alert"
  fi
}

monit_process_block() {
  local label="$1" matching="$2" unit="$3"
  echo "check process $label matching \"$matching\""
  echo "  start program = \"/bin/systemctl start $unit\""
  echo "  stop program = \"/bin/systemctl stop $unit\""
  echo "  if does not exist for 2 cycles then restart"
  echo "  if 3 restarts within 5 cycles then $(monit_alert_action "Peringatan: $label terus down di server $(hostname), Monit sudah mencoba restart 3x")"
  echo
}

install_monit() {
  local ans
  read -rp "Install Monit (watchdog auto-restart service + alert)? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log_info "Monit dilewati."
    return 0
  fi

  log_step "Install Monit"
  apt_install_if_missing monit

  local conf="/etc/monit/conf.d/vps-init-helper.conf"
  {
    echo "set daemon 120"
    echo "set log /var/log/monit.log"
    echo "set httpd port 2812 and"
    echo "    use address localhost"
    echo "    allow localhost"
    echo
    echo "check system \$HOST"
    echo "  if loadavg (5min) > 4 then $(monit_alert_action "Peringatan: load average tinggi di server $(hostname)")"
    echo "  if memory usage > 90% then $(monit_alert_action "Peringatan: penggunaan RAM di atas 90% di server $(hostname)")"
    echo
    echo "check filesystem rootfs with path /"
    echo "  if space usage > 85% then $(monit_alert_action "Peringatan: disk di atas 85% penuh di server $(hostname)")"
    echo
    monit_process_block "nginx" "nginx: master process" "nginx"
    if [ -n "$MYSQL_UNIT" ]; then
      monit_process_block "mysql" "mysqld" "$MYSQL_UNIT"
    fi
    if is_done "postgresql_install"; then
      monit_process_block "postgresql" "postgres" "postgresql"
    fi
    if is_done "mongodb_install"; then
      monit_process_block "mongod" "mongod" "mongod"
    fi
    if is_done "docker_install"; then
      monit_process_block "docker" "dockerd" "docker"
    fi
    if is_done "minio_install"; then
      monit_process_block "minio" "minio server" "minio"
    fi
    if is_done "redis_install"; then
      monit_process_block "redis" "redis-server" "redis-server"
    fi
  } > "$conf"

  if ! grep -q "^include /etc/monit/conf.d" /etc/monit/monitrc 2>/dev/null; then
    echo "include /etc/monit/conf.d/*" >> /etc/monit/monitrc
  fi

  systemctl enable --now monit >/dev/null 2>&1
  monit reload >/dev/null 2>&1 || true

  MONIT_INSTALLED="yes"
  INSTALLED_ITEMS+=("Monit — watchdog auto-restart nginx/DB/docker + alert (web UI port 2812, localhost only)")
  return 0
}

install_logwatch() {
  local ans
  read -rp "Install logwatch (ringkasan log harian)? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log_info "logwatch dilewati."
    return 0
  fi

  log_step "Install logwatch"
  apt_install_if_missing logwatch
  mkdir -p "$OUTPUT_DIR/logs"

  cat > /etc/cron.daily/vps-init-helper-logwatch <<CRON_EOF
#!/usr/bin/env bash
OUTFILE="$OUTPUT_DIR/logs/logwatch-\$(date +%Y%m%d).txt"
/usr/sbin/logwatch --output stdout --format text --range yesterday > "\$OUTFILE" 2>/dev/null
CRON_EOF

  if [ "$TELEGRAM_ENABLED" = "yes" ]; then
    cat >> /etc/cron.daily/vps-init-helper-logwatch <<CRON_EOF
SUMMARY=\$(head -c 3500 "\$OUTFILE")
$SCRIPTS_DIR/notify-telegram.sh "Ringkasan log harian \$(hostname):
\$SUMMARY"
CRON_EOF
  fi

  chmod +x /etc/cron.daily/vps-init-helper-logwatch

  LOGWATCH_INSTALLED="yes"
  INSTALLED_ITEMS+=("logwatch — ringkasan log harian (disimpan di $OUTPUT_DIR/logs)")
  return 0
}

install_aide() {
  local ans
  read -rp "Install AIDE (file integrity monitoring)? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log_info "AIDE dilewati."
    return 0
  fi

  log_step "Install AIDE (membuat baseline bisa memakan waktu beberapa menit)"
  apt_install_if_missing aide aide-common

  if ! is_done "aide_baseline"; then
    if command_exists aideinit; then
      aideinit >/dev/null 2>&1 || true
    else
      aide --init >/dev/null 2>&1 || true
    fi
    if [ -f /var/lib/aide/aide.db.new ]; then
      cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    elif [ -f /var/lib/aide/aide.db.new.gz ]; then
      gunzip -c /var/lib/aide/aide.db.new.gz > /var/lib/aide/aide.db
    fi
    mark_done "aide_baseline"
  fi

  if [ -x /etc/cron.daily/aide ]; then
    chmod -x /etc/cron.daily/aide
  fi

  mkdir -p "$OUTPUT_DIR/logs"
  cat > /etc/cron.daily/vps-init-helper-aide <<CRON_EOF
#!/usr/bin/env bash
REPORT="$OUTPUT_DIR/logs/aide-\$(date +%Y%m%d).txt"
if ! aide --check > "\$REPORT" 2>&1; then
CRON_EOF

  if [ "$TELEGRAM_ENABLED" = "yes" ]; then
    cat >> /etc/cron.daily/vps-init-helper-aide <<CRON_EOF
  SUMMARY=\$(head -c 3500 "\$REPORT")
  $SCRIPTS_DIR/notify-telegram.sh "Peringatan AIDE: perubahan file sistem terdeteksi di \$(hostname):
\$SUMMARY"
CRON_EOF
  fi

  cat >> /etc/cron.daily/vps-init-helper-aide <<'CRON_EOF2'
fi
CRON_EOF2

  chmod +x /etc/cron.daily/vps-init-helper-aide

  AIDE_INSTALLED="yes"
  INSTALLED_ITEMS+=("AIDE — file integrity monitoring aktif (baseline sudah dibuat)")
  return 0
}

install_lynis() {
  log_step "Install & jalankan Lynis (audit keamanan)"
  apt_install_if_missing lynis

  lynis audit system --quiet --no-colors > "$OUTPUT_DIR/lynis-report.txt" 2>&1 || true

  LYNIS_SCORE=$(grep -oP '^hardening_index=\K[0-9]+' /var/log/lynis-report.dat 2>/dev/null | tail -n1)
  LYNIS_SCORE="${LYNIS_SCORE:-N/A}"

  INSTALLED_ITEMS+=("Lynis — audit keamanan dijalankan, hardening index: $LYNIS_SCORE/100 (lihat lynis-report.txt)")
  log_info "Lynis hardening index: $LYNIS_SCORE/100"
}

# ============================================================
# Output generation
# ============================================================

write_helper_scripts() {
  log_step "Menulis backup.sh & restore.sh ke $SCRIPTS_DIR"
  mkdir -p "$SCRIPTS_DIR"

  cat > "$SCRIPTS_DIR/backup.sh" <<'BACKUP_SCRIPT_EOF'
#!/usr/bin/env bash
# vps-init-helper — backup.sh
# Dumps every database installed by setup.sh (MySQL/MariaDB, PostgreSQL, MongoDB)
# plus nginx config, telegram.conf, and any docker-compose files, into one
# GPG-encrypted (AES-256) timestamped archive.
#
# Usage: sudo ./backup.sh [output-dir]
#   output-dir defaults to /root/vps-init-helper/backups

set -euo pipefail

BACKUP_DIR="${1:-/root/vps-init-helper/backups}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan sebagai root: sudo ./backup.sh" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
echo "==> Backup dimulai ($TIMESTAMP)"

if command -v mysqldump >/dev/null 2>&1 && { systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; }; then
  echo "  - Dumping MySQL/MariaDB..."
  read -rsp "    MySQL root password: " MYSQL_PW; echo
  MYSQL_DEFAULTS="$(mktemp)"
  chmod 600 "$MYSQL_DEFAULTS"
  printf '[client]\nuser=root\npassword=%s\n' "$MYSQL_PW" > "$MYSQL_DEFAULTS"
  mysqldump --defaults-extra-file="$MYSQL_DEFAULTS" --all-databases --routines --events --triggers \
    > "$WORKDIR/mysql-all-databases.sql"
  rm -f "$MYSQL_DEFAULTS"
  unset MYSQL_PW
fi

if command -v pg_dumpall >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
  echo "  - Dumping PostgreSQL..."
  sudo -u postgres pg_dumpall > "$WORKDIR/postgres-all-databases.sql"
fi

if command -v mongodump >/dev/null 2>&1 && systemctl is-active --quiet mongod 2>/dev/null; then
  echo "  - Dumping MongoDB..."
  read -rp "    MongoDB admin user (kosongkan jika tanpa auth): " MONGO_USER
  MONGO_ARGS=()
  if [ -n "$MONGO_USER" ]; then
    # --password tanpa nilai bikin mongodump prompt password secara interaktif
    # (masked), supaya password tidak pernah muncul di `ps`/`/proc/<pid>/cmdline`.
    MONGO_ARGS=(--username "$MONGO_USER" --password --authenticationDatabase admin)
  fi
  mongodump --out "$WORKDIR/mongodb-dump" "${MONGO_ARGS[@]}"
fi

if [ -d /etc/nginx ]; then
  echo "  - Archiving nginx config..."
  cp -r /etc/nginx "$WORKDIR/nginx-config"
fi

if [ -f /root/vps-init-helper/telegram.conf ]; then
  echo "  - Menyertakan konfigurasi notifikasi Telegram..."
  cp /root/vps-init-helper/telegram.conf "$WORKDIR/telegram.conf"
fi

echo "  - Mencari docker-compose files di /opt, /srv, /home..."
find /opt /srv /home -maxdepth 4 \( -iname "docker-compose*.yml" -o -iname "compose.yml" -o -iname "compose.yaml" \) 2>/dev/null \
  | while read -r f; do
      mkdir -p "$WORKDIR/docker-compose-files$(dirname "$f")"
      cp "$f" "$WORKDIR/docker-compose-files$(dirname "$f")/"
    done

dpkg -l > "$WORKDIR/installed-packages.txt"

TAR_TMP="$(mktemp)"
tar -czf "$TAR_TMP" -C "$WORKDIR" .

echo "==> Mengenkripsi backup (AES-256 via GPG)..."
while true; do
  read -rsp "    Buat passphrase enkripsi backup: " GPG_PASS; echo
  read -rsp "    Ulangi passphrase: " GPG_PASS2; echo
  if [ "$GPG_PASS" != "$GPG_PASS2" ]; then
    echo "    Passphrase tidak sama, coba lagi." >&2
    continue
  fi
  if [ -z "$GPG_PASS" ]; then
    echo "    Passphrase tidak boleh kosong." >&2
    continue
  fi
  break
done

ARCHIVE="$BACKUP_DIR/vps-backup-$TIMESTAMP.tar.gz.gpg"
# Passphrase dikirim lewat stdin (--passphrase-fd 0), bukan argumen
# --passphrase, supaya tidak muncul di `ps`/`/proc/<pid>/cmdline`.
gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "$ARCHIVE" "$TAR_TMP" <<< "$GPG_PASS"
unset GPG_PASS GPG_PASS2
rm -f "$TAR_TMP"

echo "==> Backup selesai: $ARCHIVE"
echo "    SIMPAN passphrase di atas — tanpa itu backup TIDAK BISA di-restore, dan script ini tidak menyimpannya."
echo "    Salin file ini ke server baru (scp) lalu jalankan restore.sh di sana setelah setup.sh selesai."
BACKUP_SCRIPT_EOF

  cat > "$SCRIPTS_DIR/restore.sh" <<'RESTORE_SCRIPT_EOF'
#!/usr/bin/env bash
# vps-init-helper — restore.sh
# Restores a GPG-encrypted backup archive produced by backup.sh onto a server
# that has already been provisioned by setup.sh (so the DB engines/nginx
# already exist).
#
# Usage: sudo ./restore.sh <backup-archive.tar.gz.gpg>

set -euo pipefail

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  echo "Usage: sudo ./restore.sh <backup-archive.tar.gz.gpg>" >&2
  exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  echo "Archive tidak ditemukan: $ARCHIVE" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan sebagai root: sudo ./restore.sh <archive>" >&2
  exit 1
fi

TAR_TMP="$(mktemp)"
read -rsp "Passphrase backup: " GPG_PASS; echo
# Passphrase dikirim lewat stdin (--passphrase-fd 0), bukan argumen
# --passphrase, supaya tidak muncul di `ps`/`/proc/<pid>/cmdline`.
if ! gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt -o "$TAR_TMP" "$ARCHIVE" 2>/dev/null <<< "$GPG_PASS"; then
  echo "Gagal decrypt — passphrase salah atau file bukan backup GPG yang valid." >&2
  rm -f "$TAR_TMP"
  exit 1
fi
unset GPG_PASS

WORKDIR="$(mktemp -d)"
echo "==> Mengekstrak backup..."
tar -xzf "$TAR_TMP" -C "$WORKDIR"
rm -f "$TAR_TMP"

if [ -f "$WORKDIR/mysql-all-databases.sql" ]; then
  if command -v mysql >/dev/null 2>&1; then
    echo "==> Restoring MySQL/MariaDB..."
    read -rsp "    MySQL root password (server ini): " MYSQL_PW; echo
    MYSQL_DEFAULTS="$(mktemp)"
    chmod 600 "$MYSQL_DEFAULTS"
    printf '[client]\nuser=root\npassword=%s\n' "$MYSQL_PW" > "$MYSQL_DEFAULTS"
    mysql --defaults-extra-file="$MYSQL_DEFAULTS" < "$WORKDIR/mysql-all-databases.sql"
    rm -f "$MYSQL_DEFAULTS"
    unset MYSQL_PW
  else
    echo "  ! Dump MySQL ditemukan tapi 'mysql' client tidak terinstall di server ini. Lewati." >&2
  fi
fi

if [ -f "$WORKDIR/postgres-all-databases.sql" ]; then
  if command -v psql >/dev/null 2>&1; then
    echo "==> Restoring PostgreSQL..."
    sudo -u postgres psql -f "$WORKDIR/postgres-all-databases.sql"
  else
    echo "  ! Dump PostgreSQL ditemukan tapi 'psql' tidak terinstall di server ini. Lewati." >&2
  fi
fi

if [ -d "$WORKDIR/mongodb-dump" ]; then
  if command -v mongorestore >/dev/null 2>&1; then
    echo "==> Restoring MongoDB..."
    read -rp "    MongoDB admin user (kosongkan jika tanpa auth): " MONGO_USER
    MONGO_ARGS=()
    if [ -n "$MONGO_USER" ]; then
      # --password tanpa nilai bikin mongorestore prompt password secara
      # interaktif (masked), supaya password tidak pernah muncul di
      # `ps`/`/proc/<pid>/cmdline`.
      MONGO_ARGS=(--username "$MONGO_USER" --password --authenticationDatabase admin)
    fi
    mongorestore "${MONGO_ARGS[@]}" "$WORKDIR/mongodb-dump"
  else
    echo "  ! Dump MongoDB ditemukan tapi 'mongorestore' tidak terinstall di server ini. Lewati." >&2
  fi
fi

if [ -d "$WORKDIR/nginx-config" ]; then
  echo "==> Restoring nginx config..."
  TS="$(date +%Y%m%d-%H%M%S)"
  if [ -d /etc/nginx ]; then
    cp -r /etc/nginx "/etc/nginx.bak-$TS"
    echo "    Config lama dicadangkan ke /etc/nginx.bak-$TS"
  fi
  cp -r "$WORKDIR/nginx-config/." /etc/nginx/
  if nginx -t; then
    systemctl reload nginx
    echo "    nginx config valid, reloaded."
  else
    echo "  ! nginx config tidak valid setelah restore — cek manual sebelum reload." >&2
  fi
fi

if [ -f "$WORKDIR/telegram.conf" ]; then
  echo "==> Memulihkan konfigurasi notifikasi Telegram..."
  mkdir -p /root/vps-init-helper
  cp "$WORKDIR/telegram.conf" /root/vps-init-helper/telegram.conf
  chmod 600 /root/vps-init-helper/telegram.conf
fi

echo
echo "==> Restore selesai."
if [ -d "$WORKDIR/docker-compose-files" ]; then
  echo "    docker-compose files ditemukan di backup — review manual dan pindahkan ke lokasi yang sesuai:"
  echo "    $WORKDIR/docker-compose-files"
  echo "    (folder ini TIDAK dihapus otomatis supaya kamu sempat meninjau isinya)"
else
  rm -rf "$WORKDIR"
fi

echo
echo "Catatan: baseline AIDE dan laporan Lynis TIDAK ikut ter-restore (memang harus"
echo "dibuat ulang di server baru karena filesystem state-nya berbeda). Jalankan ulang"
echo "modul AIDE/Lynis di setup.sh kalau kamu pakai keduanya."
RESTORE_SCRIPT_EOF

  chmod +x "$SCRIPTS_DIR/backup.sh" "$SCRIPTS_DIR/restore.sh"
}

generate_report() {
  log_step "Membuat install-report.md"
  mkdir -p "$OUTPUT_DIR"
  {
    echo "# Install Report — vps-init-helper"
    echo
    echo "Tanggal: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Host: $(hostname)"
    echo "OS: $OS_ID $OS_VERSION_ID ($OS_CODENAME)"
    echo
    echo "## Yang ter-install"
    echo
    local item
    for item in "${INSTALLED_ITEMS[@]}"; do
      echo "- $item"
    done
    echo
    echo "## Akun & akses"
    echo
    if [ -n "$NEW_USER" ]; then
      echo "- User sudo baru: \`$NEW_USER\`"
    else
      echo "- User sudo baru: (tidak dibuat — di-skip saat setup, pastikan sudah ada akses non-root+sudo lain)"
    fi
    echo "- SSH port saat ini: \`$SSH_PORT\` (belum diubah, password login SSH masih aktif — lihat security.md)"
    echo
    echo "## Audit keamanan & monitoring"
    echo
    echo "- Lynis hardening index: **$LYNIS_SCORE/100** (detail: \`$OUTPUT_DIR/lynis-report.txt\`)"
    echo "- Notifikasi Telegram: $( [ "$TELEGRAM_ENABLED" = "yes" ] && echo "aktif" || echo "tidak aktif" )"
    echo "- Monit (watchdog): $( [ "$MONIT_INSTALLED" = "yes" ] && echo "aktif" || echo "tidak diinstall" )"
    echo "- logwatch (ringkasan harian): $( [ "$LOGWATCH_INSTALLED" = "yes" ] && echo "aktif" || echo "tidak diinstall" )"
    echo "- AIDE (file integrity): $( [ "$AIDE_INSTALLED" = "yes" ] && echo "aktif" || echo "tidak diinstall" )"
    echo "- UFW dibatasi ke IP Cloudflare saja (port 80/443): $( [ "$CF_IP_LOCK" = "yes" ] && echo "ya" || echo "tidak" )"
    echo
    echo "## Lokasi penting"
    echo
    echo "- Semua output helper ini: \`$OUTPUT_DIR\`"
    echo "- Script backup: \`$SCRIPTS_DIR/backup.sh\`"
    echo "- Script restore: \`$SCRIPTS_DIR/restore.sh\`"
    echo "- Panduan hardening keamanan: \`$SECURITY_FILE\`"
    echo "- Panduan migrasi server: \`$MIGRATION_FILE\`"
    echo "- Laporan client (untuk dikirim ke client): \`$OUTPUT_DIR/client-report.md\` / \`.html\`"
    echo
    echo "## Langkah selanjutnya"
    echo
    echo "1. Baca dan ikuti **$SECURITY_FILE** untuk hardening keamanan (SSH key-only, disable root login, dll)."
    echo "2. Simpan semua password database yang barusan kamu buat — script ini TIDAK menyimpannya di mana pun."
    echo "3. Kalau nanti pindah server, baca **$MIGRATION_FILE**."
  } > "$REPORT_FILE"
  log_info "Report tersimpan di $REPORT_FILE"
}

generate_security_md() {
  log_step "Membuat security.md"
  cat > "$SECURITY_FILE" <<EOF
# Panduan Hardening Keamanan — vps-init-helper

Langkah-langkah di bawah ini **sengaja tidak dijalankan otomatis oleh setup.sh**
karena berisiko mengunci akses kamu sendiri ke server kalau ada kesalahan
(salah paste SSH key, port firewall belum sesuai, dll). Ikuti urutan ini,
dan JANGAN skip langkah verifikasi.

$( if [ -n "$NEW_USER" ]; then echo "User sudo yang dibuat setup.sh: \`$NEW_USER\`"; else echo "**User sudo baru TIDAK dibuat** (pembuatan user di-skip saat setup)."; fi )
SSH port saat ini: \`$SSH_PORT\`

## 0. WAJIB: Verifikasi dulu sebelum lanjut

$( if [ -n "$NEW_USER" ]; then cat <<VERIFY_WITH_USER
Buka **terminal/sesi baru** (jangan tutup sesi root yang sedang jalan ini) dan
pastikan kamu bisa login sebagai user baru pakai SSH key:

\`\`\`
ssh -p $SSH_PORT $NEW_USER@<ip-server>
\`\`\`

Kalau berhasil login TANPA diminta password, lanjut ke langkah 1.
Kalau gagal, JANGAN lanjutkan — perbaiki dulu \`/home/$NEW_USER/.ssh/authorized_keys\`
lewat sesi root yang masih terbuka.
VERIFY_WITH_USER
else cat <<VERIFY_NO_USER
Kamu memilih SKIP pembuatan user baru saat setup, jadi setup.sh TIDAK
membuatkan akses non-root untukmu. Sebelum lanjut ke langkah 1 (disable
password/root login SSH), pastikan dulu salah satu dari ini SUDAH ADA dan
SUDAH DITES BERHASIL dari sesi terpisah:

- User non-root lain di server ini dengan SSH key + akses sudo, ATAU
- Mekanisme akses lain di luar SSH (misal console/VNC dari provider VPS)

**Kalau tidak ada satupun dari itu, JANGAN lanjutkan ke langkah 1** — kamu
akan terkunci total dari server ini begitu password/root login SSH dimatikan.
VERIFY_NO_USER
fi )

## 1. Disable login SSH via password (wajib SSH key)

Edit \`/etc/ssh/sshd_config\`:

\`\`\`
PasswordAuthentication no
PermitRootLogin no
\`\`\`

Lalu:

\`\`\`
sudo systemctl restart ssh
\`\`\`

Setelah ini root TIDAK BISA login via SSH sama sekali (baik password maupun
key) — $( [ -n "$NEW_USER" ] && echo "semua akses lewat user \`$NEW_USER\` + \`sudo\`." || echo "pastikan akses non-root+sudo alternatifmu (lihat langkah 0) sudah teruji." )

## 2. (Opsional tapi direkomendasikan) Ganti port SSH default

Mengurangi noise dari bot yang scan port 22. Edit \`/etc/ssh/sshd_config\`:

\`\`\`
Port <port-baru>
\`\`\`

Lalu buka port baru di firewall SEBELUM restart SSH (supaya tidak ter-lockout):

\`\`\`
sudo ufw allow <port-baru>/tcp comment 'SSH baru'
sudo systemctl restart ssh
\`\`\`

Verifikasi login pakai port baru dari sesi terpisah dulu, baru:

\`\`\`
sudo ufw delete allow $SSH_PORT/tcp
\`\`\`

## 3. Batasi akses database ke localhost saja

Database yang di-install setup.sh secara default sudah listen di
\`127.0.0.1\` saja (tidak bisa diakses dari luar). Kalau kamu memang butuh
akses remote ke database, baru:

- **MySQL/MariaDB**: edit \`bind-address\` di
  \`/etc/mysql/mariadb.conf.d/50-server.cnf\` (atau \`/etc/mysql/mysql.conf.d/mysqld.cnf\`),
  lalu buka port dengan \`sudo ufw allow from <ip-trusted> to any port 3306\`
  (JANGAN buka ke semua IP).
- **PostgreSQL**: edit \`listen_addresses\` di \`postgresql.conf\` dan tambahkan
  rule di \`pg_hba.conf\`, lalu buka port serupa dengan ufw dibatasi IP tertentu.
- **MongoDB**: edit \`bindIp\` di \`/etc/mongod.conf\`, buka port serupa dengan
  ufw dibatasi IP tertentu.
- **Redis**: sudah bind ke \`127.0.0.1\` secara default (paket redis-server), tidak
  perlu diubah kecuali memang butuh akses remote — kalau begitu, edit \`bind\`
  di \`/etc/redis/redis.conf\`, lalu buka port serupa dengan ufw dibatasi IP
  tertentu.
- **MinIO**: MinIO sendiri listen di semua interface (\`0.0.0.0:9000\`/\`9001\`),
  tapi port API (9000) dan Console (9001) **belum dibuka di UFW** secara
  default — sama seperti database. Kalau butuh akses S3 API atau Console dari
  luar, buka dengan \`sudo ufw allow from <ip-trusted> to any port 9000,9001\`
  (JANGAN buka ke semua IP kalau bisa dihindari; kalau memang harus publik,
  taruh nginx reverse proxy + TLS di depannya, jangan expose 9000/9001 polos).

Kalau semua aplikasi kamu jalan di server yang sama (akses via localhost),
biarkan default ini — jangan buka port DB/MinIO ke publik sama sekali.

## 4. Review UFW & fail2ban

\`\`\`
sudo ufw status verbose
sudo fail2ban-client status sshd
\`\`\`

Pastikan hanya port yang benar-benar perlu yang \`ALLOW\`.

## 5. Cek unattended-upgrades aktif

\`\`\`
sudo systemctl status unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades
\`\`\`

## 6. Kalau server ini menghadap publik dengan domain

- Pasang SSL lewat Let's Encrypt: \`sudo apt install certbot python3-certbot-nginx\`
  lalu \`sudo certbot --nginx -d domain-kamu.com\`.
- Pastikan config nginx untuk tiap site tidak expose \`server_tokens\` versi nginx
  (\`server_tokens off;\` di \`/etc/nginx/nginx.conf\`).

## 7. Kalau domain di belakang Cloudflare (rekomendasi kalau kamu selalu pakai Cloudflare)

- Set mode SSL/TLS di dashboard Cloudflare ke **Full (Strict)** — bukan
  "Flexible" (Flexible membuat koneksi Cloudflare↔origin server TIDAK
  terenkripsi, meskipun visitor↔Cloudflare terlihat aman).
- Untuk Full (Strict), origin server butuh sertifikat valid. Dua opsi:
  - **Cloudflare Origin CA certificate** (gratis, valid 15 tahun): dashboard
    Cloudflare > SSL/TLS > Origin Server > Create Certificate, lalu pasang
    hasilnya ke nginx (\`ssl_certificate\` / \`ssl_certificate_key\`).
  - Atau tetap pakai Let's Encrypt certbot seperti poin 6 — keduanya valid
    untuk mode Full (Strict).
$( [ "$CF_IP_LOCK" = "yes" ] && cat <<'CFNOTE'
- UFW di server ini SUDAH dibatasi hanya menerima port 80/443 dari IP resmi
  Cloudflare (diaktifkan saat setup). Origin server tidak bisa diakses
  langsung lewat IP asli untuk trafik web.
CFNOTE
)
$( [ "$CF_IP_LOCK" != "yes" ] && cat <<'CFNOTE2'
- Port 80/443 di server ini MASIH terbuka untuk semua IP (bukan hanya
  Cloudflare). Kalau mau membatasi supaya origin server tidak bisa diserang
  langsung (bypass Cloudflare), jalankan ulang setup.sh dan pilih "Ya" saat
  ditanya soal pembatasan IP Cloudflare, atau terapkan manual dengan
  mengambil https://www.cloudflare.com/ips-v4 dan ips-v6 lalu buat ufw rule
  \`ufw allow from <cidr> to any port 80,443 proto tcp\` untuk tiap range.
CFNOTE2
)

## 8. Monitoring & notifikasi yang sudah aktif di server ini

$( [ "$TELEGRAM_ENABLED" = "yes" ] && echo "- Notifikasi Telegram AKTIF — fail2ban, Monit, logwatch, AIDE akan kirim alert ke chat yang kamu daftarkan." || echo "- Notifikasi Telegram TIDAK aktif — modul monitoring di bawah ini (kalau ada) hanya mencatat ke log lokal, tidak mengirim alert eksternal." )
$( [ "$MONIT_INSTALLED" = "yes" ] && echo "- Monit aktif — cek status: \`sudo monit status\` (butuh login lokal, web UI hanya di localhost:2812)." )
$( [ "$LOGWATCH_INSTALLED" = "yes" ] && echo "- logwatch aktif — laporan harian tersimpan di \`$OUTPUT_DIR/logs/\`." )
$( [ "$AIDE_INSTALLED" = "yes" ] && echo "- AIDE aktif — baseline file integrity sudah dibuat. Kalau kamu SENGAJA mengubah file sistem (upgrade, config baru), jalankan \`sudo aideinit\` ulang supaya baseline tidak terus memicu alert palsu." )

## 9. Audit keamanan berkala dengan Lynis

Lynis sudah dijalankan sekali saat setup (hardening index: lihat
\`install-report.md\`). Jalankan ulang kapan saja untuk memantau progres:

\`\`\`
sudo lynis audit system
\`\`\`

Bandingkan skor dari waktu ke waktu — target realistis adalah peningkatan
bertahap, bukan skor sempurna dalam sekali jalan.

---

Setelah semua langkah di atas selesai, VPS ini sudah dalam kondisi hardened.
Simpan file ini sebagai referensi — file yang sama juga akan ditulis ulang
kalau kamu jalankan setup.sh lagi di VPS baru saat migrasi.
EOF
  log_info "Panduan keamanan tersimpan di $SECURITY_FILE"
}

generate_migration_md() {
  log_step "Membuat migration.md"
  cat > "$MIGRATION_FILE" <<'EOF'
# Panduan Migrasi Server — vps-init-helper

Cara pindah dari VPS lama ke VPS baru tanpa kehilangan data.

## Ringkasan alur

```
[VPS LAMA]                          [VPS BARU]
scripts/backup.sh   --archive.tar.gz-->  scp   --> setup.sh  --> scripts/restore.sh archive.tar.gz
```

## Langkah detail

### 1. Di VPS lama — buat backup

```
sudo /root/vps-init-helper/scripts/backup.sh
```

Ini akan mendump semua database yang terinstall (MySQL/MariaDB, PostgreSQL,
MongoDB — sesuai yang benar-benar aktif), meng-archive config nginx dan
konfigurasi notifikasi Telegram (`telegram.conf`, kalau ada), mengumpulkan
file docker-compose yang ditemukan, lalu mengenkripsi semuanya (AES-256 via
GPG) menjadi satu file:

```
/root/vps-init-helper/backups/vps-backup-<timestamp>.tar.gz.gpg
```

Kamu akan diminta membuat **passphrase enkripsi** saat backup dibuat —
**catat passphrase ini di password manager**, karena tanpa itu backup tidak
bisa di-restore sama sekali, dan script tidak menyimpannya di mana pun.

**Catatan MinIO:** data objek MinIO (`/var/lib/minio/data`) TIDAK ikut di
dalam archive backup.sh (bisa sangat besar, tidak cocok untuk dump SQL biasa).
Migrasikan data MinIO terpisah, misalnya dengan `mc mirror` (MinIO Client)
dari server lama ke server baru setelah MinIO di server baru aktif.

### 2. Pindahkan archive ke VPS baru

```
scp /root/vps-init-helper/backups/vps-backup-<timestamp>.tar.gz.gpg root@<ip-vps-baru>:/root/
```

### 3. Di VPS baru — jalankan setup.sh

Jalankan `setup.sh` yang sama seperti pertama kali dulu. Script ini aman
dijalankan di VPS kosong (idempotent) dan akan menginstall stack yang sama:

```
sudo bash setup.sh
```

Saat diminta memilih database, pilih database YANG SAMA dengan yang dipakai
di VPS lama (cek `install-report.md` di VPS lama kalau lupa).

### 4. Di VPS baru — restore data

```
sudo /root/vps-init-helper/scripts/restore.sh /root/vps-backup-<timestamp>.tar.gz.gpg
```

Kamu akan diminta passphrase yang dibuat saat backup. Ini akan restore semua
database dump, config nginx, dan `telegram.conf` (kalau ada, supaya
notifikasi tetap jalan dengan bot/chat yang sama). Kalau ada file
docker-compose di dalam backup, script TIDAK menaruhnya otomatis (untuk
menghindari overwrite yang tidak diinginkan) — cek pesan di akhir restore.sh
untuk lokasi filenya, lalu pindahkan manual ke tempat yang sesuai dan jalankan
`docker compose up -d`.

**Catatan penting:** baseline AIDE dan laporan Lynis TIDAK ikut ter-backup/restore
— keduanya harus dibuat ulang di server baru (state filesystem berbeda). Kalau
kamu pakai AIDE/Lynis, jalankan modulnya lagi lewat `setup.sh` di server baru
(sudah otomatis kalau kamu jalankan ulang setup.sh dan pilih "Ya" pada modul
yang bersangkutan).

### 5. Verifikasi

- `systemctl status nginx mysql postgresql mongod docker` (sesuai yang di-install)
- Test akses aplikasi kamu lewat browser/curl
- Cek `pm2 list` sebagai user sudo (bukan root) untuk lihat apakah proses Node
  perlu di-deploy ulang (backup.sh tidak menyalin source code aplikasi, hanya
  database & config — deploy ulang source code seperti biasa, misalnya lewat
  git pull + pm2 restart)

### 6. Ulangi hardening

Ikuti `/root/vps-init-helper/security.md` di VPS baru dari awal — hardening
tidak ikut ter-backup/restore (SSH key & firewall rules bersifat per-server).

### 7. Setelah yakin semua jalan normal

Baru matikan/hapus VPS lama. Jangan buru-buru — biarkan VPS lama tetap hidup
beberapa hari sebagai fallback sampai kamu yakin VPS baru stabil.
EOF
  log_info "Panduan migrasi tersimpan di $MIGRATION_FILE"
}

generate_client_report() {
  log_step "Membuat client-report.md dan client-report.html"

  local db_list=""
  local db
  for db in "${SELECTED_DBS[@]}"; do
    case "$db" in
      mysql) db_list="${db_list}- MySQL/MariaDB
" ;;
      postgresql) db_list="${db_list}- PostgreSQL
" ;;
      mongodb) db_list="${db_list}- MongoDB
" ;;
      minio) db_list="${db_list}- MinIO (Object Storage, S3-compatible, AGPLv3)
" ;;
      redis) db_list="${db_list}- Redis
" ;;
    esac
  done
  [ -z "$db_list" ] && db_list="Tidak ada database yang diinstall pada server ini."

  local title="Laporan Setup & Keamanan Server"
  [ -n "$CLIENT_NAME" ] && title="Laporan Setup & Keamanan Server — $CLIENT_NAME"

  {
    echo "# $title"
    echo
    echo "**Tanggal:** $(date '+%d %B %Y')  "
    echo "**Server:** \`$(hostname)\`  "
    [ -n "$CLIENT_NAME" ] && echo "**Client/Project:** $CLIENT_NAME  "
    echo
    echo "## Ringkasan"
    echo
    echo "Server ini telah disiapkan dan diamankan mengikuti praktik hardening"
    echo "standar industri untuk lingkungan production, mencakup pengerasan akses,"
    echo "firewall, deteksi intrusi, monitoring otomatis, dan backup terenkripsi."
    echo
    echo "## Skor Audit Keamanan"
    echo
    echo "**Hardening Index (Lynis): $LYNIS_SCORE / 100**"
    echo
    echo "Lynis adalah tool audit keamanan open-source yang mengukur konfigurasi"
    echo "server terhadap praktik terbaik industri (mengacu pada prinsip CIS"
    echo "Benchmark). Skor ini adalah baseline hari ini — direkomendasikan untuk"
    echo "diperiksa ulang secara berkala."
    echo
    echo "## Yang Sudah Diterapkan"
    echo
    echo "### Akses & Autentikasi"
    echo "- Login SSH menggunakan kunci kriptografi (SSH key), bukan password"
    echo "- Akses langsung sebagai root dinonaktifkan setelah verifikasi akun administratif baru"
    echo "- Firewall (UFW) aktif dengan kebijakan default menolak semua koneksi masuk kecuali yang diizinkan eksplisit"
    if [ "$CF_IP_LOCK" = "yes" ]; then
      echo "- Akses web (port 80/443) dibatasi hanya melalui jaringan Cloudflare, origin server tidak bisa diakses langsung"
    fi
    echo
    echo "### Deteksi & Pencegahan Intrusi"
    echo "- fail2ban aktif, otomatis memblokir alamat IP yang melakukan percobaan login berulang kali gagal"
    if [ "$AIDE_INSTALLED" = "yes" ]; then
      echo "- AIDE (File Integrity Monitoring) aktif, mendeteksi perubahan file sistem yang tidak sah"
    fi
    echo
    echo "### Monitoring & Notifikasi"
    if [ "$MONIT_INSTALLED" = "yes" ]; then
      echo "- Monit aktif, otomatis merestart service kritikal (web server, database, dll) jika berhenti bekerja"
    fi
    if [ "$TELEGRAM_ENABLED" = "yes" ]; then
      echo "- Notifikasi real-time ke Telegram untuk kejadian keamanan (percobaan intrusi, service down, dll)"
    fi
    if [ "$LOGWATCH_INSTALLED" = "yes" ]; then
      echo "- Ringkasan aktivitas log dikirim setiap hari"
    fi
    if [ "$MONIT_INSTALLED" != "yes" ] && [ "$TELEGRAM_ENABLED" != "yes" ] && [ "$LOGWATCH_INSTALLED" != "yes" ]; then
      echo "- (Tidak ada modul monitoring tambahan yang diaktifkan pada server ini)"
    fi
    echo
    echo "### Backup & Disaster Recovery"
    echo "- Prosedur backup database terenkripsi (AES-256) siap dipakai kapan saja"
    echo "- Prosedur migrasi terdokumentasi untuk pemulihan cepat ke server baru bila diperlukan"
    echo
    echo "## Database Terinstall"
    echo
    echo "$db_list"
    echo "## Rekomendasi Selanjutnya"
    echo
    echo "- Pasang sertifikat SSL/TLS untuk domain yang digunakan (Let's Encrypt atau Cloudflare Origin Certificate, disarankan mode Cloudflare \"Full (Strict)\")"
    echo "- Jadwalkan review skor Lynis secara berkala untuk memastikan tingkat keamanan terus meningkat"
    echo "- Pastikan kredensial database disimpan di password manager tim, bukan dokumen biasa"
    echo "- Jadwalkan backup rutin (mingguan/harian sesuai kebutuhan) menggunakan \`backup.sh\`"
    echo
    echo "---"
    echo "*Laporan ini dibuat otomatis oleh vps-init-helper pada $(date '+%d %B %Y, %H:%M %Z').*"
  } > "$OUTPUT_DIR/client-report.md"

  generate_client_report_html "$title"

  log_info "Laporan client tersimpan di $OUTPUT_DIR/client-report.md dan client-report.html"
}

generate_client_report_html() {
  local title="$1"
  local title_html="${title//&/&amp;}"
  title_html="${title_html//</&lt;}"
  title_html="${title_html//>/&gt;}"
  title_html="${title_html//\"/&quot;}"
  title_html="${title_html//\'/&#39;}"
  local db_items=""
  local db
  for db in "${SELECTED_DBS[@]}"; do
    case "$db" in
      mysql) db_items="${db_items}<li>MySQL/MariaDB</li>" ;;
      postgresql) db_items="${db_items}<li>PostgreSQL</li>" ;;
      mongodb) db_items="${db_items}<li>MongoDB</li>" ;;
      minio) db_items="${db_items}<li>MinIO (Object Storage, S3-compatible, AGPLv3)</li>" ;;
      redis) db_items="${db_items}<li>Redis</li>" ;;
    esac
  done
  [ -z "$db_items" ] && db_items="<li>Tidak ada database yang diinstall pada server ini</li>"

  local score_color="#16a34a"
  if [ "$LYNIS_SCORE" != "N/A" ]; then
    if [ "$LYNIS_SCORE" -lt 50 ] 2>/dev/null; then
      score_color="#dc2626"
    elif [ "$LYNIS_SCORE" -lt 75 ] 2>/dev/null; then
      score_color="#d97706"
    fi
  fi

  cat > "$OUTPUT_DIR/client-report.html" <<HTML_EOF
<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<title>${title_html}</title>
<style>
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; color: #1f2937; line-height: 1.6; }
  h1 { font-size: 1.6rem; border-bottom: 3px solid #2563eb; padding-bottom: 10px; }
  h2 { font-size: 1.2rem; color: #2563eb; margin-top: 2rem; }
  h3 { font-size: 1rem; margin-top: 1.5rem; }
  .meta { color: #6b7280; font-size: 0.9rem; margin-bottom: 2rem; }
  .score-badge { display: inline-block; font-size: 2rem; font-weight: bold; color: ${score_color}; }
  .score-box { background: #f3f4f6; border-radius: 8px; padding: 20px; margin: 1rem 0; }
  ul { padding-left: 1.4rem; }
  li { margin-bottom: 0.4rem; }
  footer { margin-top: 3rem; font-size: 0.8rem; color: #9ca3af; border-top: 1px solid #e5e7eb; padding-top: 1rem; }
  @media print { body { margin: 0; } }
</style>
</head>
<body>
<h1>${title_html}</h1>
<div class="meta">
  Tanggal: $(date '+%d %B %Y')<br>
  Server: <code>$(hostname)</code>
</div>

<h2>Ringkasan</h2>
<p>Server ini telah disiapkan dan diamankan mengikuti praktik hardening standar industri
untuk lingkungan production, mencakup pengerasan akses, firewall, deteksi intrusi,
monitoring otomatis, dan backup terenkripsi.</p>

<h2>Skor Audit Keamanan</h2>
<div class="score-box">
  <span class="score-badge">${LYNIS_SCORE}/100</span><br>
  <span>Hardening Index (Lynis)</span>
</div>
<p>Lynis adalah tool audit keamanan open-source yang mengukur konfigurasi server
terhadap praktik terbaik industri (mengacu pada prinsip CIS Benchmark). Skor ini
adalah baseline hari ini — direkomendasikan untuk diperiksa ulang secara berkala.</p>

<h2>Yang Sudah Diterapkan</h2>

<h3>Akses &amp; Autentikasi</h3>
<ul>
  <li>Login SSH menggunakan kunci kriptografi (SSH key), bukan password</li>
  <li>Akses langsung sebagai root dinonaktifkan setelah verifikasi akun administratif baru</li>
  <li>Firewall (UFW) aktif dengan kebijakan default menolak semua koneksi masuk kecuali yang diizinkan eksplisit</li>
  $( [ "$CF_IP_LOCK" = "yes" ] && echo "<li>Akses web (port 80/443) dibatasi hanya melalui jaringan Cloudflare, origin server tidak bisa diakses langsung</li>" )
</ul>

<h3>Deteksi &amp; Pencegahan Intrusi</h3>
<ul>
  <li>fail2ban aktif, otomatis memblokir alamat IP yang melakukan percobaan login berulang kali gagal</li>
  $( [ "$AIDE_INSTALLED" = "yes" ] && echo "<li>AIDE (File Integrity Monitoring) aktif, mendeteksi perubahan file sistem yang tidak sah</li>" )
</ul>

<h3>Monitoring &amp; Notifikasi</h3>
<ul>
  $( [ "$MONIT_INSTALLED" = "yes" ] && echo "<li>Monit aktif, otomatis merestart service kritikal jika berhenti bekerja</li>" )
  $( [ "$TELEGRAM_ENABLED" = "yes" ] && echo "<li>Notifikasi real-time ke Telegram untuk kejadian keamanan</li>" )
  $( [ "$LOGWATCH_INSTALLED" = "yes" ] && echo "<li>Ringkasan aktivitas log dikirim setiap hari</li>" )
  $( [ "$MONIT_INSTALLED" != "yes" ] && [ "$TELEGRAM_ENABLED" != "yes" ] && [ "$LOGWATCH_INSTALLED" != "yes" ] && echo "<li>(Tidak ada modul monitoring tambahan yang diaktifkan pada server ini)</li>" )
</ul>

<h3>Backup &amp; Disaster Recovery</h3>
<ul>
  <li>Prosedur backup database terenkripsi (AES-256) siap dipakai kapan saja</li>
  <li>Prosedur migrasi terdokumentasi untuk pemulihan cepat ke server baru bila diperlukan</li>
</ul>

<h2>Database Terinstall</h2>
<ul>
${db_items}
</ul>

<h2>Rekomendasi Selanjutnya</h2>
<ul>
  <li>Pasang sertifikat SSL/TLS untuk domain yang digunakan (Let's Encrypt atau Cloudflare Origin Certificate, disarankan mode Cloudflare "Full (Strict)")</li>
  <li>Jadwalkan review skor Lynis secara berkala untuk memastikan tingkat keamanan terus meningkat</li>
  <li>Pastikan kredensial database disimpan di password manager tim, bukan dokumen biasa</li>
  <li>Jadwalkan backup rutin menggunakan backup.sh</li>
</ul>

<footer>
  Laporan ini dibuat otomatis oleh vps-init-helper pada $(date '+%d %B %Y, %H:%M %Z').
</footer>
</body>
</html>
HTML_EOF
}

print_summary() {
  echo -e "\n${COLOR_STEP}============================================================${COLOR_RESET}"
  echo -e "${COLOR_INFO} Setup selesai!${COLOR_RESET}"
  echo -e "${COLOR_STEP}============================================================${COLOR_RESET}"
  echo "Lynis hardening index: $LYNIS_SCORE/100"
  echo
  echo "Baca laporan lengkap: $REPORT_FILE"
  echo "WAJIB baca sebelum lanjut pakai server ini: $SECURITY_FILE"
  echo "Kalau nanti migrasi server: $MIGRATION_FILE"
  echo "Laporan untuk client: $OUTPUT_DIR/client-report.md (atau .html untuk versi rapi)"
  echo
  if [ -n "$NEW_USER" ]; then
    echo "User sudo baru: $NEW_USER"
    echo "Test login SEKARANG dari sesi terminal terpisah sebelum menutup sesi ini:"
    echo "  ssh -p $SSH_PORT $NEW_USER@<ip-server-ini>"
  else
    echo "User sudo baru: (tidak dibuat, di-skip saat setup)"
    echo "PENTING: pastikan kamu sudah punya akses non-root+sudo lain yang teruji sebelum mengikuti security.md (disable password/root login SSH)."
  fi
}

# ============================================================
# Main
# ============================================================

main() {
  require_root
  detect_os
  dispatch_to_rocky_if_needed "$@"
  print_banner

  mkdir -p "$OUTPUT_DIR" "$STATE_DIR" "$SCRIPTS_DIR"

  ask_client_info
  configure_hostname_timezone
  system_update
  setup_swap
  create_new_user
  setup_telegram_alerts
  setup_firewall
  setup_fail2ban
  install_nginx
  select_and_install_databases

  if ! install_docker; then
    log_warn "Docker tidak ter-install. Kamu bisa coba install manual nanti."
  fi
  if ! install_node_pm2; then
    log_warn "Node.js/PM2 tidak ter-install. Kamu bisa coba install manual nanti."
  fi

  install_misc_tools
  install_monit
  install_logwatch
  install_aide
  install_lynis

  write_helper_scripts
  generate_report
  generate_security_md
  generate_migration_md
  generate_client_report
  print_summary
}

main "$@"
