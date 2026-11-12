#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/updateworkbench-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
# Normalized path (TMPDIR ends in "/"), so fixture paths compare exactly.
test_root="$(cd "$test_root" && pwd)"
# Fixture apps are created under TMPDIR; a .noindex folder keeps them out of Spotlight and Launch Services.
test_work_dir="$test_root/work.noindex"
mkdir -p "$test_work_dir/module-cache" "$test_work_dir/tmp"
export TMPDIR="$test_work_dir/tmp/" UW_TEST_TMP="$test_work_dir/tmp"
# All backend sources; App.swift and AppServices.swift contain the SwiftUI entry point and UserNotifications calls.
backend_sources="Sources/UpdateWorkbench/Core.swift
Sources/UpdateWorkbench/SparkleBackend.swift
Sources/UpdateWorkbench/ArchiveSafety.swift
Sources/UpdateWorkbench/DiskImage.swift
Sources/UpdateWorkbench/TrustedSigners.swift
Sources/UpdateWorkbench/UpdateHistory.swift
Sources/UpdateWorkbench/Rules.swift
Sources/UpdateWorkbench/ReleaseNotes.swift
Sources/UpdateWorkbench/AppStoreCLI.swift
Sources/UpdateWorkbench/GitHubBackend.swift
Sources/UpdateWorkbench/SecurityBackend.swift
Sources/UpdateWorkbench/NetworkSettings.swift
Sources/UpdateWorkbench/ElectronBackend.swift
Sources/UpdateWorkbench/Discovery.swift
Sources/UpdateWorkbench/Maintenance.swift
Sources/UpdateWorkbench/Presentation.swift"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$test_work_dir/module-cache" \
  $backend_sources \
  Tests/GitHubTests.swift \
  Tests/FeatureTests.swift \
  Tests/BackendTests.swift \
  Tests/PresentationTests.swift \
  Tests/ArchiveSafetyTests.swift \
  Tests/WorkflowTests.swift \
  Tests/DiskImageTests.swift \
  -o "$test_work_dir/backend-tests"
"$test_work_dir/backend-tests"

for fixture in SecurityBackendTests; do
    # shellcheck disable=SC2086
    xcrun swiftc -swift-version 6 -parse-as-library \
      -module-cache-path "$test_work_dir/module-cache" \
      $backend_sources \
      "Tests/$fixture.swift" -o "$test_work_dir/$fixture"
    "$test_work_dir/$fixture"
done
