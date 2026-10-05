```bash
#!/usr/bin/env bash

# Ghost - Disk Space Investigator
# Version 0.2

set -u

show_header() {
    echo
    echo "Ghost - Disk Space Investigator"
    echo "================================"
    echo
}

show_disk_usage() {
    echo "SYSTEM STORAGE"
    echo "--------------------------------"
    echo

    df -h "$HOME" | awk 'NR==2 {
        printf "Total:       %s\n", $2
        printf "Used:        %s\n", $3
        printf "Available:   %s\n", $4
        printf "Usage:       %s\n", $5
    }'

    echo
}

show_top_directories() {
    echo "TOP DIRECTORIES"
    echo "--------------------------------"
    echo

    du -h --max-depth=1 "$HOME" 2>/dev/null |
        sort -hr |
        head -n 10

    echo
}

find_large_files() {
    show_header

    echo "LARGE FILE INVESTIGATOR"
    echo "--------------------------------"
    echo
    echo "Scanning: $HOME"
    echo
    echo "This may take a moment..."
    echo

    find "$HOME" -type f -size +500M -printf '%s %p\n' 2>/dev/null |
        sort -nr |
        head -n 15 |
        awk '{
            size = $1
            $1 = ""
            file = substr($0, 2)

            if (size >= 1073741824)
                printf "%.2f GB\t%s\n", size / 1073741824, file
            else
                printf "%.2f MB\t%s\n", size / 1048576, file
        }'

    echo
}

scan() {
    show_header
    show_disk_usage
    show_top_directories
}

show_help() {
    show_header

    echo "Usage:"
    echo "  ./ghost.sh <command>"
    echo
    echo "Commands:"
    echo "  scan       Scan disk usage"
    echo "  large      Find large files"
    echo "  help       Show this help message"
    echo
}

case "${1:-help}" in
    scan)
        scan
        ;;

    large)
        find_large_files
        ;;

    help)
        show_help
        ;;

    *)
        echo "Unknown command: $1"
        echo
        echo "Run './ghost.sh help' for usage."
        exit 1
        ;;
esac
```