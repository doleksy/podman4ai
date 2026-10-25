# Source lives in Project volumes, not on Host drives

Each project's source is cloned from GitHub into its own named Podman volume, and the Sandbox never mounts a Windows path such as `E:\workspace`. Mounting Host folders would give every Sandbox a path into Windows and make file access slow, and since editing happens in VS Code attached to the Sandbox there is no need for Windows to see the files. GitHub is the backup; the volume only protects unpushed work across Sandbox rebuilds.

## Consequences

- Existing projects on `E:\` are re-cloned into a Project volume rather than mounted.
- Editing from a Windows-native editor against the files directly is not supported.
- Only split editors are allowed, whose engine runs inside the Sandbox and whose interface runs on Windows: VS Code (attach to running container) now, JetBrains Rider via Gateway if ever wanted. Visual Studio is ruled out for Sandbox work: it runs entirely on Windows, and opening a solution runs MSBuild files the Agent can write, which would execute on the Host. Code needing Visual Studio is pulled from GitHub after review and opened outside podman4ai.
