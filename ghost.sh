#!/usr/bin/env bash

# ==========================================
# GHOST
# Disk Space Investigator
# Version 0.10
# ==========================================

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo 'Ghost requires Bash 4.4 or newer.' >&2
    return 1 2>/dev/null || exit 1
fi

set -u

# ==========================================
# CONFIGURATION
# ==========================================

configure_storage_paths() {
    STORAGE_HOME="${1%/}"
    [[ -n "$STORAGE_HOME" ]] || STORAGE_HOME=/
    CACHE_DIR="$STORAGE_HOME/.cache"
    NPM_DIR="$STORAGE_HOME/.npm"
    DOWNLOADS_DIR="$STORAGE_HOME/Downloads"
    VAR_DIR="$STORAGE_HOME/.var"
    LOCAL_DIR="$STORAGE_HOME/.local"
    DOCKER_DIR="$STORAGE_HOME/.docker"
    TRASH_DIR="$STORAGE_HOME/.local/share/Trash"
}

configure_storage_paths "$HOME"

# Duplicate detection threshold.
DUPLICATE_MIN_SIZE_BYTES=$((10 * 1024 * 1024))

# Age analysis threshold.
AGE_MIN_SIZE_BYTES=$((10 * 1024 * 1024))
AGE_THRESHOLD_DAYS=30

# ==========================================
# HEADER
# ==========================================

show_header() {
    echo
    echo "=========================================="
    echo "       GHOST - Disk Space Investigator"
    echo "=========================================="
    echo
}

# ==========================================
# FORMAT BYTES
# ==========================================

format_bytes() {
    local bytes="$1"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        printf 'unknown'
        return 1
    fi

    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GiB\", $bytes / 1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MiB\", $bytes / 1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.2f KiB\", $bytes / 1024}"
    else
        echo "${bytes} B"
    fi
}

# ==========================================
# GET DIRECTORY SIZE
# ==========================================

get_directory_size() {
    local directory="$1"

    if [[ ! -d "$directory" ]]; then
        echo "0"
        return
    fi

    du -sB1 "$directory" 2>/dev/null | awk '{print $1}'
}

# ==========================================
# PATH RESOLUTION
# ==========================================

resolve_path() {
    local path="$1"

    if [[ "$path" == "~" ]]; then
        path="$STORAGE_HOME"
    elif [[ "$path" == "~/"* ]]; then
        path="$STORAGE_HOME/${path:2}"
    fi

    if [[ "$path" != /* ]]; then
        path="$(realpath "$path" 2>/dev/null || echo "$path")"
    fi

    echo "$path"
}

# ==========================================
# DISK INFORMATION
# ==========================================

get_disk_total() {
    df -B1 "$STORAGE_HOME" | awk 'NR==2 {print $2}'
}

get_disk_used() {
    df -B1 "$STORAGE_HOME" | awk 'NR==2 {print $3}'
}

get_disk_available() {
    df -B1 "$STORAGE_HOME" | awk 'NR==2 {print $4}'
}

get_disk_usage_percent() {
    df "$STORAGE_HOME" | awk 'NR==2 {gsub("%","",$5); print $5}'
}

get_storage_health() {
    local usage="$1"

    if (( usage >= 95 )); then
        echo "CRITICAL"
    elif (( usage >= 85 )); then
        echo "HIGH"
    elif (( usage >= 70 )); then
        echo "MODERATE"
    else
        echo "GOOD"
    fi
}

# ==========================================
# DISK USAGE
# ==========================================

show_disk_usage() {
    echo "SYSTEM STORAGE"
    echo "------------------------------------------"
    echo

    df -h "$STORAGE_HOME" | awk 'NR==2 {
        printf "Total:       %s\n", $2
        printf "Used:        %s\n", $3
        printf "Available:   %s\n", $4
        printf "Usage:       %s\n", $5
    }'

    echo
}

# ==========================================
# TOP DIRECTORIES
# ==========================================

show_top_directories() {
    echo "TOP DIRECTORIES"
    echo "------------------------------------------"
    echo

    du -h --max-depth=1 "$STORAGE_HOME" 2>/dev/null |
        sort -hr |
        head -n 10

    echo
}

# ==========================================
# LARGE FILE INVESTIGATOR
# ==========================================

find_large_files() {
    show_header

    echo "LARGE FILE INVESTIGATOR"
    echo "------------------------------------------"
    echo
    echo "Scanning: $STORAGE_HOME"
    echo "Looking for files larger than 500 MiB..."
    echo

    files=$(
        find "$STORAGE_HOME" \
            -type f \
            -size +500M \
            -printf '%p\n' \
            2>/dev/null
    )

    if [[ -z "$files" ]]; then
        echo "No files larger than 500 MiB were found."
        echo
        return
    fi

    printf "%-15s %-15s %s\n" "ACTUAL" "LOGICAL" "FILE"
    printf "%-15s %-15s %s\n" "------" "-------" "----"

    while IFS= read -r file; do

        logical=$(stat -c '%s' "$file" 2>/dev/null)
        actual=$(du -B1 "$file" 2>/dev/null | awk '{print $1}')

        if [[ -z "$logical" || -z "$actual" ]]; then
            continue
        fi

        logical_display=$(format_bytes "$logical")
        actual_display=$(format_bytes "$actual")

        printf "%-15s %-15s %s\n" \
            "$actual_display" \
            "$logical_display" \
            "$file"

    done <<< "$files"

    echo
}

# ==========================================
# GHOST DETECTION
# ==========================================

detect_ghost() {
    local name="$1"
    local path="$2"
    local type="$3"
    local risk="$4"
    local recommendation="$5"

    if [[ ! -d "$path" ]]; then
        return
    fi

    local size
    size=$(get_directory_size "$path")

    if [[ "$size" == "0" ]]; then
        return
    fi

    echo "👻 $name"
    echo "   Location:       $path"
    echo "   Size:           $(format_bytes "$size")"
    echo "   Type:           $type"
    echo "   Risk:           $risk"
    echo "   Recommendation: $recommendation"
    echo
}

detect_ghosts() {
    show_header

    echo "GHOST DETECTION"
    echo "------------------------------------------"
    echo
    echo "Searching for known storage consumers..."
    echo

    detect_ghost \
        "Docker Directory" \
        "$DOCKER_DIR" \
        "Development environment" \
        "REVIEW" \
        "Directory size only; use Docker-native tools to inspect images and volumes."

    detect_ghost \
        "Downloads" \
        "$DOWNLOADS_DIR" \
        "User files" \
        "REVIEW" \
        "Check old installers, archives and unused downloads."

    detect_ghost \
        "Application Cache" \
        "$CACHE_DIR" \
        "Application cache" \
        "REVIEW" \
        "Review with the owning application; cleanup semantics have not been verified."

    detect_ghost \
        "NPM Data" \
        "$NPM_DIR" \
        "Package manager data" \
        "REVIEW" \
        "Includes more than cache; inspect before considering cleanup."

    detect_ghost \
        "User Data" \
        "$LOCAL_DIR" \
        "Application data" \
        "REVIEW" \
        "Inspect before removing anything."

    detect_ghost \
        "Application Storage" \
        "$VAR_DIR" \
        "Application storage" \
        "REVIEW" \
        "Inspect installed applications and their data."

    echo "------------------------------------------"
    echo
    echo "Ghost detection complete."
    echo
}

# ==========================================
# DIRECTORY INSPECTOR
# ==========================================

inspect_directory() (
    local directory

    directory=$(resolve_path "$1")

    if [[ ! -d "$directory" ]]; then
        echo
        echo "Error: directory does not exist."
        echo "Path: $directory"
        echo
        exit 1
    fi

    show_header

    echo "DIRECTORY INSPECTOR"
    echo "------------------------------------------"
    echo
    echo "Path:"
    printf '  %q\n' "$directory"
    echo

    local total_size measurement
    if ! measurement=$(du -sB1 -- "$directory"); then
        echo 'Directory measurement incomplete.' >&2
        return 2
    fi
    total_size="${measurement%%$'\t'*}"

    echo "Total size:"
    echo "  $(format_bytes "$total_size")"
    echo

    echo "CONTENTS"
    echo "------------------------------------------"
    echo

    printf "%-15s %s\n" "SIZE" "PATH"
    printf "%-15s %s\n" "----" "----"

    shopt -s dotglob nullglob
    local -a children=("$directory"/*)
    local entry size path
    if (( ${#children[@]} == 0 )); then
        echo 'No directory entries.'
    else
        while IFS= read -r -d '' entry; do
            size="${entry%%$'\t'*}"
            path="${entry#*$'\t'}"
            printf '%-15s %q\n' "$(format_bytes "$size")" "$path"
        done < <(du -sB1 --null -- "${children[@]}" | sort -znr | head -z -n 15)
    fi

    echo
)

# ==========================================
# DUPLICATE FILE INVESTIGATOR
# ==========================================

find_duplicates() {

    show_header

    echo "DUPLICATE FILE INVESTIGATOR"
    echo "------------------------------------------"
    echo
    echo "Scanning: $STORAGE_HOME"
    echo "Minimum file size: $(format_bytes "$DUPLICATE_MIN_SIZE_BYTES")"
    echo
    echo "Ghost will first group files by size,"
    echo "then hash only matching candidates."
    echo

    local temp_dir

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghost-duplicates.XXXXXX" 2>/dev/null)

    if [[ -z "$temp_dir" || ! -d "$temp_dir" ]]; then
        echo "Error: could not create temporary workspace."
        echo
        return 1
    fi

    trap 'rm -rf "$temp_dir"' EXIT

    local scanned_files=0
    local hash_candidates=0
    local duplicate_groups=0
    local duplicate_bytes=0

    declare -A size_count

    # ======================================
    # PHASE 1
    # ======================================

    echo "PHASE 1: SIZE ANALYSIS"
    echo "------------------------------------------"
    echo

    while IFS= read -r -d '' file; do

        local size

        size=$(stat -c '%s' "$file" 2>/dev/null)

        if [[ -z "$size" ]]; then
            continue
        fi

        ((scanned_files++))

        local group_file
        group_file="$temp_dir/$size"

        if [[ ! -f "$group_file" ]]; then
            : > "$group_file"
        fi

        printf '%s\0' "$file" >> "$group_file"

        local current_count
        current_count="${size_count[$size]:-0}"

        size_count["$size"]=$((current_count + 1))

    done < <(
        find "$STORAGE_HOME" \
            -path "$CACHE_DIR" -prune -o \
            -path "$DOCKER_DIR" -prune -o \
            -path "$TRASH_DIR" -prune -o \
            -type f \
            -size +"${DUPLICATE_MIN_SIZE_BYTES}"c \
            -print0 \
            2>/dev/null
    )

    echo "Files scanned: $scanned_files"
    echo

    # ======================================
    # PHASE 2
    # ======================================

    echo "PHASE 2: HASH ANALYSIS"
    echo "------------------------------------------"
    echo

    if (( scanned_files == 0 )); then
        echo "No files matched the duplicate scan criteria."
        echo
        trap - EXIT
        rm -rf "$temp_dir"
        return
    fi

    while IFS= read -r size; do

        local count
        count="${size_count[$size]:-0}"

        if (( count < 2 )); then
            continue
        fi

        hash_candidates=$((hash_candidates + count))

        declare -A hash_first=()
        declare -A hash_count=()

        while IFS= read -r -d '' file; do

            local hash

            hash=$(sha256sum -- "$file" 2>/dev/null | awk '{print $1}')

            if [[ -z "$hash" ]]; then
                continue
            fi

            if [[ -z "${hash_first[$hash]+exists}" ]]; then

                hash_first["$hash"]="$file"
                hash_count["$hash"]=1

            else

                local first_file
                first_file="${hash_first[$hash]}"

                if cmp -s -- "$first_file" "$file"; then

                    local existing_count
                    existing_count="${hash_count[$hash]:-1}"

                    if (( existing_count == 1 )); then

                        ((duplicate_groups++))

                        echo "DUPLICATE GROUP #$duplicate_groups"
                        echo "------------------------------------------"
                        echo
                        echo "Hash:"
                        echo "  $hash"
                        echo
                        echo "File size:"
                        echo "  $(format_bytes "$size")"
                        echo
                        echo "Files:"
                        echo "  1. $first_file"
                        echo "  2. $file"

                    else

                        echo "  $((existing_count + 1)). $file"

                    fi

                    hash_count["$hash"]=$((existing_count + 1))

                    duplicate_bytes=$((duplicate_bytes + size))

                    echo

                fi

            fi

        done < "$temp_dir/$size"

        unset hash_first
        unset hash_count

    done < <(
        printf '%s\n' "${!size_count[@]}" |
        sort -nr
    )

    # ======================================
    # RESULTS
    # ======================================

    echo "=========================================="
    echo

    echo "DUPLICATE ANALYSIS COMPLETE"
    echo "------------------------------------------"
    echo

    echo "Files scanned:          $scanned_files"
    echo "Same-size candidates:   $hash_candidates"
    echo "Duplicate groups:       $duplicate_groups"
    echo

    if (( duplicate_bytes > 0 )); then

        echo "Potential recovery:"
        echo "  $(format_bytes "$duplicate_bytes")"
        echo

        echo "IMPORTANT:"
        echo "Ghost has not deleted anything."
        echo "Review duplicate groups before cleanup."
        echo

    else

        echo "No confirmed duplicate files were found."
        echo

    fi

    trap - EXIT
    rm -rf "$temp_dir"
}

# ==========================================
# AGE ANALYSIS HELPERS
# ==========================================

get_old_file_size() {
    local directory="$1"
    local days="$2"

    if [[ ! -d "$directory" ]]; then
        echo "0"
        return
    fi

    find "$directory" \
        -path "$CACHE_DIR" -prune -o \
        -path "$DOCKER_DIR" -prune -o \
        -path "$TRASH_DIR" -prune -o \
        -type f \
        -size +"${AGE_MIN_SIZE_BYTES}"c \
        -mtime +"$days" \
        -printf '%s\n' \
        2>/dev/null |
        awk '{sum += $1} END {print sum+0}'
}

get_old_file_count() {
    local directory="$1"
    local days="$2"

    if [[ ! -d "$directory" ]]; then
        echo "0"
        return
    fi

    find "$directory" \
        -path "$CACHE_DIR" -prune -o \
        -path "$DOCKER_DIR" -prune -o \
        -path "$TRASH_DIR" -prune -o \
        -type f \
        -size +"${AGE_MIN_SIZE_BYTES}"c \
        -mtime +"$days" \
        -print \
        2>/dev/null |
        wc -l
}

get_file_category() {
    local file="$1"

    if [[ "$file" == "$DOWNLOADS_DIR/"* ]]; then
        echo "Downloads"
    elif [[ "$file" == "$VAR_DIR/"* ]]; then
        echo "Application Data"
    elif [[ "$file" == "$LOCAL_DIR/"* ]]; then
        echo "Application Data"
    elif [[ "$file" == "$CACHE_DIR/"* ]]; then
        echo "Cache"
    elif [[ "$file" == "$DOCKER_DIR/"* ]]; then
        echo "Docker"
    elif [[ "$file" == "$STORAGE_HOME/.config/"* ]]; then
        echo "Configuration"
    else
        echo "User File"
    fi
}

# ==========================================
# OLD FILE INVESTIGATOR
# ==========================================

find_old_files() {

    local directory="$1"

    directory=$(resolve_path "$directory")

    if [[ ! -d "$directory" ]]; then
        echo
        echo "Error: directory does not exist."
        echo "Path: $directory"
        echo
        return 1
    fi

    show_header

    echo "AGE ANALYSIS"
    echo "------------------------------------------"
    echo
    echo "Scanning: $directory"
    echo "Minimum file size: $(format_bytes "$AGE_MIN_SIZE_BYTES")"
    echo "Age threshold:      $AGE_THRESHOLD_DAYS days"
    echo
    echo "Ghost excludes cache, Docker and Trash data"
    echo "from the age investigation."
    echo

    local old_size
    local old_count
    local very_old_size
    local very_old_count
    local stale_size
    local stale_count

    old_size=$(get_old_file_size "$directory" 30)
    old_count=$(get_old_file_count "$directory" 30)

    very_old_size=$(get_old_file_size "$directory" 90)
    very_old_count=$(get_old_file_count "$directory" 90)

    stale_size=$(get_old_file_size "$directory" 180)
    stale_count=$(get_old_file_count "$directory" 180)

    echo "AGE SUMMARY"
    echo "------------------------------------------"
    echo

    echo "Older than 30 days:"
    echo "  Files:       $old_count"
    echo "  Storage:     $(format_bytes "$old_size")"
    echo

    echo "Older than 90 days:"
    echo "  Files:       $very_old_count"
    echo "  Storage:     $(format_bytes "$very_old_size")"
    echo

    echo "Older than 180 days:"
    echo "  Files:       $stale_count"
    echo "  Storage:     $(format_bytes "$stale_size")"
    echo

    echo "OLDEST LARGE FILES"
    echo "------------------------------------------"
    echo

    printf "%-10s %-15s %-20s %s\n" \
        "AGE" \
        "SIZE" \
        "CATEGORY" \
        "FILE"

    printf "%-10s %-15s %-20s %s\n" \
        "---" \
        "----" \
        "--------" \
        "----"

    local now
    now=$(date +%s)

    local found_files=0

    while IFS=$'\t' read -r mtime size file; do

        if [[ -z "$file" ]]; then
            continue
        fi

        local mtime_int
        mtime_int="${mtime%.*}"

        local age_seconds
        age_seconds=$((now - mtime_int))

        if (( age_seconds < 0 )); then
            age_seconds=0
        fi

        local age_days
        age_days=$((age_seconds / 86400))

        local category
        category=$(get_file_category "$file")

        printf "%-10s %-15s %-20s %s\n" \
            "${age_days}d" \
            "$(format_bytes "$size")" \
            "$category" \
            "$file"

        ((found_files++))

    done < <(
        find "$directory" \
            -path "$CACHE_DIR" -prune -o \
            -path "$DOCKER_DIR" -prune -o \
            -path "$TRASH_DIR" -prune -o \
            -type f \
            -size +"${AGE_MIN_SIZE_BYTES}"c \
            -mtime +"$AGE_THRESHOLD_DAYS" \
            -printf '%T@\t%s\t%p\n' \
            2>/dev/null |
        sort -t $'\t' -k2,2nr |
        head -n 20
    )

    echo

    if (( found_files == 0 )); then
        echo "No large files older than $AGE_THRESHOLD_DAYS days were found."
        echo
        return
    fi

    echo "AGE INTERPRETATION"
    echo "------------------------------------------"
    echo

    if (( stale_size > 0 )); then
        echo "Strong review candidates were found."
        echo "$(format_bytes "$stale_size") belongs to files older than 180 days."
    elif (( very_old_size > 0 )); then
        echo "Several files are substantially old."
        echo "$(format_bytes "$very_old_size") belongs to files older than 90 days."
    else
        echo "Older files exist, but none exceed 90 days."
        echo "Review them based on their location and purpose."
    fi

    echo
    echo "IMPORTANT:"
    echo "Age alone does not mean a file is safe to delete."
    echo "Ghost will use age as evidence, not as an automatic"
    echo "deletion decision."
    echo
}

# ==========================================
# CONTEXT-AWARE DIAGNOSIS
# ==========================================

GHOST_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$GHOST_SOURCE_DIR" != "${BASH_SOURCE[0]}" ]] || GHOST_SOURCE_DIR=.
GHOST_SOURCE_DIR="$(cd -- "$GHOST_SOURCE_DIR" && pwd)"
GHOST_SCRIPT_PATH="$GHOST_SOURCE_DIR/${BASH_SOURCE[0]##*/}"
if [[ ! -r "$GHOST_SOURCE_DIR/lib/diagnosis.sh" || ! -r "$GHOST_SOURCE_DIR/lib/history.sh" ]]; then
    echo 'Error: keep ghost.sh and its lib/ directory together.' >&2
    return 1 2>/dev/null || exit 1
fi
source "$GHOST_SOURCE_DIR/lib/diagnosis.sh"
source "$GHOST_SOURCE_DIR/lib/history.sh"

# ==========================================
# FULL SYSTEM SCAN
# ==========================================

scan() {
    show_header
    show_disk_usage
    show_top_directories
}

# ==========================================
# HELP
# ==========================================

show_help() {
    show_header

    echo "Usage:"
    echo "  bash ghost.sh [command]"
    echo "  No command: immediate context-aware diagnosis (same as analyze)."
    echo

    echo "Commands:"
    echo "  scan              Scan disk usage"
    echo "  large             Find files larger than 500 MiB"
    echo "  ghosts            Detect storage ghosts"
    echo "  inspect <path>    Inspect a directory"
    echo "  duplicates        Find confirmed duplicate files"
    echo "  age [path]        Find large files older than 30 days"
    echo "  analyze           Explain storage pressure and rank review findings"
    echo "  snapshot          Save a private local storage baseline"
    echo "  changes [id]      Compare live storage with a saved baseline (default: latest)"
    echo "  help              Show this help message"
    echo
}

# ==========================================
# COMMAND ROUTER
# ==========================================

main() {
    case "${1:-analyze}" in

        scan)
            scan
            ;;

        large)
            find_large_files
            ;;

        ghosts)
            detect_ghosts
            ;;

        inspect)
            if [[ -z "${2:-}" ]]; then
                echo
                echo "Error: inspect requires a directory."
                echo
                echo "Example:"
                echo "  bash ghost.sh inspect ~/.cache"
                echo
                return 1
            fi

            inspect_directory "$2"
            ;;

        duplicates)
            find_duplicates
            ;;

        age)

            if [[ -n "${2:-}" ]]; then
                find_old_files "$2"
            else
                find_old_files "$DOWNLOADS_DIR"
            fi

            ;;

        analyze)
            analyze
            ;;

        snapshot)
            if (( $# != 1 )); then
                echo 'Usage: bash ghost.sh snapshot' >&2
                return 1
            fi
            storage_history snapshot
            ;;

        changes)
            if (( $# > 2 )); then
                echo 'Usage: bash ghost.sh changes [snapshot-id]' >&2
                return 1
            fi
            storage_history changes "${2:-}"
            ;;

        help|-h|--help)
            show_help
            ;;

        *)
            echo
            printf 'Unknown command: %q\n' "$1"
            echo "Run 'bash ghost.sh help' for usage."
            echo
            return 1
            ;;

    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
