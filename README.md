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
| `--follow <file>` | Tail a file (shorthand for `tail -f`) |
| `--run-in-blocks <script>` | Run script via block-run (notebook-style) |

### Options

| Option | Description |
|--------|-------------|
| `--title "..."` | Label shown at top of pane |
| `--page` | Pipe through `less -R` with mouse scrolling |
| `--log` | Capture output via `script(1)` |
| `--interactive` | Skip `script(1)` wrapping (for interactive commands) |
| `--full` | Pane spans full window width/height |
| `--no-full` | Pane splits current pane only (default) |

## Examples

### Show syntax-highlighted code

```bash
claude-pane run side --page --command 'pygmentize -l python example.py'
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

### Close a pane

```bash
claude-pane kill side
claude-pane kill below
```

## Configuration

Create `~/.claude-pane.conf` to set defaults:

```bash
# Default to full-width/height panes
CREATE_FULL_PANES=true
```

## How It Works

1. Creates a marker file in `/tmp/claude-pane.$USER/` to track pane positions
2. When opening a pane at an existing position, respawns instead of creating new
3. Commands are wrapped with:
   - Optional title header
   - Exit code display
   - "Press q to close" prompt
4. Optionally logs output via `script(1)` for debugging

## For Claude Code Users

See [CLAUDE.md](CLAUDE.md) for heuristics and examples on how to teach Claude to use this tool effectively in teaching sessions.
