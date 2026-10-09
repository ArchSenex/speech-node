# speech-node tray icon: starts the node in WSL (hidden) and shows a small icon by the clock.
#   Green: running and ready.  Amber: starting up or loading the voice model.  Grey: stopped.
#   Hover: what it's doing.  Click: a menu with "Stop speech node (free the graphics card)" and "Start again".
# Closing it from the menu stops the node too, so the computer is entirely back to normal.
#   powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File speech-node-tray.ps1 [-Distro Ubuntu] [-Repo <path in WSL>]
param([string]$Distro = "Ubuntu", [string]$Repo = "", [int]$Port = 7860)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function ConvertTo-WslPath([string]$p) {
    # C:\x\y -> /mnt/c/x/y ;  \\wsl.localhost\Ubuntu\home\me\x (or \\wsl$\...) -> /home/me/x
    $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
    if ($full -match '^\\\\wsl(\.localhost|\$)\\[^\\]+(\\.*)?$') { return ($Matches[2] -replace '\\', '/') }
    if ($full -match '^([A-Za-z]):\\(.*)$') { return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')" }
    throw "Can't find this script's folder from WSL: $full"
}
if (-not $Repo) { $Repo = ConvertTo-WslPath (Join-Path $PSScriptRoot "..") }

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 3, 3, 26, 26)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(160, 0, 0, 0)), 2), 3, 3, 26, 26)
    # a little speech mark
    $g.FillRectangle([System.Drawing.Brushes]::White, 10, 12, 12, 2)
    $g.FillRectangle([System.Drawing.Brushes]::White, 10, 17, 8, 2)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icons = @{
    ready   = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 160, 67))
    loading = New-DotIcon ([System.Drawing.Color]::FromArgb(219, 160, 30))
    stopped = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
}

$script:proc = $null
function Start-Node {
    if ($script:proc -and -not $script:proc.HasExited) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "-d $Distro bash -lc `"$Repo/scripts/run.sh`""
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $script:proc = [System.Diagnostics.Process]::Start($psi)
}
function Stop-Node {
    # ends the node and its model copies inside WSL, then the wsl.exe that ran it
    # only the speech node's own Python processes (its environment under ~/speech-node), nothing else in WSL
    & wsl -d $Distro bash -lc "pkill -f 'speech-node/venv/bin/python' ; sleep 2 ; pkill -9 -f 'speech-node/venv/bin/python' ; true" | Out-Null
    if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    $script:proc = $null
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icons.loading
$tray.Text = "Speech node: starting"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$status = $menu.Items.Add("Starting...")
$status.Enabled = $false
[void]$menu.Items.Add("-")
$stop = $menu.Items.Add("Stop speech node (free the graphics card)")
$start = $menu.Items.Add("Start again")
[void]$menu.Items.Add("-")
$quit = $menu.Items.Add("Stop and close this icon")
$tray.ContextMenuStrip = $menu
# a left click opens the same menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') {
    $m = [System.Windows.Forms.NotifyIcon].GetMethod("ShowContextMenu", [System.Reflection.BindingFlags]"Instance,NonPublic"); $m.Invoke($tray, $null) } })

$stop.add_Click({ Stop-Node; Update-Status })
$start.add_Click({ Start-Node; Update-Status })
$quit.add_Click({ Stop-Node; $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })

function Update-Status {
    $running = $script:proc -and -not $script:proc.HasExited
    $h = $null
    try { $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 } catch {}
    if (-not $running -and -not $h) {
        $tray.Icon = $icons.stopped; $tray.Text = "Speech node: stopped"; $status.Text = "Stopped. The graphics card is free."
        $stop.Enabled = $false; $start.Enabled = $true; return
    }
    $stop.Enabled = $true; $start.Enabled = $false
    if (-not $h) { $tray.Icon = $icons.loading; $tray.Text = "Speech node: starting"; $status.Text = "Starting..."; return }
    $vram = if ($h.vram.free_mb) { " | $([math]::Round($h.vram.free_mb / 1024, 1)) GB free" } else { "" }
    if ($h.loaded -lt 1) {
        $tray.Icon = $icons.loading; $state = "loading the voice model"
    } else {
        $tray.Icon = $icons.ready
        $state = if ($h.busy -gt 0) { "speaking ($($h.busy) at once, $($h.queued) waiting)" } else { "ready, idle" }
    }
    $text = "Speech node: $state"
    $tray.Text = $text.Substring(0, [math]::Min(63, $text.Length))  # Windows caps tray tooltips at 63 characters
    $status.Text = "$($h.name): $state | $($h.loaded) of $($h.slots) loaded | $($h.done) done$vram"
}

Start-Node
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Update-Status })
$timer.Start()
$tray.ShowBalloonTip(4000, "Speech node", "Running in the background. Click the dot by the clock to stop it.", 'Info')
[System.Windows.Forms.Application]::Run()
