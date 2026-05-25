# TURU-BLOK

Lock layar Mac otomatis jam 23:00 - 07:00 WIB tiap hari. Sambil kucing greenscreen mondar-mandir di fullscreen biar inget waktunya tidur, bukan kerja.

## Apa yang dikerjain

- Spawn fullscreen window di semua monitor (`CGShieldingWindowLevel` — di atas menu bar, dock, screensaver)
- Play video kucing greenscreen kamu, chroma-keyed (background hijau jadi transparan)
- Kucing animate kiri-kanan, posisi Y random tiap putaran
- Block keyboard shortcut: Cmd+Q, Cmd+Opt+Esc (Force Quit), Cmd+Tab, Cmd+Space, F3, F11, Ctrl+arrows (Mission Control / Spaces)
- Ignore signal SIGTERM/SIGINT/SIGHUP — `kill <pid>` ga akan kerja
- launchd `KeepAlive` auto-restart kalau di-`kill -9` via Activity Monitor
- Anti time-tampering: deteksi user ubah jam sistem (mundurin/majukan), durasi tetep dihitung berdasarkan progresi natural

## Restart-resilience (v2)

- `RunAtLoad: true` — saat boot, binary auto-spawn, cek lock window, lanjut lock kalau iya
- `StartCalendarInterval` di-set tiap jam dari 23 sampai 06 — kalau Mac di-force-shutdown jam 02:00, jam 03:00 launchd nyalain lagi (max delay 1 jam)
- Sentinel `skip-next.flag` di Application Support → install.sh touch dulu sebelum `launchctl load`, biar RunAtLoad initial ga nge-trigger lock spurious saat install
- Lockfile `lock.pid` → cek apakah ada instance lain yang masih hidup (`kill -0`), kalau iya exit immediately. Single-running guarantee.

## Yang TETAP bisa bypass (jujur)

- Force shutdown + restart kasih kamu ~ 1 jam sebelum kucing nongol lagi (delay sampai jam berikutnya di StartCalendarInterval)
- Recovery Mode → unload launchd plist via Terminal
- Boot dari external drive
- Hapus binary + plist manually

Tujuan-nya bukan unbreakable, tapi friction tinggi untuk self-control.

## Struktur

```
TURU-BLOK/
├── README.md
├── assets/          # Drop video kucing di sini: cat.mp4 / cat.mov
├── app/             # Swift Package
│   └── Sources/turublok/
├── launchd/         # plist template
├── scripts/         # build / install / test / uninstall
└── logs/            # runtime logs
```

## Setup pertama kali

```bash
# 1. Build
./scripts/build.sh

# 2. Drop video kucing greenscreen
cp ~/Downloads/cat_greenscreen.mp4 assets/cat.mp4

# 3. Test 30 detik dulu sebelum install permanen
./scripts/test.sh 30

# 4. Kalau test OK, install schedule jam 23:00
./scripts/install.sh

# 5. Approve Accessibility permission:
#    System Settings → Privacy & Security → Accessibility
#    → enable: ~/.local/bin/turublok
```

## Cek status

```bash
~/.local/bin/turublok --status
launchctl list | grep turublok
tail -f logs/turublok.log
```

## Uninstall

```bash
./scripts/uninstall.sh
```

## Trigger manual (untuk debug)

```bash
launchctl start com.turublok.lock     # paksa start sekarang
launchctl stop com.turublok.lock      # stop (akan auto-restart karena KeepAlive)
```

## Emergency bypass (kalau bener-bener stuck)

Kalau ada deadline mendesak yang ga bisa ditunda:

1. **Force shutdown:** Hold power button 10 detik
2. **Boot Recovery Mode:** Pas startup, hold power button sampai keluar options
3. **Open Terminal:** Utilities → Terminal
4. **Disable launchd:**
   ```bash
   launchctl disable gui/$(id -u)/com.turublok.lock
   ```
5. **Restart normally**

Atau lebih simpel: `./scripts/uninstall.sh` dari Terminal sesudah login. (Tapi kalau lock aktif, Terminal ga akan bisa diakses sampai jam 07:00 — itu intinya.)

## Tweak konfigurasi

Edit `app/Sources/turublok/LockConfig.swift`:

```swift
static func current() -> LockConfig {
    LockConfig(
        startHour: 23,           // ubah jam mulai
        endHour: 7,              // ubah jam selesai
        timezone: TimeZone(identifier: "Asia/Jakarta") ?? .current
    )
}
```

Lalu edit `launchd/com.turublok.lock.plist` bagian `StartCalendarInterval` biar match dengan `startHour`. Rebuild + reinstall.

## Catatan teknis

- macOS 13+, Apple Silicon atau Intel
- Tidak butuh root / sudo
- Tidak butuh notarization (binary user-local)
- AVPlayer + CIColorCubeWithColorSpace untuk chroma key (warna hue 75-165° dianggap green screen)
- State persisted di `~/Library/Application Support/turublok/state.json`
- Logs di `~/Projects/TURU-BLOK/logs/`
