#!/usr/bin/env bash
# Local, read-only context engine. Loaded by ghost.sh, not an executable entry point.

diagnosis_requirements() {
    local tool
    for tool in df du find stat realpath sort awk date mktemp rm; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'Error: diagnosis requires %s (GNU utilities on Linux).\n' "$tool" >&2
            return 1
        fi
    done
    if ! stat -c '%s' -- "${BASH_SOURCE[0]}" >/dev/null 2>&1 ||
       ! realpath -e -- "$STORAGE_HOME" >/dev/null 2>&1; then
        echo 'Error: diagnosis requires a readable home and GNU stat/realpath.' >&2
        return 1
    fi
}

diagnosis_issue() {
    diagnosis_issues+=("$1")
}

# Never follow an aliased source into personal or application-owned storage.
# HOME itself may be a symlink; components below it must retain their location.
diagnosis_source() {
    local path="$1" canonical expected
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        # A missing directory below an inaccessible parent is not a known zero.
        local parent="${path%/*}"
        while [[ ! -e "$parent" && "$parent" != / ]]; do
            parent="${parent%/*}"
            [[ -n "$parent" ]] || parent=/
        done
        if [[ ! -r "$parent" || ! -x "$parent" ]]; then
            diagnosis_issue "Cannot check source below an unreadable directory: $(printf '%q' "$path")"
        fi
        return 1
    fi
    if ! IFS= read -r -d '' canonical < <(realpath -ze -- "$path" 2>/dev/null); then
        diagnosis_issue "Cannot resolve source: $(printf '%q' "$path")"
        return 1
    fi
    expected="${diagnosis_physical_home%/}/${path#"$STORAGE_HOME"/}"
    if [[ "$canonical" != "$expected" || -L "$path" ]]; then
        diagnosis_issue "PROTECTED alias skipped: $(printf '%q' "$path")"
        return 1
    fi
    if [[ ! -r "$path" || ( -d "$path" && ! -x "$path" ) ]]; then
        diagnosis_issue "Unreadable source: $(printf '%q' "$path")"
        return 1
    fi
}

# Positive evidence of ownership takes precedence over every candidate rule.
diagnosis_protected_context() {
    local path="$1" parent="$1" root
    for root in "$LOCAL_DIR" "$VAR_DIR" "$DOCKER_DIR" "$STORAGE_HOME/.config" \
        "$STORAGE_HOME/Documents" "$STORAGE_HOME/Pictures" "$STORAGE_HOME/Videos" \
        "$STORAGE_HOME/Music" "$STORAGE_HOME/Desktop" "$STORAGE_HOME/Projects"; do
        if [[ "$path" == "$root" || "$path" == "$root/"* ]]; then
            return 0
        fi
    done
    if [[ "$path" == "$NPM_DIR" || "$path" == "$NPM_DIR/"* ]]; then
        [[ "$path" == "$NPM_DIR/_cacache" ]] || return 0
    fi
    [[ -d "$parent" ]] || parent="${parent%/*}"
    while [[ "$parent" == "$STORAGE_HOME" || "$parent" == "$STORAGE_HOME/"* ]]; do
        if [[ -e "$parent/.git" || -e "$parent/.hg" || -f "$parent/package.json" ||
              -f "$parent/pyproject.toml" || -f "$parent/Cargo.toml" ||
              ! -r "$parent" || ! -x "$parent" ]]; then
            return 0
        fi
        [[ "$parent" == "$STORAGE_HOME" ]] && break
        parent="${parent%/*}"
    done
    return 1
}

classify_finding() {
    local path="$1" kind="$2" age="$3"
    finding_class=PROTECTED
    finding_reason='Unknown or personal data; reclaimability has not been established.'
    if diagnosis_protected_context "$path"; then
        finding_reason='Personal, project, or application-managed context takes precedence; inspect before acting.'
    elif [[ "$kind" == cache && ( "$path" == "$CACHE_DIR/google-chrome" ||
            "$path" == "$CACHE_DIR/JetBrains" || "$path" == "$NPM_DIR/_cacache" ) ]]; then
        finding_class=REVIEW
        finding_reason='Recognized cache location; application state and cleanup semantics have not been checked.'
    elif [[ "$kind" == download && "$path" == "$DOWNLOADS_DIR/"* ]]; then
        case "${path,,}" in
            *.iso|*.rpm|*.deb|*.tar|*.tar.gz|*.tar.xz|*.tgz|*.zip|*.7z|*.appimage)
                if (( age > AGE_THRESHOLD_DAYS )); then
                    finding_class=REVIEW
                    finding_reason='Large installer/archive download, modified over 30 days ago; it may still be needed.'
                else
                    finding_reason='Recent installer/archive download; age does not justify a stale-file recommendation.'
                fi
                ;;
        esac
    fi
}

diagnosis_add() {
    local path="$1" allocated="$2" logical="$3" evidence="$4" kind="$5" age="${6:-0}"
    # Only successfully measured, nonzero allocations are useful priorities.
    [[ "$allocated" =~ ^[0-9]+$ && "$logical" =~ ^[0-9]+$ ]] || return 1
    (( allocated > 0 )) || return 0
    classify_finding "$path" "$kind" "$age"
    finding_paths+=("$path")
    finding_allocated+=("$allocated")
    finding_logical+=("$logical")
    finding_evidence+=("$evidence")
    finding_classes+=("$finding_class")
    finding_reasons+=("$finding_reason")
    if [[ -d "$path" ]]; then
        finding_inspect+=("$path")
    else
        finding_inspect+=("${path%/*}")
    fi
}

diagnosis_directory() {
    local path="$1" kind="$2" evidence="$3" measurement bytes
    diagnosis_source "$path" || return 0
    if [[ ! -d "$path" ]]; then
        diagnosis_issue "Expected a directory: $(printf '%q' "$path")"
        return 0
    fi
    # Capture the producer's exit status, not awk's. A partial du is not a zero.
    if ! measurement=$(du -sxB1 -- "$path" 2> "$diagnosis_workspace/errors"); then
        diagnosis_issue "Directory measurement incomplete: $(printf '%q' "$path")"
        return 0
    fi
    bytes="${measurement%%$'\t'*}"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        diagnosis_issue "Invalid directory measurement: $(printf '%q' "$path")"
        return 0
    fi
    # For directories, logical size is deliberately not inferred from du.
    diagnosis_add "$path" "$bytes" 0 "$evidence" "$kind"
}

diagnosis_downloads() {
    diagnosis_source "$DOWNLOADS_DIR" || return 0
    if [[ ! -d "$DOWNLOADS_DIR" ]]; then
        diagnosis_issue "Expected Downloads directory: $(printf '%q' "$DOWNLOADS_DIR")"
        return 0
    fi
    local logical blocks mtime path age timestamp now
    now=$(date +%s)
    # Spool records so find's failures remain visible; NULs preserve every name.
    if ! find "$DOWNLOADS_DIR" -xdev -mindepth 1 -maxdepth 1 -type f \
        -size +"${AGE_MIN_SIZE_BYTES}"c -printf '%s\0%b\0%T@\0%p\0' \
        > "$diagnosis_workspace/downloads" 2> "$diagnosis_workspace/errors"; then
        diagnosis_issue "Downloads scan incomplete: $(printf '%q' "$DOWNLOADS_DIR")"
    fi
    while IFS= read -r -d '' logical && IFS= read -r -d '' blocks &&
          IFS= read -r -d '' mtime && IFS= read -r -d '' path; do
        timestamp="${mtime%.*}"
        if [[ ! "$logical" =~ ^[0-9]+$ || ! "$blocks" =~ ^[0-9]+$ ||
              ! "$timestamp" =~ ^-?[0-9]+$ ]]; then
            diagnosis_issue "Invalid file measurement: $(printf '%q' "$path")"
            continue
        fi
        age=$(( (now - timestamp) / 86400 ))
        (( age >= 0 )) || age=0
        diagnosis_add "$path" "$((blocks * 512))" "$logical" \
            "download file; modified ${age}d ago" download "$age"
    done < "$diagnosis_workspace/downloads"
}

diagnosis_disk() {
    local snapshot total used available percent
    # POSIX layout avoids wrapping mount/device names; one snapshot for all values.
    if snapshot=$(LC_ALL=C df -PB1 -- "$STORAGE_HOME" 2> "$diagnosis_workspace/errors"); then
        read -r total used available percent < <(printf '%s\n' "$snapshot" | awk 'NR==2 {print $2,$3,$4,$5}') || true
        percent="${percent%%%}"
        if [[ "$total" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ &&
              "$available" =~ ^[0-9]+$ && "$percent" =~ ^[0-9]+$ ]]; then
            printf 'Storage pressure: %s | %s%% used | %s available\n' \
                "$(get_storage_health "$percent")" "$percent" "$(format_bytes "$available")"
            printf 'Used: %s / %s (home filesystem)\n' "$(format_bytes "$used")" "$(format_bytes "$total")"
            return
        fi
    fi
    echo 'Storage pressure: UNKNOWN (filesystem measurement unavailable)'
    diagnosis_issue 'Disk measurement failed; pressure could not be established.'
}

diagnosis_render_finding() {
    local index="$1" prefix="$2" command_path="$0"
    # When sourced, use the original script rather than the caller's name.
    [[ "$command_path" == *ghost.sh ]] || command_path="$GHOST_SCRIPT_PATH"
    printf '%s%s  %q\n' "$prefix" "${finding_classes[$index]}" "${finding_paths[$index]}"
    printf '   %s on disk | %s\n' "$(format_bytes "${finding_allocated[$index]}")" "${finding_evidence[$index]}"
    if (( finding_logical[index] > 0 && finding_logical[index] != finding_allocated[index] )); then
        printf '   Logical size: %s (allocation determines rank)\n' "$(format_bytes "${finding_logical[$index]}")"
    fi
    printf '   Why: %s\n' "${finding_reasons[$index]}"
    printf '   Investigate: bash %q inspect %q\n\n' "$command_path" "${finding_inspect[$index]}"
}

# A subshell scopes temporary state/traps and never leaks into a sourcing caller.
analyze() (
    diagnosis_requirements || return 1
    local diagnosis_workspace diagnosis_physical_home diagnosis_temp_root
    if ! IFS= read -r -d '' diagnosis_temp_root < <(realpath -ze -- "${TMPDIR:-/tmp}"); then
        echo 'Error: cannot resolve temporary directory.' >&2
        return 1
    fi
    diagnosis_workspace=$(mktemp -d "$diagnosis_temp_root/ghost-diagnosis.XXXXXXXX") || return 1
    trap '[[ "$diagnosis_workspace" == "$diagnosis_temp_root"/ghost-diagnosis.* ]] && rm -rf -- "$diagnosis_workspace"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local -a diagnosis_issues=() finding_paths=() finding_allocated=() finding_logical=()
    local -a finding_evidence=() finding_classes=() finding_reasons=() finding_inspect=()
    local finding_class finding_reason
    if ! IFS= read -r -d '' diagnosis_physical_home < <(realpath -ze -- "$STORAGE_HOME"); then
        echo 'Error: cannot resolve home directory.' >&2
        return 1
    fi
    show_header
    diagnosis_disk
    echo 'Scope: known app/cache locations + top-level Downloads (>10 MiB).'
    echo 'For nested Downloads or duplicate files, use the deeper investigation commands.'
    echo
    # Progress belongs on interactive stderr, never in a captured report.
    [[ ! -t 2 ]] || printf 'Ghost: measuring known storage locations...\n' >&2
    diagnosis_directory "$CACHE_DIR/google-chrome" cache 'browser cache location; application state unknown'
    diagnosis_directory "$CACHE_DIR/JetBrains" cache 'IDE cache location; application state unknown'
    diagnosis_directory "$NPM_DIR/_cacache" cache 'npm content-cache location; application state unknown'
    diagnosis_directory "$LOCAL_DIR" context 'application-managed data; directory measurement only'
    diagnosis_directory "$VAR_DIR" context 'application-managed data; directory measurement only'
    diagnosis_directory "$DOCKER_DIR" context 'Docker directory only; images/volumes and reclaimability unknown'
    diagnosis_downloads

    local index rank=0 review_count=0 protected_count=0
    echo 'START HERE'
    echo 'Largest measured REVIEW findings; this order is not a safety score.'
    # Sort numeric byte/index pairs only. Paths never pass through line parsing.
    while read -r _ index; do
        [[ -n "$index" ]] || continue
        review_count=$((review_count + 1))
        if (( rank < 3 )); then
            rank=$((rank + 1))
            diagnosis_render_finding "$index" "$rank. "
        fi
    done < <(
        for ((index=0; index<${#finding_paths[@]}; index++)); do
            if [[ "${finding_classes[$index]}" == REVIEW ]]; then
                printf '%s %s\n' "${finding_allocated[$index]}" "$index"
            fi
        done | LC_ALL=C sort -k1,1nr -k2,2n
    )
    if (( review_count == 0 )); then
        if (( ${#diagnosis_issues[@]} > 0 )); then
            echo 'No review candidates in successfully measured sources; the scan is incomplete.'
        else
            echo 'No review candidates in this scope. Broaden the investigation with scan or age.'
        fi
        echo
    elif (( review_count > 3 )); then
        printf 'Showing 3 of %s review findings in this scope.\n\n' "$review_count"
    fi
    echo 'PROTECTED STORAGE CONTEXT'
    for ((index=0; index<${#finding_paths[@]}; index++)); do
        [[ "${finding_classes[$index]}" == PROTECTED ]] || continue
        protected_count=$((protected_count + 1))
        diagnosis_render_finding "$index" ''
    done
    (( protected_count > 0 )) || echo 'No protected findings were measured in this scope.'
    if (( ${#diagnosis_issues[@]} > 0 )); then
        echo
        echo 'SCAN INCOMPLETE'
        printf '  - %s\n' "${diagnosis_issues[@]}"
    fi
    echo
    echo 'Investigation only. No user files changed. Review bytes are not guaranteed recovery.'
    echo 'SAFE is reserved for verified cleanup rules; this diagnosis makes no SAFE claims.'
    echo 'Age means time since modification, not last use. Sources may overlap; no recovery total is inferred.'
    printf 'Deeper age evidence: bash %q age %q\n' "$GHOST_SCRIPT_PATH" "$DOWNLOADS_DIR"
    printf 'Duplicate investigation: bash %q duplicates\n' "$GHOST_SCRIPT_PATH"
    (( ${#diagnosis_issues[@]} == 0 )) || return 2
)
