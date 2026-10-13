# Distribution, disk access, tips and platform feasibility (October 2026)

Research gathered on 2026-10-13, checked against this Mac (macOS 27.0.1).

## Mac App Store: not feasible for raw-disk recovery

Four independent layers block it:

1. **Unix permissions.** Physical disk nodes are `crw-r----- root operator`. Only disk images the user attached are user-owned. Quinn (Apple DTS, Mar 2025) confirmed an SD card's errno 13 comes from this layer and recommended an SMAppService daemon: developer.apple.com/forums/thread/777577
2. **App Sandbox.** Full Disk Access doesn't bypass the sandbox, and child processes inherit it, so `authopen` from a sandboxed app fails too (Nov 2025): developer.apple.com/forums/thread/807142
3. **TCC privacy checks.** Even a root helper was refused raw access to a removable disk until the GUI app had Removable Volumes or Full Disk Access; the helper inherits the app's grant (Oct 2025): developer.apple.com/forums/thread/802650
4. **App Review 2.4.5.** Requires the sandbox; bans root escalation and setuid.

Escape hatches checked: temporary-exception entitlements (routinely refused); sandboxed SMAppService daemon in an App Store app (technically possible since 14.2, App Review "takes a dim view"); DiskArbitration (no raw I/O); FSKit (block access only for partitions a module claims and mounts; theoretical for undelete).

What App Store recovery apps actually do: Disk Drill's App Store edition scans only disk images the user makes, and needs a separate PKG from the website for a LaunchDaemon. EaseUS reviewers get stuck on Full Disk Access and are told to download the website version. Data Recovery EX needs a disk image.

**Decision: direct download only.** An App Store "image analyser" edition would be a poor experience and isn't worth it.

## Getting raw read access (direct distribution)

| Approach | Prompts | Notes |
|---|---|---|
| AppleScript `with administrator privileges` | Every time | What the Grok version did. Runs the whole worker as root |
| `authopen -stdoutpipe -extauth` | Once per scan | Setuid system tool opens the device and passes a read-only fd back. App never runs as root. Quinn calls it intended for interactive command-line use rather than an API (thread 708765), so keep the access layer swappable |
| Full Disk Access only | None | Not enough: doesn't change root:operator 0640 |
| SMAppService daemon + XPC | One-time toggle in System Settings › Login Items | Quinn's recommendation for wide distribution. Persistent background item, extra setup step |

**Decision for v1: authopen**, because a one-time-use app shouldn't make people visit System Settings or leave a daemon installed. The Swift side is `DiskAccess`; swapping to an SMAppService helper later only changes that file. If TCC blocks the read, the app shows the Privacy & Security steps.

## Signing, notarization, updates

- Developer ID Application: weio Ltd (H4T6Q9X2TH) is already in the keychain.
- Sign inside-out with `--options runtime --timestamp`; avoid `--deep`.
- DMG: build, codesign, `xcrun notarytool submit --keychain-profile weio-notary --wait`, `xcrun stapler staple`, check with `spctl -a -vvv -t install`.
- Sparkle 2: EdDSA keys via `generate_keys` (private key stays in the keychain), `SUPublicEDKey` + `SUFeedURL` in Info.plist, `generate_appcast` for signatures. Non-sandboxed apps don't need Sparkle's XPC services.
- Homebrew: since 5.0.0 casks must be signed and notarized. Notability thresholds (75 stars / 30 forks / 30 watchers, or 225/90/90 when self-submitted; repos under 30 days old usually ineligible). Use our own tap until then. Set `auto_updates true`.
- Setapp: 70% revenue share; only makes sense for a paid app.

## Tips

- **App Store rule (3.1.1):** tips must be in-app purchases; external donation links get rejected, including US-only apps after the Epic ruling (thread 844046, Aug 2026). US anti-steering law is still in flux (Ninth Circuit Dec 2025; Supreme Court granted cert 30 June 2026).
- **Direct distribution:** no Apple rules.

| Platform | Platform fee | Processing | Apple Pay |
|---|---|---|---|
| GitHub Sponsors | 0% personal | none charged to you | not documented |
| Ko-fi | 0% on one-off tips (free plan) | Stripe/PayPal rates | yes, via Stripe in Safari |
| Stripe Payment Link (customer chooses amount) | 0% | 1.5% + 20p UK cards; 2.5% + 20p EEA; 3.15% + 20p intl | yes |
| Buy Me a Coffee | 5% | + Stripe | via Stripe |
| PayPal | — | 2.9% + 30p | no |

Stripe allows tips only for a good or service provided: present it as a tip for the app. Tips are trading income (for weio Ltd, ordinary company revenue).

## iPhone and iPad: not feasible

No raw block API; Files gives file-level access only. DriverKit on M-series iPads would mean writing your own mass-storage and file-system stack and is tied to your own hardware (DTS, thread 758598). PhotoKit returns no Recently Deleted assets since iOS 16, and per-file encryption makes truly deleted photos unreachable.

## Internal and external drives

- **Internal (T2 / Apple silicon):** SIP blocks raw reads of the boot disk (Apple's own tools carry `com.apple.rootless.restricted-block-devices`); the drive is always encrypted with keys in the Secure Enclave; APFS trims freed space. Offer the Trash, Photos Recently Deleted, iCloud Drive Recently Deleted and Time Machine instead.
- **SD/CF/USB flash on FAT32/exFAT:** best case. No evidence macOS trims on delete for FAT/exFAT, and card readers rarely pass TRIM through. exFAT keeps the NoFatChain contiguity flag, which makes undelete reliable. Some cameras' full format overwrites data.
- **External HDDs:** highly recoverable if unencrypted (no TRIM).
- **External SSDs:** Thunderbolt/USB4 NVMe with APFS or HFS+ get trimmed: poor odds. SATA SSDs behind USB bridges usually aren't trimmed unless `trimforce` is on.

To verify in practice: whether the Removable Volumes grant is attributed to the app when authopen opens the device (handled with a Privacy help sheet if not).
