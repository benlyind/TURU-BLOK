# TURU-BLOK — "Sleeping My Love" 💤

Lock layar Mac otomatis pas jam tidur, sama kucing fullscreen mondar-mandir biar inget waktunya istirahat bukan kerja. Plus **kontrol dari HP pasangan** — biar yang pegang kunci bukan kamu sendiri (akuntabilitas beneran).

> Asal-usul: dibikin buat orang yang suka begadang kerja sampai subuh, terus istrinya yang jagain dari HP. 🐱

## Fitur

- **Bedtime lock 23:00–07:00 WIB** — fullscreen, di atas semua app, kucing greenscreen yang udah di-chroma-key (transparan)
- **Kontrol dari HP pasangan** (PWA "Sleeping My Love", via WiFi lokal):
  - 😴 **Tidur Sayang** — kunci layar sekarang juga
  - ☀️ **Boleh Kerja** — buka kunci
  - 🌙 **Izin Begadang** — boleh melek sampai jam yang dipilih, lewat itu auto-lock
  - 🚫 **Jangan Begadang** — batalin izin
- **Block keyboard shortcut** (Cmd+Q, Cmd+Opt+Esc Force Quit, Cmd+Tab, Spotlight, Mission Control) via CGEventTap
- **Time-based fatigue watch** — kerja 60 menit non-stop → kucing istirahat 10 menit
- **Restart-resilient** — auto-resume habis reboot, sleep-aware (tutup laptop pas lock → buka pagi → ga nyangkut)
- **Anti time-tampering** — ubah jam sistem ga nge-bypass

## Yang TETAP bisa bypass (jujur)

Ini Mac kamu, kamu punya akses terminal — software ga bisa 100% nahan. Recovery Mode, unload launchd, edit file config, semua jalur "nyurang sadar" masih ada. Tujuannya **naikin friction + akuntabilitas sosial** (pasangan pegang kontrol), bukan penjara. Kayak Cold Turkey dkk.

## Arsitektur

```
TURU-BLOK/
├── app/                      # Swift package (CLI: turublok)
│   └── Sources/turublok/
│       ├── main.swift            # mode: --lock --fatigue-lock --force-lock
│       │                         #       --watch-eyes --snooze --status dst
│       ├── LockController.swift  # orchestrator window + event block + timer
│       ├── LockWindow.swift      # fullscreen transparan, AVPlayer HEVC-alpha
│       ├── EventBlocker.swift     # CGEventTap block keyboard
│       ├── TimeGuard.swift        # countdown + anti-tampering + sleep-aware
│       ├── TimeWatcher.swift      # fatigue (HIDIdleTime, no kamera)
│       ├── Pause.swift            # snooze / izin begadang
│       └── …
├── web/                      # control panel buat HP pasangan
│   ├── server.py                 # HTTP server (stdlib, token auth, lokal-only)
│   └── public/                   # PWA (index.html, Lottie kucing, manifest)
├── launchd/                  # 4 agent: lock / eyes / web / forcelock
├── scripts/                  # build / setup-codesign / install / uninstall / test
└── assets/cat.mov.zip        # video kucing (di-extract install.sh — lihat catatan)
```

## Setup

Butuh macOS 13+, Xcode toolchain, `ffmpeg` (buat proses video greenscreen).

```bash
# 1. Build binary
./scripts/build.sh

# 2. Bikin self-signed cert (WAJIB — biar Accessibility permission persist
#    across rebuild; tanpa ini keyboard-block ga jalan)
./scripts/setup-codesign.sh

# 3. Install (extract video, sign app, load launchd agents)
./scripts/install.sh

# 4. Approve di System Settings → Privacy & Security:
#    - Accessibility → ~/Applications/Turublok.app   (wajib, buat block keyboard)
#    - Camera        → cuma kalau pakai eye-watch versi kamera (default time-based)
```

### Video kucing (asset)

Repo nyimpen `assets/cat.mov.zip`. `install.sh` otomatis meng-extract jadi `assets/cat.mov`. Kalau mau manual:

```bash
cd assets && unzip cat.mov.zip
```

> ⚠️ **Catatan lisensi:** video kucing bawaan berasal dari klip stock. Untuk dipakai sendiri di rumah aman, tapi kalau kamu fork & redistribusi, sebaiknya **ganti dengan video greenscreen kucing milikmu sendiri** (atau CC0). Cara proses video greenscreen baru → HEVC alpha:
> ```bash
> ./scripts/process-video.sh /path/ke/kucing-greenscreen.mov
> ```

## Kontrol dari HP pasangan

Setelah install, server kontrol jalan otomatis.

1. HP & Mac **sejaringan WiFi** (VPN di HP matiin)
2. Buka Safari: `http://<nama-mac>.local:8787` (cek output install.sh buat URL pasti)
3. Masukin **PIN default `1111`**
4. Share → **Add to Home Screen** → jadi app "Sleeping My Love"
5. Tap **"ganti PIN rahasia"** → set PIN cuma pasangan yang tau (biar kamu ga bisa pair sendiri)

Keamanan control panel: PIN di-hash (PBKDF2) · rate-limit · **1 device only** (pair baru kick yang lama) · **lokal-only** (koneksi non-LAN diblok, ga ke-expose internet).

## Operasi sehari-hari

```bash
turublok --status            # liat state (window, snooze, dll)
turublok --snooze            # libur sampai window berikutnya
turublok --clear-snooze      # batalin libur
./scripts/test.sh 30         # tes lock 30 detik
launchctl list | grep turublok
tail -f logs/turublok.log
```

## Uninstall

```bash
./scripts/uninstall.sh       # unload agent, hapus app + state
```

## Ganti jam

Edit `app/Sources/turublok/LockConfig.swift` (`startHour`/`endHour`) + `launchd/com.turublok.lock.plist` (`StartCalendarInterval`), lalu rebuild + reinstall.

## Catatan teknis

- AVPlayer + **HEVC with alpha** (bukan ProRes 4444 — lebih ringan & reliable di AVPlayer). Convert pakai `avconvert --preset PresetHEVC*WithAlpha`.
- Window di `CGWindowLevelForKey(.mainMenuWindow)+1` (BUKAN `CGShieldingWindowLevel` — itu nge-block AVPlayer rendering di macOS modern).
- Accessibility (TCC) keyed ke designated requirement = bundle id + cert leaf → self-signed cert bikin permission persist across rebuild.
