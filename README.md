# SunGlasses

A pair of sunglasses in your Mac's menu bar. Drop icons on it to hide them; click it to see them again.

- **⌘-drag** a menu bar icon onto the sunglasses to hide it. Repeat for as many icons as you like.
- **Click** the sunglasses to reveal the hidden icons, lined up on its left. Click again to hide them.
- **⌘-drag** a revealed icon away from the sunglasses to stop hiding it.
- **Dark lenses** mean icons are hidden behind them; **clear lenses** mean nothing is.
- Right-click for Start at Login, updates and Quit.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/josearci/SunGlasses/main/install.sh | bash
```

It downloads the latest release, puts **SunGlasses.app** in your Applications folder and starts it. The sunglasses appear in your menu bar.

- **Allow it in Accessibility** when macOS asks (System Settings › Privacy & Security › Accessibility). That is how SunGlasses sees you ⌘-drag an icon onto it. Until then the sunglasses are there but ignore drops; right-click them for a shortcut to the setting.
- **Requirements:** macOS 27 or later, on an Apple Silicon Mac. It has to stay in `/Applications` (see *How it works*).
- **Updates:** SunGlasses keeps itself up to date. Every change merged into `main` becomes a new release. The app checks for one at launch and every few hours, downloads it in the background, and offers **Restart to Update** in its right-click menu.

## How it works

macOS 27 draws the whole menu bar as one window, so the classic trick of stretching an invisible divider off-screen no longer hides anything. SunGlasses instead uses the private `MenuBarClientCore` framework behind macOS's assessment (exam lockdown) mode, which restricts the menu bar to an allow-list of apps: the apps behind the sunglasses are simply left off the list. Hidden Bar 1.11.1 uses the same mechanism.

That brings a few limits:

- Hiding is per app: an app with several icons hides them all together.
- Apple's own items (clock, Wi-Fi, Sound, Control Center) can't be hidden.
- Assessment mode also stops Notification Center opening while folded. Clicking the clock still opens it: SunGlasses lifts the restriction for the instant it takes to open (hidden icons may flicker) and folds again right away.
- Apps outside `/Applications` (even `~/Applications`) are hidden while folded, whether or not they're behind the sunglasses.
- macOS keeps an app's own icon visible only for the copy in `/Applications`; a copy anywhere else hides its own sunglasses.
- Being a private framework, a macOS update could break it. If the framework is missing, SunGlasses leaves everything visible rather than hiding the wrong things.

**Privacy.** SunGlasses stores the list of hidden apps in its own preferences on your Mac. Its only network request is reading the public release info from GitHub to check for updates.

## Uninstall

Right-click the sunglasses, choose Quit, then delete **SunGlasses.app** from Applications. Hidden icons come back as soon as it quits. To also forget which apps were hidden: `defaults delete com.josearci.SunGlasses`.

## Development

The whole app is [`SunGlasses.swift`](SunGlasses.swift).

```bash
./build.sh                    # build this checkout and (re)install it into /Applications
./scripts/build-app.sh        # just build .build/SunGlasses.app
```

Logs: `log stream --predicate 'subsystem == "com.josearci.SunGlasses"'`.

**How a release happens:** every push to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml). It builds `SunGlasses.app` with `scripts/build-app.sh` and publishes it as a GitHub Release tagged `v1.0.<commit count>`. Installed copies pick it up on their next update check.

**Signing.** macOS ties the Accessibility grant to the app's signing certificate, so every build must carry the same one or users would have to re-allow SunGlasses after each update. All builds are signed with a self-signed "SunGlasses Signing" certificate: local builds take it from your login keychain, releases from the repo's `SIGNING_P12` / `SIGNING_PASSWORD` secrets. `scripts/make-signing-cert.sh` creates it and puts it in both places; it only needs to run once (it needs `gh` logged in, and the first local build afterwards asks whether `codesign` may use the key: choose Always Allow). A build without the certificate falls back to ad-hoc signing and warns. Builds aren't notarized: the installer downloads with `curl`, which doesn't trigger Gatekeeper, and the app downloads its own updates the same way, checking that each one carries the same signature before installing it.

## License

[MIT](LICENSE).
