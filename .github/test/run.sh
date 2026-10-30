#!/usr/bin/env bash
# Runs the addon's GUT tests (test/unit/) in CI (RN3). Builds the
# same minimal project the parse check uses, adds GUT, and runs
# gut_cmdln against res://addons/rollback_netcode/test/unit.
#
# GUT is pinned to the version hopnbop vendors (9.7.1, matched to
# Godot 4.7). bitwes/Gut publishes no release assets, so CI
# downloads the tag archive and takes its addons/gut. Locally,
# point GUT_SRC at a vendored addons/gut to skip the download:
#
#   GODOT=/path/to/godot GUT_SRC=/path/to/addons/gut \
#     bash .github/test/run.sh
set -uo pipefail

godot="${GODOT:-godot}"
gut_tag="v9.7.1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="$repo_root/.github/parse-check"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
project="$work/project"
addon="$project/addons/rollback_netcode"

mkdir -p "$addon"
cp -R "$harness/project.godot" "$harness/check_addon_scripts.gd" \
  "$harness/consumer_stubs" "$project/"
cp "$(dirname "${BASH_SOURCE[0]}")/pre_run.gd" "$project/"
tar -C "$repo_root" --exclude=./.git --exclude=./.github -cf - . \
  | tar -C "$addon" -xf -

if [ -n "${GUT_SRC:-}" ]; then
  cp -R "$GUT_SRC" "$project/addons/gut"
else
  curl -fsSL "https://github.com/bitwes/Gut/archive/refs/tags/$gut_tag.zip" \
    -o "$work/gut.zip"
  unzip -q "$work/gut.zip" -d "$work/gut-src"
  cp -R "$work/gut-src/Gut-${gut_tag#v}/addons/gut" "$project/addons/gut"
fi

# --import registers the class_names (GutTest among them); judge it
# by the class cache, as the parse check does.
"$godot" --headless --path "$project" --import >"$work/import.log" 2>&1
if ! grep -q '"GutTest"' "$project/.godot/global_script_class_cache.cfg" \
  2>/dev/null; then
  cat "$work/import.log"
  echo "::error::the import did not register GutTest"
  exit 1
fi

"$godot" --headless --path "$project" -s addons/gut/gut_cmdln.gd \
  -gdir=res://addons/rollback_netcode/test/unit -ginclude_subdirs \
  -gpre_run_script=res://pre_run.gd \
  -gexit 2>&1 | tee "$work/gut.log"
rc=${PIPESTATUS[0]}

# GUT exits 0 even when nothing ran, so the log's own verdict is
# the gate: every file passed, and the summary shows real tests.
if [ "$rc" -ne 0 ] || ! grep -q 'All tests passed' "$work/gut.log" \
  || grep -qE 'Failing Tests +[1-9]|Nothing was run' "$work/gut.log"; then
  echo "::error::the GUT run failed (Godot exit $rc); the log above says why"
  exit 1
fi
grep -E 'Tests +[0-9]+|Passing Tests' "$work/gut.log" | tail -2
echo "gut-tests: OK"
