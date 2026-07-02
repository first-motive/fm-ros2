# Thin Windows entry point for the fm_ros2 launch. The logic lives in bash
# (run.sh, which dispatches to the native or container path); this ensures Git for
# Windows is present, then delegates through Git Bash, forwarding all arguments.
#
#   .\run.ps1                # route by the profile in .fm_ros2.json (native on Windows)
#   .\run.ps1 --native       # force the native path (pixi/RoboStack)
#   .\run.ps1 --no-foxglove  # (native) skip auto-opening a viewer
#
# The container path is not supported on Windows (OrbStack is macOS-only); run.sh
# refuses it with a WSL2 pointer.
$ErrorActionPreference = 'Stop'

# Locate Git Bash: prefer bash.exe on PATH, else the standard install locations.
function Find-Bash {
  $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe",
                   "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

$bash = Find-Bash
if (-not $bash) {
  Write-Error 'Git for Windows not found - install it (or run .\install.ps1 first): https://git-scm.com/download/win'
  exit 1
}

# Pass the wrapper's directory through the environment; cygpath converts it to a
# POSIX path inside Git Bash. Forward wrapper args as bash positional parameters
# ("$@") rather than string interpolation, so no argument can inject shell syntax.
$env:FM_HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
& $bash -lc 'cd "$(cygpath -u "$FM_HERE")" && ./run.sh "$@"' -- @args
exit $LASTEXITCODE
