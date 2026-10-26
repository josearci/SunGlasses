# SunGlasses

A macOS menu bar app that hides menu bar icons behind a pair of sunglasses.

- **⌘-drag** an icon onto the sunglasses to hide it. Repeat for as many as you like.
- **Click** the sunglasses to reveal the hidden icons, lined up on their left. Click again to hide them.
- **⌘-drag** a revealed icon away from the sunglasses to remove it for good.
- **Dark lenses** while icons are hidden, **clear lenses** when nothing is.
- Right-click for "Start at Login" and Quit.

## Build

```sh
./build.sh
```

Builds straight into `/Applications/SunGlasses.app` and launches it. It must live in `/Applications`:
macOS 27 only keeps an app's own icon visible for the copy there.

Signs with the "Apple Development" certificate if one is in the keychain, otherwise ad-hoc. A stable
signature matters: macOS ties the Accessibility grant to it, and an ad-hoc signature changes every build.

## Requirements

- macOS 27 (Golden Gate). Earlier versions draw each icon as its own window and need a different approach.
- **Accessibility** permission, to see ⌘-drags and work out which icon was dropped.

## How it works

macOS 27 draws the whole menu bar as one window, so the classic "stretch an invisible divider off-screen"
trick no longer hides anything. SunGlasses instead uses the private `MenuBarClientCore` framework behind
macOS's assessment (exam lockdown) mode, which restricts the menu bar to an allow-list of apps. Hidden
apps are simply left off the list. Hidden Bar 1.11.1 uses the same mechanism.

Being a private framework, a macOS update could break it. If the framework is missing, SunGlasses stays
unfolded rather than hiding the wrong things.

Limits that come with the approach:

- Hiding is per app: an app with several icons hides them all together.
- Apple's own items (clock, Wi-Fi, Sound, Control Center) can't be hidden.
