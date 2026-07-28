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

# --- MySQL / MariaDB ---
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

# --- PostgreSQL ---
if command -v pg_dumpall >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
  echo "  - Dumping PostgreSQL..."
  sudo -u postgres pg_dumpall > "$WORKDIR/postgres-all-databases.sql"
fi

# --- MongoDB ---
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

# --- nginx config ---
if [ -d /etc/nginx ]; then
  echo "  - Archiving nginx config..."
  cp -r /etc/nginx "$WORKDIR/nginx-config"
fi

# --- telegram.conf (alert config, keep continuity across migration) ---
if [ -f /root/vps-init-helper/telegram.conf ]; then
  echo "  - Menyertakan konfigurasi notifikasi Telegram..."
  cp /root/vps-init-helper/telegram.conf "$WORKDIR/telegram.conf"
fi

# --- docker-compose files (best-effort scan) ---
echo "  - Mencari docker-compose files di /opt, /srv, /home..."
find /opt /srv /home -maxdepth 4 \( -iname "docker-compose*.yml" -o -iname "compose.yml" -o -iname "compose.yaml" \) 2>/dev/null \
  | while read -r f; do
      mkdir -p "$WORKDIR/docker-compose-files$(dirname "$f")"
      cp "$f" "$WORKDIR/docker-compose-files$(dirname "$f")/"
    done

# --- installed package list (useful reference during migration) ---
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
