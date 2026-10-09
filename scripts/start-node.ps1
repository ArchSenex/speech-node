# Starts speech-node in WSL from Windows, in its own window (for a shortcut or a log-on task).
#   powershell -ExecutionPolicy Bypass -File start-node.ps1 [-Distro Ubuntu] [-Repo ~/speech-node-app]
param([string]$Distro = "Ubuntu", [string]$Repo = "")
if (-not $Repo) {
    # this script's own checkout, as WSL sees it
    $Repo = (& wsl -d $Distro wslpath -a ($PSScriptRoot + "\..")).Trim()
}
Start-Process wsl -ArgumentList @("-d", $Distro, "bash", "-lc", "`"$Repo/scripts/run.sh`"")
