#!/usr/bin/env bash
set -euo pipefail

# claude-pane: tmux pane manager for Claude Code teaching sessions
# Creates panes to show docs, code examples, SQL, or live processes

MARKER_DIR="/tmp/claude-pane.${USER:-$(id -un)}"
LOG_DIR="$MARKER_DIR/logs"
CONFIG_FILE="${HOME}/.claude-pane.conf"

# Load config if exists (sets defaults like CREATE_FULL_PANES)
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Default values (config can override these)
CREATE_FULL_PANES="${CREATE_FULL_PANES:-false}"

# Check for optional dependencies
IS_INSTALLED_BLOCK_RUN=false
command -v block-run &>/dev/null && IS_INSTALLED_BLOCK_RUN=true

# Colors
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
DIM=$'\e[2m'
RESET=$'\e[0m'

#-----------------------------------------------------------------------------
# Usage
#-----------------------------------------------------------------------------

usage() {
    cat <<'EOF'
claude-pane: tmux pane manager for teaching sessions

USAGE:
  claude-pane <command> [args]

COMMANDS:
  run <position> [options]   Create or replace pane at position
  kill <position>            Close pane at position
  list                       Show active panes

Run 'claude-pane <command> --help' for command-specific help.
EOF
    exit "${1:-0}"
}

usage_run() {
    cat <<'EOF'
claude-pane run: Create or replace pane at position

USAGE:
  claude-pane run <position> [options] <content-source>

REQUIRED:
  position <side|below>       Where to open the pane

CONTENT SOURCE (one required):
  --command '<cmd>'           Run arbitrary command (use '-' to read from stdin)
  --follow <file>             Shorthand for tail -f <file>
  --run-in-blocks <script>    Run script via block-run (notebook-style)

OPTIONS:
  --title "..."               Label shown at top of pane
  --page                      Pipe through less -R with mouse scrolling
  --log                       Capture output via script(1)
  --interactive               Skip script(1) wrapping (for interactive commands)
  --full                      Pane spans full window width/height
  --no-full                   Pane splits current pane only (default)

  Note: Set CREATE_FULL_PANES=true in ~/.claude-pane.conf to default to --full

EXAMPLES:
  claude-pane run side --title "SQL JOINs" --command './demo.sql'
  claude-pane run below --follow /var/log/nginx/access.log
  claude-pane run side --page --command 'docker images'

  # Read command from stdin (avoids quoting issues):
  claude-pane run side --command - << 'EOF'
  echo "Hello!"
  EOF
EOF
    if [[ "$IS_INSTALLED_BLOCK_RUN" == "false" ]]; then
        echo
        echo "NOTE: --run-in-blocks requires 'block-run'. Install from:"
        echo "  https://github.com/shitchell/block-run"
    fi
    exit "${1:-0}"
}

usage_kill() {
    cat <<'EOF'
claude-pane kill: Close pane at position

USAGE:
  claude-pane kill <position>

REQUIRED:
  position <side|below>       Position of pane to close
EOF
    exit "${1:-0}"
}

die() {
    echo "${RED}error:${RESET} $*" >&2
    exit 1
}

#-----------------------------------------------------------------------------
# Marker file management
#-----------------------------------------------------------------------------

marker_path() {
    local position="$1"
    echo "$MARKER_DIR/${position}.marker"
}

read_marker() {
    local marker_file="$1"
    [[ -f "$marker_file" ]] || return 1
    source "$marker_file"
}

write_marker() {
    local position="$1"
    local pane_id="$2"
    local title="${3:-}"
    local command="${4:-}"

    mkdir -p "$MARKER_DIR"
    local marker_file
    marker_file=$(marker_path "$position")

    local tty=""
    tty=$(tmux display-message -t "$pane_id" -p '#{pane_tty}' 2>/dev/null) || true

    # Use printf %q to safely escape values for sourcing
    printf 'PANE_ID=%q\n' "$pane_id" > "$marker_file"
    printf 'TITLE=%q\n' "$title" >> "$marker_file"
    printf 'TTY=%q\n' "$tty" >> "$marker_file"
    printf 'COMMAND=%q\n' "$command" >> "$marker_file"
}

remove_marker() {
    local position="$1"
    local marker_file
    marker_file=$(marker_path "$position")
    rm -f "$marker_file"
}

# Check if pane from marker still exists
pane_exists() {
    local pane_id="$1"
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane_id"
}

#-----------------------------------------------------------------------------
# Find current pane (for splitting)
#-----------------------------------------------------------------------------

find_current_pane() {
    # If TMUX_PANE is set, use it
    if [[ -n "${TMUX_PANE:-}" ]]; then
        echo "$TMUX_PANE"
        return 0
    fi

    # Walk process tree to find tty
    local pid=$$ tty_name=""
    while [[ $pid -gt 1 ]]; do
        tty_name=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$tty_name" && "$tty_name" != "?" ]]; then
            break
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done

    [[ -n "$tty_name" && "$tty_name" != "?" ]] || {
        die "could not determine current tty"
    }

    # Match tty to tmux pane
    local pane_id
    pane_id=$(tmux list-panes -a -F '#{pane_id} #{pane_tty}' 2>/dev/null \
        | grep "/dev/${tty_name}$" \
        | awk '{print $1}' \
        | head -1)

    [[ -n "$pane_id" ]] || {
        die "could not find tmux pane for tty $tty_name"
    }

    echo "$pane_id"
}

#-----------------------------------------------------------------------------
# Command wrapping
#-----------------------------------------------------------------------------

# Build the wrapped command with header, footer, q-to-close
# Note: We use $'\e[..m' syntax for colors so they survive quoting layers
wrap_command() {
    local cmd="$1"
    local title="${2:-}"
    local header_instructions="${3:-}"
    local use_page="${4:-false}"
    local use_log="${5:-false}"
    local log_file="${6:-}"

    local wrapped=""

    # Header: title and/or instructions
    if [[ -n "$title" ]]; then
        wrapped+="printf '%s\\n' \$'\\e[36m=== $title ===\\e[0m'; "
    fi
    if [[ -n "$header_instructions" ]]; then
        wrapped+="printf '%s\\n' \$'\\e[2m$header_instructions\\e[0m'; "
    fi
    if [[ -n "$title" || -n "$header_instructions" ]]; then
        wrapped+="echo; "
    fi

    # Main command (with optional paging)
    if [[ "$use_page" == "true" ]]; then
        wrapped+="{ $cmd; } 2>&1 | less -R --mouse; EXIT_CODE=\${PIPESTATUS[0]}; "
    else
        wrapped+="$cmd; EXIT_CODE=\$?; "
    fi

    # Footer: exit code + q to close
    wrapped+="echo; "
    wrapped+="printf '%s ' \$'\\e[2m(exit code: '\"\$EXIT_CODE\"\$')\\e[0m'; "
    wrapped+="printf '%s\\n' \$'Press \\e[36mq\\e[0m to close'; "
    wrapped+="while IFS= read -rsn1 key; do [[ \"\$key\" == \"q\" ]] && break; done"

    # Wrap in script(1) for logging if requested
    if [[ "$use_log" == "true" && -n "$log_file" ]]; then
        mkdir -p "$LOG_DIR"
        # Escape single quotes in wrapped command
        local escaped_wrapped="${wrapped//\'/\'\\\'\'}"
        echo "script -q '$log_file' -c 'bash -c '\''$escaped_wrapped'\'''"
    else
        echo "$wrapped"
    fi
}

#-----------------------------------------------------------------------------
# run command
#-----------------------------------------------------------------------------

cmd_run() {
    local position=""
    local title=""
    local command=""
    local follow_file=""
    local blocks_script=""
    local use_page=false
    local use_log=false
    local use_interactive=false
    local use_full="$CREATE_FULL_PANES"  # default from config or false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage_run 0
                ;;
            --title)
                [[ -n "${2:-}" ]] || die "--title requires an argument"
                title="$2"
                shift 2
                ;;
            --command)
                [[ -n "${2:-}" ]] || die "--command requires an argument"
                command="$2"
                shift 2
                ;;
            --follow)
                [[ -n "${2:-}" ]] || die "--follow requires an argument"
                follow_file="$2"
                shift 2
                ;;
            --run-in-blocks)
                [[ -n "${2:-}" ]] || die "--run-in-blocks requires an argument"
                blocks_script="$2"
                shift 2
                ;;
            --page)
                use_page=true
                shift
                ;;
            --log)
                use_log=true
                shift
                ;;
            --full)
                use_full=true
                shift
                ;;
            --no-full)
                use_full=false
                shift
                ;;
            --interactive)
                use_interactive=true
                shift
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                if [[ -z "$position" ]]; then
                    position="$1"
                else
                    die "unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    # Validate position
    [[ -n "$position" ]] || die "position is required (side or below)"
    [[ "$position" == "side" || "$position" == "below" ]] || die "position must be 'side' or 'below'"

    # Validate content source (exactly one required)
    local source_count=0
    [[ -n "$command" ]] && ((++source_count))
    [[ -n "$follow_file" ]] && ((++source_count))
    [[ -n "$blocks_script" ]] && ((++source_count))

    [[ $source_count -eq 1 ]] || die "exactly one content source required (--command, --follow, or --run-in-blocks)"

    # Handle --command - (read from stdin)
    if [[ "$command" == "-" ]]; then
        if [[ -t 0 ]]; then
            die "--command - requires input from stdin (use heredoc or pipe)"
        fi
        command=$(cat)
    fi

    # Warn about common quoting issues
    if [[ -n "$command" ]]; then
        if [[ "$command" == *'\\!'* ]]; then
            echo "${YELLOW}warning:${RESET} command contains '\\!' - this may be a quoting issue" >&2
            echo "  tip: use single quotes or --command - with heredoc" >&2
        fi
    fi

    # --interactive disables --log
    if [[ "$use_interactive" == "true" ]]; then
        use_log=false
    fi

    # Build the actual command
    local actual_cmd=""
    local header_instructions=""

    if [[ -n "$follow_file" ]]; then
        [[ -f "$follow_file" || -p "$follow_file" ]] || die "file not found: $follow_file"
        actual_cmd="tail -f '$follow_file'"
        header_instructions="(Ctrl+C to stop)"
    elif [[ -n "$blocks_script" ]]; then
        [[ "$IS_INSTALLED_BLOCK_RUN" == "true" ]] || die "--run-in-blocks requires 'block-run'. Install from: https://github.com/shitchell/block-run"
        [[ -f "$blocks_script" ]] || die "script not found: $blocks_script"
        actual_cmd="block-run '$blocks_script'"
    else
        actual_cmd="$command"
    fi

    if [[ "$use_page" == "true" ]]; then
        header_instructions="(scroll: mouse/arrows, q to quit)"
    fi

    # Generate log file name if logging
    local log_file=""
    if [[ "$use_log" == "true" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local cmd_slug
        cmd_slug=$(echo "$actual_cmd" | tr -cs '[:alnum:]' '_' | head -c 50)
        log_file="$LOG_DIR/${timestamp}-${cmd_slug}.log"
    fi

    # Wrap the command
    local wrapped_cmd
    if [[ "$use_interactive" == "true" ]]; then
        # Minimal wrapping for interactive - just header/footer, no script
        wrapped_cmd=$(wrap_command "$actual_cmd" "$title" "$header_instructions" "$use_page" false "")
    else
        wrapped_cmd=$(wrap_command "$actual_cmd" "$title" "$header_instructions" "$use_page" "$use_log" "$log_file")
    fi

    # Find source pane
    local source_pane
    source_pane=$(find_current_pane)

    # Check for existing pane at position
    local marker_file
    marker_file=$(marker_path "$position")

    local existing_pane=""
    if [[ -f "$marker_file" ]]; then
        read_marker "$marker_file"
        if pane_exists "$PANE_ID"; then
            existing_pane="$PANE_ID"
        else
            # Stale marker
            remove_marker "$position"
        fi
    fi

    local new_pane_id=""

    # Write command to temp script to avoid quoting hell
    local cmd_script
    cmd_script=$(mktemp "$MARKER_DIR/cmd.XXXXXX.sh")
    chmod 755 "$cmd_script"
    cat > "$cmd_script" << CMDEOF
#!/usr/bin/env bash
$wrapped_cmd
rm -f "\$0"  # self-delete
CMDEOF

    if [[ -n "$existing_pane" ]]; then
        # Respawn existing pane
        tmux respawn-pane -t "$existing_pane" -k "$cmd_script"
        new_pane_id="$existing_pane"
        echo "respawned pane $new_pane_id at position '$position'"
    else
        # Create new pane
        # -f = full width/height (span entire window edge, not just current pane)
        local split_opts=""
        local full_flag=""
        [[ "$use_full" == "true" ]] && full_flag="f"

        case "$position" in
            side)  split_opts="-h${full_flag}" ;;   # horizontal split
            below) split_opts="-v${full_flag}" ;;   # vertical split
        esac

        new_pane_id=$(tmux split-window $split_opts -t "$source_pane" -P -F '#{pane_id}' "$cmd_script")
        echo "opened pane $new_pane_id at position '$position'"
    fi

    # Write marker
    write_marker "$position" "$new_pane_id" "$title" "$actual_cmd"

    if [[ "$use_log" == "true" ]]; then
        echo "logging to: $log_file"
    fi
}

#-----------------------------------------------------------------------------
# kill command
#-----------------------------------------------------------------------------

cmd_kill() {
    local position=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage_kill 0
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                if [[ -z "$position" ]]; then
                    position="$1"
                else
                    die "unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$position" ]] || die "position is required (side or below)"
    [[ "$position" == "side" || "$position" == "below" ]] || die "position must be 'side' or 'below'"

    local marker_file
    marker_file=$(marker_path "$position")

    if [[ ! -f "$marker_file" ]]; then
        echo "no pane at position '$position'"
        return 0
    fi

    read_marker "$marker_file"

    if pane_exists "$PANE_ID"; then
        tmux kill-pane -t "$PANE_ID"
        echo "killed pane $PANE_ID at position '$position'"
    else
        echo "pane $PANE_ID was already closed"
    fi

    remove_marker "$position"
}

#-----------------------------------------------------------------------------
# list command
#-----------------------------------------------------------------------------

cmd_list() {
    mkdir -p "$MARKER_DIR"

    local found=false

    for marker_file in "$MARKER_DIR"/*.marker; do
        [[ -f "$marker_file" ]] || continue

        local position
        position=$(basename "$marker_file" .marker)

        read_marker "$marker_file"

        local status
        if pane_exists "$PANE_ID"; then
            status="${GREEN}active${RESET}"
        else
            status="${YELLOW}stale${RESET}"
        fi

        echo "${CYAN}$position${RESET}: $PANE_ID ($status)"
        [[ -n "${TITLE:-}" ]] && echo "  title: $TITLE"
        [[ -n "${COMMAND:-}" ]] && echo "  command: $COMMAND"
        echo

        found=true
    done

    if [[ "$found" == "false" ]]; then
        echo "no active panes"
    fi
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------

main() {
    [[ $# -gt 0 ]] || usage 1

    local cmd="$1"
    shift

    case "$cmd" in
        run)
            cmd_run "$@"
            ;;
        kill)
            cmd_kill "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        --help|-h)
            usage 0
            ;;
        *)
            die "unknown command: $cmd (try 'run', 'kill', or 'list')"
            ;;
    esac
}

main "$@"
