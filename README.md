# claude-pane

A tmux pane manager for Claude Code teaching sessions. Opens panes to show documentation, code examples, SQL queries, or running processes alongside the main conversation.

## Installation

```bash
# Clone the repo
git clone https://github.com/shitchell/claude-pane.git
cd claude-pane

# Install globally (requires root)
sudo ./install.sh

# Or install locally (to ~/.local/bin)
./install.sh --local
```

To uninstall:

```bash
# Remove local install
./uninstall.sh

# Remove both local and global install
sudo ./uninstall.sh
```

## Requirements

- **tmux** - Must be running inside a tmux session
- **block-run** (optional) - For `--run-in-blocks` feature. Install from: https://github.com/shitchell/block-run

## Usage

```bash
claude-pane <command> [args]
```

### Commands

| Command | Description |
|---------|-------------|
| `run <position> [options]` | Create or replace pane at position |
| `kill <position>` | Close pane at position |
| `list` | Show active panes |
| `capture <position>` | Capture pane contents to stdout |
| `flush <position>` | Force-flush logs for pane |
| `help [command]` | Show help for a specific command |

### Positions

- `side` - Opens pane to the right (horizontal split)
- `below` - Opens pane at the bottom (vertical split)

## Run Command Options

```bash
claude-pane run <side|below> [options] <content-source>
```

### Content Sources (one required)

| Option | Description |
|--------|-------------|
| `--command '<cmd>'` | Run arbitrary command (use `-` to read from stdin) |
| `--follow <file>` | Tail a file (shorthand for `tail -f`), repeatable |
| `--run-in-blocks <script>` | Run script via block-run (notebook-style) |
| `--view <file>` | View file in less (uses `lessfilter` if available for syntax highlighting) |

### Options

| Option | Description |
|--------|-------------|
| `--title "..."` | Label shown at top of pane |
| `--page` | Pipe through `less -R` with mouse scrolling |
| `--no-page` | Disable paging (default for most sources) |
| `--interactive` | Enable stdin for interactive commands |
| `--full` | Pane spans full window width/height |
| `--no-full` | Pane splits current pane only (default) |
| `--pipefail` | Enable pipefail in wrapper script (default) |
| `--no-pipefail` | Disable pipefail |

## Examples

### Show syntax-highlighted code

```bash
claude-pane run side --page --command 'pygmentize -l python example.py'
```

### View a file (with lessfilter highlighting if available)

```bash
claude-pane run side --view ~/.bashrc
```

### Run a script block-by-block

```bash
claude-pane run side --page --run-in-blocks ~/examples/demo.sql
```

### Follow a log file

```bash
claude-pane run below --full --follow /var/log/nginx/access.log
```

### Show command output with a title

```bash
claude-pane run side --title "Docker Containers" --page --command 'docker ps -a'
```

### Read command from stdin (avoids quoting issues)

```bash
claude-pane run side --command - << 'EOF'
echo "Hello!"
for i in 1 2 3; do
    echo "Count: $i"
done
EOF
```

### Replace an existing pane

Running `claude-pane run side ...` when a side pane already exists will respawn that pane with the new command (no flickering).

### Capture pane contents

```bash
claude-pane capture side > output.txt
```

### Close panes

```bash
claude-pane kill side
claude-pane kill below
```

## Configuration

Create `~/.config/claude-pane/config` or `~/.claude-pane.conf` to set defaults:

```bash
# Default to full-width/height panes
CREATE_FULL_PANES=true

# Log size limit (default: 5M)
LOG_SIZE_LIMIT=10M

# Log retention in days (default: 3)
LOG_RETENTION_DAYS=7
```

## How It Works

1. Creates marker files in `/tmp/claude-pane.$USER/` to track pane positions
2. When opening a pane at an existing position, respawns instead of creating new (no flickering)
3. All commands are wrapped with `script(1)` for PTY preservation and logging
4. Output is logged to `/tmp/claude-pane.$USER/logs/` with timing data
5. Commands display:
   - Optional title header (cyan)
   - Navigation hints (`--page`: scroll instructions, `--follow`: Ctrl+C hint)
   - Exit code on completion
   - "Press q to close" prompt (non-paging modes)
6. Stale markers and old logs (>3 days) are cleaned up automatically

## For Claude Code Users

See these guides for heuristics on using claude-pane effectively:

- [CLAUDE-development.md](CLAUDE-development.md) - Development workflows (file viewing, log streaming, diffs)
- [CLAUDE-teaching.md](CLAUDE-teaching.md) - Teaching sessions (code examples, live demos, notebooks)
