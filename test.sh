#!/bin/sh
# Runs the offline test suites with `swift test`. Extra arguments are passed through,
# for example `./test.sh --filter VersionOrderTests`.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/updateworkbench-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
# Normalized path (TMPDIR ends in "/"), so fixture paths compare exactly.
test_root="$(cd "$test_root" && pwd)"
# Fixture apps are created under TMPDIR; a .noindex folder keeps them out of Spotlight and Launch Services.
test_work_dir="$test_root/work.noindex"
mkdir -p "$test_work_dir/tmp"
export TMPDIR="$test_work_dir/tmp/" UW_TEST_TMP="$test_work_dir/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache"
swift test --scratch-path "$PWD/.build" --disable-sandbox "$@"
