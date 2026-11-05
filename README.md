# EdgeStash

A tiny macOS menu bar app that stashes a window of any app (Notion by default) just past a
screen edge. Touch the edge with the pointer and it slides out; move the pointer away and it
slides back. Similar to Rectangle Pro's "Stash", free and open source.

- Works with the **native** app window (via the Accessibility API), not a web view.
- Slides out when the pointer rests on the edge, or when you activate the app (Dock, Cmd-Tab).
- Slides back when the pointer leaves the window (hover) or the app loses focus (activation),
  and hands keyboard focus back to the app you were using.
- Drag the window away from the edge to unpin it. Quitting EdgeStash puts the window back.
- Width presets: keep the current width, or snap to Minimum (the app's own minimum), 25%, 33%,
  50%, 75% or 100% of the screen's usable width. Applied immediately and whenever a window is stashed.
- Menu bar: pick the app, the window, the edge (left/right), the width, Launch at Login.

## Install

```sh
brew install --cask marunouchiR5/tap/edgestash
```

Or download the zip from [Releases](https://github.com/marunouchiR5/edge-stash/releases).

On first launch grant **System Settings › Privacy & Security › Accessibility › EdgeStash**.

> Builds that are not signed with a Developer ID and notarized are blocked by Gatekeeper on
> first open. Allow it under *System Settings › Privacy & Security › Open Anyway*, or run
> `xattr -dr com.apple.quarantine /Applications/EdgeStash.app`.

## Tuning

```sh
defaults write io.github.marunouchir5.EdgeStash revealDelay -float 0.08      # seconds on the edge before sliding out
defaults write io.github.marunouchir5.EdgeStash hideDelay -float 0.35        # seconds outside before sliding back
defaults write io.github.marunouchir5.EdgeStash animationDuration -float 0.16
defaults write io.github.marunouchir5.EdgeStash peek -float 1                # points left visible (macOS minimum is 1)
defaults write io.github.marunouchir5.EdgeStash widthPreset half            # current|minimum|quarter|third|half|threeQuarters|full
```

## Known limitations

- macOS won't place a window fully off screen, so 1pt stays visible at the edge.
- The edge must be a "hard" edge (no other display beyond it), otherwise the pointer just crosses over.
- If the Dock lives on the same edge, it can compete for the pointer there; put the Dock on another edge.
- One stashed window at a time.

## Develop

```sh
swift test                      # unit tests (geometry + reveal/hide policy)
swift run EdgeStash             # run from source (Accessibility is granted to your terminal)
Scripts/install_local.sh        # build, sign with your dev identity, install to /Applications, launch
swift Scripts/make_icon.swift   # regenerate Resources/AppIcon.icns
```

## Release

Distribution follows the same model as [CodexBar](https://github.com/steipete/CodexBar):
GitHub Releases + a Homebrew cask.

1. Bump `version.env`, commit, `git tag vX.Y.Z && git push --tags`.
2. `.github/workflows/release.yml` tests, builds a universal app, zips it and creates the GitHub release.
   Add the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`,
   `APPLE_APP_PASSWORD` to get Developer ID signing + notarization; without them the build is ad-hoc signed.
3. Copy the updated `Casks/edgestash.rb` (workflow artifact) into the `homebrew-tap` repo.

Locally the same is `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… PUBLISH=1 Scripts/release.sh`.

## License

MIT
