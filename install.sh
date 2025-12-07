#!/usr/bin/env bash
set -euo pipefail

# claude-pane installer

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Install claude-pane.

Options:
  --local    Install to user directory (~/.local/bin)
             Default: global install to /usr/local/bin

Global install requires root privileges (use: sudo ./install.sh)
EOF
    exit "${1:-0}"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Defaults
LOCAL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            LOCAL=true
            shift
            ;;
        --help|-h)
            usage 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

# Determine install paths
if [[ "$LOCAL" == true ]]; then
    BIN_DIR="${HOME}/.local/bin"
else
    # Global install requires root
    if [[ "$(id -u)" -ne 0 ]]; then
        die "global install requires root (use: sudo ./install.sh or ./install.sh --local)"
    fi
    BIN_DIR="/usr/local/bin"
fi

# Find script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing claude-pane..."
echo "  Binary: ${BIN_DIR}/claude-pane"
echo

# Create directory
mkdir -pv "$BIN_DIR"

# Install script
cp -v "$SCRIPT_DIR/claude-pane.sh" "$BIN_DIR/claude-pane"
chmod -v 755 "$BIN_DIR/claude-pane"

echo
echo "Done!"

# Check if bin dir is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo
    echo "Note: $BIN_DIR is not in your PATH."
    echo "Add it with:  export PATH=\"$BIN_DIR:\$PATH\""
fi
