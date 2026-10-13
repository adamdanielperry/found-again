# Found Again

[foundagain.app](https://foundagain.app) · The repository and Swift targets keep the original working name, DataRecover.

A free Mac app that gets deleted photos, videos and files back from memory cards, USB sticks and external drives. No trial, no limits, no account, and the app never goes online. A tip request appears only after a successful recovery.

## What it does

1. **File records first.** Reads FAT16, FAT32 and exFAT directories and the NTFS master file table (including emptied Windows Recycle Bins) for deleted entries, so files come back with their names, folders and dates in seconds.
2. **Deep scan.** Reads every 512-byte sector looking for files by their contents, so reformatted cards and lost names still work. Files found this way are named by capture date and camera model.
3. **Recover.** Copies chosen files to a folder on the Mac. Never writes to the source; refuses to save onto it.

Formats found by the deep scan: JPEG, HEIC, AVIF, PNG, GIF, TIFF, WebP, BMP, PSD; RAW from Canon (CR2, CR3), Nikon, Sony, Fujifilm, Adobe DNG, Olympus/OM, Panasonic, Pentax, Samsung; MOV, MP4, M4V, 3GP, AVI, MKV/WebM; MP3, WAV, M4A, FLAC; PDF, Word/Excel/PowerPoint (old and new), Pages/Numbers/Keynote, EPUB, ZIP.

Also: live results during the scan, thumbnails including video frames, in-app preview, quality flags (Partial/Damaged), bad-sector tolerance, and "Save a Copy of This Disk" for failing cards.

## Build and run

```bash
scripts/build-app.sh            # dist/<Name>.app for this Mac
UNIVERSAL=1 scripts/build-app.sh  # Apple silicon + Intel
scripts/release.sh              # signed, notarized DMG (needs the notarytool profile in scripts/app.env)
swift build --build-tests && swift test --skip-build
```

Requires macOS 14+ and Xcode 16+ (developed on Xcode 27 / macOS 27).

## Layout

| Path | What |
|---|---|
| `Sources/DataRecoverCore` | Recovery engine: devices, readers, FAT/exFAT scanners, carving (`Carving/`), restore, disk imaging |
| `Sources/DataRecover` | SwiftUI app. `Brand.swift` holds the name, domain and colours |
| `Sources/CDiskAccess` | C helper: asks for authorization and gets a read-only descriptor from `/usr/libexec/authopen` |
| `Sources/recover-cli` | Developer tool: `swift run recover-cli <image> [--quick] [--save <folder>]` |
| `scripts/` | Build, release, `app.env` (name, bundle ID, signing identities), `dev/` test helpers |
| `site/` | Website generator: `node site/build.mjs [--brand id]` → `site/dist` (Cloudflare Pages) |
| `docs/research/` | Market and distribution research |

## Testing without a real card

```bash
scripts/dev/make-test-card.sh /tmp/cards exfat       # exFAT card with deleted photos, a video and a PDF
scripts/dev/make-test-card.sh /tmp/cards formatted   # FAT32 card reformatted after shooting
hdiutil attach /tmp/cards/card-exfat.dmg
RECOVER_ALLOW_DISK_IMAGES=disk12 "dist/Found Again.app/Contents/MacOS/FoundAgain"   # list that image as if it were a card
```

`RECOVER_DEFAULT_DESTINATION=/tmp/out` makes recoveries default to a disposable folder. `--render-thumbnails <image> <folder>` and `--snapshot-window <png> [--image <dmg>] [--select n]` check thumbnails and the window without screen access.
