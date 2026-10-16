#!/usr/bin/env bash
set -euo pipefail
umask 077

test_dir="${BASH_SOURCE[0]%/*}"
repo_dir="$(cd -- "$test_dir/.." && pwd)"
source "$repo_dir/ghost.sh"
test_temp_root="$(cd -- "${TMPDIR:-/tmp}" && pwd -P)"
test_workspace=$(mktemp -d "$test_temp_root/ghost-history-tests.XXXXXXXX")
trap '[[ "$test_workspace" == "$test_temp_root"/ghost-history-tests.* ]] && rm -rf -- "$test_workspace"' EXIT
fixture="$test_workspace/"$'home [space]*\nroot'
mkdir -p -- "$fixture"
configure_storage_paths "$fixture"
unset XDG_STATE_HOME
passed=0
output=''
check() {
    local name="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s\n%s\n' "$name" "$output" >&2
        exit 1
    fi
}
contains() { [[ "$1" == *"$2"* ]]; }
excludes() { [[ "$1" != *"$2"* ]]; }
equals() { [[ "$1" == "$2" ]]; }
capture() { output=$(main "$@" 2>&1) && result=0 || result=$?; }
snapshot_id() { printf '%s\n' "$1" | sed -n 's/^Saved snapshot: //p'; }

capture changes
check 'first use explains how to save a baseline' contains "$output" 'No saved baseline.'
check 'first use is successful' equals "$result" 0
check 'changes creates no history directory on first use' test ! -e "$LOCAL_DIR"
capture snapshot unexpected
check 'snapshot rejects unexpected arguments' equals "$result" 1
capture changes first second
check 'changes rejects unexpected arguments' equals "$result" 1

# All known directories exist, so ordinary comparisons have seven useful totals.
mkdir -p -- "$CACHE_DIR/google-chrome" "$CACHE_DIR/JetBrains" "$NPM_DIR/_cacache" \
    "$LOCAL_DIR" "$VAR_DIR" "$DOCKER_DIR" "$DOWNLOADS_DIR"
dd if=/dev/zero of="$DOWNLOADS_DIR/base.iso" bs=1M count=11 status=none
printf 'valuable application data\n' > "$LOCAL_DIR/personal.txt"
capture snapshot
check 'explicit snapshot succeeds' equals "$result" 0
baseline=$(snapshot_id "$output")
check 'saved snapshot has a valid ID' history_snapshot_name "$baseline"
store="$LOCAL_DIR/state/ghost"
if ! history_private "$store"; then
    stat -c 'History directory mode=%a owner=%u' -- "$store"
    printf 'Expected owner=%s\n' "$EUID"
fi
check 'history directory is private' history_private "$store"
check 'snapshot file is private' history_private "$store/$baseline"
check 'latest pointer is private' history_private "$store/latest"

capture changes
check 'unchanged sources are counted' contains "$output" 'Unchanged comparable sources: 7'
check 'saving the baseline does not create artificial growth' excludes "$output" '+1.'
check 'history exclusion handles glob characters and newline paths' equals "$result" 0

# Growth is ordered by allocation and includes a useful read-only drill-down.
dd if=/dev/zero of="$DOWNLOADS_DIR/new.iso" bs=1M count=12 status=none
dd if=/dev/zero of="$CACHE_DIR/JetBrains/cache" bs=1M count=2 status=none
capture changes
check 'new data is measured against the saved baseline' contains "$output" '+12.00 MiB  Downloads'
check 'cache growth is visible' contains "$output" 'JetBrains cache'
first_growth=$(printf '%s\n' "$output" | sed -n '/^+/p' | head -n 1)
check 'largest increase appears first' contains "$first_growth" 'Downloads'
check 'source path is safely displayed' contains "$output" "$(printf '%q' "$DOWNLOADS_DIR")"
check 'growth includes investigation command' contains "$output" 'Investigate: bash '
check 'changes leaves the baseline alone' contains "$output" "Baseline: $baseline"
check 'changes reports overlap instead of an aggregate total' contains "$output" 'not a combined total'

capture snapshot
second=$(snapshot_id "$output")
check 'repeated snapshots get unique identifiers' test "$second" != "$baseline"
check 'previous snapshots are retained' test -f "$store/$baseline"
capture changes
check 'latest means last successfully saved snapshot' contains "$output" "Baseline: $second"
check 'later snapshots do not measure their own files as growth' contains "$output" 'Unchanged comparable sources: 7'
capture changes "$baseline"
check 'explicit old baseline is supported' contains "$output" '+12.00 MiB  Downloads'

# This file remains present but drops below the Downloads measurement threshold.
truncate -s 0 -- "$DOWNLOADS_DIR/new.iso"
capture changes
check 'shrinkage is reported independently' contains "$output" '-12.00 MiB  Downloads'
check 'shrinkage is not claimed as cleanup' contains "$output" 'A decrease does not establish cleanup or recovered space.'

# A removed source is unavailable; its old measurement must not become a decrease.
mv -- "$CACHE_DIR/JetBrains" "$test_workspace/moved-cache"
capture changes
check 'missing current source is not comparable' contains "$output" 'baseline=ok, now=missing'
check 'missing current source returns incomplete status' equals "$result" 2
check 'missing source is never reported as bytes reclaimed' excludes "$output" '-2.00 MiB  JetBrains cache'
mv -- "$test_workspace/moved-cache" "$CACHE_DIR/JetBrains"

output=$( (du() { return 1; }; main changes "$baseline") 2>&1 ) && result=0 || result=$?
check 'failed measurement is not comparable' contains "$output" 'baseline=ok, now=error'
check 'failed measurement returns incomplete status' equals "$result" 2
output=$( (find() { return 1; }; main changes "$baseline") 2>&1 ) && result=0 || result=$?
check 'failed Downloads scan is not a zero-byte source' contains "$output" 'Downloads (>10 MiB, top level): baseline=ok, now=error'
check 'failed Downloads scan returns incomplete status' equals "$result" 2

# Failed publication never replaces the selected baseline or leaves scratch files.
output=$( (mv() { return 1; }; main snapshot) 2>&1 ) && result=0 || result=$?
check 'write failure is explicit' equals "$result" 1
capture changes
check 'failed save keeps previous baseline' contains "$output" "Baseline: $second"
pending_count=$(find "$store" -name '.pending.*' -printf 'x' | wc -c)
check 'failed save cleans only its pending files' equals "$pending_count" 0

# A saved partial snapshot carries statuses; a failed baseline is not a zero.
output=$( (find() { return 1; }; main snapshot) 2>&1 ) && result=0 || result=$?
check 'partial snapshot is saved with an incomplete status' equals "$result" 2
partial=$(snapshot_id "$output")
check 'partial snapshot explains the unavailable source' contains "$output" 'Incomplete source recorded: Downloads'
capture changes "$partial"
check 'failed baseline remains unknown after recovery' contains "$output" 'baseline=error, now=ok'
check 'recovered measurement does not become false growth' excludes "$output" '+11.00 MiB  Downloads'

# Parse stored data as fields, never shell code. These are corruption tests, not
# snapshots written by the application; keep the original fixture for restoration.
cp -- "$store/$baseline" "$test_workspace/good-snapshot"
rewrite_field() {
    local position="$1" replacement="$2" value
    local -a fields=()
    while IFS= read -r -d '' value; do fields+=("$value"); done < "$test_workspace/good-snapshot"
    fields[$position]="$replacement"
    printf '%s\0' "${fields[@]}" > "$store/$baseline"
}
printf -v malicious '$(touch %q)' "$test_workspace/executed"
rewrite_field 10 "$malicious"
capture changes "$baseline"
check 'malformed numeric data is rejected' equals "$result" 1
check 'snapshot data is never evaluated as shell code' test ! -e "$test_workspace/executed"
rewrite_field 10 999999999999999999999999
capture changes "$baseline"
check 'overflowing numeric data is rejected' equals "$result" 1
rewrite_field 5 different-scope
capture changes "$baseline"
check 'different scopes are not compared' equals "$result" 2
check 'different scope is explained' contains "$output" 'Snapshot scope or home filesystem differs.'
rewrite_field 3 /another/home
capture changes "$baseline"
check 'another home cannot be compared as this home' equals "$result" 2
rewrite_field 11 999999999
capture changes "$baseline"
check 'different source filesystem is not comparable' contains "$output" 'source filesystem changed'
cp -- "$test_workspace/good-snapshot" "$store/$baseline"
printf 'truncated' > "$store/$baseline"
capture changes "$baseline"
check 'truncated snapshots are rejected' equals "$result" 1
cp -- "$test_workspace/good-snapshot" "$store/$baseline"
printf '\0' >> "$store/$baseline"
capture changes "$baseline"
check 'trailing records are rejected' equals "$result" 1
cp -- "$test_workspace/good-snapshot" "$store/$baseline"

if [[ "$(uname -s)" == Linux ]]; then
    chmod 644 "$store/$baseline"
    capture changes "$baseline"
    check 'publicly readable snapshots are refused' equals "$result" 1
    chmod 600 "$store/$baseline"
fi
capture changes '../outside.ghost'
check 'snapshot identifiers cannot escape the history directory' equals "$result" 1
XDG_STATE_HOME=relative capture snapshot
check 'relative state paths are refused' equals "$result" 1

# Retained snapshots contain only source directory names, never individual files.
check 'snapshot does not retain Downloads filenames' excludes "$(tr '\0' '\n' < "$store/$second")" 'base.iso'
check 'snapshot does not retain personal filenames' excludes "$(tr '\0' '\n' < "$store/$second")" 'personal.txt'
data_before=$(sha256sum -- "$LOCAL_DIR/personal.txt" "$DOWNLOADS_DIR/base.iso")
files_before=$(find "$store" -type f -printf '%f\0' | sort -z | sha256sum)
capture changes "$baseline"
files_after=$(find "$store" -type f -printf '%f\0' | sort -z | sha256sum)
check 'changes saves no new history files' equals "$files_before" "$files_after"
check 'history leaves application and download contents unchanged' equals "$data_before" "$(sha256sum -- "$LOCAL_DIR/personal.txt" "$DOWNLOADS_DIR/base.iso")"

# Both-absent optional sources need no invented zero and do not fail a report.
empty_fixture="$test_workspace/empty home"
mkdir -- "$empty_fixture"
configure_storage_paths "$empty_fixture"
capture snapshot
check 'missing optional sources do not fail snapshot creation' equals "$result" 0
capture changes
check 'both-absent sources are labeled' contains "$output" 'absent in both scans (optional source)'
check 'both-absent sources do not fail a useful comparison' equals "$result" 0

if [[ "$(uname -s)" == Linux ]]; then
    configure_storage_paths "$fixture"
    truncate -s 1G -- "$DOWNLOADS_DIR/large-sparse.iso"
    capture changes "$second"
    check 'real sparse allocation never becomes a logical GiB increase' excludes "$output" '+1.00 GiB'
    ln -- "$DOWNLOADS_DIR/base.iso" "$DOWNLOADS_DIR/linked.iso"
    capture changes "$second"
    check 'hard links are counted once within Downloads' contains "$output" '-12.00 MiB  Downloads'
    mv -- "$CACHE_DIR/google-chrome" "$test_workspace/chrome-original"
    ln -s -- "$DOWNLOADS_DIR" "$CACHE_DIR/google-chrome"
    capture changes "$second"
    check 'aliased source is not compared' contains "$output" 'baseline=ok, now=alias'
    mv -- "$CACHE_DIR/google-chrome" "$test_workspace/chrome-alias"
    mv -- "$test_workspace/chrome-original" "$CACHE_DIR/google-chrome"
    if (( EUID != 0 )); then
        chmod 000 "$DOWNLOADS_DIR"
        capture changes "$second"
        chmod 700 "$DOWNLOADS_DIR"
        check 'unreadable current source is not comparable' contains "$output" 'baseline=ok, now=unreadable'
        check 'unreadable source returns incomplete status' equals "$result" 2
    else
        echo 'SKIP native permission checks: run as a non-root Linux user.'
    fi
else
    echo 'SKIP native sparse-file, symlink, and permission checks: requires Linux.'
fi

printf '\n%s history checks passed.\n' "$passed"
