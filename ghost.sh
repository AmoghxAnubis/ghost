#!/usr/bin/env bash

# ==========================================
# GHOST
# Disk Space Investigator
# Version 0.6
# ==========================================

set -u

# ==========================================
# CONFIGURATION
# ==========================================

CACHE_DIR="$HOME/.cache"
NPM_DIR="$HOME/.npm"
DOWNLOADS_DIR="$HOME/Downloads"
VAR_DIR="$HOME/.var"
LOCAL_DIR="$HOME/.local"
DOCKER_DIR="$HOME/.docker"

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

    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes / 1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.2f KB\", $bytes / 1024}"
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
# DISK INFORMATION
# ==========================================

get_disk_total() {
    df -B1 "$HOME" | awk 'NR==2 {print $2}'
}

get_disk_used() {
    df -B1 "$HOME" | awk 'NR==2 {print $3}'
}

get_disk_available() {
    df -B1 "$HOME" | awk 'NR==2 {print $4}'
}

get_disk_usage_percent() {
    df "$HOME" | awk 'NR==2 {gsub("%","",$5); print $5}'
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

    df -h "$HOME" | awk 'NR==2 {
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

    du -h --max-depth=1 "$HOME" 2>/dev/null |
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
    echo "Scanning: $HOME"
    echo "Looking for files larger than 500 MB..."
    echo

    files=$(
        find "$HOME" \
            -type f \
            -size +500M \
            -printf '%p\n' \
            2>/dev/null
    )

    if [[ -z "$files" ]]; then
        echo "No files larger than 500 MB were found."
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
        "Docker Storage" \
        "$DOCKER_DIR" \
        "Development environment" \
        "REVIEW" \
        "Inspect unused Docker images, containers and volumes."

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
        "LOW" \
        "Cache data can usually be regenerated by applications."

    detect_ghost \
        "NPM Cache" \
        "$NPM_DIR" \
        "Package manager cache" \
        "LOW" \
        "Unused npm cache can usually be regenerated."

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

inspect_directory() {
    local directory="$1"

    if [[ "$directory" == "~" ]]; then
        directory="$HOME"
    elif [[ "$directory" == "~/"* ]]; then
        directory="$HOME/${directory#~/}"
    fi

    if [[ "$directory" != /* ]]; then
        directory="$(realpath "$directory" 2>/dev/null || echo "$directory")"
    fi

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
    echo "  $directory"
    echo

    local total_size
    total_size=$(get_directory_size "$directory")

    echo "Total size:"
    echo "  $(format_bytes "$total_size")"
    echo

    echo "CONTENTS"
    echo "------------------------------------------"
    echo

    printf "%-15s %s\n" "SIZE" "PATH"
    printf "%-15s %s\n" "----" "----"

    du -sB1 "$directory"/* "$directory"/.[!.]* "$directory"/..?* 2>/dev/null |
        sort -nr |
        head -n 15 |
        while read -r size path; do
            printf "%-15s %s\n" "$(format_bytes "$size")" "$path"
        done

    echo
}

# ==========================================
# ANALYSIS HELPERS
# ==========================================

show_analysis_item() {
    local name="$1"
    local size="$2"
    local category="$3"
    local reclaimability="$4"
    local action="$5"

    echo "👻 $name"
    echo "   Size:            $(format_bytes "$size")"
    echo "   Category:        $category"
    echo "   Reclaimability:  $reclaimability"
    echo "   Action:          $action"
    echo
}

# ==========================================
# DOWNLOAD ANALYSIS
# ==========================================

get_download_candidates() {

    if [[ ! -d "$DOWNLOADS_DIR" ]]; then
        echo "0"
        return
    fi

    find "$DOWNLOADS_DIR" \
        -type f \
        \( \
            -name "*.rpm" \
            -o -name "*.deb" \
            -o -name "*.tar" \
            -o -name "*.tar.gz" \
            -o -name "*.tar.xz" \
            -o -name "*.tgz" \
            -o -name "*.AppImage" \
        \) \
        -printf '%s\n' 2>/dev/null |
        awk '{sum += $1} END {print sum+0}'
}

# ==========================================
# CACHE ANALYSIS
# ==========================================

analyze_cache() {

    local chrome_size=0
    local jetbrains_size=0
    local npm_size=0

    if [[ -d "$CACHE_DIR/google-chrome" ]]; then
        chrome_size=$(get_directory_size "$CACHE_DIR/google-chrome")
    fi

    if [[ -d "$CACHE_DIR/JetBrains" ]]; then
        jetbrains_size=$(get_directory_size "$CACHE_DIR/JetBrains")
    fi

    if [[ -d "$NPM_DIR" ]]; then
        npm_size=$(get_directory_size "$NPM_DIR")
    fi

    if (( chrome_size > 0 )); then
        show_analysis_item \
            "Chrome Cache" \
            "$chrome_size" \
            "Browser Cache" \
            "HIGH" \
            "Can usually be regenerated by Chrome."
    fi

    if (( jetbrains_size > 0 )); then
        show_analysis_item \
            "JetBrains Cache" \
            "$jetbrains_size" \
            "IDE Cache" \
            "HIGH" \
            "Can usually be regenerated by JetBrains IDEs."
    fi

    if (( npm_size > 0 )); then
        show_analysis_item \
            "NPM Cache" \
            "$npm_size" \
            "Package Manager Cache" \
            "HIGH" \
            "Can usually be regenerated by npm."
    fi
}

# ==========================================
# CACHE CANDIDATE SIZE
# ==========================================

get_cache_candidate_size() {

    local chrome_size=0
    local jetbrains_size=0
    local npm_size=0

    if [[ -d "$CACHE_DIR/google-chrome" ]]; then
        chrome_size=$(get_directory_size "$CACHE_DIR/google-chrome")
    fi

    if [[ -d "$CACHE_DIR/JetBrains" ]]; then
        jetbrains_size=$(get_directory_size "$CACHE_DIR/JetBrains")
    fi

    if [[ -d "$NPM_DIR" ]]; then
        npm_size=$(get_directory_size "$NPM_DIR")
    fi

    echo $((chrome_size + jetbrains_size + npm_size))
}

# ==========================================
# STORAGE ANALYSIS
# ==========================================

analyze() {

    show_header

    echo "STORAGE ANALYSIS"
    echo "------------------------------------------"
    echo

    # --------------------------------------
    # Disk health
    # --------------------------------------

    local total
    local used
    local available
    local usage
    local health

    total=$(get_disk_total)
    used=$(get_disk_used)
    available=$(get_disk_available)
    usage=$(get_disk_usage_percent)
    health=$(get_storage_health "$usage")

    echo "DISK HEALTH"
    echo "------------------------------------------"
    echo
    echo "Used:              $(format_bytes "$used") / $(format_bytes "$total")"
    echo "Usage:             ${usage}%"
    echo "Available:         $(format_bytes "$available")"
    echo "Storage Health:    $health"
    echo

    # --------------------------------------
    # High priority
    # --------------------------------------

    echo "HIGH PRIORITY"
    echo "------------------------------------------"
    echo

    local docker_size=0
    local downloads_size=0
    local download_candidates=0

    docker_size=$(get_directory_size "$DOCKER_DIR")
    downloads_size=$(get_directory_size "$DOWNLOADS_DIR")
    download_candidates=$(get_download_candidates)

    if (( docker_size > 0 )); then
        show_analysis_item \
            "Docker Desktop" \
            "$docker_size" \
            "Development Infrastructure" \
            "MEDIUM" \
            "Inspect Docker resources before cleanup."
    fi

    if (( downloads_size > 0 )); then
        show_analysis_item \
            "Downloads" \
            "$downloads_size" \
            "Installers / Archives / User Files" \
            "HIGH" \
            "Review old installers and archives before removing."
    fi

    if (( download_candidates > 0 )); then
        echo "   Installer/archive candidates:"
        echo "   $(format_bytes "$download_candidates")"
        echo
    fi

    # --------------------------------------
    # Cache candidates
    # --------------------------------------

    echo "CACHE CANDIDATES"
    echo "------------------------------------------"
    echo

    analyze_cache
    local cache_candidates
    cache_candidates=$(get_cache_candidate_size)

    # --------------------------------------
    # Review required
    # --------------------------------------

    echo "REVIEW REQUIRED"
    echo "------------------------------------------"
    echo

    local var_size=0
    local local_size=0

    var_size=$(get_directory_size "$VAR_DIR")
    local_size=$(get_directory_size "$LOCAL_DIR")

    if (( var_size > 0 )); then
        show_analysis_item \
            "Application Storage" \
            "$var_size" \
            "Application Data" \
            "LOW" \
            "Inspect applications before removing data."
    fi

    if (( local_size > 0 )); then
        show_analysis_item \
            "User Application Data" \
            "$local_size" \
            "Application Data" \
            "LOW" \
            "Inspect before removing anything."
    fi

    # --------------------------------------
    # Summary
    # --------------------------------------

    echo "SUMMARY"
    echo "------------------------------------------"
    echo

    local known_consumers=0

    known_consumers=$(
        (
            echo "$docker_size"
            echo "$downloads_size"
            echo "$(get_directory_size "$CACHE_DIR")"
            echo "$(get_directory_size "$NPM_DIR")"
            echo "$var_size"
            echo "$local_size"
        ) |
        awk '{sum += $1} END {print sum+0}'
    )

    echo "Known storage consumers:  $(format_bytes "$known_consumers")"
    echo "Cache candidates:        $(format_bytes "$cache_candidates")"
    echo "Storage Health:          $health"
    echo

    echo "RECOMMENDATION"
    echo "------------------------------------------"
    echo

    if (( usage >= 85 )); then
        echo "Your disk is under significant storage pressure."
        echo "Investigate Docker, Downloads and cache candidates."
    elif (( usage >= 70 )); then
        echo "Your disk has moderate storage pressure."
        echo "Review the largest storage consumers before they grow."
    else
        echo "Your disk is not currently under storage pressure."
        echo "The largest investigation targets are:"
        echo "  1. Docker storage"
        echo "  2. Downloads"
        echo "  3. Application caches"
    fi

    echo
}

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
    echo "  ./ghost.sh <command>"
    echo

    echo "Commands:"
    echo "  scan              Scan disk usage"
    echo "  large             Find files larger than 500 MB"
    echo "  ghosts            Detect storage ghosts"
    echo "  inspect <path>    Inspect a directory"
    echo "  analyze           Analyze storage and give recommendations"
    echo "  help              Show this help message"
    echo
}

# ==========================================
# COMMAND ROUTER
# ==========================================

case "${1:-help}" in

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
            echo "  ./ghost.sh inspect ~/.cache"
            echo
            exit 1
        fi

        inspect_directory "$2"
        ;;

    analyze)
        analyze
        ;;

    help)
        show_help
        ;;

    *)
        echo
        echo "Unknown command: $1"
        echo "Run './ghost.sh help' for usage."
        echo
        exit 1
        ;;

esac