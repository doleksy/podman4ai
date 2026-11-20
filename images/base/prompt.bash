# The Sandbox's bash prompt, sourced at the end of the Agent user's
# ~/.bashrc: the project's name (which p4a sets in P4A_PROJECT) in place of
# Debian's user@host, since the host is only the container's ID; the
# current directory; and, inside a git repository, git's own prompt helper
# showing the branch, with * after it for unstaged changes and + for staged
# ones. For example:
#
#   hello-world:/workspace/Hello-World (master *)$
# shellcheck source=/dev/null # Debian's git package's, in the image
. /usr/lib/git-core/git-sh-prompt
# shellcheck disable=SC2034 # read by __git_ps1
GIT_PS1_SHOWDIRTYSTATE=1
PS1='\[\e[1;34m\]${P4A_PROJECT:-\h}\[\e[0m\]:\w\[\e[32m\]$(__git_ps1 " (%s)")\[\e[0m\]\$ '
