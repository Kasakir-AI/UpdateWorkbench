# Update Workbench

Update Workbench is a native macOS app that finds and installs updates for your apps and command-line tools. It covers Homebrew, the Mac App Store (through `mas`), Sparkle feeds, Electron apps and GitHub releases, and runs safety checks before every install. Nothing installs until you choose Update.

## Install

**With Homebrew:**

```sh
brew install --cask kasakir-ai/tap/update-workbench
```

Homebrew then keeps it up to date (`brew upgrade`), and Update Workbench updates itself through Homebrew too.

**Or download it:**

1. Download the latest `UpdateWorkbench-<version>.dmg` (or the `.zip`) from the [Releases page](https://github.com/Kasakir-AI/UpdateWorkbench/releases).
2. Open the DMG and drag **Update Workbench** into **Applications**.
3. Open **Update Workbench** from Applications. The download is signed with Developer ID and notarized by Apple.

Requires macOS 14 or newer on Apple silicon. Check the download against `SHA256SUMS` with `shasum -a 256 -c SHA256SUMS`.

**Updating:** from 0.5.0 on, Update Workbench updates itself. Choose **Update Workbench → Check for Updates…** (every check also looks), then **Update and Relaunch**. A copy installed with Homebrew is updated through Homebrew; a downloaded copy installs the new release only if it carries the developer's release signature. To move from 0.4.x to 0.5.0, quit Update Workbench, drag the new version into Applications and choose **Replace** (settings, rules and approvals are kept); you may need the right-click **Open** step once more.

**App Store updates (optional):** install the free `mas` tool with **Homebrew → Install mas…** (or `brew install mas` in Terminal) and stay signed in to the App Store app. When mas needs your Mac password to install an App Store update, click **Finish in Terminal** and type the password there. Update Workbench never sees it. You can also click **Open App Store Updates** and update in the App Store app.

## Build from source

Requires Xcode command-line tools.

```sh
./build.sh   # builds dist.noindex/UpdateWorkbench.app (ad-hoc signed)
./test.sh    # offline test suite (swift test); extra arguments go to swift test, e.g. --filter VersionOrderTests
./make-release.sh   # DMG, ZIP, SHA256SUMS and the signed appcast.xml in release/
```

Releases are signed with an Ed25519 release key kept in the developer's login Keychain (`xcrun swift tools/release-key.swift generate | public-key | sign FILE`). Only its public half is in the repository (`Resources/release-public-key.txt`); `build.sh` writes it into Info.plist as `SUPublicEDKey`, together with the feed address `SUFeedURL`. A build made with a different key can't update copies made with this one.

The version and build number are set once, at the top of `build.sh`. GitHub Actions runs `./test.sh` and `./build.sh` on every push to `main` and on pull requests.

Builds go to `dist.noindex/`. Spotlight skips folders whose names end in `.noindex`, so development builds, test fixtures and release staging never appear in Spotlight or Launchpad next to the copy in Applications.

## New in 0.5.1

- Developer ID signing and Apple notarization for direct downloads and Homebrew installs.

## New in 0.5.0

- **Updates itself.** Update Workbench checks for its own new versions with every check and from **Update Workbench → Check for Updates…**. **Update and Relaunch** installs the new version and restarts the app. Each release is signed with the developer's release key, and a download without that signature is never installed.
- **Install with Homebrew.** `brew install --cask kasakir-ai/tap/update-workbench`. When Homebrew installed it, Update Workbench updates itself through Homebrew.
- **A softer look.** Pastel colors throughout, in light and dark mode: the update summary, source and status badges, app tiles, the sidebar, cards and sheets.
- **Right-click an app** in any list to update, skip, snooze, ignore, open or show it in Finder.
- **Fixes.** Approving a new developer signature or accepting a license agreement right after an update now retries the install (it used to do nothing while the follow-up check ran). The History badge counts only apps whose last update failed, so it clears after a successful retry. Relaunching no longer quits the app if the new copy can't be opened.

## New in 0.4.1

- **Betas move on to the final release.** If you run a beta such as `1.0-beta.1`, the finished `1.0` is now offered. Before, it wasn't.
- **No more fake updates.** The same version written two ways (`2.0` and `2.0.0`) is no longer shown as an update.
- **Clearer GitHub limit message.** GitHub allows 60 checks an hour without an account. When that's reached, the app now says so and tells you when it resets.
- **Test copies stay out of Spotlight.** Development builds, test apps and half-finished updates are kept in folders Spotlight skips, so only the app in Applications shows up.

## New in 0.4.0

- **Signer changes you can review.** If an update is signed by a different developer team, Update Workbench stops and shows both teams with their certificate details. You can approve the new team for that one app after confirming; approvals are listed with dates in Settings → Trust and can be revoked. Code signing and Gatekeeper still have to pass.
- **DMG installs.** Disk images are attached read-only and hidden from Finder, license agreements are shown before mounting, exactly one matching app is copied out with the full set of checks, and the image is always detached.
- **History.** Every update attempt is logged in the History section with its result.
- **No leftover copies.** Installs swap the new version in, verify it, then delete the old one (or put it back if anything fails). Nothing is left in `/Applications`.
- **App Store with mas.** Install mas from the Homebrew menu, see App Store updates with the rest, and update them (with a Terminal hand-off when mas needs your password).
- **Menu bar and scheduled checks.** Check daily or weekly in the background, with optional notifications. The menu bar icon shows the update count and a quick list. Nothing installs automatically.
- **Release notes.** "What's new" is shown in the detail pane and before each update, sanitized and rendered as plain native text.
- **Rules.** Skip a version, ignore an app, or hold back betas globally or per app, all managed in Settings → Rules.
- **Fixes.** An app updated while Update Workbench was open no longer stays in the update list (versions are read fresh from disk), and a launch hang in an early 0.4.0 build is fixed.

## Interface (0.3.0)

- **Dark by default** with color accents. Settings → Appearance offers Dark (default), Light or System.
- **Simple main flow:** the Updates hero card says how many updates are waiting, with **Check for Updates** / **Update All** buttons. Each row that can be installed here has its own **Update** button. Every install still asks first.
- **Color-coded badges** for each source (Homebrew, Formula, App Store, Sparkle, GitHub, Electron, Vendor, Manual) and status (Update ready, Manual update, Updates itself, Snoozed, Version skipped, Ignored, Update failed, Up to date). Badges always include an icon and text, so color is never the only signal.
- **Detail pane in cards:** versions with the main action first, then update source, suggestions, details, app security, a collapsed *Custom update source* section, and a **Manage** card with red destructive actions behind confirmations. A **Later** menu groups skip, snooze and ignore.
- **Guided empty, loading and error states**, a status footer in the sidebar, sidebar count badges, tooltips, VoiceOver labels and a collapsible activity console.
- **Keyboard shortcuts:** ⌘R check, ⇧⌘U update all, ⇧⌘E export, ⌘1–⌘7 switch sections, ⌥⌘L show or hide the console, ⌘, Settings.
- On-screen paths under your home folder are shown with `~`.

## App icon

![App icon](Resources/AppIcon/AppIcon-1024.png)

An original icon drawn in code by `Resources/AppIcon/make-icon.swift`. `./build.sh` turns it into `AppIcon.icns`.

## Screenshots

Rendered with fictional apps and the built-in snapshot harness. They show no real inventory or personal data.

| Updates (dark) | Updates (light) |
| --- | --- |
| ![Updates in dark mode](docs/screenshots/updates-dark.png) | ![Updates in light mode](docs/screenshots/updates-light.png) |
| **Suggestions** | **Permissions** |
| ![Suggestions with Homebrew and GitHub matches](docs/screenshots/suggestions-dark.png) | ![Permissions overview](docs/screenshots/permissions-dark.png) |
| **First run** | **Settings → Appearance** |
| ![First run](docs/screenshots/first-run-dark.png) | ![Appearance settings](docs/screenshots/settings-appearance-dark.png) |
| **History** | **Release notes** |
| ![Update history](docs/screenshots/history-dark.png) | ![Release notes in the detail pane](docs/screenshots/release-notes-dark.png) |
| **New developer signature** | **Settings → Rules** |
| ![Signer approval sheet](docs/screenshots/signer-approval-dark.png) | ![Rules settings](docs/screenshots/settings-rules-dark.png) |
| **Menu bar** | **Settings → Trust** |
| ![Menu bar panel](docs/screenshots/menubar-dark.png) | ![Trust settings](docs/screenshots/settings-trust-dark.png) |
| **Update Workbench updates itself** | **Settings → Updates** |
| ![Self-update banner](docs/screenshots/self-update-light.png) | ![Update Workbench update settings](docs/screenshots/settings-updates-light.png) |

To render every screen yourself in dark and light (fake data, no scanning, nothing installed, real settings untouched):

```sh
./build.sh
dist.noindex/UpdateWorkbench.app/Contents/MacOS/UpdateWorkbench --render-snapshots /tmp/updateworkbench-snapshots
```

Running the app from `dist.noindex/` registers that copy with Launch Services again. Run `./build.sh` afterwards, or `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u dist.noindex/UpdateWorkbench.app`, so it doesn't appear next to the installed app.

## Available features

- Inventory `/Applications`, `~/Applications`, and additional folders configured in Settings.
- Check installed Homebrew casks and formulae, optional `mas` App Store CLI, HTTPS Sparkle appcasts, Electron apps that declare an electron-updater feed, and public GitHub repositories you select.
- Direct per-item updates and sequential Update All with console results. No Terminal automation or stored passwords.
- **Electron update feeds:** apps shipping `Contents/Resources/app-update.yml` (electron-updater `github`, `generic` or `s3` provider) are checked through the published `latest-mac.yml`. One native DMG (preferred) or ZIP is chosen per CPU; its published SHA-512 must match before the normal direct-install checks run. Private/token providers, missing checksums and ambiguous payloads fail closed (update shown, direct install disabled).
- **GitHub repository suggestions:** repositories found in an app's Electron update config, Sparkle feed URL, Info.plist URLs, or its Homebrew cask homepage/URL are listed as suggestions with their evidence. Nothing is used until you choose **Use…** and confirm.
- **Homebrew cask matching and adoption suggestions:** **Find Homebrew Matches** (Suggestions section or Homebrew menu) matches apps without a package-manager route to casks using `brew casks` and `brew info --json=v2 --cask` (read-only; no `brew update`). Matches need the cask's app artifact name; a matching bundle ID raises confidence to High. Disabled casks are excluded and deprecated ones flagged. **Adopt…** shows the exact `brew install --cask --adopt` command and runs only after confirmation. App Store apps are never suggested.
- **Homebrew management:** Reinstall (Repair), Uninstall (no `--zap`, user data kept) and Unpin (pinned formulae) for Homebrew items, each behind a confirmation that shows the command.
- **Move to Trash** for non-Homebrew app bundles, after confirmation. The bundle is moved to the Trash (never deleted); running apps, symlinks, macOS system apps and Update Workbench itself are refused.
- **Vendor-managed updaters:** apps updated by Microsoft AutoUpdate, Adobe Creative Cloud (or Acrobat's own updater), Google Software Update, Mozilla's built-in updater, Squirrel.Mac (Electron) or an undeclared Sparkle feed are labelled, with a button to open the vendor's updater or the app. Vendor protocols are not driven.
- **Permissions view:** read-only status for Full Disk Access (heuristic), App Management (no public query; guidance only), Automation (not used), notifications, administrator account, write access to each application folder, launch at login and Keychain, with System Settings links.
- **Proxy settings:** system, none or manual HTTP/HTTPS or SOCKS proxy for the app's own requests. Authentication passwords are stored only in the login Keychain (Security framework, service `local.updateworkbench.proxy`) and are answered on proxy challenges. Homebrew/mas receive the proxy host and port through `http_proxy`/`https_proxy`/`all_proxy`, never the password.
- **Notifications:** optional (Settings → General) banners for newly available updates (each version announced once) and for completed or failed updates.
- **Self-update:** every check, and **Check for Updates…** in the app menu, reads the `appcast.xml` of the latest GitHub release. The ZIP it points to must carry a valid Ed25519 signature from the release key built into the installed app (`SUPublicEDKey`), and the new app must ship the same key, have the same bundle ID and be newer. Then it is installed through the normal direct-install pipeline and the app relaunches. Copies installed with Homebrew are updated with `brew update` and `brew upgrade --cask update-workbench` instead. Settings → Updates shows how the app was installed and where updates come from.
- User-selected Homebrew adoption by cask token; catalog refresh; Homebrew diagnostics and cleanup.
- Rules (Settings → Rules): ignored apps, skipped versions, and pre-release holds (global, on by default, with per-app overrides); two/four-day snoozes. Pre-releases include versions such as `-beta.1`, `b2`, `rc1`, alpha, preview or nightly, Sparkle beta channels and GitHub pre-releases.
- Background checks Off, Daily or Weekly while the app runs (it stays in the menu bar), a menu bar icon with the update count and quick list, a Dock badge, launch at login, source filters, signature/Gatekeeper details, sanitized release notes, reveal/open actions, JSON inventory export.
- **Trusted signer approvals** (Settings → Trust) per bundle ID and team, stored in `~/Library/Application Support/Update Workbench/trusted-signers.json`, revocable anytime.
- **History** of every update attempt in `~/Library/Application Support/Update Workbench/history.json` (last 500). It's a log; previous versions aren't kept.
- **Mac App Store via mas:** `mas outdated --json` during checks, `mas update <id>` after confirmation, Homebrew → Install mas… when it's missing. Because mas installs with `sudo installer`, an update that needs your administrator password is handed to Terminal (**Finish in Terminal**) or the App Store app; Update Workbench never sees the password.
- Custom HTTPS feed and GitHub repository overrides keyed by bundle identifier or app path. GitHub payloads require an unambiguous native macOS ZIP/DMG; otherwise a release-page link supports manual installation. App-declared Sparkle archive signature requirements remain enforced.

Choose **Homebrew → Refresh Catalog** before checking for the newest Homebrew metadata. Routine checks and cask matching deliberately avoid implicit `brew update`. Homebrew installation is required for Homebrew operations; `mas` is optional and can be installed from the Homebrew menu. This app does not install dependencies automatically. App Store installs remain subject to Apple authentication and helper/OS compatibility. Homebrew or package installers needing an administrator password can fail; the app does not collect a password or silently elevate.

## Direct Sparkle, GitHub and Electron installs

Supports complete DMG/ZIP app payloads from public HTTPS appcasts, selected GitHub releases and declared Electron feeds. Downloads use HTTPS-only redirects and size limits. If the feed publishes a SHA-512 (Electron), it must match. If the installed app declares a Sparkle Ed25519 public key, its archive signature must verify before extraction. Apps without a Developer ID team (ad-hoc signed) can only be replaced this way: the archive must verify against the installed app's key and the new app must carry the same key; otherwise they are refused. The app also checks bundle ID, installed signing team, code signatures, Gatekeeper approval, version, and OS/CPU compatibility. Running apps must be closed first. The new app is staged in a private folder on the same volume (never beside the app), swapped in and verified; the previous version is deleted only after that succeeds and is put back if anything fails, so no copies are left behind. The scanner skips hidden and `*-backup-*` app bundles. A different signing team stops the install and asks you to review and approve that team for the app; Gatekeeper and code signing must still pass. DMGs are checked for encryption and license agreements, attached read-only with `-nobrowse -noautoopen`, must contain exactly one app with the expected bundle ID, are copied out with `ditto`, and are always detached. When a release offers both, the DMG is preferred over the ZIP. ZIPs may contain symbolic links, such as the `Versions/Current` framework links every Electron app ships, as long as each link is relative and stays inside its `.app` bundle. The ZIP directory is checked before anything is written: absolute or escaping link targets, entries below a link, path traversal, duplicates, encrypted entries and special files are rejected, and after extraction every link must resolve inside the bundle and hard links are refused. DMGs permit only bundle-internal links. Unsigned or unapproved different-team updates, encrypted disk images, protected destinations, PKG installers, deltas and unsupported payloads fail closed. Many GitHub-distributed Electron apps are unsigned or ad-hoc signed and will therefore fail closed by design.

## Validation status

No real application upgrades, installs, adoptions, reinstalls, uninstalls, unpins or Trash moves were executed during development. Offline tests (`./test.sh`) exercise discovery, serialization, process output handling, command deadlines, custom Homebrew destinations, appcast selection, archive signature validation, GitHub release selection, security report formatting, and the 0.2.0 additions: Electron config/metadata parsing and payload selection, SHA-512 verification, GitHub repository discovery, cask JSON parsing and matching, vendor updater detection, Homebrew action arguments and token rejection, Trash-move validation with a fake Trash, permission states, notification de-duplication and text, self-update feed parsing, proxy validation/dictionaries/challenge handling, and a Keychain round trip under a throwaway test service name.

0.3.0 interface checks: every screen (Updates hero, list and detail; Applications; Packages; Suggestions; Ignored; no-results, first-run, scanning and up-to-date states; console with a failed update; Permissions; all four Settings tabs) was rendered offscreen in dark and light with fake data and reviewed. That review found and fixed a layout bug where wrapped hero text inflated the window's minimum height to about 960–1300 pt, plus truncated buttons, duplicate actions, low-contrast light-mode badges and misleading status labels. The 0.3.0 bundle launched (window opened at its 1040×680 minimum) and was quit. Confirmation dialogs, menus and hover states can't be captured offscreen and were checked in code only. Capturing the live window with `screencapture` was refused because Screen Recording isn't granted, and no system settings were changed. Prominent buttons look grey in the offscreen renders because those windows are never key; they use the accent color in the running app.

0.4.0 checks: the new screens (History, signer approval sheet, update sheet with release notes, license sheet, Settings → General, Rules and Trust, and the menu bar panel) were rendered in dark and light and reviewed. The menu bar status item itself can't be rendered offscreen; its panel can. DMG installs were tested with fixture disk images built by `hdiutil`, and the published Invoke Community Edition 1.8.5 DMG was installed end to end into a temporary copy only (see `docs/validation.md`). The final build was installed in `/Applications` on the development Mac, stayed idle at about 0% CPU, and a read-only check of 267 apps and packages listed no stale updates and no hidden or backup copies. `mas outdated --json` was run read-only; no App Store update was installed.

A read-only smoke run on the development Mac found 80 apps (2 Electron feeds, 21 vendor-managed), checked both Electron feeds live (one real newer release with a native arm64 ZIP was identified, not installed), and produced Homebrew cask suggestions for 19 apps. The 0.2.0 bundle launched and was quit; GUI navigation of the new screens was not exercised by automation. GUI launch, navigation and a read-only scan of 267 apps and packages were verified for 0.1.0; see `docs/validation.md`.

Not end-to-end validated: actual vendor downloads and installs (Sparkle, GitHub, Electron), Homebrew installation/adoption/reinstall/uninstall/unpin, App Store installation, Trash moves of real apps, notification delivery, authenticated proxies, a self-update from the published feed (the first one will be 0.5.0 → 0.5.1), login registration and rollback under real failure conditions. Permission states other than write access and admin membership are heuristics.

0.5.0 checks: the redesigned screens and the new self-update banner and Settings → Updates tab were rendered in dark and light and reviewed. A self-update was installed end to end with the real `codesign` checks into a temporary copy: a 0.5.0 build was replaced by a re-signed 0.5.1 build from a ZIP signed with the release key, and the same ZIP with altered bytes was refused. Unit tests cover signed, unsigned, wrong-key, swapped-key and key-less archives and a Developer ID app offered a team-less update.

## Known limitations

- Squirrel.Mac Electron apps keep their update feed inside app code, so they are only labelled and opened; update.electronjs.org and vendor-specific endpoints are not probed.
- Vendor-managed updaters are opened, not driven; there is no in-app version check for Adobe, Microsoft, Google or Mozilla apps.
- Electron providers other than public `github`, `generic` and `s3` (for example private GitHub, Bitbucket, Keygen, custom), and differential (blockmap) downloads, are not supported.
- Cask matching uses app artifact names; apps whose bundle name differs from every cask artifact are not matched, and there is no automatic adoption.
- Background checks run only while Update Workbench is open (it keeps running in the menu bar); there is no separate background agent.
- Release notes are text only: images, tables and embedded media are dropped.
- `hdiutil attach` prints deprecation warnings on recent macOS versions; it still works and is used because it supports license agreements.
- Not yet available: separate app and package ignore lists and per-folder discovery settings.

Opening an unsupported app exposes its own updater. Custom feeds, suggestions and explicit Homebrew adoption cover some apps without a detected route. See `CHANGELOG.md` for changes and `docs/validation.md` for build and test records.

Primary implementation references: [Homebrew manpage](https://docs.brew.sh/Manpage), [electron-builder publish configuration](https://www.electron.build/publish), [Apple UserNotifications](https://developer.apple.com/documentation/usernotifications), [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services), [mas CLI](https://github.com/mas-cli/mas/blob/main/README.md), [Sparkle update publishing](https://sparkle-project.org/documentation/publishing/), [GitHub Releases API](https://docs.github.com/en/rest/releases/releases).

## Support

Update Workbench is free. If it helps you, you can [star the repo](https://github.com/Kasakir-AI/UpdateWorkbench), [buy me a coffee on Ko-fi](https://ko-fi.com/kasakir), or [sponsor on GitHub](https://github.com/sponsors/Kasakir-AI), once or monthly.

### Sponsors

<!-- sponsors:start -->
<!-- This section is updated automatically. Edits here are overwritten. -->

No sponsors featured here yet. [Become the first](https://github.com/sponsors/Kasakir-AI)!
All sponsors: [SPONSORS.md](https://github.com/Kasakir-AI/.github/blob/main/SPONSORS.md).
<!-- sponsors:end -->

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Kasakir-AI. The license covers this project's own code and assets only. Third-party app names and trademarks belong to their owners.
