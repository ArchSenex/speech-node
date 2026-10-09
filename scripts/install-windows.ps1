# speech-node: one-click install, update and start on a Windows machine with an NVIDIA card.
# Run "Install Speech Node.cmd" (beside this folder's scripts) by double-clicking it; run it again any time to update.
#   1. WSL and Ubuntu (if missing: installs them, then asks for a reboot; run this again after it)
#   2. the Linux packages the node needs (no password needed: run as WSL's root)
#   3. the node itself: its own Python environment, Breeze TTS 2 and its weights (about 7 GB, the first time)
#   4. node.json: named after this computer, slots from the card's memory (only the first time; edit it to change)
#   5. networking, so the gateway can reach it: WSL's mirrored mode and a firewall rule for its port (one admin prompt)
#   6. the "Speech node" tray icon (Start menu and desktop; optionally at log-on), started now
# Switches: -NoFirewall (skip step 5's admin part), -AtLogon (start the icon when you log on), -Distro <name> (default Ubuntu)
param([string]$Distro = "Ubuntu", [switch]$NoFirewall, [switch]$AtLogon, [int]$Port = 7860)
$ErrorActionPreference = "Stop"
function Say($t, $c = "Cyan") { Write-Host ""; Write-Host "== $t" -ForegroundColor $c }
function ConvertTo-WslPath([string]$p) {
    $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
    if ($full -match '^\\\\wsl(\.localhost|\$)\\[^\\]+(\\.*)?$') { return ($Matches[2] -replace '\\', '/') }
    if ($full -match '^([A-Za-z]):\\(.*)$') { return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')" }
    throw "Can't find this folder from WSL: $full"
}
function Wsl([string]$cmd, [switch]$Root) {
    $a = @("-d", $Distro); if ($Root) { $a += @("-u", "root") }
    & wsl.exe @a -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed ($LASTEXITCODE): $cmd" }
}
$App = Join-Path $PSScriptRoot ".."
$AppWsl = ConvertTo-WslPath $App

try {
    Say "1. WSL and $Distro"
    $distros = (& wsl.exe -l -q 2>$null) -replace "`0", "" | Where-Object { $_.Trim() }
    if (-not ($distros -contains $Distro)) {
        Write-Host "$Distro isn't installed. Installing WSL and $Distro (Windows will ask for permission)..."
        Start-Process wsl.exe -ArgumentList "--install", "-d", $Distro -Verb RunAs -Wait
        Write-Host ""
        Write-Host "Next: restart the computer if Windows asks you to. Ubuntu then opens by itself and asks for a" -ForegroundColor Yellow
        Write-Host "username and password (any you like; you won't need them for the node). Then run this installer again." -ForegroundColor Yellow
        Read-Host "Press Enter to close"
        exit 0
    }
    Write-Host "$Distro is there."
    Wsl "command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || { echo 'No NVIDIA card visible in WSL: update the NVIDIA driver on Windows.'; exit 1; }"

    Say "2. Linux packages"
    Wsl "dpkg -s python3-venv git >/dev/null 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv git)" -Root
    Write-Host "Done."

    Say "3. The node (Python environment, Breeze TTS 2, its weights: the first time takes a while)"
    Wsl "bash '$AppWsl/scripts/setup.sh'"

    Say "4. This machine's settings (~/speech-node/node.json)"
    $out = & wsl.exe -d $Distro -- bash -lc "bash '$AppWsl/scripts/configure-node.sh' '$($env:COMPUTERNAME.ToLower())' $Port"
    if ($LASTEXITCODE -ne 0) { throw "Couldn't write node.json" }
    $out | Where-Object { $_ -notmatch '^SLOTS=' } | ForEach-Object { Write-Host $_ }
    $slots = (($out | Where-Object { $_ -match '^SLOTS=' }) -replace 'SLOTS=', '').Trim()

    Say "5. Networking"
    $wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
    $cfg = if (Test-Path $wslconfig) { Get-Content $wslconfig -Raw } else { "" }
    if ($cfg -notmatch '(?im)^\s*networkingMode\s*=\s*mirrored') {
        if ($cfg -match '(?im)^\s*\[wsl2\]') { $cfg = $cfg -replace '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nnetworkingMode=mirrored" }
        else { $cfg = $cfg.TrimEnd() + "`r`n[wsl2]`r`nnetworkingMode=mirrored`r`n" }
        Set-Content -Path $wslconfig -Value $cfg.TrimStart() -Encoding ascii
        Write-Host "WSL now shares Windows' network (mirrored), so other machines can reach the node. Restarting WSL..."
        & wsl.exe --shutdown
    } else { Write-Host "WSL already shares Windows' network." }
    if (-not $NoFirewall) {
        $rule = Get-NetFirewallRule -DisplayName "speech-node" -ErrorAction SilentlyContinue
        if (-not $rule) {
            Write-Host "Opening port $Port in the firewall (Windows will ask for permission)..."
            Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile", "-Command", "New-NetFirewallRule -DisplayName 'speech-node' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null"
        } else { Write-Host "Port $Port is already open." }
    }

    Say "6. The tray icon"
    $inst = Join-Path $PSScriptRoot "install-tray.ps1"
    if ($AtLogon) { & $inst -Distro $Distro -AtLogon } else { & $inst -Distro $Distro }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'speech-node-tray\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process powershell.exe -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $PSScriptRoot 'speech-node-tray.ps1')`"", "-Distro", $Distro
    Write-Host "Started: look for the dot by the clock (amber while the voice model loads, green when ready)."

    Say "Done. Add this machine to the gateway" "Green"
    $hosts = @($env:COMPUTERNAME.ToLower())
    try { $ts = (& tailscale ip -4 2>$null | Select-Object -First 1); if ($ts) { $hosts += $ts.Trim() } } catch {}
    Write-Host "In llmserver's config.xml (or its admin page), under <provider name=`"speech`">, add one of:"
    foreach ($h in $hosts) { Write-Host "  <endpoint capacity=`"$slots`" enabled=`"true`">http://$($h):$Port</endpoint>" -ForegroundColor White }
    Write-Host "It takes effect as soon as the file is saved. To stop the node, click the dot by the clock."
} catch {
    Write-Host ""
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""
Read-Host "Press Enter to close"
