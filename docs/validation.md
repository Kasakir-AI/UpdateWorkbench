# Validation records

These notes record what has been built, tested and observed on the development Mac. They are not a guarantee of behavior on other systems.

## Build and tests

- `./build.sh` builds an optimized arm64 release bundle (debug info disabled), writes `Info.plist`, adds the app icon and ad-hoc signs the bundle. `Info.plist` lint and local code-signature verification pass.
- `./test.sh` runs the offline suites: appcast selection and filtering, Ed25519 archive signature verification with tamper and wrong-key rejection, installed-bundle discovery, JSON round trips, literal process arguments, large stdout/stderr capture, command deadlines, rejected updates, GitHub stable releases and asset architecture or ambiguity, signature gating, security report formatting, validated Homebrew tokens and custom app-folder arguments, Electron feeds and SHA-512, repository discovery, cask matching, vendor updaters, Homebrew actions, Trash-move validation, permissions, notifications, self-update feeds, proxy settings, a Keychain round trip under a throwaway service name, and the presentation rules (dark default, status precedence, summary text, `~` paths).
- No real app updates, Homebrew adoptions or cleanups, App Store installs, uninstalls, Trash moves or login registrations were performed during development.

## Launch checks

- 0.1.0: the app was launched in the logged-in session. A read-only check completed in about four seconds and reported 267 apps and packages with no available updates. Navigation, the console, the source filter, source overrides and the Snooze menu were exercised without changing any settings. A Sparkle app's detail showed its installed version, bundle ID, feed URL and "No compatible newer release found", with Update disabled.
- Launching the bundle with `open` from a restricted, non-GUI shell can fail with Launch Services error `-10827` and an abort during application registration. That is a limitation of that shell context, not of the app; the same bundle launches normally in the logged-in session.
- 0.2.0: a read-only smoke run found 80 apps (2 Electron feeds, 21 vendor-managed), checked both Electron feeds live (one newer release with a native arm64 ZIP was identified, not installed) and produced Homebrew cask suggestions for 19 apps. The bundle launched and quit.
- 0.3.0 and 0.3.1: every screen was rendered offscreen in dark and light with fake data (`--render-snapshots`) and reviewed. The bundle launched with its window at the 1040×680 minimum and quit cleanly.

## Not validated end to end

Real Sparkle, GitHub and Electron downloads and installs; Homebrew installation, adoption, reinstall, uninstall and unpin; App Store installation; Trash moves of real apps; notification delivery; authenticated proxies; self-update installation; login registration; and rollback under real failures. Permission states other than write access and admin membership are estimates.
