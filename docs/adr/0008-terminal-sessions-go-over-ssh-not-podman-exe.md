# Terminal sessions go over ssh, not podman.exe

On a terminal, `p4a shell` and `p4a claude` reach the Sandbox through Git Bash's own `ssh` into the Sandbox machine, and run `podman exec -it` there. They use the port, user and key that `podman machine inspect` reports, which are the ones Podman itself uses. Without a terminal, `p4a` keeps calling `podman.exe exec` as everywhere else.

`podman.exe` is a native Windows console program. Git Bash's window (mintty) runs native console programs through Windows' ConPTY, which keeps its own copy of the screen and redraws it into mintty. With Claude Code in tmux, that copy drifted away from tmux's after a while: symbols at the start of lines left repeated characters behind and drew over the text, although tmux's own copy of the screen was correct. Git Bash's `ssh` is an MSYS program, so mintty talks to it directly and the screen stayed clean.

## Considered Options

- **Keep `podman.exe exec -it`**, and look for a terminal or font setting that hides the drift. ConPTY's copy is the problem, and no mintty setting removes it.
- **winpty** (`winpty podman exec -it`). It also runs the program in a hidden console and redraws that console's screen into mintty, the same kind of copy ConPTY keeps.
- **Windows' OpenSSH** (`C:\Windows\System32\OpenSSH\ssh.exe`). It's a native program too, so it goes through ConPTY like `podman.exe`.

## Consequences

- `p4a` depends on Git Bash's `ssh` being first on PATH, as it is by default in Git Bash.
- ssh skips host key checking for the Sandbox machine, as Podman does: it's on `127.0.0.1` and its key changes when it's recreated.
- ssh hands the remote shell a single string, so `p4a` quotes each argument with Bash's `printf %q`. The Sandbox machine user's shell is bash.
- A failure in ssh itself exits 255, where `podman.exe` would have said what went wrong.
