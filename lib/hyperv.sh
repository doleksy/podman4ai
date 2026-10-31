# shellcheck shell=bash
# The one place p4a calls Hyper-V, through Windows PowerShell.
#
# Podman's Hyper-V provider creates its VMs with dynamic memory on, and
# Podman has no option to turn it off (ADR 0004). These calls need
# membership of Hyper-V Administrators, which setup already requires.

# The PowerShell command that turns dynamic memory off for the Sandbox
# machine's VM. The VM must be stopped. Also shown to users as a fix.
P4A_HYPERV_FIXED_MEMORY_COMMAND="Set-VMMemory -VMName $P4A_MACHINE -DynamicMemoryEnabled \$false"

# p4a_powershell SCRIPT
# Run SCRIPT in Windows PowerShell. Any error stops it with a non-zero exit.
p4a_powershell() {
  command -v powershell >/dev/null 2>&1 \
    || p4a_die "powershell not found on PATH" "run p4a from Git Bash on Windows"
  MSYS_NO_PATHCONV=1 command powershell -NoProfile -NonInteractive -Command \
    "\$ErrorActionPreference = 'Stop'; $1"
}

# Turn dynamic memory off for the Sandbox machine's VM, so it always has
# its full memory.
p4a_hyperv_turn_off_dynamic_memory() {
  p4a_powershell "$P4A_HYPERV_FIXED_MEMORY_COMMAND"
}

# Print True or False: whether the Sandbox machine's VM has dynamic memory
# on. Fails, printing nothing, if Hyper-V can't say.
p4a_hyperv_dynamic_memory() {
  local answer
  answer="$(p4a_powershell "(Get-VMMemory -VMName $P4A_MACHINE).DynamicMemoryEnabled" 2>/dev/null)" || return 1
  answer="${answer//$'\r'/}"
  [[ $answer == True || $answer == False ]] || return 1
  echo "$answer"
}
