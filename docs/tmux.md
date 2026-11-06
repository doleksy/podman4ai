# tmux cheat sheet

`p4a claude <project>` puts you in the project's Claude session, a tmux session named `claude` in its Sandbox. It starts the project and the session if needed. `Ctrl-b` is the prefix: press it, let go, then press the key.

| To | Do |
|---|---|
| Leave, keeping Claude running | `Ctrl-b d` (detach), or just close the terminal |
| Come back | `p4a claude <project>`, from any Git Bash |
| Come back from `p4a shell <project>` | `tmux attach -t claude` |
| Scroll back | Mouse wheel. Or `Ctrl-b [`, then arrows / `PgUp` / `PgDn`; `q` to stop |
| Search the scrollback | `Ctrl-b [`, then `Ctrl-r` and type; `q` to stop |
| Split side by side / top and bottom | `Ctrl-b %` / `Ctrl-b "` |
| Move between panes | Click one, or `Ctrl-b` then an arrow |
| Resize a pane | Drag its border |
| Close a pane | `exit` in it |
| Zoom a pane to full size and back | `Ctrl-b z` |

Quitting Claude Code ends the session. The next `p4a claude <project>` starts a new one.
