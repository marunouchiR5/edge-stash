# EdgeStash

A tiny macOS menu bar app that stashes a window at each screen edge
(Slack on the left, Notion on the right by default). Touch an edge with the pointer and its window slides out; move the pointer away and it
slides back. Similar to Rectangle Pro's "Stash", free and open source.

- Works with the **native** app window (via the Accessibility API), not a web view.
- Slides out when the pointer rests on the edge, or when you activate the app (Dock, Cmd-Tab).
- Hover previews leave the current app and keyboard focus in place. Click a side window to interact.
- Slides back when the pointer leaves a preview. A side window you clicked stays visible while focused.
- Enable **Keep Visible** on either or both sides to keep side windows open alongside your current window.
- Drag a window away from its edge to unpin that side. Quitting EdgeStash puts both windows back.
- Width presets: keep the current width, or snap to Minimum (the app's own minimum), 25%, 33%,
  50%, 75% or 100% of the screen's usable width. Applied immediately and whenever a window is stashed.
- Menu bar: **Left Edge** and **Right Edge** each have their own app, window, screen, width and pin toggle.
- Use different apps, or two different windows of the same app. A window can belong to only one side.
- Automatic discovery skips your currently focused window; choose it explicitly in **Window** to pin it.
- Window menus use generic numbers instead of reading potentially private window titles.
- Choose a screen separately for each side, or use **Follow Pointer (All Displays)**.
- Display changes retain the selected windows. System repositioning does not silently unpin them.

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

Use **Left Edge › App** to choose Slack and **Right Edge › App** to choose another running app.
Open the apps normally; EdgeStash waits if an app is not running or has no eligible window.
If its only window is the one you are using, EdgeStash leaves it in place. Open another window or
choose a window explicitly. Enable **Keep Visible** on both sides to show both without changing focus.
Each side's **Window** menu shows `Window 1`, `Window 2`, etc., with the managed window checked.
Use **Left Edge › Screen** and **Right Edge › Screen** to pin each side to **Built-in Display**
or a specific **External Display**. A fixed side responds only to that display's edge; hovering
the built-in screen cannot pull an externally pinned window onto it. Display choices survive
relaunches and reordering. Disconnecting a selected display pauses that side and returns its
window to an available display; reconnecting resumes the same window on the selected display.

To keep Stage Manager on the built-in screen while using EdgeStash on an external screen,
leave Stage Manager enabled and select the external screen for both sides. This confines
EdgeStash; it does not change macOS Stage Manager settings per display. macOS can still
restrict windows belonging to a different Stage Manager group, which the menu reports explicitly.

Existing single-edge preferences migrate to their original side; the other side receives a
different default app. A previously paused configuration stays paused on both sides.

App, pin and width preferences are stored separately for each side. Timing and peek settings
are shared:

```sh
defaults write io.github.marunouchir5.EdgeStash revealDelay -float 0.08      # seconds on the edge before sliding out
defaults write io.github.marunouchir5.EdgeStash hideDelay -float 0.35        # seconds outside before sliding back
defaults write io.github.marunouchir5.EdgeStash animationDuration -float 0.16
defaults write io.github.marunouchir5.EdgeStash peek -float 1                # points left visible (macOS minimum is 1)
defaults write io.github.marunouchir5.EdgeStash left.widthPreset half       # current|minimum|quarter|third|half|threeQuarters|full
defaults write io.github.marunouchir5.EdgeStash right.widthPreset third
```

## Privacy

EdgeStash controls native window geometry and focus locally using Accessibility. It does not
read message bodies or window titles, capture screenshots, or send app data over the network.
Preferences contain app bundle identifiers, local display identifiers and behavior settings,
not conversations or document names. Display menu labels use generic built-in/external names
and dimensions rather than custom monitor names.

## Known limitations

- macOS won't place a window fully off screen, so 1pt stays visible at the edge.
- The edge must be a "hard" edge (no other display beyond it), otherwise the pointer just crosses over.
- If the Dock lives on the same edge, it can compete for the pointer there; put the Dock on another edge.
- One stashed window per side (two total).
- **Stage Manager:** macOS can keep a background app in its thumbnail strip even after its
  Accessibility frame has moved on screen. EdgeStash detects this and shows a status warning
  with a shortcut to Desktop & Dock settings. Selecting an external display avoids pulling
  side windows onto the built-in display; it cannot override macOS grouping rules. EdgeStash
  never changes this system setting automatically.
  Hovering shows the stashed window next to your current window only when both are in the
  same Stage Manager group; otherwise macOS switches groups. When the stashed window is
  outside the current group, the menu bar icon changes and the menu suggests dragging it in.

## Develop

```sh
swift test                      # unit tests (geometry, policy, preferences and safe window selection)
bash Scripts/test_window_coexistence.sh  # installed-app regression with synthetic windows only
EDGESTASH_NATIVE_TESTS=1 swift test --filter HoverIntegrationTests  # native hover regression
swift run EdgeStash             # run from source (Accessibility is granted to your terminal)
Scripts/install_local.sh        # build, sign with your dev identity, install to /Applications, launch
swift Scripts/make_icon.swift   # regenerate Resources/AppIcon.icns
```

The native regression test temporarily restarts the installed EdgeStash and checks that
automatic discovery preserves the focused window, two side windows can coexist without
changing the current app or window, and quitting does not switch focus. It also covers two
windows of the same app. Test apps contain synthetic text only; saved preferences are not changed.

The native hover test runs the production controller and timers against synthetic native windows,
feeding deterministic pointer positions at both edges of each attached display. It checks actual
WindowServer visibility as well as AX geometry, pointer departure, focus preservation, display-change
binding, and system repositioning. It requires Accessibility on the terminal and Stage Manager off;
it never moves the physical pointer, reads window titles, captures screenshots, or changes system settings.
With Stage Manager enabled, the native suite instead tests fixed external-screen routing,
inactive built-in edges, real external-window visibility, preserved focus and reconnect behavior,
while keeping Stage Manager enabled throughout.

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
