# Thin Windows entry point for the fm_ros2 install. The logic lives in bash
# (install.sh); this ensures Git for Windows is present, then delegates through Git
# Bash, forwarding all arguments. pixi and the foxglove viewer are installed by the
# bash path (scripts/install/native.sh) — this wrapper stays minimal on purpose.
#
#   .\install.ps1                       # OS default: native + foxglove
#   .\install.ps1 --container           # force the container path (refused later on Windows)
#   .\install.ps1 --native --viewer rviz
#
# Windows has no container run path (OrbStack is macOS-only); the native path is
# the supported one here. run.ps1 mirrors this wrapper for the launch.
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
  Write-Host 'Git for Windows not found - installing via winget ...'
  winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
  $bash = Find-Bash
  if (-not $bash) {
    Write-Error 'Git Bash still not found after install - see https://git-scm.com/download/win'
    exit 1
  }
}

# Pass the wrapper's directory through the environment; cygpath converts it to a
# POSIX path inside Git Bash. Forward wrapper args as bash positional parameters
# ("$@") rather than string interpolation, so no argument can inject shell syntax.
$env:FM_HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
& $bash -lc 'cd "$(cygpath -u "$FM_HERE")" && ./install.sh "$@"' -- @args
exit $LASTEXITCODE
