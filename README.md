# Update Workbench

Update Workbench is a native macOS app that finds and installs updates for your apps and command-line tools. It covers Homebrew, the Mac App Store (through `mas`), Sparkle feeds, Electron apps and GitHub releases, and runs safety checks before every install. Nothing installs until you choose Update.

## Install

1. Download `UpdateWorkbench-0.3.1.dmg` (or the `.zip`) from the [Releases page](https://github.com/Kasakir-AI/UpdateWorkbench/releases).
2. Open the DMG and drag **Update Workbench** into **Applications**.
3. **First launch:** the app is ad-hoc signed and not notarized by Apple, so macOS blocks a normal double-click the first time. Right-click (or Control-click) the app in Applications and choose **Open**, then **Open** again. Or try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. After that it opens normally.

Requires macOS 14 or newer on Apple silicon. Check the download against `SHA256SUMS` with `shasum -a 256 -c SHA256SUMS`.

## Build from source

Requires Xcode command-line tools.

```sh
./build.sh   # builds dist/UpdateWorkbench.app (ad-hoc signed)
./test.sh    # offline test suite
./make-release.sh   # DMG, ZIP and SHA256SUMS in release/
```

## Interface (0.3.0)

- **Dark by default** with color accents. Settings → Appearance offers Dark (default), Light or System.
- **Simple main flow:** the Updates hero card says how many updates are waiting, with **Check for Updates** / **Update All** buttons. Each row that can be installed here has its own **Update** button. Every install still asks first.
- **Color-coded badges** for each source (Homebrew, Formula, App Store, Sparkle, GitHub, Electron, Vendor, Manual) and status (Update ready, Manual update, Updates itself, Snoozed, Version skipped, Ignored, Update failed, Up to date). Badges always include an icon and text, so color is never the only signal.
- **Detail pane in cards:** versions with the main action first, then update source, suggestions, details, app security, a collapsed *Custom update source* section, and a **Manage** card with red destructive actions behind confirmations. A **Later** menu groups skip, snooze and ignore.
- **Guided empty, loading and error states**, a status footer in the sidebar, sidebar count badges, tooltips, VoiceOver labels and a collapsible activity console.
- **Keyboard shortcuts:** ⌘R check, ⇧⌘U update all, ⇧⌘E export, ⌘1–⌘6 switch sections, ⌥⌘L show or hide the console, ⌘, Settings.
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

To render every screen yourself in dark and light (fake data, no scanning, nothing installed, real settings untouched):

```sh
./build.sh
dist/UpdateWorkbench.app/Contents/MacOS/UpdateWorkbench --render-snapshots /tmp/updateworkbench-snapshots
```

## Available features

- Inventory `/Applications`, `~/Applications`, and additional folders configured in Settings.
- Check installed Homebrew casks and formulae, optional `mas` App Store CLI, HTTPS Sparkle appcasts, Electron apps that declare an electron-updater feed, and public GitHub repositories you select.
- Direct per-item updates and sequential Update All with console results. No Terminal automation or stored passwords.
- **Electron update feeds:** apps shipping `Contents/Resources/app-update.yml` (electron-updater `github`, `generic` or `s3` provider) are checked through the published `latest-mac.yml`. One native ZIP (preferred) or DMG is chosen per CPU; its published SHA-512 must match before the normal direct-install checks run. Private/token providers, prereleases for stable installs, missing checksums and ambiguous payloads fail closed (update shown, direct install disabled).
- **GitHub repository suggestions:** repositories found in an app's Electron update config, Sparkle feed URL, Info.plist URLs, or its Homebrew cask homepage/URL are listed as suggestions with their evidence. Nothing is used until you choose **Use…** and confirm.
- **Homebrew cask matching and adoption suggestions:** **Find Homebrew Matches** (Suggestions section or Homebrew menu) matches apps without a package-manager route to casks using `brew casks` and `brew info --json=v2 --cask` (read-only; no `brew update`). Matches need the cask's app artifact name; a matching bundle ID raises confidence to High. Disabled casks are excluded and deprecated ones flagged. **Adopt…** shows the exact `brew install --cask --adopt` command and runs only after confirmation. App Store apps are never suggested.
- **Homebrew management:** Reinstall (Repair), Uninstall (no `--zap`, user data kept) and Unpin (pinned formulae) for Homebrew items, each behind a confirmation that shows the command.
- **Move to Trash** for non-Homebrew app bundles, after confirmation. The bundle is moved to the Trash (never deleted); running apps, symlinks, macOS system apps and Update Workbench itself are refused.
- **Vendor-managed updaters:** apps updated by Microsoft AutoUpdate, Adobe Creative Cloud (or Acrobat's own updater), Google Software Update, Mozilla's built-in updater, Squirrel.Mac (Electron) or an undeclared Sparkle feed are labelled, with a button to open the vendor's updater or the app. Vendor protocols are not driven.
- **Permissions view:** read-only status for Full Disk Access (heuristic), App Management (no public query; guidance only), Automation (not used), notifications, administrator account, write access to each application folder, launch at login and Keychain, with System Settings links.
- **Proxy settings:** system, none or manual HTTP/HTTPS or SOCKS proxy for the app's own requests. Authentication passwords are stored only in the login Keychain (Security framework, service `local.updateworkbench.proxy`) and are answered on proxy challenges. Homebrew/mas receive the proxy host and port through `http_proxy`/`https_proxy`/`all_proxy`, never the password.
- **Notifications:** optional (Settings → General) banners for newly available updates (each version announced once) and for completed or failed updates.
- **Self-update:** Settings → Updates accepts `github:owner/repository`, a GitHub repository URL, or an HTTPS Sparkle appcast. It is **disabled by default** because no release feed is published. Installation reuses the verified direct-install pipeline, so a release must match the bundle ID and Developer ID team; the ad-hoc development build cannot self-update.
- User-selected Homebrew adoption by cask token; catalog refresh; Homebrew diagnostics and cleanup.
- Persistent app ignores, two/four-day snoozes, and version skips; manual, hourly, four-hourly, or daily checks while running.
- Menu bar controls, launch at login, source filters, signature/Gatekeeper details, release-note links, reveal/open actions, JSON inventory export.
- Custom HTTPS feed and GitHub repository overrides keyed by bundle identifier or app path. GitHub payloads require an unambiguous native macOS ZIP/DMG; otherwise a release-page link supports manual installation. App-declared Sparkle archive signature requirements remain enforced.

Choose **Homebrew → Refresh Catalog** before checking for the newest Homebrew metadata. Routine checks and cask matching deliberately avoid implicit `brew update`. Homebrew installation is required for Homebrew operations; `mas` is optional and was not found on the development Mac. This app does not install dependencies automatically. App Store installs remain subject to Apple authentication and helper/OS compatibility. Homebrew or package installers needing an administrator password can fail; the app does not collect a password or silently elevate.

## Direct Sparkle, GitHub and Electron installs

Supports complete ZIP/DMG app payloads from public HTTPS appcasts, selected GitHub releases and declared Electron feeds. Downloads use HTTPS-only redirects and size limits. If the feed publishes a SHA-512 (Electron), it must match. If the installed app declares a Sparkle Ed25519 public key, its archive signature must verify before extraction. The app also checks bundle ID, installed signing team, code signatures, Gatekeeper approval, version, and OS/CPU compatibility. Running apps must be closed first. Replacement uses staging and rollback; a hidden backup beside the app is retained and its path is logged. ZIPs containing symlinks are rejected before extraction; DMGs permit only bundle-internal links. Unsigned/different-team updates, protected destinations, PKG installers, deltas and unsupported payloads fail closed. Many GitHub-distributed Electron apps are unsigned or ad-hoc signed and will therefore fail closed by design.

## Validation status

No real application upgrades, installs, adoptions, reinstalls, uninstalls, unpins or Trash moves were executed during development. Offline tests (`./test.sh`) exercise discovery, serialization, process output handling, command deadlines, custom Homebrew destinations, appcast selection, archive signature validation, GitHub release selection, security report formatting, and the 0.2.0 additions: Electron config/metadata parsing and payload selection, SHA-512 verification, GitHub repository discovery, cask JSON parsing and matching, vendor updater detection, Homebrew action arguments and token rejection, Trash-move validation with a fake Trash, permission states, notification de-duplication and text, self-update feed parsing, proxy validation/dictionaries/challenge handling, and a Keychain round trip under a throwaway test service name.

0.3.0 interface checks: every screen (Updates hero, list and detail; Applications; Packages; Suggestions; Ignored; no-results, first-run, scanning and up-to-date states; console with a failed update; Permissions; all four Settings tabs) was rendered offscreen in dark and light with fake data and reviewed. That review found and fixed a layout bug where wrapped hero text inflated the window's minimum height to about 960–1300 pt, plus truncated buttons, duplicate actions, low-contrast light-mode badges and misleading status labels. The 0.3.0 bundle launched (window opened at its 1040×680 minimum) and was quit. Confirmation dialogs, menus and hover states can't be captured offscreen and were checked in code only. Capturing the live window with `screencapture` was refused because Screen Recording isn't granted, and no system settings were changed. Prominent buttons look grey in the offscreen renders because those windows are never key; they use the accent color in the running app.

A read-only smoke run on the development Mac found 80 apps (2 Electron feeds, 21 vendor-managed), checked both Electron feeds live (one real newer release with a native arm64 ZIP was identified, not installed), and produced Homebrew cask suggestions for 19 apps. The 0.2.0 bundle launched and was quit; GUI navigation of the new screens was not exercised by automation. GUI launch, navigation and a read-only scan of 267 apps and packages were verified for 0.1.0; see `docs/validation.md`.

Not end-to-end validated: actual vendor downloads and installs (Sparkle, GitHub, Electron), Homebrew installation/adoption/reinstall/uninstall/unpin, App Store installation, Trash moves of real apps, notification delivery, authenticated proxies, self-update installation, login registration and rollback under real failure conditions. Permission states other than write access and admin membership are heuristics.

## Known limitations

- Squirrel.Mac Electron apps keep their update feed inside app code, so they are only labelled and opened; update.electronjs.org and vendor-specific endpoints are not probed.
- Vendor-managed updaters are opened, not driven; there is no in-app version check for Adobe, Microsoft, Google or Mozilla apps.
- Electron providers other than public `github`, `generic` and `s3` (for example private GitHub, Bitbucket, Keygen, custom), and differential (blockmap) downloads, are not supported.
- Cask matching uses app artifact names; apps whose bundle name differs from every cask artifact are not matched, and there is no automatic adoption.
- No published self-update feed or Developer ID signing and notarization yet.
- Not yet available: full release-note rendering, a Dock badge, separate app and package ignore lists, and per-folder discovery settings.

Opening an unsupported app exposes its own updater. Custom feeds, suggestions and explicit Homebrew adoption cover some apps without a detected route. See `CHANGELOG.md` for changes and `docs/validation.md` for build and test records.

Primary implementation references: [Homebrew manpage](https://docs.brew.sh/Manpage), [electron-builder publish configuration](https://www.electron.build/publish), [Apple UserNotifications](https://developer.apple.com/documentation/usernotifications), [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services), [mas CLI](https://github.com/mas-cli/mas/blob/main/README.md), [Sparkle update publishing](https://sparkle-project.org/documentation/publishing/), [GitHub Releases API](https://docs.github.com/en/rest/releases/releases).

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 kasakir-ai. The license covers this project's own code and assets only. Third-party app names and trademarks belong to their owners.
