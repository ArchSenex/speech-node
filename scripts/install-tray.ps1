# Adds "Speech node" shortcuts that open the tray icon (which starts the node, and stops it from its menu).
#   powershell -ExecutionPolicy Bypass -File install-tray.ps1            # Start menu and desktop
#   powershell -ExecutionPolicy Bypass -File install-tray.ps1 -AtLogon   # also start it when this user logs on
#   powershell -ExecutionPolicy Bypass -File install-tray.ps1 -Remove    # take the shortcuts away again
param([switch]$AtLogon, [switch]$Remove, [string]$Distro = "Ubuntu")
$tray = Join-Path $PSScriptRoot "speech-node-tray.ps1"
$places = @(
    [Environment]::GetFolderPath("Programs"),
    [Environment]::GetFolderPath("Desktop")
)
if ($AtLogon) { $places += [Environment]::GetFolderPath("Startup") }
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in $places + @([Environment]::GetFolderPath("Startup"))) {
    $lnk = Join-Path $dir "Speech node.lnk"
    if ($Remove) { if (Test-Path $lnk) { Remove-Item $lnk; "Removed $lnk" }; continue }
    if ($places -notcontains $dir) { continue }
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = "powershell.exe"
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tray`" -Distro $Distro"
    $s.Description = "Speech node: lends this computer's graphics card to the speech service. Click the dot by the clock to stop it."
    $s.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,168"
    $s.Save()
    "Added $lnk"
}
