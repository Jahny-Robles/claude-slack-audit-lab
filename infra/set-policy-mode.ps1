<#
.SYNOPSIS
  Sets POLICY_MODE in .env (monitor | redact | block) and stops any running copies of the bot,
  so the new mode takes effect the next time you start it.

    powershell -ExecutionPolicy Bypass -File .\infra\set-policy-mode.ps1 block
    powershell -ExecutionPolicy Bypass -File .\infra\set-policy-mode.ps1 redact

  Edits only the POLICY_MODE line and keeps its trailing comment. Writes the file as UTF-8
  without a byte-order mark (Windows PowerShell 5.1's Set-Content -Encoding UTF8 adds one,
  which breaks the first line of .env).
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("monitor", "redact", "block")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$envPath = Join-Path $root ".env"
if (-not (Test-Path $envPath)) { throw ".env not found at $envPath - run this from the project folder." }

$lines = [System.Collections.ArrayList]@(Get-Content $envPath)
$changed = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(\s*POLICY_MODE\s*=\s*)(\S*)(.*)$') {
        $lines[$i] = $Matches[1] + $Mode + $Matches[3]
        $changed = $true
        break
    }
}
if (-not $changed) { [void]$lines.Add("POLICY_MODE=$Mode") }

[System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))

# read it back instead of assuming the write worked
$check = (Get-Content $envPath | Where-Object { $_ -match '^\s*POLICY_MODE\s*=' } | Select-Object -First 1)
if ($check -notmatch "=\s*$Mode(\s|$)") { throw "Wrote the file but POLICY_MODE did not read back as '$Mode'." }
Write-Host "POLICY_MODE is now: $Mode" -ForegroundColor Green

# stop stale bot copies - each one keeps the OLD mode until restarted, and Slack splits events between them
$bots = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like '*bot.py*' })
if ($bots.Count -gt 0) {
    $bots | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Write-Host "Stopped $($bots.Count) running bot process(es)." -ForegroundColor Yellow
} else {
    Write-Host "No bot was running." -ForegroundColor Yellow
}

Write-Host "`nNow start the bot in your venv window:" -ForegroundColor Cyan
Write-Host "    python app\bot.py"
Write-Host "The startup line should say: policy=$Mode"
