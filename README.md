# Applepie

<p align="center">
  <img src="AppIcon.png" width="96" height="96" alt="Applepie icon">
</p>

<p align="center">
  macOS menu bar app that publishes now-playing info to Discord Rich Presence.
</p>

<p align="center">
  <a href="https://github.com/Skyline-23/Applepie-RPC/releases/latest">Download</a>
  ·
  <a href="#homebrew">Homebrew</a>
  ·
  <a href="#development">Development</a>
</p>

Applepie pulls playback metadata from:
- Your Mac (Music.app)
- AirPlay targets like HomePod / Apple TV (via `pyatv` through `PylibKit`)

Then it keeps your Discord activity updated with track details and playback progress.

## Features
- Discord Rich Presence with track title, artist, album, and artwork
- Playback progress bar (position and duration)
- AirPlay device selection + pairing flow for protected devices
- Adjustable update interval
- Clear cached pairing credentials

## Install

### DMG (Recommended)
1. Download the latest DMG from the GitHub Releases page.
2. Move `Applepie-RPC.app` into `/Applications`.
3. Launch Applepie and grant permissions when prompted.

### Homebrew
Homebrew tap is hosted in a dedicated repo:
`https://github.com/Skyline-23/homebrew-applepie-rpc`

```bash
brew tap skyline-23/applepie-rpc
brew install --cask applepie-rpc
```

To upgrade:

```bash
brew upgrade --cask applepie-rpc
```

## Updates (Sparkle)
Applepie supports automatic updates (Sparkle) via:
`https://github.com/Skyline-23/Applepie-RPC/releases/latest/download/appcast.xml`

To avoid conflicts with cask-managed installs, Applepie prefers Homebrew as the update authority when it detects a Homebrew cask install.

## Requirements
- macOS
- Discord desktop app running
- Apple Music authorization (prompted at launch)
- Accessibility permission (prompted at launch)
- AirPlay devices on the same network (for HomePod/Apple TV)

## Usage
- Click the menu bar icon to open the UI.
- Select an AirPlay device from the Device menu.
- If pairing is required, enter the PIN shown on the device.
- Adjust the update interval slider to control polling.
- Use Clear Cache to remove stored pairing credentials.

## Troubleshooting
- No progress bar: some devices do not expose duration; try another target or re-pair.
- RPC not updating: confirm Discord is running and check logs for `[DiscordService]`.
- Pairing issues: Clear Cache and retry pairing.

## Notes
- Pairing credentials are stored under `~/Library/Application Support/Applepie-RPC/pyatv_storage.json`.
- The Python runtime is bundled via PylibKit; no system Python setup is required.

## Development
1. Open `Applepie-RPC.xcodeproj` in Xcode.
2. Build and run the `Applepie-RPC` target.
3. Grant permissions when prompted.

## Release Flow
1. Create a tag like `v1.2.3` and push it.
2. GitHub Actions builds the app, creates a DMG, generates `appcast.xml`, and publishes a release.
3. The workflow updates `Skyline-23/homebrew-applepie-rpc` cask version/sha automatically.
4. Clients will see the update once the tag and appcast are live.

Tag naming follows SemVer: `vMAJOR.MINOR.PATCH` (3-part). For hotfixes, bump `PATCH`. Legacy 4-part tags exist; avoid creating new ones.

### Required GitHub secrets
- `CERT_P12_BASE64`, `CERT_PASSWORD`, `KEYCHAIN_PASSWORD`
- `APPLE_ID`, `APPLE_PASSWORD`, `TEAM_ID`
- `APPSTORE_PRIVATE_KEY_P8`, `APPSTORE_KEY_ID`
- `SPARKLE_ED25519_PRIVATE_KEY` (matches `SUPublicEDKey` in Info.plist)
