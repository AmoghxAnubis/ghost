#!/usr/bin/env bash
# Behavioral checks; isolated roots, no scans of the developer's real home.
set -euo pipefail

test_dir="${BASH_SOURCE[0]%/*}"
repo_dir="$(cd -- "$test_dir/.." && pwd)"
source "$repo_dir/ghost.sh"

test_temp_root="$(cd -- "${TMPDIR:-/tmp}" && pwd -P)"
test_workspace=$(mktemp -d "$test_temp_root/ghost-tests.XXXXXXXX")
trap '[[ "$test_workspace" == "$test_temp_root"/ghost-tests.* ]] && rm -rf -- "$test_workspace"' EXIT
fixture="$test_workspace/home space"
mkdir -p "$fixture/Downloads"
configure_storage_paths "$fixture"

# A live filesystem's free space changes between invocations. Keep the pressure
# fixture stable while exercising the real parser and all real file collectors.
df() {
    printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\n'
    printf '/dev/fixture 107374182400 94489280512 12884901888 88%% /\n'
}

passed=0
check() {
    local name="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name" >&2
        printf '%s\n' "${output:-}" >&2
        exit 1
    fi
}
contains() { [[ "$1" == *"$2"* ]]; }
excludes() { [[ "$1" != *"$2"* ]]; }
equals() { [[ "$1" == "$2" ]]; }

output=$(main)
check 'empty diagnosis equals explicit analyze' equals "$output" "$(main analyze)"
check 'empty sources are not invented' contains "$output" 'No review candidates in this scope.'
check 'disk pressure is visible' contains "$output" 'Storage pressure:'
check 'empty diagnosis does not claim recovery' excludes "$output" 'Potential recovery:'

# Real allocated file, old installer; larger apparent size on a sparse archive.
dd if=/dev/zero of="$DOWNLOADS_DIR/old installer.iso" bs=1M count=11 status=none
touch -d '400 days ago' -- "$DOWNLOADS_DIR/old installer.iso"
if [[ "$(uname -s)" == Linux ]]; then
    truncate -s 900M -- "$DOWNLOADS_DIR/sparse.iso"
    touch -d '400 days ago' -- "$DOWNLOADS_DIR/sparse.iso"
fi
mkdir -p "$CACHE_DIR/JetBrains" "$NPM_DIR/_cacache" "$LOCAL_DIR/share/extensions"
printf 'generated cache\n' > "$CACHE_DIR/JetBrains/cache"
printf 'package cache\n' > "$NPM_DIR/_cacache/cache"
printf 'valuable app data\n' > "$LOCAL_DIR/share/extensions/data"

output=$(main)
check 'old archive is first review finding' contains "$output" "1. REVIEW  $(printf '%q' "$DOWNLOADS_DIR/old installer.iso")"
check 'classification includes reasoning' contains "$output" 'Large installer/archive download'
check 'modification age is explicit' contains "$output" 'modified 400d ago'
check 'application data is protected' contains "$output" "PROTECTED  $(printf '%q' "$LOCAL_DIR")"
check 'cache remains reviewable, not automatically safe' contains "$output" 'Recognized cache location; application state'
check 'binary units are correct' contains "$output" 'MiB on disk'
check 'no unconditional safe finding' excludes "$output" 'SAFE  '
check 'first screen includes an investigation step' contains "$(printf '%s\n' "$output" | head -n 25)" 'Investigate:'

# Emulate Linux metadata for a mostly sparse file on every host. Its 512 KiB
# allocation is below the real installer and above the small cache fixtures,
# so the logical-size explanation remains visible among the top three.
sparse_output=$( (
    find() {
        command find "$@"
        printf '%s\0%s\0%s\0%s\0' 943718400 1024 "$(date -d '400 days ago' +%s).0" "$DOWNLOADS_DIR/sparse-metadata.iso"
    }
    main
) )
check 'sparse metadata ranks by allocation' contains "$sparse_output" "1. REVIEW  $(printf '%q' "$DOWNLOADS_DIR/old installer.iso")"
check 'apparent size stays separate from allocation' contains "$sparse_output" 'Logical size: 900.00 MiB (allocation determines rank)'

classify_finding "$DOWNLOADS_DIR/new.iso" download 2
check 'recent installer remains protected' equals "$finding_class" PROTECTED
classify_finding "$DOWNLOADS_DIR/personal-video.mp4" download 400
check 'old personal file remains protected' equals "$finding_class" PROTECTED
classify_finding "$LOCAL_DIR/share/extensions/archive.zip" download 400
check 'application context outranks age and type' equals "$finding_class" PROTECTED
classify_finding "$STORAGE_HOME/Documents/cache" cache 400
check 'personal context outranks cache label' equals "$finding_class" PROTECTED
classify_finding "$STORAGE_HOME/mystery" cache 400
check 'unknown cache locations remain protected' equals "$finding_class" PROTECTED
mkdir -p "$DOWNLOADS_DIR/.git"
classify_finding "$DOWNLOADS_DIR/old installer.iso" download 400
check 'project marker outranks installer evidence' equals "$finding_class" PROTECTED
mv -- "$DOWNLOADS_DIR/.git" "$test_workspace/project-marker"

# File names survive storage, sorting, display, and the emitted Bash command.
odd_name=$'-odd\narchive.iso'
cp -- "$DOWNLOADS_DIR/old installer.iso" "$DOWNLOADS_DIR/$odd_name"
touch -d '400 days ago' -- "$DOWNLOADS_DIR/$odd_name"
output=$(main)
check 'newline and leading dash are safely displayed' contains "$output" "$(printf '%q' "$DOWNLOADS_DIR/$odd_name")"
inspect_line=$(printf '%s\n' "$output" | sed -n 's/^   Investigate: //p' | head -n 1)
check 'drill-down command is valid Bash' bash -n <<< "$inspect_line"
drilldown_output=$(eval "$inspect_line")
check 'emitted read-only drill-down command runs' contains "$drilldown_output" 'DIRECTORY INSPECTOR'
check 'inspector preserves unusual file names' contains "$drilldown_output" "$(printf '%q' "$DOWNLOADS_DIR/$odd_name")"
check 'only three review findings are recommended' contains "$output" 'Showing 3 of 4 review findings'

# Inject deterministic producer failures to check that pipeline success cannot
# conceal a failed measurement. Real permission behavior is checked separately.
output=$( (du() { return 1; }; main) 2>&1 ) && result=0 || result=$?
check 'du failure returns incomplete status' equals "$result" 2
check 'du failure is visible' contains "$output" 'Directory measurement incomplete:'
output=$( (find() { return 1; }; main) 2>&1 ) && result=0 || result=$?
check 'find failure returns incomplete status' equals "$result" 2
check 'find failure is visible' contains "$output" 'Downloads scan incomplete:'
output=$( (df() { return 1; }; main) 2>&1 ) && result=0 || result=$?
check 'df failure returns incomplete status' equals "$result" 2
check 'failed disk measurement is unknown' contains "$output" 'Storage pressure: UNKNOWN'
output=$( (df() { printf 'invalid snapshot\n'; }; main) 2>&1 ) && result=0 || result=$?
check 'malformed disk snapshots are not healthy' contains "$output" 'Storage pressure: UNKNOWN'
output=$( (du() { printf 'not-a-measurement\n'; }; main) 2>&1 ) && result=0 || result=$?
check 'invalid measurements are not zeroes' contains "$output" 'Invalid directory measurement:'

# Unix symlinks and mode bits are not faithfully represented by Git Bash/NTFS.
if [[ "$(uname -s)" == Linux ]]; then
    mkdir -p "$STORAGE_HOME/Documents" "$CACHE_DIR/google-chrome"
    mv -- "$CACHE_DIR/google-chrome" "$test_workspace/unused-cache"
    ln -s -- "$STORAGE_HOME/Documents" "$CACHE_DIR/google-chrome"
    output=$(main 2>&1) && result=0 || result=$?
    check 'symlinked source is skipped and protected' contains "$output" 'PROTECTED alias skipped:'
    mv -- "$CACHE_DIR/google-chrome" "$test_workspace/cache-link"
    if (( EUID != 0 )); then
        chmod 000 "$DOWNLOADS_DIR"
        output=$(main 2>&1) && result=0 || result=$?
        chmod 700 "$DOWNLOADS_DIR"
        check 'unreadable source is incomplete' equals "$result" 2
        check 'unreadable source is visible' contains "$output" 'Unreadable source:'
    else
        echo 'SKIP real permissions: run this suite as a non-root Linux user.'
    fi
else
    echo 'SKIP native symlink/permission behavior: requires Linux.'
fi

# Inventory includes file contents, names, types, sizes, and modification times.
# Access times are intentionally excluded: reading may update them on Linux.
snapshot() {
    find "$STORAGE_HOME" -printf '%y %s %T@ %p\0' | sort -z
    find "$STORAGE_HOME" -type f -print0 | sort -z | xargs -0 sha256sum --
}
snapshot > "$test_workspace/before"
main > "$test_workspace/report"
snapshot > "$test_workspace/after"
check 'diagnosis leaves contents and directory entries unchanged' cmp -s "$test_workspace/before" "$test_workspace/after"

# Route smoke checks isolate dispatch from expensive legacy investigators.
for route in scan large ghosts inspect duplicates age analyze help; do
    case "$route" in
        scan) handler=scan ;;
        large) handler=find_large_files ;;
        ghosts) handler=detect_ghosts ;;
        inspect) handler=inspect_directory ;;
        duplicates) handler=find_duplicates ;;
        age) handler=find_old_files ;;
        analyze) handler=analyze ;;
        help) handler=show_help ;;
    esac
    output=$( (eval "$handler() { printf 'dispatched'; }"; main "$route" "$DOWNLOADS_DIR") )
    check "existing $route route still dispatches" equals "$output" dispatched
done
output=$(main unknown 2>&1) && result=0 || result=$?
check 'unknown command still fails' equals "$result" 1
check 'explicit help remains available' contains "$(main help)" 'Commands:'
check 'standard help flag remains cheap' contains "$(main --help)" 'Commands:'
output=$(main inspect 2>&1) && result=0 || result=$?
check 'missing inspect path returns an error' equals "$result" 1

# Exercise real legacy investigators only against this isolated storage root.
for route in scan large ghosts duplicates age; do
    if ! main "$route" > "$test_workspace/legacy-$route"; then
        echo "FAIL legacy $route execution" >&2
        exit 1
    fi
    check "legacy $route runs against fixture" test -s "$test_workspace/legacy-$route"
done
main inspect "$DOWNLOADS_DIR" > "$test_workspace/legacy-inspect"
check 'legacy inspect runs against fixture' test -s "$test_workspace/legacy-inspect"
printf '\n%s checks passed.\n' "$passed"
