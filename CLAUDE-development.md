# Development Workflows with `claude-pane`

You have access to `claude-pane`, a tool that opens tmux panes to show files, logs, and command output alongside the main conversation. This guide covers heuristics for using it effectively during development sessions.

## "Show Me ___" Heuristics

When the user asks to "show" something, prefer opening it in a pane over just reading it:

| User says | Action |
|-----------|--------|
| "Show me the config file" | `--view <file>` |
| "Show me the error logs" | `--follow <logfile>` |
| "Show me what changed" | `--page --command 'git diff'` |
| "Show me the test output" | `--page --command 'npm test'` |
| "What's in ___" / "Read ___" | Use Read tool (no pane needed) |

**Heuristics for when to use a pane:**
- User says "show me" → visual display in pane
- File is long (>30 lines) → pane with scrolling
- User wants reference material visible while working → pane stays open
- Comparing or cross-referencing → pane alongside conversation

## File Viewing with `--view`

Use `--view <file>` for viewing files - it opens them in `less` and uses `lessfilter` for syntax highlighting if available:

```bash
claude-pane run side --view src/main.py
claude-pane run side --title "Config" --view ~/.config/app/settings.json
```

**When to use `--view` vs `--page --command 'cat ...'`:**
- `--view` → syntax highlighting (if lessfilter configured), proper scrolling
- `--page --command` → when you need to transform output (grep, jq, etc.)

## Log Streaming Heuristics

### Always stream logs when:
- User explicitly asks: "watch the logs", "monitor ___", "stream ___"
- User says "let's see what happens when..."
- Running a dev server that the user will interact with

### Consider streaming logs when:
- Running tests (especially integration/e2e that may have verbose output)
- Starting a build process that might fail
- Debugging ("let's figure out why...")
- Any long-running command where output matters

### Commands that typically warrant log streaming:

| Command type | Example | Position |
|--------------|---------|----------|
| Dev servers | `npm run dev`, `yarn start`, `flask run`, `rails s` | `below --full` |
| Docker | `docker compose up`, `docker logs -f` | `below --full` |
| Tests | `npm test`, `pytest -v`, `go test -v` | `below` |
| Builds | `npm run build`, `cargo build`, `make` | `below` |
| Watchers | `tsc --watch`, `nodemon` | `below --full` |

```bash
# Dev server logs
claude-pane run below --full --title "Dev Server" --command 'npm run dev'

# Follow existing log file
claude-pane run below --full --follow /var/log/app/error.log

# Docker compose
claude-pane run below --full --title "Docker" --command 'docker compose up'
```

## Common Development Patterns

### Split-screen reference
Show a related file while discussing or editing another:

```bash
# Show test file while implementing
claude-pane run side --view tests/test_auth.py

# Show types/interface while implementing
claude-pane run side --title "Types" --view src/types.ts
```

### Diff viewing
Show changes for review or discussion:

```bash
# Staged changes
claude-pane run side --page --command 'git diff --cached'

# Changes vs main branch
claude-pane run side --page --command 'git diff main...HEAD'

# Specific file history
claude-pane run side --page --command 'git log -p --follow src/auth.py'
```

### Process monitoring
When debugging performance or resource issues:

```bash
# System resources
claude-pane run below --full --interactive --command 'htop'

# Docker containers
claude-pane run below --command 'watch -n2 docker stats'

# Kubernetes pods
claude-pane run below --command 'watch -n2 kubectl get pods'
```

### Database/API exploration
Show query results or API responses:

```bash
# SQL query results
claude-pane run side --page --command 'psql -c "SELECT * FROM users LIMIT 10"'

# API response
claude-pane run side --page --command 'curl -s https://api.example.com/users | jq'
```

### Man pages and documentation
Quick reference while working:

```bash
claude-pane run side --page --command 'man git-rebase'
claude-pane run side --page --command 'npm help install'
```

## Position Heuristics Recap

| Content type | Position | Why |
|--------------|----------|-----|
| Reference files | `side` | Keep visible while discussing |
| Streaming logs | `below --full` | Full width, easy to scan |
| Command output | `side --page` | Scrollable, alongside conversation |
| Interactive tools | `side --interactive` | htop, less, vim, etc. |
| Build output | `below` | Watch progress, doesn't need full width |

## Tips

1. **Check dimensions first** (first pane of session):
   ```bash
   tmux display-message -p 'Width: #{pane_width} Height: #{pane_height}'
   ```

2. **Respawn, don't recreate**: Running `claude-pane run side ...` when a side pane exists will respawn it with the new content - no flicker.

3. **Offer to close**: After showing something, mention "I can close this when you're done" or close it yourself when moving to unrelated work.

4. **Combine with capture**: If you need to analyze pane contents programmatically:
   ```bash
   claude-pane capture side | grep -i error
   ```
