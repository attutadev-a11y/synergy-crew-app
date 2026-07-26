# Synergy Crew — unofficial iPhone app

Full-screen iOS wrapper around the 3134S Synergy OS app shell
(`https://team-3134s.web.app/app.html?source=app`). Unsigned `.ipa`, built by
CI on every push — install it by sideloading.

- Bundle id: `com.synergy3134s.crew`
- Deployment target: iOS 15
- Dark VOLTAGE launch (charcoal `#0A0A0D`, no white flash), pull-to-refresh,
  swipe back/forward, inline media; links that leave the team domains open
  in Safari.
- **Capture protection.** The web view is hosted inside the secure canvas iOS
  uses for password fields, so screenshots, screen recordings and mirroring
  render team content black while it stays visible on device. A live recording
  also raises a charcoal curtain ("Screen recording detected — 3134S content
  hidden"), and taking a screenshot flashes one ("Screenshots are disabled for
  team content"). The secure canvas is private API surface, so it is probed
  defensively — if a future iOS reshapes it, the app hosts the web view
  normally instead of showing a blank screen.

## Download

Latest build: **[SynergyCrew.ipa](https://github.com/attutadev-a11y/synergy-crew-app/releases/latest/download/SynergyCrew.ipa)**
(from the [`latest` release](https://github.com/attutadev-a11y/synergy-crew-app/releases/latest)).

## Install with AltStore

The ipa is **unsigned** — AltStore signs it with your own (free) Apple ID and
re-signs it automatically. Free Apple IDs cap sideloaded apps at 3 and the
signature expires every 7 days, so keep AltServer around to refresh.

1. On a Mac or PC, install [AltServer](https://altstore.io) and run it.
2. Plug in your iPhone → AltServer menu → **Install AltStore** → pick your
   device, sign in with your Apple ID (this happens inside AltServer, on your
   computer).
3. On the iPhone: **Settings → General → VPN & Device Management** → trust
   your Apple ID's developer profile.
4. Download `SynergyCrew.ipa` (link above) on the iPhone.
5. Open **AltStore → My Apps → +** and pick the downloaded ipa.
6. Launch **Synergy Crew** from the home screen.

Refresh: open AltStore on the same Wi-Fi as a running AltServer every week
(or enable AltStore background refresh). Sideloadly works too if you prefer.

## Build locally (macOS)

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project SynergyCrew.xcodeproj -scheme SynergyCrew \
  -sdk iphoneos -configuration Release -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir Payload && cp -r build/Build/Products/Release-iphoneos/SynergyCrew.app Payload/
zip -r SynergyCrew.ipa Payload
```

## Layout

- `project.yml` — XcodeGen spec (the `.xcodeproj` is generated, never committed)
- `Sources/` — Swift app (AppDelegate + `CrewViewController` WKWebView shell,
  `CaptureProtection.swift` secure canvas + capture curtain), launch storyboard,
  asset catalog with the volt-bolt AppIcon
- `tools/gen_icons.py` — regenerates the icon set (Pillow)
- `.github/workflows/build-ipa.yml` — CI: build unsigned ipa, upload artifact,
  publish to the `latest` release
