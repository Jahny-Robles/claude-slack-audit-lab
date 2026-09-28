<#
.SYNOPSIS
  Reads the Sentinel ingestion settings back out of Azure and writes them straight into .env.

  Use this when the values printed by setup-sentinel-ingestion.ps1 were lost, or when
  copying them out of a console window went wrong. Nothing has to be copied by hand.

  The client secret is only ever displayed once at creation and cannot be retrieved
  afterwards, so this RESETS it. The old secret stops working; nothing else changes.

.NOTES
  az login   # must already be done, into the subscription holding the workspace
  powershell -ExecutionPolicy Bypass -File .\infra\write-env-from-azure.ps1
#>

$ResourceGroup = "jahnylabs-siem"
$DcrName       = "dcr-claude-audit"
$SpName        = "sp-claude-slack-audit-lab"

$ErrorActionPreference = "Stop"

# $PSScriptRoot is empty when a script is piped or run in some hosts - fall back to cwd
$root = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$envPath = Join-Path $root ".env"
if (-not (Test-Path $envPath)) { throw ".env not found at $envPath - run this from the project folder." }

Write-Host "Reading DCR $DcrName ..." -ForegroundColor Cyan
$sub = (az account show | ConvertFrom-Json).id
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName" + "?api-version=2023-03-11"
$dcr = az rest --method get --url $url | ConvertFrom-Json

$endpoint    = $dcr.properties.endpoints.logsIngestion
$immutableId = $dcr.properties.immutableId
if (-not $endpoint)    { throw "DCR has no logsIngestion endpoint - is its kind 'Direct'?" }
if (-not $immutableId) { throw "DCR has no immutableId." }

Write-Host "Looking for service principal $SpName ..." -ForegroundColor Cyan
$tenantId = (az account show | ConvertFrom-Json).tenantId
$appId = ""
try { $appId = az ad sp list --display-name $SpName --query "[0].appId" -o tsv } catch { $appId = "" }
$secret = ""
if ($appId) {
    Write-Host "Resetting client secret (the old one stops working now) ..." -ForegroundColor Yellow
    $secret = az ad app credential reset --id $appId --query password -o tsv
    if (-not $secret) { throw "Credential reset returned nothing - check you can manage this app registration." }
} else {
    $appId = ""
    Write-Host "No service principal - the bot will use your 'az login' session instead." -ForegroundColor Yellow
}

# ---- rewrite the five lines in place, leaving everything else untouched ----
$map = [ordered]@{
    LOGS_INGESTION_ENDPOINT = $endpoint
    DCR_IMMUTABLE_ID        = $immutableId
    AZURE_TENANT_ID         = $tenantId
    AZURE_CLIENT_ID         = $appId
    AZURE_CLIENT_SECRET     = $secret
}

$lines = [System.Collections.ArrayList]@(Get-Content $envPath)
foreach ($key in $map.Keys) {
    $value   = $map[$key]
    $matched = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$key\s*=") { $lines[$i] = "$key=$value"; $matched = $true; break }
    }
    if (-not $matched) { [void]$lines.Add("$key=$value") }
}
# no BOM: PowerShell 5.1 "-Encoding UTF8" would prepend one to .env
[System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`nWrote 5 values into $envPath" -ForegroundColor Green
Write-Host "  LOGS_INGESTION_ENDPOINT = $endpoint"
Write-Host "  DCR_IMMUTABLE_ID        = $immutableId"
Write-Host "  AZURE_TENANT_ID         = $tenantId"
Write-Host "  AZURE_CLIENT_ID         = $appId"
Write-Host ("  AZURE_CLIENT_SECRET     = " + $(if ($secret) { "(written, not displayed)" } else { "(empty - using az login)" }))
Write-Host "`nNothing to copy - .env is already updated." -ForegroundColor Green
Read-Host "Press Enter to close"
