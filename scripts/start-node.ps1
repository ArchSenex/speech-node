# Starts speech-node in WSL from Windows, in its own console window (for a shortcut). For a quiet icon by the clock
# with a Stop button, use speech-node-tray.ps1 instead.
#   powershell -ExecutionPolicy Bypass -File start-node.ps1 [-Distro Ubuntu] [-Repo <path in WSL>]
param([string]$Distro = "Ubuntu", [string]$Repo = "")
function ConvertTo-WslPath([string]$p) {
    # C:\x\y -> /mnt/c/x/y ;  \\wsl.localhost\Ubuntu\home\me\x (or \\wsl$\...) -> /home/me/x
    $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
    if ($full -match '^\\\\wsl(\.localhost|\$)\\[^\\]+(\\.*)?$') { return ($Matches[2] -replace '\\', '/') }
    if ($full -match '^([A-Za-z]):\\(.*)$') { return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')" }
    throw "Can't find this script's folder from WSL: $full"
}
if (-not $Repo) { $Repo = ConvertTo-WslPath (Join-Path $PSScriptRoot "..") }
Start-Process wsl -ArgumentList @("-d", $Distro, "bash", "-lc", "`"$Repo/scripts/run.sh`"")
