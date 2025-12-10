#!/usr/bin/env bash
#
# claude-pane: tmux pane manager for Claude Code teaching sessions
# Creates panes to show docs, code examples, SQL, or live processes
#
# Design principles:
# * "One contiguous block": feature updates should only require changes in one place
# * Sourceable: all functions use return, never exit (except help after parse-args)
# * DRY: single source of truth for field definitions, etc.


## exit codes ##################################################################
################################################################################

declare -ri E_SUCCESS=0
declare -ri E_ERROR=1
declare -ri E_INVALID_OPTION=2
declare -ri E_INVALID_ACTION=3


## global defaults #############################################################
################################################################################

# Directory paths (can be overridden by config)
MARKER_DIR="${MARKER_DIR:-/tmp/claude-pane.${USER:-$(id -un)}}"
LOG_DIR="${LOG_DIR:-${MARKER_DIR}/logs}"
CONFIG_FILE="${CONFIG_FILE:-${HOME}/.claude-pane.conf}"

# Configuration defaults
LOG_SIZE_LIMIT="${LOG_SIZE_LIMIT:-5M}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-3}"
CREATE_FULL_PANES="${CREATE_FULL_PANES:-false}"

# Global marker array for read/write operations
declare -A MARKER

# Global output from find-pane-at-position
FOUND_PANE_ID=""
FOUND_VIA=""

# Command stage globals (set by __action-run-parse-args and build functions)
COMMAND_RAW=""
COMMAND_BUILT=""
COMMAND_FINAL=""


## traps #######################################################################
################################################################################

function silence-output() {
    :  'Silence all script output'
    exec 3>&1 4>&2 1>/dev/null 2>&1
}

function restore-output() {
    :  'Restore script output after a call to silence-output'
    [[ -t 3 ]] && exec 1>&3 3>&-
    [[ -t 4 ]] && exec 2>&4 4>&-
}

function trap-exit() {
    :  'An exit trap to restore output on script end'
    restore-output
}
trap trap-exit EXIT


## colors ######################################################################
################################################################################

# Determine if we're in a terminal
[[ -t 1 ]] && __IN_TERMINAL=true || __IN_TERMINAL=false

function setup-colors() {
    :  'Set up color variables'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'
    C_WHITE=$'\e[37m'
    S_RESET=$'\e[0m'
    S_BOLD=$'\e[1m'
    S_DIM=$'\e[2m'
    S_UNDERLINE=$'\e[4m'
    S_BLINK=$'\e[5m'
    S_INVERT=$'\e[7m'
    S_HIDDEN=$'\e[8m'
}

function unset-colors() {
    :  'Unset color variables'
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE=''
    S_RESET='' S_BOLD='' S_DIM='' S_UNDERLINE='' S_BLINK='' S_INVERT='' S_HIDDEN=''
}


## usage functions #############################################################
################################################################################

function help-usage() {
    :  'Print brief usage'
    echo "usage: $(basename "${0}") [-h] [--help] [-c <when>] <action> [<args>]"
}

function help-epilogue() {
    :  'Print a brief description of the script'
    echo "tmux pane manager for Claude Code teaching sessions"
}

function help-full() {
    :  'Print full help'
    help-usage
    help-epilogue
    echo
    echo "Actions:"
    cat << '    EOF'
    run <position> [opts]     create or replace pane at position
    kill <position>           close pane at position
    list                      show active panes
    capture <position>        capture pane contents to stdout
    flush <position>          force-flush logs for pane
    help [action]             display help for a specific action
    EOF
    echo
    echo "Base Options:"
    cat << '    EOF'
    -h                        display usage
    --help                    display this help message
    --config-file <file>      use the specified configuration file
    -c/--color <when>         when to use color ("auto", "always", "never")
    EOF
    echo
    echo "For action-specific help, run:"
    echo "    $(basename "${0}") <action> --help"
}

function parse-args() {
    :  'Parse command-line arguments for the base command'
    local -- __color_when="${COLOR:-auto}"
    local -- __i

    # Parse the arguments first for a config file
    for (( __i=1; __i<=${#}; __i++ )); do
        if [[ "${!__i}" == "--config-file" ]]; then
            (( __i++ ))
            CONFIG_FILE="${!__i}"
        fi
    done

    # Default values
    DO_COLOR=false
    DO_SILENT=false
    ACTION=""
    ACTION_ARGS=()

    # Loop over the arguments
    while [[ ${#} -gt 0 ]]; do
        case "${1}" in
            -h)
                help-usage
                help-epilogue
                exit ${E_SUCCESS}
                ;;
            --help)
                help-full
                exit ${E_SUCCESS}
                ;;
            --config-file)
                shift 1
                ;;
            -c | --color)
                __color_when="${2}"
                shift 1
                ;;
            -*)
                echo "error: unknown option: ${1}" >&2
                return ${E_INVALID_OPTION}
                ;;
            *)
                ACTION="${1}"
                shift 1
                break
                ;;
        esac
        shift 1
    done

    # Collect remaining arguments for the action
    ACTION_ARGS=("${@}")

    # Ensure an action was specified
    if [[ -z "${ACTION}" ]]; then
        echo "error: no action specified" >&2
        help-full >&2
        return ${E_INVALID_ACTION}
    fi

    # Set up colors
    case "${__color_when}" in
        on | yes | always)
            DO_COLOR=true
            ;;
        off | no | never)
            DO_COLOR=false
            ;;
        auto)
            ${__IN_TERMINAL} && DO_COLOR=true || DO_COLOR=false
            ;;
        *)
            echo "error: invalid color mode: ${__color_when}" >&2
            return ${E_ERROR}
            ;;
    esac
    ${DO_COLOR} && setup-colors || unset-colors

    return ${E_SUCCESS}
}


## core helper functions #######################################################
################################################################################

function error() {
    :  'Print error message to stderr'
    echo "error: ${1}" >&2
}

function load-env() {
    :  'Safely load key=value pairs from env/config file'
    :  'Uses declare to set variables without eval risks'
    local -- __file="${1}"
    local -- __key
    local -- __value

    [[ -f "${__file}" ]] || return 0  # Missing config is not an error

    while IFS='=' read -r __key __value; do
        # Skip empty lines and comments
        [[ -z "${__key}" || "${__key}" == \#* ]] && continue
        # Validate key is a valid variable name
        [[ "${__key}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || {
            error "invalid config key: ${__key}"
            continue
        }
        # Use declare -g to set global variable
        declare -g "${__key}=${__value}"
    done < "${__file}"
}

function check-tmux-running() {
    :  'Verify we are running inside a tmux session'
    [[ -n "${TMUX:-}" ]] || {
        error "not running inside a tmux session"
        return 1
    }
    # Verify tmux is responsive
    tmux display-message -p '#{session_id}' &>/dev/null || {
        error "tmux session not responding"
        return 1
    }
}

function ensure-directories() {
    :  'Create required directories if they do not exist'
    mkdir -p "${MARKER_DIR}" "${LOG_DIR}" || {
        error "failed to create directories"
        return 1
    }
}

function validate-position() {
    :  'Validate position argument is side or below'
    local -- __position="${1}"

    [[ -n "${__position}" ]] || {
        error "position is required (side or below)"
        return 1
    }
    [[ "${__position}" == "side" || "${__position}" == "below" ]] || {
        error "position must be 'side' or 'below', got: ${__position}"
        return 1
    }
}

function check-command-exists() {
    :  'Check if a command exists, with helpful error message'
    local -- __cmd="${1}"
    local -- __hint="${2:-}"

    command -v "${__cmd}" &>/dev/null || {
        if [[ -n "${__hint}" ]]; then
            error "${__cmd} not found - ${__hint}"
        else
            error "${__cmd} not found"
        fi
        return 1
    }
}


## marker management ###########################################################
################################################################################

function build-marker-path() {
    :  'Build path to marker file for position'
    local -- __position="${1}"

    echo "${MARKER_DIR}/${__position}.marker"
}

function write-marker() {
    :  'Write MARKER associative array to marker file'
    :  'Uses atomic write (temp file + rename) to prevent race conditions'
    local -- __position="${1}"
    local -- __marker_file
    local -- __temp_file
    local -- __key

    __marker_file=$(build-marker-path "${__position}")
    __temp_file="${__marker_file}.$$"
    mkdir -p "${MARKER_DIR}"

    for __key in "${!MARKER[@]}"; do
        printf '%s=%q\n' "${__key}" "${MARKER[${__key}]}"
    done > "${__temp_file}"

    mv "${__temp_file}" "${__marker_file}"
}

function read-marker() {
    :  'Read marker file into MARKER associative array'
    :  'Values are shell-quoted by write-marker(), so we use eval to unquote'
    :  'Keys are validated to prevent injection attacks'
    local -- __marker_file="${1}"
    local -- __key
    local -- __value

    [[ -f "${__marker_file}" ]] || return 1

    # Verify file is owned by us (prevent tampering)
    [[ -O "${__marker_file}" ]] || {
        error "marker file not owned by current user: ${__marker_file}"
        return 1
    }

    MARKER=()
    while IFS='=' read -r __key __value; do
        # Skip empty lines
        [[ -n "${__key}" ]] || continue
        # Validate key is a safe identifier (lowercase, underscore, digits)
        [[ "${__key}" =~ ^[a-z_][a-z0-9_]*$ ]] || {
            error "invalid marker key: ${__key}"
            continue
        }
        # Safely unquote the value (written with printf %q)
        eval "MARKER[${__key}]=${__value}"
    done < "${__marker_file}"
}

function remove-marker() {
    :  'Remove marker file for position'
    local -- __position="${1}"

    rm -f "$(build-marker-path "${__position}")"
}

function pane-exists() {
    :  'Check if pane ID exists in tmux'
    local -- __pane_id="${1}"

    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fxq "${__pane_id}"
}

function clean-stale-markers() {
    :  'Remove markers for panes that no longer exist'
    :  'Called at start of every invocation - simplifies logic elsewhere'
    local -- __marker_file

    [[ -d "${MARKER_DIR}" ]] || return 0

    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue

        read-marker "${__marker_file}" || continue
        if ! pane-exists "${MARKER[pane_id]:-}"; then
            rm -f "${__marker_file}"
        fi
    done
}

function clean-old-logs() {
    :  'Remove logs older than LOG_RETENTION_DAYS that are not still active'
    :  'Called at start of every invocation alongside clean-stale-markers'
    local -- __marker_file
    local -- __log_file
    local -A __active_logs=()

    [[ -d "${LOG_DIR}" ]] || return 0

    # Collect log files from active markers (already cleaned by clean-stale-markers)
    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue
        read-marker "${__marker_file}" || continue
        [[ -n "${MARKER[log_file]:-}" ]] && __active_logs["${MARKER[log_file]}"]=1
    done

    # Find and delete old logs not in active set
    while IFS= read -r -d '' __log_file; do
        [[ -z "${__active_logs[${__log_file}]:-}" ]] && rm -f "${__log_file}"
    done < <(find "${LOG_DIR}" -type f -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)
}


## pane management #############################################################
################################################################################

function get-current-pane-id() {
    :  'Get the tmux pane ID of the current shell'
    :  'Used to determine which pane to split from'
    local -- __pid
    local -- __tty_name
    local -- __pane_id
    local -- __pane_list

    # Fast path: TMUX_PANE is set
    if [[ -n "${TMUX_PANE:-}" ]]; then
        echo "${TMUX_PANE}"
        return 0
    fi

    # Fallback: walk process tree to find tty
    __pid=$$
    __tty_name=""
    while [[ ${__pid} -gt 1 ]]; do
        __tty_name=$(ps -o tty= -p "${__pid}" 2>/dev/null | tr -d ' ')
        if [[ -n "${__tty_name}" && "${__tty_name}" != "?" ]]; then
            break
        fi
        __pid=$(ps -o ppid= -p "${__pid}" 2>/dev/null | tr -d ' ')
    done

    [[ -n "${__tty_name}" && "${__tty_name}" != "?" ]] || {
        error "could not determine current tty"
        return 1
    }

    # Match tty to tmux pane
    __pane_list=$(tmux list-panes -a -F '#{pane_id} #{pane_tty}' 2>/dev/null)
    __pane_id=$(grep "/dev/${__tty_name}$" <<< "${__pane_list}" | head -1 | cut -d' ' -f1)

    [[ -n "${__pane_id}" ]] || {
        error "could not find tmux pane for tty ${__tty_name}"
        return 1
    }

    echo "${__pane_id}"
}

function find-pane-at-position() {
    :  'Find pane ID at position, with marker -> title fallback'
    :  'Sets globals: FOUND_PANE_ID, FOUND_VIA (marker|title)'
    :  'Returns 1 if no pane found at position'
    local -- __position="${1}"
    local -- __marker_file
    local -- __expected_title
    local -- __window_id
    local -- __pane_info

    FOUND_PANE_ID=""
    FOUND_VIA=""

    __marker_file=$(build-marker-path "${__position}")
    __expected_title="claude-pane:${__position}"

    # 1. Try marker file first (also validates pane still exists)
    if read-marker "${__marker_file}" 2>/dev/null && pane-exists "${MARKER[pane_id]:-}"; then
        FOUND_PANE_ID="${MARKER[pane_id]}"
        FOUND_VIA="marker"
        return 0
    fi

    # Marker exists but pane doesn't - stale, remove it
    [[ -f "${__marker_file}" ]] && rm -f "${__marker_file}"

    # 2. Fallback: search current window for pane with expected title
    __window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null) || return 1

    # List panes in current window with their titles
    __pane_info=$(tmux list-panes -t "${__window_id}" -F '#{pane_id}	#{pane_title}' 2>/dev/null \
        | grep -F "	${__expected_title}$" \
        | head -1)

    if [[ -n "${__pane_info}" ]]; then
        FOUND_PANE_ID="${__pane_info%%	*}"
        FOUND_VIA="title"
        return 0
    fi

    return 1
}


## action functions ############################################################
################################################################################

### help action ################################################################

function __action-help-help() {
    :  'Print help for the help action'
    echo "usage: $(basename "${0}") help [<action>]"
    echo
    echo "Display help for the specified action or for $(basename "${0}") if no"
    echo "action is specified."
}

function __action-help-parse-args() {
    :  'Parse arguments for the help action'
    HELP_ACTION=""

    while [[ ${#} -gt 0 ]]; do
        case "${1}" in
            -h | --help)
                __action-help-help
                exit ${E_SUCCESS}
                ;;
            -*)
                error "unknown option: ${1}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                HELP_ACTION="${1}"
                ;;
        esac
        shift 1
    done

    return ${E_SUCCESS}
}

function __action-help() {
    :  'Display help for the specified action'
    local -- __help_func

    if [[ -n "${HELP_ACTION}" ]]; then
        __help_func="__action-${HELP_ACTION}-help"
        if type -t "${__help_func}" &>/dev/null; then
            "${__help_func}"
        else
            error "no help found for action: ${HELP_ACTION}"
            return ${E_INVALID_ACTION}
        fi
    else
        help-full
    fi
}


### run action #################################################################

function __action-run-help() {
    :  'Print help for the run action'
    cat << 'EOF'
usage: claude-pane run <position> [options] <content-source>

Create or replace pane at position.

REQUIRED:
  position <side|below>       where to open the pane

CONTENT SOURCE (one required):
  --command '<cmd>'           run arbitrary command (use '-' to read from stdin)
  --follow <file>             shorthand for tail -f <file> (repeatable)
  --run-in-blocks <script>    run script via block-run (notebook-style)
  --view <file>               view file in less (uses lessfilter if available)

OPTIONS:
  --title "..."               label shown at top of pane
  --page                      pipe through less -R with mouse scrolling
  --no-page                   disable paging (default for most, except --run-in-blocks)
  --interactive               enable stdin for interactive commands
  --pipefail                  enable pipefail (default)
  --no-pipefail               disable pipefail
  --full                      pane spans full window width/height
  --no-full                   pane splits current pane only (default)

EXAMPLES:
  claude-pane run side --title "SQL JOINs" --command './demo.sql'
  claude-pane run below --follow /var/log/nginx/access.log
  claude-pane run side --page --command 'docker images'
  claude-pane run side --view ~/.bashrc         # syntax-highlighted if lessfilter exists

  # Read command from stdin (avoids quoting issues):
  claude-pane run side --command - << 'EOF'
  echo "Hello!"
  EOF
EOF
}

function __action-run-parse-args() {
    :  'Parse arguments for the run action'
    local -- __arg

    # Reset globals
    RUN_POSITION=""
    RUN_COMMAND=""
    RUN_FOLLOW_FILES=()
    RUN_BLOCKS_SCRIPT=""
    RUN_VIEW_FILE=""
    RUN_TITLE=""
    DO_PAGE=false
    DO_PAGE_EXPLICIT=false
    DO_INTERACTIVE=false
    DO_PIPEFAIL=true
    DO_FULL="${CREATE_FULL_PANES}"

    while [[ ${#} -gt 0 ]]; do
        __arg="${1}"
        case "${__arg}" in
            -h | --help)
                __action-run-help
                exit ${E_SUCCESS}
                ;;
            --title)
                [[ -n "${2:-}" ]] || { error "--title requires an argument"; return 1; }
                RUN_TITLE="${2}"
                shift
                ;;
            --command)
                [[ -n "${2:-}" ]] || { error "--command requires an argument"; return 1; }
                RUN_COMMAND="${2}"
                shift
                ;;
            --follow)
                [[ -n "${2:-}" ]] || { error "--follow requires an argument"; return 1; }
                RUN_FOLLOW_FILES+=("${2}")
                shift
                ;;
            --run-in-blocks)
                [[ -n "${2:-}" ]] || { error "--run-in-blocks requires an argument"; return 1; }
                RUN_BLOCKS_SCRIPT="${2}"
                shift
                ;;
            --view)
                [[ -n "${2:-}" ]] || { error "--view requires an argument"; return 1; }
                RUN_VIEW_FILE="${2}"
                shift
                ;;
            --page)
                DO_PAGE=true
                DO_PAGE_EXPLICIT=true
                ;;
            --no-page)
                DO_PAGE=false
                DO_PAGE_EXPLICIT=true
                ;;
            --interactive)
                DO_INTERACTIVE=true
                ;;
            --pipefail)
                DO_PIPEFAIL=true
                ;;
            --no-pipefail)
                DO_PIPEFAIL=false
                ;;
            --full)
                DO_FULL=true
                ;;
            --no-full)
                DO_FULL=false
                ;;
            -*)
                error "unknown option: ${__arg}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                if [[ -z "${RUN_POSITION}" ]]; then
                    RUN_POSITION="${__arg}"
                else
                    error "unexpected argument: ${__arg}"
                    return 1
                fi
                ;;
        esac
        shift
    done

    # Handle --command - (read from stdin)
    if [[ "${RUN_COMMAND}" == "-" ]]; then
        if [[ -t 0 ]]; then
            error "--command - requires input from stdin (use heredoc or pipe)"
            return 1
        fi
        RUN_COMMAND=$(cat)
    fi

    # Default to paging for --run-in-blocks (unless explicitly disabled)
    if [[ -n "${RUN_BLOCKS_SCRIPT}" && "${DO_PAGE_EXPLICIT}" == "false" ]]; then
        DO_PAGE=true
    fi

    # --view requires interactive mode (less needs keyboard input)
    if [[ -n "${RUN_VIEW_FILE}" ]]; then
        DO_INTERACTIVE=true
    fi

    # Validate
    __action-run-validate-args || return ${?}

    return ${E_SUCCESS}
}

function __action-run-validate-args() {
    :  'Validate run arguments'
    local -i __source_count=0

    # Position is valid
    validate-position "${RUN_POSITION}" || return 1

    # Exactly one content source
    [[ -n "${RUN_COMMAND}" ]] && (( ++__source_count ))
    [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]] && (( ++__source_count ))
    [[ -n "${RUN_BLOCKS_SCRIPT}" ]] && (( ++__source_count ))
    [[ -n "${RUN_VIEW_FILE}" ]] && (( ++__source_count ))

    [[ ${__source_count} -eq 1 ]] || {
        error "exactly one content source required (--command, --follow, --run-in-blocks, or --view)"
        return 1
    }

    # Files exist for --follow
    if [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]]; then
        local -- __file
        for __file in "${RUN_FOLLOW_FILES[@]}"; do
            [[ -f "${__file}" || -p "${__file}" ]] || {
                error "file not found: ${__file}"
                return 1
            }
        done
    fi

    # File exists and block-run available for --run-in-blocks
    if [[ -n "${RUN_BLOCKS_SCRIPT}" ]]; then
        [[ -f "${RUN_BLOCKS_SCRIPT}" ]] || {
            error "script not found: ${RUN_BLOCKS_SCRIPT}"
            return 1
        }
        check-command-exists "block-run" "install from https://github.com/shitchell/block-run" || return 1
    fi

    # File exists for --view
    if [[ -n "${RUN_VIEW_FILE}" ]]; then
        [[ -e "${RUN_VIEW_FILE}" ]] || {
            error "file not found: ${RUN_VIEW_FILE}"
            return 1
        }
    fi

    # --interactive and --page are mutually exclusive
    ${DO_INTERACTIVE} && ${DO_PAGE} && {
        error "--interactive and --page are mutually exclusive"
        return 1
    }

    # --view and --page are mutually exclusive (--view uses less internally)
    [[ -n "${RUN_VIEW_FILE}" ]] && ${DO_PAGE} && {
        error "--view and --page are mutually exclusive (--view uses less internally)"
        return 1
    }

    return ${E_SUCCESS}
}

function __action-run-build-command() {
    :  'Transform content source into COMMAND_RAW and COMMAND_BUILT'

    if [[ -n "${RUN_COMMAND}" ]]; then
        COMMAND_RAW="${RUN_COMMAND}"
        COMMAND_BUILT="${COMMAND_RAW}"
    elif [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]]; then
        COMMAND_RAW="${RUN_FOLLOW_FILES[*]}"
        COMMAND_BUILT="tail -f ${RUN_FOLLOW_FILES[*]@Q}"
    elif [[ -n "${RUN_BLOCKS_SCRIPT}" ]]; then
        COMMAND_RAW="${RUN_BLOCKS_SCRIPT}"
        COMMAND_BUILT="block-run ${RUN_BLOCKS_SCRIPT@Q}"
    elif [[ -n "${RUN_VIEW_FILE}" ]]; then
        COMMAND_RAW="${RUN_VIEW_FILE}"
        # Use lessfilter if available for syntax highlighting, otherwise plain less
        if command -v lessfilter &>/dev/null; then
            COMMAND_BUILT="lessfilter ${RUN_VIEW_FILE@Q} | less -R"
        else
            COMMAND_BUILT="less ${RUN_VIEW_FILE@Q}"
        fi
    fi
}

function __action-run-build-paths() {
    :  'Build log, timing, and script paths with shared identifiers'
    local -- __timestamp
    local -- __slug

    __timestamp=$(date +%H%M%S%3N)  # HHMMSS + 3 digits of nanoseconds (sub-ms precision)
    __slug=$(printf '%s' "${COMMAND_RAW:-unknown}" | tr -cs '[:alnum:]' '_' | cut -c1-50)

    LOG_FILE="${LOG_DIR}/${__timestamp}-${__slug}.script.log"
    LOG_TIMING_FILE="${LOG_DIR}/${__timestamp}-${__slug}.timing"
    SCRIPT_FILE="${LOG_DIR}/${__timestamp}-${__slug}.sh"
}

function __action-run-build-wrapped-command() {
    :  'Build COMMAND_FINAL with script() wrapper'
    local -- __script_opts

    # script options: -q (quiet), -e (return exit), -f (flush)
    # -c must be separate as it takes an argument
    # -T (timing log), -o (size limit)
    __script_opts="-qe"
    ${DO_INTERACTIVE} || __script_opts+="f"

    # Build command string - only quote values that need it, not options
    # -c must be followed by its argument (the command)
    COMMAND_FINAL="script ${__script_opts} -c ${COMMAND_BUILT@Q}"
    COMMAND_FINAL+=" -T ${LOG_TIMING_FILE@Q}"
    COMMAND_FINAL+=" -o ${LOG_SIZE_LIMIT@Q}"
    COMMAND_FINAL+=" ${LOG_FILE@Q}"

    # Add </dev/null for non-interactive to prevent input stealing
    ${DO_INTERACTIVE} || COMMAND_FINAL+=" </dev/null"
}

function __action-run-build-post-process-string() {
    :  'Build post-process string to append after command'
    :  'Returns " | less -R" or "" etc.'

    if ${DO_PAGE}; then
        echo " | less -R"
    else
        echo ""
    fi
}

function __action-run-generate-script() {
    :  'Generate the temp script that runs in the pane'
    local -- __post_process

    __post_process=$(__action-run-build-post-process-string)

    {
        printf '%s\n' '#!/usr/bin/env bash'

        # Pipefail
        ${DO_PIPEFAIL} && printf '%s\n' 'set -o pipefail'

        # Colors for exit display (embedded)
        printf '%s\n' "S_DIM=\$'\\e[2m'"
        printf '%s\n' "S_RESET=\$'\\e[0m'"
        printf '%s\n' "C_CYAN=\$'\\e[36m'"

        # Exit trap
        printf '%s\n' '__exit_code=0'
        printf '%s\n' 'trap '"'"'__on_exit'"'"' EXIT'
        printf '%s\n' ''
        printf '%s\n' '__on_exit() {'
        printf '%s\n' '    echo'
        printf '%s\n' '    echo "${S_DIM}(exit code: ${__exit_code})${S_RESET}"'

        # Only show q-to-quit and read loop if not paging
        if ! ${DO_PAGE}; then
            printf '%s\n' '    echo "${S_DIM}Press ${C_CYAN}q${S_RESET}${S_DIM} to exit${S_RESET}"'
            printf '%s\n' '    while IFS= read -rsn1 __key; do [[ "${__key}" == "q" ]] && break; done'
        fi

        printf '%s\n' '}'
        printf '%s\n' ''

        # When paging, title and instructions must be INSIDE the subshell that pipes to less
        # (otherwise less takes over the screen and hides them)
        if ${DO_PAGE}; then
            # Build header content to include in the piped subshell
            printf '%s' '{'
            if [[ -n "${RUN_TITLE}" ]]; then
                printf '%s' " echo \"\${C_CYAN}=== ${RUN_TITLE} ===\${S_RESET}\";"
                printf '%s' ' echo;'
            fi
            printf '%s' ' echo "${S_DIM}(scroll: arrows/mouse, q to quit)${S_RESET}";'
            printf '%s' ' echo;'
            printf '%s' " ${COMMAND_FINAL};"
            printf '%s\n' " }${__post_process}"
        else
            # Non-paging: title can be echoed directly before command
            if [[ -n "${RUN_TITLE}" ]]; then
                printf '%s\n' "echo \"\${C_CYAN}=== ${RUN_TITLE} ===\${S_RESET}\""
                printf '%s\n' 'echo'
            fi
            # Follow mode instructions (Ctrl+C to stop tail, then q to quit)
            if [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]]; then
                printf '%s\n' 'echo "${S_DIM}(Ctrl+C to stop, then q to quit)${S_RESET}"'
                printf '%s\n' 'echo'
            fi
            printf '%s\n' "(${COMMAND_FINAL})${__post_process}"
        fi
        printf '%s\n' '__exit_code=${PIPESTATUS[0]}'

    } > "${SCRIPT_FILE}"

    chmod 700 "${SCRIPT_FILE}"
}

function __action-run-create-or-update-pane() {
    :  'Create new pane or respawn existing at position'
    local -- __source_pane
    local -- __marker_file
    local -- __new_pane_id=""
    local -- __message
    local -- __is_respawn=false
    local -a __tmux_args=()

    __source_pane=$(get-current-pane-id) || return 1
    __marker_file=$(build-marker-path "${RUN_POSITION}")

    # Check if we should respawn (marker exists AND pane still exists)
    if read-marker "${__marker_file}" 2>/dev/null && pane-exists "${MARKER[pane_id]:-}"; then
        # Existing pane - respawn it
        __tmux_args=(respawn-pane -t "${MARKER[pane_id]}" -k "${SCRIPT_FILE}")
        __new_pane_id="${MARKER[pane_id]}"
        __message="respawned pane"
        __is_respawn=true
    else
        # New pane - create it
        # Build split args as array for proper quoting
        __tmux_args=(split-window)
        case "${RUN_POSITION}" in
            side)  __tmux_args+=(-h) ;;
            below) __tmux_args+=(-v) ;;
        esac
        ${DO_FULL} && __tmux_args+=(-f)
        __tmux_args+=(-t "${__source_pane}" -P -F '#{pane_id}' "${SCRIPT_FILE}")
        __message="opened pane"
    fi

    # Execute tmux command
    if ${__is_respawn}; then
        tmux "${__tmux_args[@]}" || { error "failed to respawn pane"; return 1; }
    else
        __new_pane_id=$(tmux "${__tmux_args[@]}") || { error "failed to create pane"; return 1; }
    fi

    # Set pane title for fallback discovery (if marker goes missing)
    tmux select-pane -t "${__new_pane_id}" -T "claude-pane:${RUN_POSITION}"

    # Update marker
    MARKER=(
        [pane_id]="${__new_pane_id}"
        [title]="${RUN_TITLE}"
        [command]="${COMMAND_RAW}"
        [log_file]="${LOG_FILE}"
        [script_file]="${SCRIPT_FILE}"
    )
    write-marker "${RUN_POSITION}"

    # Output
    echo "${__message} ${__new_pane_id} at position '${RUN_POSITION}'"
    echo "log: ${LOG_FILE}"
    echo "script: ${SCRIPT_FILE}"
}

function __action-run() {
    :  'Create or replace pane at position'

    # 1. Build command stages
    __action-run-build-command  # COMMAND_RAW -> COMMAND_BUILT

    # 2. Build paths (log, timing, script - all share timestamp/slug)
    __action-run-build-paths

    # 3. Build final wrapped command
    __action-run-build-wrapped-command  # -> COMMAND_FINAL

    # 4. Generate temp script
    __action-run-generate-script  # writes to SCRIPT_FILE

    # 5. Create or update pane
    __action-run-create-or-update-pane || return ${?}
}


### kill action ################################################################

function __action-kill-help() {
    :  'Print help for the kill action'
    cat << 'EOF'
usage: claude-pane kill <position>

Close pane at position.

REQUIRED:
  position <side|below>    position of pane to close
EOF
}

function __action-kill-parse-args() {
    :  'Parse arguments for kill action'
    local -- __arg

    KILL_POSITION=""

    while [[ ${#} -gt 0 ]]; do
        __arg="${1}"
        case "${__arg}" in
            -h | --help)
                __action-kill-help
                exit ${E_SUCCESS}
                ;;
            -*)
                error "unknown option: ${__arg}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                if [[ -z "${KILL_POSITION}" ]]; then
                    KILL_POSITION="${__arg}"
                else
                    error "unexpected argument: ${__arg}"
                    return 1
                fi
                ;;
        esac
        shift
    done

    # Validate
    validate-position "${KILL_POSITION}" || return 1

    return ${E_SUCCESS}
}

function __action-kill() {
    :  'Close pane at position'

    if ! find-pane-at-position "${KILL_POSITION}"; then
        echo "no pane at position '${KILL_POSITION}'"
        return 0
    fi

    # Report how we found it
    if [[ "${FOUND_VIA}" == "title" ]]; then
        echo "warning: marker file missing, but found pane ${FOUND_PANE_ID} by title 'claude-pane:${KILL_POSITION}'" >&2
    fi

    # Kill the pane
    tmux kill-pane -t "${FOUND_PANE_ID}" || { error "failed to kill pane"; return 1; }

    # Clean up marker (if it existed)
    remove-marker "${KILL_POSITION}"

    echo "killed pane ${FOUND_PANE_ID} at position '${KILL_POSITION}'"
}


### list action ################################################################

function __action-list-help() {
    :  'Print help for the list action'
    cat << 'EOF'
usage: claude-pane list

Show all tracked panes and their status.
EOF
}

function __action-list-parse-args() {
    :  'Parse arguments for list action'
    while [[ ${#} -gt 0 ]]; do
        case "${1}" in
            -h | --help)
                __action-list-help
                exit ${E_SUCCESS}
                ;;
            -*)
                error "unknown option: ${1}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                error "unexpected argument: ${1}"
                return 1
                ;;
        esac
        shift
    done

    return ${E_SUCCESS}
}

function __action-list() {
    :  'List all tracked panes and their status'
    local -- __marker_file
    local -- __position
    local -- __status
    local -- __found=false

    [[ -d "${MARKER_DIR}" ]] || { echo "no active panes"; return 0; }

    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue

        __position="${__marker_file##*/}"
        __position="${__position%.marker}"

        read-marker "${__marker_file}" || continue

        if pane-exists "${MARKER[pane_id]:-}"; then
            __status="${C_GREEN}active${S_RESET}"
        else
            __status="${C_YELLOW}stale${S_RESET}"
        fi

        echo "${C_CYAN}${__position}${S_RESET}: ${MARKER[pane_id]:-} (${__status})"
        [[ -n "${MARKER[title]:-}" ]] && echo "  title: ${MARKER[title]}"
        [[ -n "${MARKER[command]:-}" ]] && echo "  command: ${MARKER[command]}"
        echo

        __found=true
    done

    ${__found} || echo "no active panes"
}


### capture action #############################################################

function __action-capture-help() {
    :  'Print help for the capture action'
    cat << 'EOF'
usage: claude-pane capture <position>

Capture and output current pane contents.

REQUIRED:
  position <side|below>    position of pane to capture
EOF
}

function __action-capture-parse-args() {
    :  'Parse arguments for capture action'
    local -- __arg

    CAPTURE_POSITION=""

    while [[ ${#} -gt 0 ]]; do
        __arg="${1}"
        case "${__arg}" in
            -h | --help)
                __action-capture-help
                exit ${E_SUCCESS}
                ;;
            -*)
                error "unknown option: ${__arg}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                if [[ -z "${CAPTURE_POSITION}" ]]; then
                    CAPTURE_POSITION="${__arg}"
                else
                    error "unexpected argument: ${__arg}"
                    return 1
                fi
                ;;
        esac
        shift
    done

    # Validate
    validate-position "${CAPTURE_POSITION}" || return 1

    return ${E_SUCCESS}
}

function __action-capture() {
    :  'Capture and output current pane contents'

    if ! find-pane-at-position "${CAPTURE_POSITION}"; then
        error "no pane at position '${CAPTURE_POSITION}'"
        return 1
    fi

    # Warn if found via fallback
    if [[ "${FOUND_VIA}" == "title" ]]; then
        echo "warning: marker file missing, found pane ${FOUND_PANE_ID} by title" >&2
    fi

    # Capture pane contents
    tmux capture-pane -t "${FOUND_PANE_ID}" -p
}


### flush action ###############################################################

function __action-flush-help() {
    :  'Print help for the flush action'
    cat << 'EOF'
usage: claude-pane flush <position>

Force-flush logs for pane at position.
Sends SIGUSR1 to the script process to flush output.

REQUIRED:
  position <side|below>    position of pane to flush
EOF
}

function __action-flush-parse-args() {
    :  'Parse arguments for flush action'
    local -- __arg

    FLUSH_POSITION=""

    while [[ ${#} -gt 0 ]]; do
        __arg="${1}"
        case "${__arg}" in
            -h | --help)
                __action-flush-help
                exit ${E_SUCCESS}
                ;;
            -*)
                error "unknown option: ${__arg}"
                return ${E_INVALID_OPTION}
                ;;
            *)
                if [[ -z "${FLUSH_POSITION}" ]]; then
                    FLUSH_POSITION="${__arg}"
                else
                    error "unexpected argument: ${__arg}"
                    return 1
                fi
                ;;
        esac
        shift
    done

    # Validate
    validate-position "${FLUSH_POSITION}" || return 1

    return ${E_SUCCESS}
}

function __action-flush() {
    :  'Force-flush logs for pane at position'
    local -- __pane_pid
    local -- __script_pid

    if ! find-pane-at-position "${FLUSH_POSITION}"; then
        error "no pane at position '${FLUSH_POSITION}'"
        return 1
    fi

    # Warn if found via fallback
    if [[ "${FOUND_VIA}" == "title" ]]; then
        echo "warning: marker file missing, found pane ${FOUND_PANE_ID} by title" >&2
    fi

    # Find script process in the pane
    # Get the pane's PID, then find child script process
    __pane_pid=$(tmux display-message -t "${FOUND_PANE_ID}" -p '#{pane_pid}')

    # Find script child process
    __script_pid=$(pgrep -P "${__pane_pid}" -x script 2>/dev/null | head -1)

    [[ -n "${__script_pid}" ]] || { error "no script process found in pane"; return 1; }

    # Send SIGUSR1 to flush
    kill -USR1 "${__script_pid}" || { error "failed to send flush signal"; return 1; }
    echo "flushed logs for pane at '${FLUSH_POSITION}'"
}


## main ########################################################################
################################################################################

function main() {
    local -- __exit_code=${E_SUCCESS}
    local -- __action_func
    local -- __parse_func

    # Parse base arguments (sets ACTION, ACTION_ARGS, colors, etc.)
    parse-args "${@}" || return ${?}

    # Prerequisites
    check-tmux-running || return 1
    load-env "${CONFIG_FILE}"
    ensure-directories || return 1

    # Housekeeping
    clean-stale-markers
    clean-old-logs

    # Dynamic action dispatch
    __action_func="__action-${ACTION}"
    __parse_func="__action-${ACTION}-parse-args"

    # Verify the action function exists
    if ! type -t "${__action_func}" &>/dev/null; then
        error "unknown action: ${ACTION}"
        return ${E_INVALID_ACTION}
    fi

    # Parse action-specific arguments if a parser exists
    if type -t "${__parse_func}" &>/dev/null; then
        "${__parse_func}" "${ACTION_ARGS[@]}" || return ${?}
    fi

    # Call the action function
    "${__action_func}"
    __exit_code=${?}

    return ${__exit_code}
}


## run #########################################################################
################################################################################

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "${@}"
