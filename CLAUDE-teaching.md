# Teaching Panes with `claude-pane`

You have access to `claude-pane`, a tool that opens tmux panes to show documentation, code examples, SQL queries, or running processes alongside the main conversation.

## When to Use Panes

**Heuristics for when to open a pane:**

- **5+ lines of code or SQL** → show in a pane
- **Multi-step processes** (Docker setup, service configuration) → show in pane with updates as steps progress
- **Live logs or streaming output** (tail -f, server logs, build output) → show in pane
- **New concepts** the user hasn't encountered before → offer to show examples

**Don't use panes for simple things** like basic command reminders (`ls`, `cd`, `git status`).

## Choosing Pane Position

**Before the first time you use `claude-pane` in a session**, fetch the terminal dimensions:

```bash
tmux display-message -p 'Width: #{pane_width} Height: #{pane_height}'
```

**Position heuristics:**

| Condition | Position | Reason |
|-----------|----------|--------|
| Streaming logs / live output | `below --full` | Full-width, easy to watch |
| Terminal width < 80 cols | `below --full` | Not enough horizontal room |
| Width ≥ 4× height | `side` | Wide screen, room to split horizontally |
| Otherwise | `below` | More vertical room |

After opening the first pane, ask: **"Does that look okay on your screen?"**

## Basic Usage

```bash
claude-pane run <side|below> [options] --command '<cmd>'
claude-pane run side --command '<new command>'    # replaces existing side pane
claude-pane kill <side|below>                     # close pane at position
claude-pane list                                  # show active panes
```

**Options:**
- `--title "..."` → Label shown at top of pane
- `--page` → Pipe through less (for scrollable static output)
- `--full` → Pane spans full window width/height
- `--no-full` → Pane splits current pane only (default)
- `--follow <file>` → Shorthand for `tail -f <file>`
- `--view <file>` → View file in less (uses `lessfilter` if available)
- `--run-in-blocks <script>` → Run script block-by-block (requires [block-run](https://github.com/shitchell/block-run))

## Code Examples in Panes

**Heuristic: choose based on whether the code should be executed**

| Situation | Tool | Why |
|-----------|------|-----|
| Have real data, safe to run | `block-run` | Shows code + executes + shows output |
| No data, or unsafe to run | `pygmentize` | Syntax highlighting only, no execution |

### With real data: use `block-run`

`block-run` executes scripts block-by-block like a notebook. Blocks are separated by blank lines.

1. **Validate your query first** - run it to make sure it works
2. **Write an example script** with appropriate shebang
3. **Use incremental queries** - show what smaller sections return, then combine
4. **Show it in a pane**

Example script (`example.py`):
```python
#!/usr/bin/env python3

# First, let's define some data
x = 10
print(f"x = {x}")

# Now let's do some math
y = x * 2
print(f"y = {y}")

# Combine them
print(f"x + y = {x + y}")
```

Show it:
```bash
claude-pane run side --page --run-in-blocks example.py
```

### Without data or unsafe: use `pygmentize`

```bash
claude-pane run side --page --command 'pygmentize -l python example.py'
```

## Live Logs

For web dev or debugging, show logs while the user interacts:

```bash
claude-pane run below --full --follow /var/log/nginx/access.log
```

This creates a feedback loop: user does something → sees the result in the logs → understands the connection.

## Always Explain How to Interact

After opening a pane, briefly explain:

- For paged output: "Use arrow keys to scroll, press `q` to close"
- For live logs: "Watch this as you interact. Press `Ctrl+C` to stop, then `q` to close"
- Always mention: "I can close this for you anytime—just ask!"

## Syntax Highlighting Tools

- **Markdown**: `glow <file>` or pipe to `glow -`
- **Code (no execution)**: `pygmentize -l <language>` (e.g., `-l sql`, `-l python`, `-l bash`)
- **Code (with execution)**: `block-run` automatically highlights each block

## Example Workflows

### Teaching a concept with live code

```bash
# Write the example
cat > /tmp/example.py << 'EOF'
#!/usr/bin/env python3

# Define a list
numbers = [1, 2, 3, 4, 5]
print(f"numbers = {numbers}")

# List comprehension doubles each number
doubled = [x * 2 for x in numbers]
print(f"doubled = {doubled}")

# Filter for even numbers
evens = [x for x in doubled if x % 4 == 0]
print(f"evens = {evens}")
EOF

# Show it block by block
claude-pane run side --title "List Comprehensions" --page --run-in-blocks /tmp/example.py
```

### Showing static documentation

```bash
claude-pane run side --title "Git Cheat Sheet" --page --command 'cat ~/docs/git-cheatsheet.md | glow -'
```

### Monitoring a build process

```bash
claude-pane run below --full --title "Build Output" --command 'npm run build'
```
