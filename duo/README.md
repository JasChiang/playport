# Playport for iPhone Duo (DuoHinge)

A layout for the iPhone Duo's three screens, added to the **official Playport IPA** as an
injected dylib. Playport itself is not rebuilt (it builds only on x86-64 Linux), so this works
with an unchanged release.

## What it does

| Posture | Game | Touch controls |
| --- | --- | --- |
| Inner screen upright, folded like a laptop or flat | the upper half, full width | all of them below the hinge |
| Cover screen upright | full width at the top | all of them below the picture |
| Sideways (inner or cover) | full width at the top | over the whole screen, mostly on the band below the picture |

- The layout follows the screen live during a game: fold, unfold, close or turn the phone and it
  changes. On the inner screen iOS turns the app with the phone; apps can't rotate it themselves.
- The app runs at the Duo's native resolution, not in the letterboxed 667×375 compatibility
  window. Without this, an app built against an older SDK always gets that window.
- Library, Home and the other pages:
  - keep at least a 16-point margin on both sides on every screen;
  - are drawn 1.2× larger sideways on the inner screen, where they would otherwise leave much
    of the height empty;
  - go on the upper screen only while folded like a laptop.
- The touch controls keep the same margin on both sides; on the cover screen sideways, the
  camera takes one side.

## Use it

You need a Mac with Xcode, with an iOS 27.1 or later SDK (for `UIHingeInteraction`), and the
official Playport IPA from the
[releases](https://github.com/playportdev/playport/releases) (made for v0.5.0).

```sh
git clone -b duo-hinge https://github.com/JasChiang/playport.git
cd playport
duo/package.sh ~/Downloads/Playport-0.5.0.ipa      # writes Playport-0.5.0-duo.ipa
```

Install `Playport-0.5.0-duo.ipa` the way you install Playport now: Xcode, AltStore, SideStore,
Sideloadly or similar. These re-sign the app with your account.

- Use the **same bundle ID** as your current Playport install, so it upgrades in place. A new
  bundle ID makes a second app, and deleting the old one deletes its games, saves and Steam
  sign-in.
- Playport's JIT setup, pairing and Increased Memory Limit work as before: see Playport's own
  documentation.

If Xcode is not in `/Applications/Xcode.app`, set `DEVELOPER_DIR`, for example
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer duo/package.sh ...`.

## Files

| File | What |
| --- | --- |
| `DuoHinge.m` | the dylib: method swizzling of Playport's `GameSurfaceView`, `TouchControlsView`, `AppDelegate` and its hosting controller |
| `build.sh` | builds `build/DuoHinge.dylib` |
| `insert_dylib.py` | adds an `LC_LOAD_DYLIB` to a Mach-O executable |
| `package.sh` | official IPA → Duo IPA |

## Limits

- Made against **Playport v0.5.0**. A later Playport can rename or rework the classes this
  patches. If it can't find them, DuoHinge does nothing and logs it.
- Library's column count and the pages' arrangement are in Playport's SwiftUI code and can't
  be changed from a dylib.
- Debug log: `idevicesyslog | grep "\[duo\]"`.

## License

GPL-3.0-or-later, like Playport. If you share a Duo IPA, share this source with it.
