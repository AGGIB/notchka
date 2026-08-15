<p align="center">
  <img src="scripts/dmg-assets/logo-marketing.png" width="180" alt="Notchka">
</p>

<h1 align="center">Notchka</h1>

<p align="center">
  Your MacBook's notch as an interactive panel: music from any source, clipboard history,
  quick notes, and pinned snippets — all in one place, with zero network requests.
</p>

<p align="center">
  <img src="docs/screenshots/panel-expanded-music.png" width="640" alt="Notchka's expanded panel, music tab">
</p>

<p align="center">
  <img src="docs/screenshots/panel-peek.png" width="360" alt="Notchka in peek state — hovering over the notch">
</p>

## Features

- **Music from any source** — Apple Music, Spotify, YouTube in the browser: pause,
  skip tracks, cover art, and progress — no extensions required.
- **Clipboard history** — text, images, files with source attribution.
  Copies from password managers never enter the feed.
- **Quick notes** — short text at your fingertips, no separate app needed.
- **Pinned snippets** — email, phone number, and other frequently pasted values,
  with masking for sensitive fields. Click to paste the value into the active app,
  `⌥`+click to just copy.
- **Unified search** — one query finds a clipboard entry, a note, and a pin at once.
- **Hover or hotkey** — `⌥Space` expands the panel from anywhere; hovering the cursor
  over the notch shows a preview without clicking.

The panel isn't a permanently floating window — it lives on top of the screen's physical
notch and expands only when needed. The rest of the time it uses no noticeable CPU.

<p align="center">
  <img src="docs/screenshots/panel-notes.png" width="320" alt="Quick notes tab">
  <img src="docs/screenshots/panel-pins.png" width="320" alt="Pinned snippets tab">
</p>

## Installation

1. Download the latest `Notchka-x.y.z.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag `Notchka.app` into `Applications`.
3. Launch Notchka from Applications. There's no Dock icon — it's a background
   agent app that lives only in the notch area.

The build is signed with a Developer ID and notarized by Apple, so Gatekeeper opens it
without extra steps.

### Accessibility permission

On the first click of a pinned snippet or clipboard entry, macOS will ask for
**Accessibility** permission — it's needed for exactly one action: programmatic paste
(`⌘V`) into the active app. Without this permission, pasting is unavailable, but copying
to the clipboard still works as usual — Notchka explains this right in the interface with
a link to the relevant section of System Settings.

Hovering over the notch and the global `⌥Space` hotkey require no permissions.

## Privacy

- Notchka makes zero network requests. No telemetry, no analytics, no update checks.
- All data — clipboard history, notes, pins — is stored locally in
  `~/Library/Application Support/kz.mobilefirst.notchka/notch.sqlite` (SQLite, unencrypted
  — the file is protected only by user-level filesystem permissions).
- The DMG download counter visible on the releases page is tracked by GitHub on its
  own side — the app knows nothing about it and plays no part in it.

## Building from source

Requirements: macOS 26+, Xcode 26.6+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/AGGIB/notchka.git
cd notchka
xcodegen generate
open Notchka.xcodeproj
```

The project builds without a personal signing identity too (ad-hoc by default in
`project.yml`) — fine for reading the code and local tweaks. For a stable local
signature (important so the Accessibility permission isn't requested again after every
rebuild), pass your identity as build arguments:

```bash
xcodebuild -project Notchka.xcodeproj -scheme Notchka \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<your-team-id> build
```

### Building the DMG

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
DEVELOPMENT_TEAM=<TEAMID> \
NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE=<profile> \
./scripts/build-dmg.sh
```

Without `NOTARIZE=1` the script will build the DMG with an ad-hoc or specified signature,
but without notarization — fine for local testing, not for public distribution.

## License

MIT — see [LICENSE](LICENSE). Third-party dependencies and their licenses are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) (GRDB.swift, mediaremote-adapter).
