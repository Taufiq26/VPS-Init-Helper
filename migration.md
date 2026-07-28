# Panduan Migrasi Server — vps-init-helper

Cara pindah dari VPS lama ke VPS baru tanpa kehilangan data.

> Catatan: file ini juga otomatis ditulis ulang oleh `setup.sh` ke
> `/root/vps-init-helper/migration.md` di setiap server yang kamu setup,
> supaya selalu tersedia di server itu sendiri tanpa perlu clone repo ini lagi.

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
MongoDB — sesuai yang benar-benar aktif), meng-archive config nginx, dan
mengumpulkan file docker-compose yang ditemukan, menjadi satu file:

```
/root/vps-init-helper/backups/vps-backup-<timestamp>.tar.gz
```

### 2. Pindahkan archive ke VPS baru

```
scp /root/vps-init-helper/backups/vps-backup-<timestamp>.tar.gz root@<ip-vps-baru>:/root/
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
sudo /root/vps-init-helper/scripts/restore.sh /root/vps-backup-<timestamp>.tar.gz
```

Ini akan restore semua database dump dan config nginx. Kalau ada file
docker-compose di dalam backup, script TIDAK menaruhnya otomatis (untuk
menghindari overwrite yang tidak diinginkan) — cek pesan di akhir restore.sh
untuk lokasi filenya, lalu pindahkan manual ke tempat yang sesuai dan jalankan
`docker compose up -d`.

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
