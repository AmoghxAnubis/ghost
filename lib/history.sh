#!/usr/bin/env bash
# Explicit, private snapshots of source totals. Stored data is never sourced or
# evaluated. NUL-delimited fields preserve unusual paths without extra packages.

history_uint() { [[ "$1" =~ ^(0|[1-9][0-9]{0,17})$ ]]; }
history_snapshot_name() { [[ "$1" =~ ^snapshot-[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{12}\.ghost$ ]]; }

history_private() {
    local path="$1" mode owner
    [[ ! -L "$path" && -r "$path" ]] || return 1
    mode=$(stat -c '%a' -- "$path") && owner=$(stat -c '%u' -- "$path") || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 077) == 0 ))
}

history_cleanup() {
    local pending
    for pending in "${history_pending[@]}"; do
        [[ "$pending" == "$history_dir"/.pending.* ]] && rm -f -- "$pending"
    done
    [[ "$diagnosis_workspace" == "$diagnosis_temp_root"/ghost-history.* ]] && rm -rf -- "$diagnosis_workspace"
    return 0
}

history_setup() {
    local action="$1" state_root="${XDG_STATE_HOME:-$STORAGE_HOME/.local/state}" tool
    diagnosis_requirements || return 1
    for tool in mkdir mv; do
        command -v "$tool" >/dev/null 2>&1 || { printf 'Error: history requires %s.\n' "$tool" >&2; return 1; }
    done
    if [[ "$state_root" != /* ]]; then
        echo 'Error: XDG_STATE_HOME must be an absolute path.' >&2
        return 1
    fi
    history_dir="${state_root%/}/ghost"
    if [[ -L "$history_dir" ]]; then
        echo 'Error: Ghost history must be a private directory, not a symlink.' >&2
        return 1
    fi
    if [[ "$action" == snapshot ]]; then
        (umask 077; mkdir -p -- "$history_dir") || return 1
    elif [[ ! -e "$history_dir" ]]; then
        echo 'No saved baseline. Run: bash ghost.sh snapshot'
        return 3
    fi
    if [[ ! -d "$history_dir" || ! -x "$history_dir" ]] || ! history_private "$history_dir"; then
        echo 'Error: history directory must belong to you with no group/other permissions.' >&2
        return 1
    fi
    IFS= read -r -d '' history_dir < <(realpath -ze -- "$history_dir") || return 1
    IFS= read -r -d '' diagnosis_physical_home < <(realpath -ze -- "$STORAGE_HOME") || return 1
    history_home_device=$(stat -c '%d' -- "$STORAGE_HOME") || return 1
    history_scope="known-v1;du-one-filesystem;downloads-top-level-min=$AGE_MIN_SIZE_BYTES;exclude=$history_dir"
    IFS= read -r -d '' diagnosis_temp_root < <(realpath -ze -- "${TMPDIR:-/tmp}") || return 1
    diagnosis_workspace=$(mktemp -d "$diagnosis_temp_root/ghost-history.XXXXXXXX") || return 1
    trap history_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    storage_source_catalog
}

# GNU du exclusions use glob patterns; quote every metacharacter in a literal
# state path. Excluding Ghost's own state prevents saving history creating growth.
history_exclusion() {
    history_exclude_pattern="${history_dir//\\/\\\\}"
    history_exclude_pattern="${history_exclude_pattern//\[/\\[}"
    history_exclude_pattern="${history_exclude_pattern//\*/\\*}"
    history_exclude_pattern="${history_exclude_pattern//\?/\\?}"
}

history_collect() {
    local index path measurement bytes blocks device failed file_device inode key
    local -A download_seen=()
    history_exclusion
    for ((index=0; index<${#storage_source_ids[@]}; index++)); do
        path="${storage_source_paths[$index]}"
        history_statuses[$index]=error
        history_bytes[$index]=-
        history_devices[$index]=-
        if ! diagnosis_source "$path"; then
            history_statuses[$index]="$diagnosis_source_status"
            continue
        fi
        [[ -d "$path" ]] || continue
        path="$diagnosis_source_path"
        device=$(stat -c '%d' -- "$path" 2> "$diagnosis_workspace/errors") || continue
        [[ "$device" =~ ^[0-9]+$ ]] || continue
        if [[ "${storage_source_kinds[$index]}" == downloads ]]; then
            # No personal filenames are retained, even in the scratch records.
            if ! LC_ALL=C find "$path" -xdev -mindepth 1 -maxdepth 1 -type f \
                -size +"${AGE_MIN_SIZE_BYTES}"c -printf '%D\0%i\0%b\0' \
                > "$diagnosis_workspace/blocks" 2> "$diagnosis_workspace/errors"; then
                continue
            fi
            bytes=0
            failed=0
            while IFS= read -r -d '' file_device; do
                if ! IFS= read -r -d '' inode || ! IFS= read -r -d '' blocks; then
                    failed=1
                    break
                fi
                if [[ ! "$file_device" =~ ^[0-9]+$ || ! "$inode" =~ ^[0-9]+$ ]]; then
                    failed=1
                    break
                fi
                key="$file_device:$inode"
                [[ -z "${download_seen[$key]+exists}" ]] || continue
                download_seen[$key]=1
                if ! history_uint "$blocks" || (( blocks > 1000000000000000 || bytes > 999999999999999999 - blocks * 512 )); then
                    failed=1
                    break
                fi
                bytes=$((bytes + blocks * 512))
            done < "$diagnosis_workspace/blocks"
            (( failed == 0 )) || continue
        else
            if ! measurement=$(du -sxB1 --exclude="$history_exclude_pattern" -- "$path" 2> "$diagnosis_workspace/errors"); then
                continue
            fi
            bytes="${measurement%%$'\t'*}"
        fi
        history_uint "$bytes" || continue
        history_statuses[$index]=ok
        history_bytes[$index]="$bytes"
        history_devices[$index]="$device"
    done
}

history_write_snapshot() {
    local pending stamp name index pointer now
    now=$(date +%s) && history_uint "$now" || return 1
    stamp=$(date -u -d "@$now" +%Y%m%dT%H%M%SZ) || return 1
    pending=$(mktemp "$history_dir/.pending.XXXXXXXXXXXX") || return 1
    history_pending+=("$pending")
    name="snapshot-$stamp-${pending##*.}.ghost"
    {
        printf '%s\0' GHOST-SNAPSHOT 1 "$now" "$diagnosis_physical_home" "$history_home_device" "$history_scope" "${#storage_source_ids[@]}"
        for ((index=0; index<${#storage_source_ids[@]}; index++)); do
            printf '%s\0' "${storage_source_ids[$index]}" "${storage_source_paths[$index]}" \
                "${history_statuses[$index]}" "${history_bytes[$index]}" "${history_devices[$index]}"
        done
    } > "$pending" || return 1
    # Publish a complete immutable record, then atomically update the default.
    mv -T -n -- "$pending" "$history_dir/$name" || return 1
    [[ ! -e "$pending" ]] || return 1
    pointer=$(mktemp "$history_dir/.pending.XXXXXXXXXXXX") || return 1
    history_pending+=("$pointer")
    printf '%s\0' "$name" > "$pointer" || return 1
    mv -T -- "$pointer" "$history_dir/latest" || return 1
    printf 'Saved snapshot: %s\n' "$name"
    printf 'Private local history: %q\n' "$history_dir"
    echo 'Known-location totals only; individual filenames are not stored.'
    echo 'Compare later with: bash ghost.sh changes'
}

history_load_snapshot() {
    local name="$1" fd value extra index field invalid=0 size
    local -a header=() record=()
    if [[ -z "$name" ]]; then
        if [[ ! -f "$history_dir/latest" ]]; then
            echo 'No saved baseline. Run: bash ghost.sh snapshot'
            return 3
        fi
        if ! history_private "$history_dir/latest"; then
            echo 'Error: latest snapshot pointer is not private or is a symlink.' >&2
            return 1
        fi
        size=$(stat -c '%s' -- "$history_dir/latest") || return 1
        if ! history_uint "$size" || (( size > 128 )); then
            echo 'Error: invalid latest snapshot pointer size.' >&2
            return 1
        fi
        exec {fd}< "$history_dir/latest" || return 1
        IFS= read -r -d '' name <&"$fd" || invalid=1
        extra=''
        if IFS= read -r -d '' extra <&"$fd" || [[ -n "$extra" ]]; then invalid=1; fi
        exec {fd}<&-
    fi
    if (( invalid != 0 )) || ! history_snapshot_name "$name"; then
        echo 'Error: invalid snapshot identifier. Use the ID printed by snapshot.' >&2
        return 1
    fi
    if [[ ! -f "$history_dir/$name" ]] || ! history_private "$history_dir/$name"; then
        echo 'Error: snapshot is missing, not private, or is a symlink.' >&2
        return 1
    fi
    size=$(stat -c '%s' -- "$history_dir/$name") || return 1
    if ! history_uint "$size" || (( size > 262144 )); then
        echo 'Error: invalid snapshot size.' >&2
        return 1
    fi
    exec {fd}< "$history_dir/$name" || return 1
    for ((field=0; field<7; field++)); do
        if ! IFS= read -r -d '' value <&"$fd"; then invalid=1; break; fi
        header+=("$value")
    done
    if (( invalid == 0 )); then
        if [[ "${header[0]}" != GHOST-SNAPSHOT || "${header[1]}" != 1 || "${header[6]}" != "${#storage_source_ids[@]}" ]] ||
            ! history_uint "${header[2]}" || (( header[2] > 253402300799 )); then
            invalid=1
        fi
    fi
    if (( invalid == 0 )); then
        for ((index=0; index<${#storage_source_ids[@]}; index++)); do
            record=()
            for ((field=0; field<5; field++)); do
                if ! IFS= read -r -d '' value <&"$fd"; then invalid=1; break; fi
                record+=("$value")
            done
            (( invalid == 0 )) || break
            if [[ "${record[0]}" != "${storage_source_ids[$index]}" || "${record[1]}" != /* ]]; then invalid=1; break; fi
            case "${record[2]}" in
                ok)
                    if ! history_uint "${record[3]}" || [[ ! "${record[4]}" =~ ^[0-9]+$ ]]; then invalid=1; break; fi ;;
                missing|unreadable|alias|error)
                    if [[ "${record[3]}" != - || "${record[4]}" != - ]]; then invalid=1; break; fi ;;
                *) invalid=1; break ;;
            esac
            baseline_paths+=("${record[1]}")
            baseline_statuses+=("${record[2]}")
            baseline_bytes+=("${record[3]}")
            baseline_devices+=("${record[4]}")
        done
        extra=''
        if IFS= read -r -d '' extra <&"$fd" || [[ -n "$extra" ]]; then invalid=1; fi
    fi
    exec {fd}<&-
    if (( invalid != 0 )); then
        echo 'Error: malformed or unsupported snapshot; no comparison made.' >&2
        return 1
    fi
    if [[ "${header[3]}" != "$diagnosis_physical_home" || "${header[4]}" != "$history_home_device" || "${header[5]}" != "$history_scope" ]]; then
        echo 'Snapshot scope or home filesystem differs. Save a fresh baseline; no comparison made.'
        return 2
    fi
    baseline_time="${header[2]}"
    baseline_name="$name"
}

history_render_changes() {
    local index delta magnitude section unchanged=0 incomparable=0 unavailable=0 changed=0
    local -a deltas=() reasons=()
    printf 'CHANGES SINCE %s\n' "$(date -u -d "@$baseline_time" '+%Y-%m-%d %H:%M:%S UTC')"
    printf 'Baseline: %s\n' "$baseline_name"
    echo 'Scope: known locations; Downloads includes only top-level files >10 MiB.'
    for ((index=0; index<${#storage_source_ids[@]}; index++)); do
        deltas[$index]=0
        if [[ "${baseline_paths[$index]}" != "${storage_source_paths[$index]}" ]]; then
            reasons[$index]='source path changed'
        elif [[ "${baseline_statuses[$index]}" == missing && "${history_statuses[$index]}" == missing ]]; then
            reasons[$index]='absent in both scans (optional source)'
        elif [[ "${baseline_statuses[$index]}" != ok || "${history_statuses[$index]}" != ok ]]; then
            reasons[$index]="baseline=${baseline_statuses[$index]}, now=${history_statuses[$index]}"
        elif [[ "${baseline_devices[$index]}" != "${history_devices[$index]}" ]]; then
            reasons[$index]='source filesystem changed'
        else
            reasons[$index]=''
            deltas[$index]=$((history_bytes[index] - baseline_bytes[index]))
            if (( deltas[index] == 0 )); then unchanged=$((unchanged + 1)); fi
        fi
    done
    for section in GROWTH SHRINKAGE; do
        echo
        echo "$section (largest first)"
        changed=0
        while read -r magnitude index; do
            [[ -n "$index" ]] || continue
            changed=$((changed + 1))
            delta="${deltas[$index]}"
            if (( delta > 0 )); then printf '+'; else printf '-'; fi
            printf '%s  %s\n' "$(format_bytes "$magnitude")" "${storage_source_labels[$index]}"
            printf '   %q | %s -> %s on disk\n' "${storage_source_paths[$index]}" \
                "$(format_bytes "${baseline_bytes[$index]}")" "$(format_bytes "${history_bytes[$index]}")"
            printf '   Investigate: bash %q inspect %q\n' "$GHOST_SCRIPT_PATH" "${storage_source_paths[$index]}"
        done < <(
            for ((index=0; index<${#storage_source_ids[@]}; index++)); do
                [[ -z "${reasons[$index]}" ]] || continue
                delta="${deltas[$index]}"
                if [[ "$section" == GROWTH ]] && (( delta > 0 )); then printf '%s %s\n' "$delta" "$index"; fi
                if [[ "$section" == SHRINKAGE ]] && (( delta < 0 )); then printf '%s %s\n' "$((-delta))" "$index"; fi
            done | LC_ALL=C sort -k1,1nr -k2,2n
        )
        (( changed > 0 )) || echo 'None among comparable sources.'
    done
    echo
    echo 'NOT COMPARABLE'
    for ((index=0; index<${#storage_source_ids[@]}; index++)); do
        [[ -n "${reasons[$index]}" ]] || continue
        unavailable=$((unavailable + 1))
        if [[ "${reasons[$index]}" != 'absent in both scans (optional source)' ]]; then
            incomparable=$((incomparable + 1))
        fi
        printf '  %s: %s\n' "${storage_source_labels[$index]}" "${reasons[$index]}"
    done
    (( unavailable > 0 )) || echo 'All sources have comparable measurements.'
    printf '\nUnchanged comparable sources: %s\n' "$unchanged"
    echo 'Locations may overlap; changes are separate observations, not a combined total.'
    echo 'A decrease does not establish cleanup or recovered space. Ghost history is excluded.'
    echo 'No snapshot saved by changes; your baseline is unchanged.'
    (( incomparable == 0 )) || return 2
}

storage_history() (
    local action="$1" requested="${2:-}" setup_status=0 index incomplete=0
    local diagnosis_workspace='' diagnosis_temp_root='' diagnosis_physical_home='' diagnosis_source_status diagnosis_source_path
    local history_dir='' history_scope history_home_device history_exclude_pattern baseline_time baseline_name
    local -a history_pending=() diagnosis_issues=() storage_source_ids=() storage_source_paths=()
    local -a storage_source_labels=() storage_source_kinds=() storage_source_evidence=()
    local -a history_statuses=() history_bytes=() history_devices=()
    local -a baseline_paths=() baseline_statuses=() baseline_bytes=() baseline_devices=()
    umask 077
    history_setup "$action" || setup_status=$?
    if (( setup_status == 3 )); then return 0; fi
    (( setup_status == 0 )) || return "$setup_status"
    if [[ "$action" == changes ]]; then
        history_load_snapshot "$requested" || setup_status=$?
        if (( setup_status == 3 )); then return 0; fi
        (( setup_status == 0 )) || return "$setup_status"
    fi
    history_collect
    if [[ "$action" == snapshot ]]; then
        if ! history_write_snapshot; then
            echo 'Error: could not complete snapshot save. Use changes to check the active baseline.' >&2
            return 1
        fi
        for ((index=0; index<${#storage_source_ids[@]}; index++)); do
            case "${history_statuses[$index]}" in
                ok) ;;
                missing) printf 'Absent source recorded: %s\n' "${storage_source_labels[$index]}" ;;
                *) printf 'Incomplete source recorded: %s (%s)\n' "${storage_source_labels[$index]}" "${history_statuses[$index]}"; incomplete=1 ;;
            esac
        done
        (( incomplete == 0 )) || return 2
    else
        history_render_changes
    fi
)
