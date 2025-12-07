#!/usr/bin/env bash
set -euo pipefail

# claude-pane uninstaller

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Uninstall claude-pane.

Options:
  --help, -h    Show this help message

Always removes from user directory (~/.local/bin).
If run as root, also removes from global directory (/usr/local/bin).
EOF
    exit "${1:-0}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 1
            ;;
    esac
done

echo "Uninstalling claude-pane..."
echo

# Always remove local install
echo "Removing local install..."
rm -fv "${HOME}/.local/bin/claude-pane" 2>/dev/null || true

# If root, also remove global install
if [[ "$(id -u)" -eq 0 ]]; then
    echo
    echo "Removing global install..."
    rm -fv /usr/local/bin/claude-pane 2>/dev/null || true
else
    echo
    echo "Note: Run as root (sudo ./uninstall.sh) to also remove global install."
fi

echo
echo "Done!"
