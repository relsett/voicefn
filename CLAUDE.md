# VoiceFn

A menu bar app for macOS: press fn, speak, press fn again, and the text appears where the cursor is.
Shipped through the Mac App Store, so everything runs in the App Sandbox.

## Design: as little as possible

VoiceFn follows Japanese minimalism (kanso: say it with less; ma: leave empty space alone).
The interface is quiet, and every element must earn its place. This rule is not up for trade-offs.

- **No helper text.** No subtitles under toggles, no footnotes, no "so you can…" captions, no
  explanations of what a setting does. The label alone carries the meaning; if it can't, rename it.
- **Speak only when something is wrong.** A message appears only when the user has to act (missing
  permission, a key conflict). It is one short line plus buttons that fix it, and it shows only
  once the problem actually happens, never as a precaution.
- **One screen, one action.** Onboarding pages and settings sections do one thing each.
- **Short labels.** Prefer one or two words. No exclamation marks, no marketing voice.
- **Nothing new by default.** Before adding a control, a line of text or a menu item, ask whether
  the app works without it. Usually it does.
- Every user-facing string is in English and Russian (`Localizable.xcstrings`), with the Russian
  equally short.

## Working in this repo

- Tests: `./scripts/test.sh`. Signed release build: `./scripts/build.sh`.
- New source files are picked up by the Xcode project automatically (synchronized group).
