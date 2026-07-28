# vps-init-helper

Satu file `setup.sh` untuk membawa VPS Debian 12 / Ubuntu LTS / Rocky Linux 8
yang kosong menjadi production ready, plus toolkit migrasi supaya gampang
pindah server di kemudian hari.

`setup.sh` mendeteksi OS secara otomatis. Untuk Debian/Ubuntu, semuanya
berjalan langsung di `setup.sh` (pakai apt/ufw). Untuk **Rocky Linux 8**,
stack-nya cukup berbeda (dnf, firewalld, SELinux) sehingga logikanya ditulis
terpisah di [`scripts/setup-rocky8.sh`](scripts/setup-rocky8.sh) — `setup.sh`
otomatis delegasi ke situ. **Kalau target VPS-mu Rocky Linux 8, copy KEDUA
file ini (satu folder yang sama)**, bukan cuma `setup.sh` sendirian:

```
scp setup.sh scripts/setup-rocky8.sh root@ip:/root/
sudo bash setup.sh
```

Untuk Debian/Ubuntu, `setup.sh` sendirian tetap cukup seperti biasa.

## Apa yang di-install

**Stack inti:**
- Update sistem + paket dasar (curl, wget, git, unzip, dll)
- Swapfile otomatis kalau RAM kecil
- User sudo baru + SSH key (pengganti akses root)
- UFW (firewall) — default deny, hanya buka port SSH/80/443, opsi membatasi 80/443 hanya dari IP Cloudflare
- fail2ban (jail sshd)
- nginx
- Database/storage — **interaktif, pilih satu atau lebih**: MySQL/MariaDB, PostgreSQL, MongoDB, MinIO (S3-compatible object storage, AGPLv3 — systemd service, API port 9000 + Console port 9001)
- Docker + Docker Compose plugin
- nvm + Node.js LTS + PM2 (jalan sebagai user baru, bukan root)
- htop, tmux, ncdu, net-tools, unattended-upgrades

**Keamanan & monitoring (opsional, interaktif):**
- Notifikasi Telegram — dipakai oleh semua modul di bawah ini untuk mengirim alert
- fail2ban → Telegram — notifikasi tiap kali ada IP yang diblokir
- Monit — watchdog yang auto-restart nginx/DB/docker kalau mati, alert via Telegram
- logwatch — ringkasan aktivitas log dikirim harian
- AIDE — file integrity monitoring, alert kalau ada file sistem berubah tanpa sepengetahuanmu
- Lynis — audit keamanan otomatis (skor hardening index 0-100, standar CIS Benchmark)

## Cara pakai

Di VPS baru, sebagai root:

```
sudo bash setup.sh
```

Script akan bertanya beberapa hal secara interaktif: nama client/project (untuk
laporan), hostname/timezone, username baru + SSH public key, database mana saja
yang mau di-install, notifikasi Telegram, pembatasan IP Cloudflare, dan modul
monitoring mana yang mau diaktifkan (Monit/logwatch/AIDE). Semua yang lain
berjalan otomatis.

Script ini **aman dijalankan berkali-kali** (idempotent) — langkah yang sudah
pernah selesai akan dilewati. Ini sengaja, supaya `setup.sh` yang sama bisa
dipakai lagi di VPS baru saat migrasi.

## Setelah setup selesai

Semua output tersimpan di `/root/vps-init-helper/` pada VPS yang baru saja
di-setup:

| File | Isi |
|---|---|
| `install-report.md` | Catatan lengkap apa saja yang ter-install, versi, port, user yang dibuat, skor Lynis, status modul monitoring |
| `security.md` | **Wajib dibaca** — checklist hardening manual: verifikasi SSH key, disable password login, disable root login, ganti port SSH, batasi akses DB, panduan Cloudflare, cara re-run Lynis |
| `migration.md` | Panduan pindah ke server baru pakai `backup.sh` / `restore.sh` |
| `client-report.md` / `.html` | **Laporan siap kirim ke client** — Bahasa Indonesia, skor keamanan, ringkasan non-teknis (`.html` bisa dibuka di browser lalu Print > Save as PDF) |
| `lynis-report.txt` | Detail teknis lengkap hasil audit Lynis |
| `telegram.conf` | Token bot + chat ID (chmod 600) |
| `scripts/backup.sh` | Dump semua DB terinstall + config nginx + telegram.conf + docker-compose files, dienkripsi AES-256 (GPG) jadi satu archive |
| `scripts/restore.sh` | Decrypt + restore dari archive `backup.sh` di server baru |
| `scripts/notify-telegram.sh` | Helper pengirim pesan Telegram, dipakai fail2ban/Monit/logwatch/AIDE |

Kenapa hardening (disable password SSH, disable root login) tidak otomatis?
Karena itu berisiko mengunci akses kamu sendiri kalau ada kesalahan (SSH key
salah paste, dll). `security.md` menuntun kamu memverifikasi akses lebih dulu
di sesi terpisah sebelum mengunci akses lama.

## Kenapa 1 file saja cukup

`setup.sh` tidak butuh file lain untuk jalan — cukup di-copy sendirian ke VPS
(`scp setup.sh root@ip:/root/` atau `curl` dari repo ini) dan dijalankan. Di
akhir proses, ia menuliskan sendiri `scripts/backup.sh` dan `scripts/restore.sh`
ke `/root/vps-init-helper/scripts/` di server itu, jadi toolkit migrasi tetap
lengkap tersedia di server meskipun kamu tidak meng-clone seluruh repo ini.

Repo ini sendiri menyimpan salinan `scripts/backup.sh`, `scripts/restore.sh`,
dan `migration.md` secara terpisah supaya bisa direview/di-version-control —
isinya identik dengan yang ditulis `setup.sh` ke server.

## Struktur repo

```
setup.sh              # entry point — Debian/Ubuntu langsung, Rocky 8 delegasi
scripts/
  setup-rocky8.sh      # WAJIB dibawa bareng setup.sh kalau target VPS Rocky Linux 8
  backup.sh            # referensi — identik dengan yang di-embed setup.sh
  restore.sh           # referensi — identik dengan yang di-embed setup.sh
migration.md            # referensi — identik dengan yang di-generate setup.sh
README.md              # dokumen ini
```

## Catatan keamanan

- Password database (MySQL root, PostgreSQL `postgres`, MongoDB admin) dan
  passphrase enkripsi backup yang kamu buat saat setup **tidak disimpan**
  oleh script ini di mana pun. Catat sendiri di password manager kamu —
  tanpa passphrase, backup terenkripsi TIDAK BISA di-restore.
- MySQL/PostgreSQL/MongoDB secara default hanya listen di `127.0.0.1` —
  tidak bisa diakses dari luar server kecuali kamu ubah manual (lihat
  `security.md`).
- Bot token Telegram tersimpan di `telegram.conf` (chmod 600, root-only).
  Modul yang membutuhkannya (fail2ban, Monit, logwatch, AIDE) membaca lewat
  `scripts/notify-telegram.sh`, tidak pernah menaruh token langsung di
  file config yang world-readable (mis. jail fail2ban).
- Kalau kamu selalu pakai Cloudflare di depan domain: aktifkan pembatasan
  IP Cloudflare di UFW saat setup, dan set mode SSL/TLS Cloudflare ke
  **Full (Strict)** (langkahnya ada di `security.md`) — mode "Flexible"
  membuat koneksi Cloudflare↔origin server tidak terenkripsi.
