# Synergy Crew — unofficial iPhone app

Full-screen iOS wrapper around the 3134S Synergy OS app shell
(`https://team-3134s.web.app/app.html?source=app`). Unsigned `.ipa`, built by
CI on every push — install it by sideloading.

- Bundle id: `com.synergy3134s.crew`
- Deployment target: iOS 15
- Dark VOLTAGE launch (charcoal `#0A0A0D`, no white flash), pull-to-refresh,
  swipe back/forward, inline media; links that leave the team domains open
  in Safari.
- **Capture protection (unverified on device — see below).** The web view is
  hosted inside the secure canvas iOS uses for password fields, which the
  window server excludes from captures. A live recording also raises a charcoal
  curtain, and taking a screenshot flashes one.

  The canvas is private API surface, so it is validated instead of assumed:

  - **Identity.** The host view is used only when the text field designates it
    as its secure content view, or its runtime class is the private secure
    canvas type. An unidentified view is never used — parking the dashboard in
    an ordinary subview while still reporting "protected" would be worse than
    no protection at all.
  - **Usability.** UIKit sizes that canvas to a single line of text. Before any
    content goes in, the host field is forced to two known sizes (320×480 and
    390×760) and the canvas must cover ≥90% of it in both axes, under either a
    constraint or an autoresizing strategy. A canvas left at a ~20pt text-line
    rect fails — that check exists because "bounds bigger than a pixel" passes
    it happily and squeezes the dashboard into a sliver.
  - **Honest fallback.** If either check fails (now or later — it is re-checked
    on appear, on becoming active, and after each page load), the app hosts the
    web view normally *and the curtains change their wording* to "team content
    IS visible in this recording" / "Screenshot taken — team content is visible
    in it", with a warning glyph instead of the padlock. The app never claims a
    protection it does not have.

## ⚠️ The capture protection is NOT confirmed until someone tests it on a phone

The secure canvas reliably excludes **UIKit-drawn** content from captures.
A `WKWebView` does not draw its content in this process — it renders in the web
content process and is composited back through a **hosted (remote) layer**.
Whether that hosted layer inherits the canvas's capture exclusion is not
documented, and **the simulator's screenshot path does not model it**. It is
entirely possible for the app to be hosting correctly and for screenshots to
still show the dashboard.

**Nobody should rely on this for anything sensitive until the device test below
passes.** Treat the feature as "attempted" until then.

### Device test

1. Sideload the build and open **Synergy Crew** on a real iPhone.
2. Attach the phone to a Mac and watch the log in Console.app (or Xcode →
   Window → Devices and Simulators), filtering for `[3134S capture]`. Every
   launch logs one of:
   - `PROTECTED(hosting): content is inside _UITextLayoutCanvasView; out-of-process layer host: YES. DEVICE TEST REQUIRED: …`
   - `UNPROTECTED: content is hosted normally and WILL appear in screenshots …`
     followed by the reason.
   The same facts are on `CaptureProtectionDiagnostics.isSecureCanvasActive`,
   `.secureCanvasClassName`, `.hostedContentUsesRemoteLayer` and
   `.lastFailureReason` — plain statics, readable from lldb.
3. With the log saying `PROTECTED(hosting)`, take a screenshot of the dashboard
   and open it in Photos.
   - Dashboard area **solid black** → the exclusion does propagate into the
     hosted web layer. Update this section to say so, with the iOS version it
     was checked on.
   - Dashboard **legible** in the screenshot → hosting works but the exclusion
     does **not** reach WKWebView's layer. The screenshot/recording curtains
     are then the only real protection, and this README's first bullet must be
     corrected to say screenshots are not blocked.
4. Repeat for a screen recording and for AirPlay mirroring — they go through
   different paths and can disagree with the screenshot result.
5. Re-run after every iOS major update: this rides on private layout, and both
   the identity and usability checks are designed to fail safe (protection off,
   honest curtains) rather than to keep working.

Status: **not yet run.** No result has been recorded here.

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
  `CaptureProtection.swift` secure canvas + capture curtain +
  `CaptureProtectionDiagnostics`), launch storyboard,
  asset catalog with the volt-bolt AppIcon
- `tools/gen_icons.py` — regenerates the icon set (Pillow)
- `.github/workflows/build-ipa.yml` — CI: build unsigned ipa, upload artifact,
  publish to the `latest` release
