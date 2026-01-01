# Applepie-RPC

Applepie-RPC is a macOS menu bar app that publishes now-playing info to Discord Rich Presence. It pulls playback metadata via pyatv (through PylibKit) from your Mac or AirPlay targets like HomePod and Apple TV, then updates Discord with track details and progress.

## Features
- Discord Rich Presence with track title, artist, album, and artwork
- Playback progress bar (position and duration)
- AirPlay device selection
- Pairing flow for protected devices
- Adjustable update interval
- Clear cached pairing credentials

## Requirements
- macOS
- Xcode (for building and running)
- Discord desktop app running
- Apple Music authorization (prompted at launch)
- Accessibility permission (prompted at launch)
- AirPlay devices on the same network

## Build and Run
1. Open `Applepie-RPC.xcodeproj` in Xcode.
2. Build and run the `Applepie-RPC` target.
3. Grant Accessibility and Apple Music permissions when prompted.
4. Keep Discord running in the background.

## Usage
- Click the menu bar icon to open the app UI.
- Select an AirPlay device from the Device menu.
- If pairing is required, enter the PIN shown on the device.
- Adjust the update interval slider to control polling.
- Use Clear Cache to remove stored pairing credentials.

## Troubleshooting
- No progress bar: the device might not expose duration; try another target or re-pair.
- RPC not updating: confirm Discord is running and check Xcode logs for `[DiscordService]`.
- Pairing issues: clear cache and retry pairing.

## Notes
- Pairing credentials are stored in the app support directory as `pyatv_storage.json`.
- The Python runtime is bundled via PylibKit; no system Python setup is required.

## Releases & Updates (Sparkle)
This project ships updates via Sparkle using the appcast at:
`https://github.com/Skyline-23/Applepie-RPC/releases/latest/download/appcast.xml`

### Release flow
1. Create a tag like `v1.2.3` and push it.
2. GitHub Actions builds the app, creates a DMG, generates `appcast.xml`, and publishes a release.
3. Clients will see the update once the tag and appcast are live.

### Required GitHub secrets
- `CERT_P12_BASE64`, `CERT_PASSWORD`, `KEYCHAIN_PASSWORD`
- `APPLE_ID`, `APPLE_PASSWORD`, `TEAM_ID`
- `APPSTORE_PRIVATE_KEY_P8`, `APPSTORE_KEY_ID`
- `SPARKLE_ED25519_PRIVATE_KEY` (matches `SUPublicEDKey` in Info.plist)
