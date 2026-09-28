<#
.SYNOPSIS
  Reports what the ClaudeAudit_CL pipeline actually has in Azure right now.

  setup-sentinel-ingestion.ps1 can report success while silently creating nothing,
  because $ErrorActionPreference does not trap native (az) command failures in
  Windows PowerShell 5.1. Run this to see real state rather than reported state.

    powershell -ExecutionPolicy Bypass -File .\infra\check-azure-setup.ps1
#>

$ResourceGroup = "jahnylabs-siem"
$Workspace     = "jahnylabs-sentinel"
$DcrName       = "dcr-claude-audit"
$SpName        = "sp-claude-slack-audit-lab"
$Table         = "ClaudeAudit_CL"

function Status($label, $ok, $detail) {
    $mark  = if ($ok) { "[ OK ]" } else { "[MISSING]" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("{0,-10} {1,-24} {2}" -f $mark, $label, $detail) -ForegroundColor $color
}

Write-Host "`n=== Actual Azure state ===`n" -ForegroundColor Cyan

$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) { Write-Host "Not logged in. Run: az login" -ForegroundColor Red; Read-Host "Press Enter"; exit 1 }
Write-Host ("Subscription : {0}" -f $acct.name)
Write-Host ("Tenant       : {0}`n" -f $acct.tenantId)

# resource group
$rg = az group show -n $ResourceGroup 2>$null | ConvertFrom-Json
Status "ResourceGroup" ([bool]$rg) $ResourceGroup

# workspace
$ws = az monitor log-analytics workspace show -g $ResourceGroup -n $Workspace 2>$null | ConvertFrom-Json
Status "Workspace" ([bool]$ws) $Workspace

# table
$tbl = $null
if ($ws) { $tbl = az monitor log-analytics workspace table show -g $ResourceGroup --workspace-name $Workspace -n $Table 2>$null | ConvertFrom-Json }
Status "Table" ([bool]$tbl) $Table

# every DCR in the RG, so a wrong-name DCR still shows up
Write-Host "`nData Collection Rules in ${ResourceGroup}:" -ForegroundColor Cyan
$dcrs = az monitor data-collection rule list -g $ResourceGroup 2>$null | ConvertFrom-Json
if ($dcrs -and $dcrs.Count -gt 0) {
    foreach ($d in $dcrs) { Write-Host ("   - {0}   (kind: {1})" -f $d.name, $(if ($d.kind) { $d.kind } else { "<none>" })) }
} else {
    Write-Host "   (none)" -ForegroundColor Red
}
$dcrOk = $dcrs | Where-Object { $_.name -eq $DcrName }
Status "DCR" ([bool]$dcrOk) $DcrName

# service principal
$sp = az ad sp list --display-name $SpName 2>$null | ConvertFrom-Json
Status "ServicePrincipal" ([bool]($sp -and $sp.Count -gt 0)) $SpName

Write-Host "`n=== What to do ===" -ForegroundColor Cyan
if (-not $tbl -or -not $dcrOk) {
    Write-Host "Re-run setup-sentinel-ingestion.ps1. It is now safe to re-run:" -ForegroundColor Yellow
    Write-Host "  - table and DCR creation are idempotent (create-or-update)"
    Write-Host "  - the service principal is only created if one does not already exist"
} else {
    Write-Host "Everything exists. Run write-env-from-azure.ps1 to populate .env." -ForegroundColor Green
}
Read-Host "`nPress Enter to close"
