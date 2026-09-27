<#
.SYNOPSIS
  One-time Azure setup for the ClaudeAudit_CL pipeline (Logs Ingestion API).

  Creates:
    1. Custom table ClaudeAudit_CL in your Sentinel Log Analytics workspace
    2. A Direct-kind Data Collection Rule (no separate DCE needed) that routes
       the Custom-ClaudeAudit_CL stream into that table
    3. A service principal the bot uses to authenticate
    4. "Monitoring Metrics Publisher" role for that SP, scoped to the DCR only (least privilege)

  Prints the values to paste into your .env at the end.

.NOTES
  Run from PowerShell on your host with the Azure CLI installed:
    az login --tenant JahnyLabs.onmicrosoft.com
    powershell -ExecutionPolicy Bypass -File .\infra\setup-sentinel-ingestion.ps1
  Edit the three variables below first if your workspace names differ.
#>

$ResourceGroup = "jahnylabs-siem"
$Workspace     = "jahnylabs-sentinel"
$DcrName       = "dcr-claude-audit"
$SpName        = "sp-claude-slack-audit-lab"
$Table         = "ClaudeAudit_CL"
$Stream        = "Custom-ClaudeAudit_CL"

$ErrorActionPreference = "Stop"
$schemaPath = Join-Path $PSScriptRoot "table_schema.json"
if (-not (Test-Path $schemaPath)) { $schemaPath = ".\infra\table_schema.json" }  # $PSScriptRoot can be empty
$columns = Get-Content $schemaPath -Raw | ConvertFrom-Json

# --- workspace facts -------------------------------------------------------
$ws = az monitor log-analytics workspace show -g $ResourceGroup -n $Workspace | ConvertFrom-Json
$location = $ws.location
Write-Host "Workspace: $($ws.id) ($location)" -ForegroundColor Cyan

# --- 1. custom table ---------------------------------------------------------
$colArgs = $columns | ForEach-Object { "$($_.name)=$($_.type)" }
Write-Host "Creating table $Table ..." -ForegroundColor Cyan
az monitor log-analytics workspace table create `
    -g $ResourceGroup --workspace-name $Workspace -n $Table `
    --retention-time 30 --columns $colArgs | Out-Null

# --- 2. DCR (kind: Direct -> gets its own logsIngestion endpoint) -----------
$sub = (az account show | ConvertFrom-Json).id
$dcrId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
$body = @{
    location   = $location
    kind       = "Direct"
    properties = @{
        streamDeclarations = @{ $Stream = @{ columns = $columns } }
        destinations       = @{ logAnalytics = @(@{ workspaceResourceId = $ws.id; name = "sentinelWs" }) }
        dataFlows          = @(@{
            streams      = @($Stream)
            destinations = @("sentinelWs")
            transformKql = "source"
            outputStream = $Stream
        })
    }
} | ConvertTo-Json -Depth 10
$bodyFile = New-TemporaryFile
Set-Content -Path $bodyFile -Value $body -Encoding utf8

Write-Host "Creating DCR $DcrName ..." -ForegroundColor Cyan
$dcr = az rest --method put `
    --url "https://management.azure.com$($dcrId)?api-version=2023-03-11" `
    --body "@$bodyFile" | ConvertFrom-Json
Remove-Item $bodyFile

# --- 3. service principal ----------------------------------------------------
Write-Host "Creating service principal $SpName ..." -ForegroundColor Cyan
$sp = az ad sp create-for-rbac --name $SpName | ConvertFrom-Json

# --- 4. least-privilege role on the DCR only --------------------------------
Write-Host "Granting Monitoring Metrics Publisher on the DCR (can take ~1 min to propagate) ..." -ForegroundColor Cyan
Start-Sleep -Seconds 20
az role assignment create --assignee $sp.appId --role "Monitoring Metrics Publisher" --scope $dcrId | Out-Null

Write-Host "`n=== Paste into .env ===" -ForegroundColor Green
Write-Host "LOGS_INGESTION_ENDPOINT=$($dcr.properties.endpoints.logsIngestion)"
Write-Host "DCR_IMMUTABLE_ID=$($dcr.properties.immutableId)"
Write-Host "AZURE_TENANT_ID=$($sp.tenant)"
Write-Host "AZURE_CLIENT_ID=$($sp.appId)"
Write-Host "AZURE_CLIENT_SECRET=$($sp.password)"
Write-Host "`nThe secret is shown ONCE. Store it in .env (git-ignored) and nowhere else." -ForegroundColor Yellow
Read-Host "Press Enter to close"
