# AIOStreams web for tvOS

AIOStreams' own web app on Apple TV, the way the official Android app does it: your server's
page on top, drawing every screen and the player's controls, and mpv playing the video beneath it.
The page comes straight from your AIOStreams instance, so every server update shows up here
without rebuilding the app.

The app speaks the same bridge as AIOStreams' Android and desktop apps (`window.aiostreamsApp`,
protocol 2), introducing itself as the Android app on a TV. The page then switches to its TV
layout, takes the remote, and hands playback to the app.

## First launch

The app asks for your AIOStreams web app address, e.g.
`https://aiostreams.example.com/jellyfin/<uuid>/<token>/web/` (the `/web/` part is added if you
leave it off). It is kept on the Apple TV only; no address is built into the app, so one build
works with any instance. Hold Play/Pause to change it later.

## Remote

| Siri Remote               | Does                                            |
| ------------------------- | ----------------------------------------------- |
| Clickpad / swipe          | Arrow keys (moves focus, seeks in the player)   |
| Click                     | Enter (hold it for the page's hold actions)     |
| Back / Menu               | The page's Back; twice on Home leaves the app   |
| Play/Pause                | Play/Pause                                      |
| **Hold Play/Pause (1 s)** | App menu: reload, server address, mpv or VLC    |

Clicking a text field opens the tvOS keyboard (dictation works there too).

## Build with GitHub Actions

The workflow generates the Xcode project with XcodeGen, installs MPVKit and TVVLCKit with
CocoaPods, and builds without signing. Nothing needs a Mac.

Every build's number (`CFBundleVersion`) is the workflow's run number, so it only goes up, and
its IPA is named `AIOStreamsTV-<version>-<build>.ipa`. The bundle id stays
`io.github.aiostreamstv.app`.

### Releases

- **Nightly:** each push to `main` replaces the `nightly` prerelease, whose tag points at the
  commit built and which holds only the newest IPA. It carries `MARKETING_VERSION` from
  `project.yml`, the next planned version.
- **Stable:** `git tag vX.Y.Z && git push --tags` builds version `X.Y.Z` into a release of its own,
  marked latest and never replaced. Then bump `MARKETING_VERSION` in `project.yml` to the next
  planned version.

## Install on the Apple TV

The IPA is unsigned; the sideloading tool signs it with your Apple ID.

- **atvloadly** (Docker on Linux, e.g. a NAS): pair the Apple TV once, upload the IPA, and it
  re-signs the app before the 7-day free-account limit runs out.
- **Sideloadly** (Mac): pair the Apple TV in *Remotes and Devices → Remote App and Devices*, pick the IPA.

With a paid Apple developer account the signature lasts a year.

## Build locally (Mac)

```sh
brew install xcodegen
xcodegen generate && pod install
open AIOStreamsTV.xcworkspace
```

Pick your Apple TV as the destination and run. Safari's *Develop* menu can inspect the page.

## Notes

- tvOS ships WebKit without exposing it in the SDK, so the app loads it at runtime. That is a
  private API: fine for sideloading, never for the App Store.
- The player is libmpv, as in AIOStreams' desktop and Android apps, from Streamyfin's
  [MPVKit](https://github.com/streamyfin/MPVKit) build, whose `vo_avfoundation` output hands
  HDR10 and HLG to the TV. With *Match Content* on in the Apple TV's settings, the TV switches to
  the video's range and frame rate. Dolby Vision plays through its HDR10 base layer. VLC remains
  in the app menu as a fallback; it shows HDR as SDR.
- Subtitles are drawn by libass with the bundled Noto Sans (SIL Open Font License).
- MPVKit and VLCKit are GPL/LGPL, so builds of this app are for personal use.
- Not carried over from the Android app: seek-bar thumbnails, the mpv config editor, downloads
  and voice search.
- tvOS may clear a web page's stored data when space runs low; you'd sign in again.
- The icon and Top Shelf image are AIOStreams' own logo, from its `branding` folder.
