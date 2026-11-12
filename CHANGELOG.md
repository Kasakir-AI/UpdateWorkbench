# Changelog

## 0.4.0 — 2026-11-12

- **Trusted signer changes.** When an update is signed by a different Developer ID team, the install stops and a sheet shows both teams side by side: signer name, team ID, certificate type and chain, signing time, certificate expiry and SHA-256 fingerprint, plus the codesign, Gatekeeper and bundle ID results. Code signing and Gatekeeper are checked *before* the question is asked, so a broken or rejected download is never offered for approval. Approving needs a confirmation checkbox and covers only that app (bundle ID) and that new team. Approvals are stored with timestamps in `~/Library/Application Support/Update Workbench/trusted-signers.json` (owner-only) and can be reviewed and revoked in Settings → Trust. Nothing is approved automatically, and the app's own self-update never uses approvals.
- **Full DMG install path.** DMGs are checked for encryption and a license agreement (read from the image's resources without mounting). A license is shown in a sheet and the image is attached only after you click Agree. Images are attached read-only with `-nobrowse -noautoopen` at a private mount point, the mount is verified, and the image is always detached, including on errors (with retries, then `-force`). Exactly one app with the expected bundle ID must be inside (other apps and the `Applications` link are ignored; zero or several matches are refused). The same checks as the ZIP path run, then the app is copied with `ditto` into a private staging folder on the same volume, re-verified, and swapped in.
- **No copies of previous versions.** Installs never leave hidden copies in `/Applications` or next to apps. The new app is staged in a private replacement folder on the same volume (not beside the app), the installed app is moved there only for the swap, the new app is moved into place and verified (version, bundle ID, code signature and team), and only then is the previous version deleted. If anything fails, the previous version is put back. The scanner skips any leftover hidden (`.Name.app`) or `*-backup-*.app` bundle.
- **Update history.** Every update attempt is logged (app, from/to version, source, result, message, time) in `history.json` and listed in a new History section with summary tiles. History is a log only; there is no restore, because previous versions aren't kept.
- **Mac App Store through mas.** Homebrew → Install mas… (or the App Store item's detail) installs mas with `brew install mas` after confirmation. Checks run `mas outdated --json` alongside the Homebrew check; results are matched to installed apps by path, bundle ID, then name. **Update** runs `mas update <id>` after the usual confirmation and is logged in History. Not-signed-in, network and other mas errors are explained in plain words; when an App Store lookup times out, the App Store items say the check could not finish this time. mas installs App Store updates with `sudo installer`, which needs a password typed in a terminal, so when it asks for one the detail pane offers **Finish in Terminal** (opens Terminal running only `mas update <id>`) and **Open App Store Updates**.
- **Background checks and a menu bar icon.** Settings → General: check Off, Daily or Weekly (replaces the hourly/4-hourly/daily interval; old settings are migrated), notifications, show the menu bar icon, launch at login. The menu bar icon shows the number of updates and opens a panel with the update list, Check Now, Open Update Workbench and Settings. The Dock icon shows the same count. Checks only look; nothing installs without your confirmation.
- **Release notes in the app.** The detail pane and the update confirmation sheet show "What's new" from the Sparkle `description`, the Sparkle `releaseNotesLink` (HTTPS only, at most 1 MB, fetched when you open the item), the Electron `releaseNotes` or the GitHub release body. Notes are sanitized: scripts, styles, frames, forms and embedded content are removed with their contents, tags are stripped, entities decoded, images dropped and only HTTPS links stay clickable. They render as native text (headings, bullets, bold, links); no web view and no remote JavaScript.
- **Ignore and skip rules.** Skip a version, ignore an app, and hold back pre-releases and betas globally (on by default) or per app (Follow global, Always hold, Allow betas). Allowing betas also lets Sparkle beta channels and GitHub pre-releases through. Settings → Rules lists every rule with a badge, lets you change or remove it, add a rule for any app, or reset all. Held-back betas appear in Ignored with a "Pre-release held" badge.
- The update confirmation now opens as a sheet with the release notes and the checks that will run.
- Tests: `Tests/WorkflowTests.swift` (rules, schedules, release-note sanitizing and feed notes, pre-release selection, signer parsing and approval store, history persistence, scanner freshness and skipped copies, mas output parsing, matching and errors) and `Tests/DiskImageTests.swift`, which builds fixture DMGs with `hdiutil` (good, wrong team, approved team, several matching apps, broken signature, Gatekeeper rejection, version and checksum mismatch, license agreement, rollback after a failed post-install check) and checks that every image is detached and nothing is left beside the app.
- Fixed a launch hang in the first 0.4.0 build: the menu bar item writes its visibility setting back on every update, and publishing those unchanged writes re-rendered every window, which wrote it again in an endless loop on the main thread. The setting now publishes only real changes. App icons are cached per path and pre-release patterns are compiled once, so drawing the lists is cheaper.
- Fixed an update that kept being offered after it was installed (seen with Invoke Community Edition 1.8.5): the scanner read versions through `Bundle`, which caches an app's Info.plist for the life of the process, so rescans still saw 1.8.1 and a retry failed with "not newer than the installed app". Info.plist is now read from disk on every check, and a successful install also removes the item from the list right away.
- Upgrading from 0.3.x: replace the app in Applications; settings, rules and history carry over. The backup retention setting from early 0.4.0 test builds is no longer used.
- Version 0.4.0 (build 6).

## 0.3.2 — 2026-11-11

- Direct installs now accept ZIPs with symbolic links. Electron apps (for example Invoke Community Edition) ship framework links such as `Versions/Current -> A`, and earlier versions refused every such ZIP with "This ZIP contains symbolic links".
- New `ArchiveSafety.swift` reads the ZIP's central directory, including each link's target, before anything is extracted. It rejects absolute targets, targets that leave the `.app` bundle, links outside any app bundle, entries that would be written through a link, path traversal, case-folded duplicates, encrypted entries, special files and archives that expand past 4 GB. Rejections say which entry was unsafe and suggest the app's own updater or its DMG.
- After extraction (`ditto -x -k` into an empty folder) every link must be relative and resolve inside the bundle; broken links and hard links are refused. Bundle ID, signing team, codesign, Gatekeeper, version and CPU checks, backup and rollback are unchanged.
- Electron feeds and GitHub releases now prefer a single native DMG over a ZIP; the ZIP is used when no DMG is offered. Several DMGs or several ZIPs still mean a manual choice.
- A signing-team mismatch now names both team IDs and points to the vendor's updater.
- Tests: `Tests/ArchiveSafetyTests.swift` builds fixture ZIPs with `zip -y` and `ditto` (nested framework layout accepted; absolute, escaping, write-through, hard and broken links rejected) and covers DMG preference.
- Version 0.3.2 (build 5).

## 0.3.1 — 2026-11-11

- New original app icon: a rounded square in the app's indigo → violet → pink gradient with refresh arrows around a down arrow, plus a simpler ring-and-arrow version for 16 and 32 px. It's generated by `Resources/AppIcon/make-icon.swift` (Core Graphics); `build.sh` builds `AppIcon.icns` with `iconutil` and sets `CFBundleIconFile`. The sidebar header shows the icon, name and version.
- Added the MIT license (`LICENSE`, Copyright (c) 2026 kasakir-ai) and a License section in the README.
- Release downloads: drag-to-Applications DMG, ZIP and SHA256SUMS. README now has Install and first-launch steps (the app is ad-hoc signed, not notarized).
- Docs: build and test records moved to `docs/validation.md`; the README now describes the app on its own.
- Version 0.3.1 (build 4).

## 0.3.0 — 2026-11-11

Interface redesign. Install, Homebrew, Trash, network and permission behavior is unchanged.

- Dark appearance by default, with Settings → Appearance (Dark (default) / Light / System) stored as `appearance`.
- Accent gradient and color splashes: an Updates hero card with update counts and **Update All**, summary stat tiles, colored sidebar symbols with count badges, colored source and status badges (icon and text, not color alone), and app icons or colored initial tiles.
- Clearer flow: Check → see updates → update one (per-row **Update**) or all. Every install still asks for confirmation first.
- Detail pane rebuilt as cards: version comparison and main action, update source, suggestions (shown first for apps without a route), details, app security, a collapsible custom update source section and a red **Manage** card. A **Later** menu groups skip, snooze and ignore.
- New statuses: Update failed (kept per item after a failed update), Manual update, Updates itself (vendor-managed), Snoozed, Version skipped, Ignored, Up to date, No update source.
- Guided empty, loading and no-results states; status footer; styled activity console that auto-scrolls and opens on failures.
- Menu commands and shortcuts: ⌘R, ⇧⌘U, ⇧⌘E, ⌘1–⌘6, ⌥⌘L.
- Settings use grouped forms. The Network tab shows save status. Resetting ignored, skipped and snoozed items now asks for confirmation.
- Permissions shown as cards with inline System Settings links and a help pane; home-folder paths are shown with `~`.
- Fixed: hero text wrapping inflated the window's minimum height to about 960–1300 pt; truncated header buttons; duplicate vendor and first-run buttons; low-contrast light-mode badges; a green check shown before any scan.
- Added `--render-snapshots <folder>` to render all screens with fake data in dark and light (volatile defaults; no scans or system changes). README screenshots live in `docs/screenshots/`.
- Added `Presentation.swift` (appearance default, status precedence, hero copy, path abbreviation) with offline tests in `Tests/PresentationTests.swift`.
- Version 0.3.0 (build 3). Network requests send `UpdateWorkbench/0.3.0`.

## 0.2.0 — 2026-11-11

Added (public formats only):

- Electron update feeds: reads electron-updater `app-update.yml` (public `github`, `generic`, `s3` providers), parses `latest-mac.yml`, selects one native ZIP/DMG, verifies its SHA-512, then uses the existing direct-install checks (bundle ID, signing team, code signature, Gatekeeper, version, CPU, rollback).
- SHA-512 verification of downloads whenever a feed publishes a checksum.
- GitHub repository suggestions from Electron configs, Sparkle feed URLs, Info.plist URLs and Homebrew cask homepage/URL, applied only after confirmation.
- Homebrew cask matching for apps without a package-manager route (read-only `brew casks` / `brew info --json=v2 --cask`), with confidence, evidence and confirmed adoption.
- Homebrew Reinstall (Repair), Uninstall and Unpin with confirmation dialogs; Move to Trash for non-Homebrew apps (never permanent deletion).
- Vendor-managed updater detection (Microsoft AutoUpdate, Adobe Creative Cloud/Acrobat, Google Software Update, Mozilla, Squirrel.Mac, undeclared Sparkle) with a button to open the vendor updater or app.
- Permissions view with read-only status and System Settings links.
- Proxy settings (system, none, manual HTTP/HTTPS or SOCKS) with authentication passwords in the login Keychain.
- Optional notifications for new updates and completed/failed updates.
- Configurable self-update from GitHub Releases or an HTTPS appcast (disabled by default; no feed is published).
- Suggestions and Permissions sidebar sections; tabbed Settings (General, Network, Updates).

Changed:

- Version 0.2.0 (build 2). Network requests send `UpdateWorkbench/0.2.0`.
- Homebrew formula pin state is shown.
- `test.sh` compiles every backend source and runs the new offline feature tests.

Not validated end to end: real installs, adoptions, reinstalls, uninstalls, Trash moves, notifications, authenticated proxies and self-update. See README.

## 0.1.0

- Initial native implementation: inventory, Homebrew, mas, Sparkle and explicit GitHub sources, verified direct installs, ignore/skip/snooze, scheduling, menu bar, security inspection and export.
