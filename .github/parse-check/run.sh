#!/usr/bin/env bash
# Fails if any GDScript file the addon ships has a parse or compile
# error. CI runs it (.github/workflows/parse-check.yml). To run it
# locally, from the repo root:
#
#   GODOT=/path/to/godot bash .github/parse-check/run.sh
#
# Godot compiles a script only inside a project, so this builds one in
# a temp dir: this directory's project.godot, check_addon_scripts.gd
# and consumer_stubs/, plus the working tree at addons/rollback_netcode/,
# where consuming games put it. It imports the project, which registers
# the class_names, then runs check_addon_scripts.gd, which loads every
# addon script outside examples/ and test/ and judges the result.
set -uo pipefail

godot="${GODOT:-godot}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="$repo_root/.github/parse-check"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
project="$work/project"
addon="$project/addons/rollback_netcode"

mkdir -p "$addon"
cp -R "$harness/project.godot" "$harness/check_addon_scripts.gd" \
  "$harness/consumer_stubs" "$project/"
tar -C "$repo_root" --exclude=./.git --exclude=./.github -cf - . \
  | tar -C "$addon" -xf -

# Counted from the repo, not the copy, so a short copy fails the check.
expected=$(find "$repo_root" \
  \( -path "$repo_root/.git" -o -path "$repo_root/.github" \
  -o -path "$repo_root/examples" -o -path "$repo_root/test" \) -prune \
  -o -type f -name '*.gd' -print | wc -l | tr -d ' ')

# --import exits non-zero on harmless warnings, so only a crash (exit
# 128 and up) counts against it, and only after three tries. Whether
# class_names registered is the real test of the import.
attempts=3
for attempt in $(seq 1 "$attempts"); do
  "$godot" --headless --path "$project" --import >"$work/import.log" 2>&1
  rc=$?
  if [ "$rc" -lt 128 ]; then
    break
  fi
  echo "::warning::godot --import died with exit $rc (attempt $attempt of $attempts)"
  if [ "$attempt" -eq "$attempts" ]; then
    cat "$work/import.log"
    echo "::error::godot --import crashed $attempts times in a row"
    exit 1
  fi
done
if ! grep -q '"NetworkOrchestrator"' \
  "$project/.godot/global_script_class_cache.cfg" 2>/dev/null; then
  cat "$work/import.log"
  echo "::error::the import did not register the addon's class_names"
  exit 1
fi

"$godot" --headless --path "$project" -s check_addon_scripts.gd \
  -- --expected-scripts="$expected" 2>&1 | tee "$work/check.log"
rc=${PIPESTATUS[0]}

# The script's own verdict, plus two guards against it not having run
# to the end: its OK line, and any script error Godot printed anyway.
if [ "$rc" -ne 0 ] || ! grep -q '^parse-check: OK' "$work/check.log" \
  || grep -qE 'SCRIPT ERROR|Parse Error|Compile Error' "$work/check.log"; then
  echo "::error::the parse check failed (Godot exit $rc); the log above says why"
  exit 1
fi
