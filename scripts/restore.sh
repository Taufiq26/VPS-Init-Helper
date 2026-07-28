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

# --- MySQL / MariaDB ---
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

# --- PostgreSQL ---
if [ -f "$WORKDIR/postgres-all-databases.sql" ]; then
  if command -v psql >/dev/null 2>&1; then
    echo "==> Restoring PostgreSQL..."
    sudo -u postgres psql -f "$WORKDIR/postgres-all-databases.sql"
  else
    echo "  ! Dump PostgreSQL ditemukan tapi 'psql' tidak terinstall di server ini. Lewati." >&2
  fi
fi

# --- MongoDB ---
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

# --- nginx config ---
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

# --- telegram.conf ---
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
