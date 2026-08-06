#!/bin/bash
# Exercises only fail-closed RunCat migration paths in a temporary home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT
export HOME="$TEMP_ROOT/home"
mkdir -p "$HOME/Applications"

# shellcheck source=../../scripts/runcat-migration.sh
RUNCAT_REMOVER="$TEMP_ROOT/runcat-safe-remove"
source "$ROOT/scripts/runcat-migration.sh"

assert_contains() {
    local output=$1 expected=$2
    [[ "$output" == *"$expected"* ]] || {
        printf 'Expected output to contain: %s\nActual output: %s\n' "$expected" "$output" >&2
        exit 1
    }
}

# A discovery result with no candidates must be a successful no-op.
runcat_discover() {
    RUNCAT_CANDIDATES=()
}
output="$(runcat_migrate)"
assert_contains "$output" 'no verified archived-identity RunCat bundle found.'

# An arbitrary bundle-shaped directory must fail identity verification before any mutation.
mismatch="$HOME/Applications/NotRunCat.app"
mkdir -p "$mismatch/Contents"
cat > "$mismatch/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.not-runcat</string></dict></plist>
PLIST
if runcat_verified_candidate "$mismatch"; then
    printf 'A mismatched bundle was accepted.\n' >&2
    exit 1
fi
[[ -d "$mismatch" ]] || { printf 'Mismatch fixture was changed.\n' >&2; exit 1; }

# A candidate presented on non-interactive input must be declined and preserved.
runcat_discover() {
    RUNCAT_CANDIDATES=("$mismatch")
}
output="$(printf 'no\n' | runcat_migrate)"
assert_contains "$output" 'declined because standard input is not interactive.'
[[ -d "$mismatch" ]] || { printf 'Declined candidate was changed.\n' >&2; exit 1; }

# The native remover must restore the same object when post-quarantine signing identity fails.
remover="$TEMP_ROOT/runcat-safe-remove"
clang -O0 -Wall -Wextra -target arm64-apple-macosx13.0 \
    -o "$remover" "$ROOT/src/runcat-safe-remove.c"
candidate="$HOME/Applications/RunCat.app"
mkdir -p "$candidate/Contents/MacOS"
cp /usr/bin/true "$candidate/Contents/MacOS/RunCat"
cat > "$candidate/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kyome.runcat.menubar</string>
<key>CFBundleExecutable</key><string>RunCat</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$candidate"
device="$(stat -f '%d' "$candidate")"
inode="$(stat -f '%i' "$candidate")"
approved_root="$(cd "$HOME/Applications" && pwd -P)"
quarantine="$approved_root/.RunCat-quarantine"
set +e
"$remover" \
    --root "$approved_root" \
    --candidate "$candidate" \
    --expected-device "$device" \
    --expected-inode "$inode" \
    --quarantine "$quarantine" \
    --bundle-id com.kyome.runcat.menubar \
    --team-id VJ5N2X84K8
remove_status=$?
set -e
[[ "$remove_status" -ne 0 ]] || { printf 'Wrong signing identity was deleted.\n' >&2; exit 1; }
[[ -d "$candidate" ]] || { printf 'Mismatched quarantined object was not restored.\n' >&2; exit 1; }
[[ ! -e "$quarantine" ]] || { printf 'Unexpected quarantine remained after safe restoration.\n' >&2; exit 1; }
control_path="$HOME/Applications/RunCat"$'\n'"Spoof.app"
if runcat_plain_path "$control_path"; then
    printf 'Control-character path was accepted.\n' >&2
    exit 1
fi

# Removal must refuse to run at all when the built remover is unavailable.
RUNCAT_REMOVER="$TEMP_ROOT/missing-remover"
if runcat_remove_candidate "$candidate"; then
    printf 'Removal ran without the native remover.\n' >&2
    exit 1
fi
[[ -d "$candidate" ]] || { printf 'Candidate changed without the native remover.\n' >&2; exit 1; }
RUNCAT_REMOVER="$remover"

# A candidate outside the two approved roots must be refused.
outside="$TEMP_ROOT/Outside.app"
mkdir -p "$outside"
set +e
"$remover" \
    --root "$approved_root" \
    --candidate "$outside" \
    --expected-device "$(stat -f '%d' "$outside")" \
    --expected-inode "$(stat -f '%i' "$outside")" \
    --quarantine "$approved_root/.Outside-quarantine" \
    --bundle-id com.kyome.runcat.menubar \
    --team-id VJ5N2X84K8
outside_status=$?
set -e
[[ "$outside_status" -ne 0 ]] || { printf 'Outside-root candidate was accepted.\n' >&2; exit 1; }
[[ -d "$outside" ]] || { printf 'Outside-root candidate was changed.\n' >&2; exit 1; }

alias_path="$HOME/Applications/Alias.app"
ln -s "$candidate" "$alias_path"
alias_device="$(stat -f '%d' "$alias_path")"
alias_inode="$(stat -f '%i' "$alias_path")"
set +e
"$remover" \
    --root "$approved_root" \
    --candidate "$alias_path" \
    --expected-device "$alias_device" \
    --expected-inode "$alias_inode" \
    --quarantine "$approved_root/.Alias-quarantine" \
    --bundle-id com.kyome.runcat.menubar \
    --team-id VJ5N2X84K8
alias_status=$?
set -e
[[ "$alias_status" -ne 0 ]] || { printf 'Symlink candidate was deleted.\n' >&2; exit 1; }
[[ -L "$alias_path" && -d "$candidate" ]] || { printf 'Symlink rejection changed an object.\n' >&2; exit 1; }
printf 'Installer safety checks passed.\n'
