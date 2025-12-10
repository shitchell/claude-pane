# Claude Pane - Design Doc

## Coding Conventions

### Naming
- `stupidly-long-function-name-that-is-explicit-and-obvious` > `short-name`
- Verb prefixes for functions: `build-marker-path`, `get-current-pane-id`, etc.
- `UPPER_SNAKE_CASE` for global vars (including parsed args)
- `__snake_case` for local vars (double underscore prefix)
- `E_*` exit codes, `C_*` colors, `S_*` styles
- `DO_*` for action booleans (DO_COLOR, DO_PAGE, DO_INTERACTIVE)
- `IS_*` / `DOES_*` for qualitative/state booleans (IS_ACTIVE, DOES_EXIST)

### Variables
- `"${var}"` everywhere, `"$var"` nowhere
- `local -- __string` for alignment with `local -i __int`
- ALL local variables declared at top of function

### Performance / Style
- `grep bar <<< "${foo}"` over `echo foo | grep bar`
- Prefer `<`/`<<`/`<<<` over `|` where possible
- Favor pure bashisms over command invocations (where it doesn't add 20+ lines)

### Design Principles
- **DRY**: Single source of truth for field definitions, etc.
- **One contiguous block**: A single feature update shouldn't require changes in multiple places
- **Sourceable**: All functions use `return`, never `exit` - script should be sourceable for reuse/testing
- **Error pattern**: `error()` prints message, caller handles return:
  ```bash
  error() { echo "error: ${1}" >&2; }
  # usage:
  [[ -f "${file}" ]] || { error "file not found"; return 1; }
  ```

### Patterns
- **Repeatable flags**: Use arrays (`-a __follow_files`) for flags that can be specified multiple times
- **`@Q` for shell quoting**: `${var@Q}` for safe quoting in generated commands
- **Trap for exit handling**: Prefer trap over inline exit code - ensures cleanup on success, failure, or signal
- **Embed functions via `declare -f`**: For functions needed in generated scripts
- **printf over heredoc**: For quote-safe script generation
- **Config via env with defaults**: `LOG_SIZE_LIMIT="${LOG_SIZE_LIMIT:-5M}"`
- **Shared identifiers for related files**: log, timing, script share timestamp/slug/pane_id
- **Array building for commands**: `__tmux_args=()` pattern, then `"${__tmux_args[@]}"`
- **DRY message building**: Set unique bits in conditional, shared bits outside


## Overview

Refactoring goals:
- Single `q` to quit (no double-quit with `--page`)
- Better logging for Claude awareness (parseable exit codes, structured output)
- Cleaner separation of concerns in `wrap_command()` and `cmd_run()`
- `script(1)` for PTY preservation (colors) with `</dev/null` to prevent input stealing
- Restructure to match `template_subcommands.sh` pattern


## Structure (from template_subcommands.sh)

```
## imports
## exit codes (E_SUCCESS, E_ERROR, E_INVALID_OPTION, E_INVALID_ACTION)
## traps
## colors (C_* for colors, S_* for styles)
## usage functions (help-usage, help-epilogue, help-full, parse-args)
## helpful functions (wrap-command, build-script-command, etc.)
## action functions
    ### run action
        __action-run-help()
        __action-run-parse-args()
        __action-run()
    ### kill action
        __action-kill-help()
        __action-kill-parse-args()
        __action-kill()
    ### list action
        __action-list-help()
        __action-list()
    ### help action (built-in from template)
## main
## run
```

### Naming Conventions

- `E_*` - exit codes
- `C_*` - colors
- `S_*` - styles (reset, bold, dim, etc.)
- `DO_*` - boolean flags
- `__action-<name>*` - action functions (private)


## Core Helper Functions

```bash
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
```


## wrap-command()

Builds the wrapped command string that will be executed in the pane.

Uses global vars set by `__action-run-parse-args()`:
- `RUN_COMMAND` - the base command to run
- `RUN_TITLE` - optional header title
- `RUN_LOG_FILE` - path to log file
- `DO_PAGE` - bool: --page was passed
- `DO_INTERACTIVE` - bool: --interactive was passed

```pseudo
function wrap-command() {
    :  'Build the wrapped command string for pane execution'

    # Output goes to WRAPPED_COMMAND (global, like template pattern)
    WRAPPED_COMMAND=""

    # --- Header ---
    if RUN_TITLE is set:
        WRAPPED_COMMAND += "echo '${C_CYAN}=== ${RUN_TITLE} ===${S_RESET}';"
        WRAPPED_COMMAND += "echo;"

    # --- Main command wrapped in script ---
    # script -qec preserves colors and logs exit code
    # -q = quiet (no header/footer in stdout, still in log)
    # -e = return exit code
    # -c = command mode

    WRAPPED_COMMAND += "script -qec '${RUN_COMMAND}' '${RUN_LOG_FILE}'"

    if NOT DO_INTERACTIVE:
        WRAPPED_COMMAND += " </dev/null"  # prevent script from stealing input

    WRAPPED_COMMAND += ";"

    # --- Footer ---
    WRAPPED_COMMAND += "echo;"
    WRAPPED_COMMAND += "echo '${S_DIM}Press ${C_CYAN}q${S_RESET}${S_DIM} to exit${S_RESET}';"

    # --- Wait for q (only if NOT paging) ---
    if NOT DO_PAGE:
        WRAPPED_COMMAND += "while IFS= read -rsn1 __key; do [[ \"\$__key\" == 'q' ]] && break; done"

    return ${E_SUCCESS}
}
```

### Resolved

1. **Caller responsibility**: ✓ `__action-run-generate-script` handles everything - wrapping, paging, trap
2. **Exit code display**: ✓ Displayed via trap in generated script


## __action-run()

Currently 213 lines as `cmd_run()`. Refactor into template pattern.

### Command Stages

```
COMMAND_RAW      --command value, or file paths from --follow, or script from --run-in-blocks
      ↓
COMMAND_BUILT    prefixed with "tail -f" or "block-run" as needed
      ↓
COMMAND_FINAL    wrapped with script(), header, trap for exit handling
```

### Global Variables (set by parse-args)

```bash
# Content source (exactly one set)
RUN_COMMAND=""           # --command value
RUN_FOLLOW_FILES=()      # --follow (repeatable)
RUN_BLOCKS_SCRIPT=""     # --run-in-blocks

# Options
RUN_POSITION=""          # side | below
RUN_TITLE=""             # --title
DO_PAGE=false            # --page / --no-page
DO_INTERACTIVE=false     # --interactive
DO_FULL=false            # --full / --no-full
DO_PIPEFAIL=true         # --pipefail / --no-pipefail (default true)

# Generated paths
LOG_FILE=""              # /path/to/timestamp-slug.log
LOG_TIMING_FILE=""       # /path/to/timestamp-slug.timing
SCRIPT_FILE=""           # /path/to/timestamp-slug.sh
```

### Configuration

```bash
LOG_SIZE_LIMIT="${LOG_SIZE_LIMIT:-5M}"      # -o limit for script(1)
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-3}"  # cleanup logs older than N days
```

### Main Flow

```bash
function __action-run-parse-args() {
    :  'Parse arguments for the run action'
    # Sets globals above
    # Handles --command - (stdin)
    # Calls __action-run-validate-args
}

function __action-run() {
    :  'Create or replace pane at position'

    # 1. Build command stages
    __action-run-build-command  # COMMAND_RAW → COMMAND_BUILT

    # 2. Build paths (log, timing, script - all share timestamp/slug)
    __action-run-build-paths

    # 3. Build final wrapped command
    __action-run-build-wrapped-command  # → COMMAND_FINAL

    # 4. Generate temp script
    __action-run-generate-script  # writes to SCRIPT_FILE

    # 5. Create or update pane
    __action-run-create-or-update-pane
}
```

### Helper Functions

```bash
function __action-run-validate-args() {
    :  'Validate run arguments'
    local -i __source_count=0

    # Position is valid
    validate-position "${RUN_POSITION}" || return 1

    # Exactly one content source
    [[ -n "${RUN_COMMAND}" ]] && (( ++__source_count ))
    [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]] && (( ++__source_count ))
    [[ -n "${RUN_BLOCKS_SCRIPT}" ]] && (( ++__source_count ))

    [[ ${__source_count} -eq 1 ]] || {
        error "exactly one content source required (--command, --follow, or --run-in-blocks)"
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

    # --interactive and --page are mutually exclusive
    ${DO_INTERACTIVE} && ${DO_PAGE} && {
        error "--interactive and --page are mutually exclusive"
        return 1
    }
}

function __action-run-build-command() {
    :  'Transform content source into COMMAND_RAW and COMMAND_BUILT'

    # Set COMMAND_RAW based on which content source was provided
    if [[ -n "${RUN_COMMAND}" ]]; then
        COMMAND_RAW="${RUN_COMMAND}"
        COMMAND_BUILT="${COMMAND_RAW}"
    elif [[ ${#RUN_FOLLOW_FILES[@]} -gt 0 ]]; then
        COMMAND_RAW="${RUN_FOLLOW_FILES[*]}"
        COMMAND_BUILT="tail -f ${RUN_FOLLOW_FILES[*]@Q}"  # @Q for quoting
    elif [[ -n "${RUN_BLOCKS_SCRIPT}" ]]; then
        COMMAND_RAW="${RUN_BLOCKS_SCRIPT}"
        COMMAND_BUILT="block-run ${RUN_BLOCKS_SCRIPT@Q}"
    fi
}

function __action-run-build-paths() {
    :  'Build log, timing, and script paths with shared identifiers'
    :  'Format: {timestamp}-{slug}.{ext}'
    local -- __timestamp
    local -- __slug

    __timestamp=$(date +%H%M%S%3N)  # HHMMSS + 3 digits of nanoseconds (sub-ms precision)
    __slug=$(tr -cs '[:alnum:]' '_' <<< "${COMMAND_RAW}" | head -c 50)

    LOG_FILE="${LOG_DIR}/${__timestamp}-${__slug}.script.log"
    LOG_TIMING_FILE="${LOG_DIR}/${__timestamp}-${__slug}.timing"
    SCRIPT_FILE="${LOG_DIR}/${__timestamp}-${__slug}.sh"
}

function __action-run-build-wrapped-command() {
    :  'Build COMMAND_FINAL with script() wrapper'
    local -- __script_opts

    # script options: -q (quiet), -e (return exit), -c (command)
    # -T (timing log), -o (size limit)
    # -f (flush) only for non-interactive
    __script_opts="-qec"
    ${DO_INTERACTIVE} || __script_opts+="f"

    COMMAND_FINAL="script ${__script_opts} '${COMMAND_BUILT}' -T '${LOG_TIMING_FILE}' -o '${LOG_SIZE_LIMIT}' '${LOG_FILE}'"

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
        echo '#!/usr/bin/env bash'

        # Pipefail
        ${DO_PIPEFAIL} && echo 'set -o pipefail'

        # Colors for exit display (embedded)
        echo "S_DIM=$'\\e[2m'"
        echo "S_RESET=$'\\e[0m'"
        echo "C_CYAN=$'\\e[36m'"

        # Exit trap
        cat << 'TRAP_EOF'
__exit_code=0
trap '__on_exit' EXIT

__on_exit() {
    echo
    echo "${S_DIM}(exit code: ${__exit_code})${S_RESET}"
TRAP_EOF

        # Only show q-to-quit and read loop if not paging
        if ! ${DO_PAGE}; then
            cat << 'TRAP_EOF'
    echo "${S_DIM}Press ${C_CYAN}q${S_RESET}${S_DIM} to exit${S_RESET}"
    while IFS= read -rsn1 __key; do [[ "${__key}" == "q" ]] && break; done
TRAP_EOF
        fi

        echo '}'

        # Header if title set
        if [[ -n "${RUN_TITLE}" ]]; then
            echo "echo '\${C_CYAN}=== ${RUN_TITLE} ===\${S_RESET}'"
            echo "echo"
        fi

        # Main command with post-processing string injected
        echo "(${COMMAND_FINAL})${__post_process}"
        echo '__exit_code=${PIPESTATUS[0]}'

    } > "${SCRIPT_FILE}"

    chmod +x "${SCRIPT_FILE}"
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

    if [[ -f "${__marker_file}" ]]; then
        # Existing pane - respawn it
        read-marker "${__marker_file}"
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


## __action-kill()

Close pane at position. Uses `find-pane-at-position()` for marker → title fallback.

### Global Variables (set by parse-args)

```bash
KILL_POSITION=""  # side | below
```

### Functions

```bash
function __action-kill-help() {
    :  'Print help for the kill action'
    cat << 'EOF'
claude-pane kill: Close pane at position

USAGE:
  claude-pane kill <position>

REQUIRED:
  position <side|below>    Position of pane to close
EOF
}

function __action-kill-parse-args() {
    :  'Parse arguments for kill action'
    local -- __arg

    KILL_POSITION=""

    while [[ $# -gt 0 ]]; do
        __arg="${1}"
        case "${__arg}" in
            --help|-h)
                __action-kill-help
                return 0
                ;;
            -*)
                error "unknown option: ${__arg}"
                return 1
                ;;
            *)
                if [[ -z "${KILL_POSITION}" ]]; then
                    KILL_POSITION="${__arg}"
                else
                    error "unexpected argument: ${__arg}"
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Validate
    validate-position "${KILL_POSITION}" || return 1
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
    __action-kill-execute-kill "${FOUND_PANE_ID}"

    # Clean up marker (if it existed)
    remove-marker "${KILL_POSITION}"

    echo "killed pane ${FOUND_PANE_ID} at position '${KILL_POSITION}'"
}

function __action-kill-execute-kill() {
    :  'Execute the actual pane kill'
    :  'Separated for future extensibility (e.g., graceful shutdown, cleanup hooks)'
    local -- __pane_id="${1}"

    tmux kill-pane -t "${__pane_id}"
}
```


## Marker Management & Housekeeping

Uses associative array pattern for DRY - add/remove fields in one place only.

**Housekeeping**: `clean-stale-markers` and `clean-old-logs` run at the start of every invocation (in `main()` before dispatching to subcommands). This keeps marker/log state consistent without explicit user intervention.

```bash
declare -A MARKER

function build-marker-path() {
    :  'Build path to marker file for position'
    local -- __position="${1}"

    echo "${MARKER_DIR}/${__position}.marker"
}

function write-marker() {
    :  'Write MARKER associative array to marker file'
    local -- __position="${1}"
    local -- __marker_file
    local -- __key

    __marker_file=$(build-marker-path "${__position}")
    mkdir -p "${MARKER_DIR}"

    for __key in "${!MARKER[@]}"; do
        printf '%s=%q\n' "${__key}" "${MARKER[${__key}]}"
    done > "${__marker_file}"
}

function read-marker() {
    :  'Read marker file into MARKER associative array'
    :  'Values are shell-quoted by write-marker(), so we use eval to unquote'
    :  'Keys are validated to prevent injection attacks'
    local -- __marker_file="${1}"
    local -- __key
    local -- __value

    [[ -f "${__marker_file}" ]] || return 1

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

    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "${__pane_id}"
}

function clean-stale-markers() {
    :  'Remove markers for panes that no longer exist'
    :  'Called at start of every invocation - simplifies logic elsewhere'
    local -- __marker_file

    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue

        read-marker "${__marker_file}"
        if ! pane-exists "${MARKER[pane_id]}"; then
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

    # Collect log files from active markers (already cleaned by clean-stale-markers)
    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue
        read-marker "${__marker_file}"
        [[ -n "${MARKER[log_file]:-}" ]] && __active_logs["${MARKER[log_file]}"]=1
    done

    # Find and delete old logs not in active set
    # Using find for simplicity - fast on small directories
    while IFS= read -r -d '' __log_file; do
        [[ -z "${__active_logs[${__log_file}]:-}" ]] && rm -f "${__log_file}"
    done < <(find "${LOG_DIR}" -type f -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)
}
```


## Pane Management

```bash
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
    :  'Find pane ID at position, with marker → title fallback'
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

    # 1. Try marker file first
    if [[ -f "${__marker_file}" ]]; then
        read-marker "${__marker_file}"
        if pane-exists "${MARKER[pane_id]}"; then
            FOUND_PANE_ID="${MARKER[pane_id]}"
            FOUND_VIA="marker"
            return 0
        fi
        # Marker exists but pane doesn't - stale, remove it
        rm -f "${__marker_file}"
    fi

    # 2. Fallback: search current window for pane with expected title
    __window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null) || return 1

    # List panes in current window with their titles
    # Format: pane_id<tab>pane_title
    __pane_info=$(tmux list-panes -t "${__window_id}" -F '#{pane_id}\t#{pane_title}' 2>/dev/null \
        | grep -F $'\t'"${__expected_title}"$ \
        | head -1)

    if [[ -n "${__pane_info}" ]]; then
        FOUND_PANE_ID="${__pane_info%%$'\t'*}"
        FOUND_VIA="title"
        return 0
    fi

    return 1
}
```

### Usage

```bash
# Write - just set whatever fields you need
MARKER=(
    [pane_id]="%5"
    [title]="My Title"
    [tty]="/dev/pts/1"
    [command]="echo hello"
)
write-marker "side"

# Read
read-marker "$(build-marker-path side)"
echo "${MARKER[pane_id]}"

# At start of main() - housekeeping
clean-stale-markers  # now all markers are valid, no stale checks needed elsewhere
clean-old-logs       # removes logs older than LOG_RETENTION_DAYS (skips active)
```


## Logging Strategy

Goal: Claude can parse logs to understand what happened.

```
Script started on 2025-12-09 04:51:37+00:00 [COMMAND="apt search elinks" TERM="screen-256color" TTY="/dev/pts/6" COLUMNS="174" LINES="100"]
...output...
Script done on 2025-12-09 04:51:39+00:00 [COMMAND_EXIT_CODE="0"]
```

- `script(1)` automatically adds structured header/footer
- Claude can grep for `COMMAND_EXIT_CODE="..."`
- Log path: `$LOG_DIR/<HHMMSS_ms>-<cmd_slug>.script.log`

### Resolved

1. **Log retention**: Age-based cleanup (default 3 days), runs at start of every invocation alongside `clean-stale-markers`. Configurable via `LOG_RETENTION_DAYS`.
2. **`--interactive --page`**: Mutually exclusive - error out if both specified.


## Mode Matrix

| Mode | `</dev/null` | `\| less -R` | wait-for-q |
|------|--------------|--------------|------------|
| default | yes | no | yes |
| `--page` | yes | yes | no |
| `--interactive` | no | no | yes |


## __action-capture()

Wraps `tmux capture-pane` for easy access to pane contents. Useful for Claude to see what's happening in interactive panes.

```bash
function __action-capture-help() {
    :  'Print help for the capture action'
    # usage: claude-pane capture <side|below> [--lines N]
}

function __action-capture-parse-args() {
    :  'Parse arguments for capture action'
    # CAPTURE_POSITION, CAPTURE_LINES (default: all visible)
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
```


## __action-flush()

Sends SIGUSR1 to the running `script` process to force-flush logs. Useful for reading partial output mid-execution.

```bash
function __action-flush-help() {
    :  'Print help for the flush action'
    # usage: claude-pane flush <side|below>
}

function __action-flush-parse-args() {
    :  'Parse arguments for flush action'
    # FLUSH_POSITION
}

function __action-flush() {
    :  'Force-flush logs for pane at position'
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
    __script_pid=$(tmux display-message -t "${FOUND_PANE_ID}" -p '#{pane_pid}')

    # Find script child process
    __script_pid=$(pgrep -P "${__script_pid}" -x script 2>/dev/null | head -1)

    [[ -n "${__script_pid}" ]] || { error "no script process found in pane"; return 1; }

    # Send SIGUSR1 to flush
    kill -USR1 "${__script_pid}"
    echo "flushed logs for pane at '${FLUSH_POSITION}'"
}
```


## __action-list()

Simple, self-contained - no parse-args needed since it takes no arguments.

```bash
function __action-list-help() {
    :  'Print help for the list action'
    cat << 'EOF'
claude-pane list: Show active panes

USAGE:
  claude-pane list
EOF
}

function __action-list() {
    :  'List all tracked panes and their status'
    local -- __marker_file
    local -- __position
    local -- __status
    local -- __found=false

    mkdir -p "${MARKER_DIR}"

    for __marker_file in "${MARKER_DIR}"/*.marker; do
        [[ -f "${__marker_file}" ]] || continue

        __position="${__marker_file##*/}"
        __position="${__position%.marker}"

        read-marker "${__marker_file}"

        if pane-exists "${MARKER[pane_id]}"; then
            __status="${C_GREEN}active${S_RESET}"
        else
            __status="${C_YELLOW}stale${S_RESET}"
        fi

        echo "${C_CYAN}${__position}${S_RESET}: ${MARKER[pane_id]} (${__status})"
        [[ -n "${MARKER[title]:-}" ]] && echo "  title: ${MARKER[title]}"
        [[ -n "${MARKER[command]:-}" ]] && echo "  command: ${MARKER[command]}"
        echo

        __found=true
    done

    ${__found} || echo "no active panes"
}
```


## main()

Entry point - housekeeping, then dispatch to subcommand.

```bash
function main() {
    local -- __action

    # Prerequisites
    check-tmux-running || return 1
    load-env "${CONFIG_FILE}"
    ensure-directories || return 1

    # Housekeeping
    clean-stale-markers
    clean-old-logs

    # Require at least one argument
    [[ $# -gt 0 ]] || { help-usage; return 1; }

    __action="${1}"
    shift

    case "${__action}" in
        run)
            __action-run-parse-args "$@" || return 1
            __action-run
            ;;
        kill)
            __action-kill-parse-args "$@" || return 1
            __action-kill
            ;;
        list)
            [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { __action-list-help; return 0; }
            __action-list
            ;;
        capture)
            __action-capture-parse-args "$@" || return 1
            __action-capture
            ;;
        flush)
            __action-flush-parse-args "$@" || return 1
            __action-flush
            ;;
        --help|-h)
            help-full
            ;;
        *)
            error "unknown command: ${__action}"
            help-usage
            return 1
            ;;
    esac
}

## run
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```


## Future Ideas

- `--run-in-blocks` integration with block-run's marker protocol for per-block exit codes
- `claude-pane status <position>` to check if pane is still running, get exit code
- `claude-pane logs [position]` to list/read recent logs
