#!/usr/bin/env bash
# vps-init-helper — refresh-cloudflare-ips.sh
# Re-fetches Cloudflare's published IP ranges and re-applies the UFW/firewalld
# allowlist for ports 80/443, replacing whatever was applied previously.
# Safe to run repeatedly (idempotent) — meant to run weekly via cron so the
# origin firewall stays in sync if Cloudflare adds/rotates IP ranges.
#
# Usage: sudo ./refresh-cloudflare-ips.sh

set -euo pipefail

STATE_DIR="/root/vps-init-helper/state"
OLD_V4="$STATE_DIR/cloudflare-ips-v4.txt"
OLD_V6="$STATE_DIR/cloudflare-ips-v6.txt"
mkdir -p "$STATE_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan sebagai root: sudo ./refresh-cloudflare-ips.sh" >&2
  exit 1
fi

NEW_V4="$(curl -fsSL https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
NEW_V6="$(curl -fsSL https://www.cloudflare.com/ips-v6 2>/dev/null || true)"

if [ -z "$NEW_V4" ]; then
  echo "Gagal mengambil daftar IP Cloudflare. Rule firewall TIDAK diubah." >&2
  exit 1
fi

OLD_V4_CONTENT="$( [ -f "$OLD_V4" ] && cat "$OLD_V4" || true )"
OLD_V6_CONTENT="$( [ -f "$OLD_V6" ] && cat "$OLD_V6" || true )"

if [ "$NEW_V4" = "$OLD_V4_CONTENT" ] && [ "$NEW_V6" = "$OLD_V6_CONTENT" ]; then
  echo "Daftar IP Cloudflare tidak berubah, rule firewall tidak perlu diupdate."
  exit 0
fi

echo "Daftar IP Cloudflare berubah — memperbarui rule firewall..."

if command -v ufw >/dev/null 2>&1; then
  # --- UFW (Debian/Ubuntu) ---
  if [ -n "$OLD_V4_CONTENT" ]; then
    while IFS= read -r cidr; do
      [ -n "$cidr" ] && ufw delete allow from "$cidr" to any port 80,443 proto tcp >/dev/null 2>&1 || true
    done <<< "$OLD_V4_CONTENT"
  fi
  if [ -n "$OLD_V6_CONTENT" ]; then
    while IFS= read -r cidr; do
      [ -n "$cidr" ] && ufw delete allow from "$cidr" to any port 80,443 proto tcp >/dev/null 2>&1 || true
    done <<< "$OLD_V6_CONTENT"
  fi

  while IFS= read -r cidr; do
    [ -n "$cidr" ] && ufw allow from "$cidr" to any port 80,443 proto tcp comment 'Cloudflare' >/dev/null
  done <<< "$NEW_V4"
  while IFS= read -r cidr; do
    [ -n "$cidr" ] && ufw allow from "$cidr" to any port 80,443 proto tcp comment 'Cloudflare' >/dev/null
  done <<< "$NEW_V6"

elif command -v firewall-cmd >/dev/null 2>&1; then
  # --- firewalld (Rocky/RHEL) ---
  if [ -n "$OLD_V4_CONTENT" ]; then
    while IFS= read -r cidr; do
      if [ -n "$cidr" ]; then
        firewall-cmd --permanent --zone=public --remove-rich-rule="rule family=\"ipv4\" source address=\"$cidr\" port port=\"80\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=public --remove-rich-rule="rule family=\"ipv4\" source address=\"$cidr\" port port=\"443\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      fi
    done <<< "$OLD_V4_CONTENT"
  fi
  if [ -n "$OLD_V6_CONTENT" ]; then
    while IFS= read -r cidr; do
      if [ -n "$cidr" ]; then
        firewall-cmd --permanent --zone=public --remove-rich-rule="rule family=\"ipv6\" source address=\"$cidr\" port port=\"80\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=public --remove-rich-rule="rule family=\"ipv6\" source address=\"$cidr\" port port=\"443\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      fi
    done <<< "$OLD_V6_CONTENT"
  fi

  while IFS= read -r cidr; do
    if [ -n "$cidr" ]; then
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$cidr\" port port=\"80\" protocol=\"tcp\" accept" >/dev/null
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$cidr\" port port=\"443\" protocol=\"tcp\" accept" >/dev/null
    fi
  done <<< "$NEW_V4"
  while IFS= read -r cidr; do
    if [ -n "$cidr" ]; then
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv6\" source address=\"$cidr\" port port=\"80\" protocol=\"tcp\" accept" >/dev/null
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv6\" source address=\"$cidr\" port port=\"443\" protocol=\"tcp\" accept" >/dev/null
    fi
  done <<< "$NEW_V6"

  firewall-cmd --reload >/dev/null
else
  echo "Tidak ditemukan ufw maupun firewall-cmd. Tidak bisa update rule firewall." >&2
  exit 1
fi

echo "$NEW_V4" > "$OLD_V4"
echo "$NEW_V6" > "$OLD_V6"

echo "Rule firewall Cloudflare berhasil diperbarui ($(date '+%Y-%m-%d %H:%M:%S'))."

if [ -x /root/vps-init-helper/scripts/notify-telegram.sh ]; then
  /root/vps-init-helper/scripts/notify-telegram.sh "vps-init-helper: daftar IP Cloudflare berubah, rule firewall $(hostname) sudah diperbarui otomatis."
fi
