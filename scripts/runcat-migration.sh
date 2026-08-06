#!/bin/bash
# Optional RunCat migration library. Source from install.sh, do not execute directly.
# Identity constants are limited to values verified from the archived official source.

RUNCAT_BUNDLE_ID='com.kyome.runcat.menubar'
RUNCAT_TEAM_ID='VJ5N2X84K8'
RUNCAT_DESIGNATED_REQUIREMENT="identifier \"$RUNCAT_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$RUNCAT_TEAM_ID\""

runcat_manual_steps() {
    local path=$1
    printf '%s\n' "To finish manually: quit RunCat, move '$path' to the Trash, then remove any RunCat entry in System Settings > General > Login Items. DockAwake never removes RunCat preferences or Application Support data."
}

# Rejects control characters so a disclosed path cannot spoof the consent prompt.
runcat_plain_path() {
    local path=$1
    [[ "$path" != *[[:cntrl:]]* ]]
}

runcat_verified_candidate() {
    local path=$1 info identifier team bundle
    [[ -d "$path" && ! -L "$path" ]] || return 1
    runcat_plain_path "$path" || return 1
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null) || return 1
    [[ "$bundle" == "$RUNCAT_BUNDLE_ID" ]] || return 1
    /usr/bin/codesign --verify --deep --strict -R "$RUNCAT_DESIGNATED_REQUIREMENT" "$path" >/dev/null 2>&1 || return 1
    info=$(/usr/bin/codesign -d --verbose=4 "$path" 2>&1) || return 1
    identifier=$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}')
    team=$(printf '%s\n' "$info" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [[ "$identifier" == "$RUNCAT_BUNDLE_ID" && "$team" == "$RUNCAT_TEAM_ID" ]]
}

runcat_discover() {
    local root path
    RUNCAT_CANDIDATES=()
    for root in "$HOME/Applications" /Applications; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        while IFS= read -r -d '' path; do
            runcat_verified_candidate "$path" && RUNCAT_CANDIDATES+=("$(cd "$path" && pwd -P)")
        done < <(/usr/bin/find -P "$root" -xdev -maxdepth 1 -type d -name '*.app' -print0)
    done
}

# Deletes only login items whose registered path is exactly the removed bundle,
# then proves that no such registration remains.
runcat_clear_login_registration() {
    local path=$1
    /usr/bin/osascript - "$path" <<'APPLESCRIPT' >/dev/null 2>&1 || return 1
on run arguments
    set candidatePath to item 1 of arguments
    tell application "System Events"
        repeat (count of (every login item whose path is candidatePath)) times
            delete (first login item whose path is candidatePath)
        end repeat
        if (count of (every login item whose path is candidatePath)) is not 0 then
            error "RunCat login item remains registered"
        end if
    end tell
end run
APPLESCRIPT
}

# Removes one authenticated bundle object, then its exact-path login registration.
# The bundle is removed first so a registration failure can never leave RunCat
# installed with its autostart silently stripped.
runcat_remove_candidate() {
    local path=$1 root parent quarantine device inode remover
    runcat_verified_candidate "$path" || return 1
    if [[ "$path" == "$(cd "$HOME/Applications" 2>/dev/null && pwd -P)"/* ]]; then
        root="$(cd "$HOME/Applications" && pwd -P)"
    elif [[ "$path" == /Applications/* ]]; then
        root=/Applications
    else
        return 1
    fi
    parent="$(dirname "$path")"
    [[ "$parent" == "$root" ]] || return 1
    quarantine="$root/.DockAwake-RunCat-quarantine.$$.$RANDOM"
    device=$(/usr/bin/stat -f '%d' "$path") || return 1
    inode=$(/usr/bin/stat -f '%i' "$path") || return 1
    remover="$RUNCAT_REMOVER"
    [[ -x "$remover" ]] || return 1

    if ! "$remover" \
        --root "$root" \
        --candidate "$path" \
        --expected-device "$device" \
        --expected-inode "$inode" \
        --quarantine "$quarantine" \
        --bundle-id "$RUNCAT_BUNDLE_ID" \
        --team-id "$RUNCAT_TEAM_ID"; then
        return 1
    fi

    if ! runcat_clear_login_registration "$path"; then
        printf '%s\n' "RunCat migration: removed $path, but its login registration could not be verified as absent. Open System Settings > General > Login Items and remove any remaining RunCat entry."
        return 0
    fi
}

runcat_migrate() {
    local answer path removed=0 failed=0
    # This function is intentionally total: every optional migration outcome returns success.
    runcat_discover
    if ((${#RUNCAT_CANDIDATES[@]} == 0)); then
        printf '%s\n' 'RunCat migration: no verified archived-identity RunCat bundle found.'
        return 0
    fi

    printf '%s\n' 'RunCat migration found these verified bundles:'
    for path in "${RUNCAT_CANDIDATES[@]}"; do
        printf '  %s (bundle %s, team %s)\n' "$path" "$RUNCAT_BUNDLE_ID" "$RUNCAT_TEAM_ID"
    done
    if [[ ! -t 0 ]]; then
        printf '%s\n' 'RunCat migration: declined because standard input is not interactive.'
        return 0
    fi
    IFS= read -r -p 'Remove only these verified RunCat bundles? Type exact lowercase yes: ' answer || answer=''
    if [[ "$answer" != yes ]]; then
        printf '%s\n' 'RunCat migration: declined. No RunCat files or login registrations were changed.'
        return 0
    fi

    for path in "${RUNCAT_CANDIDATES[@]}"; do
        if runcat_remove_candidate "$path"; then
            printf 'RunCat migration: removed verified bundle %s\n' "$path"
            removed=$((removed + 1))
        else
            printf 'RunCat migration: failed safely, nothing was deleted for %s\n' "$path"
            runcat_manual_steps "$path"
            failed=$((failed + 1))
        fi
    done
    printf 'RunCat migration: %d removed, %d failed. DockAwake installation continues.\n' "$removed" "$failed"
    return 0
}
