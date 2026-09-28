<#
.SYNOPSIS
  One-time Azure setup for the ClaudeAudit_CL pipeline (Logs Ingestion API).

  Creates:
    1. Custom table ClaudeAudit_CL in your Sentinel Log Analytics workspace
    2. A Direct-kind Data Collection Rule (no separate DCE needed) that routes
       the Custom-ClaudeAudit_CL stream into that table
    3. A service principal the bot uses to authenticate
    4. "Monitoring Metrics Publisher" role for that SP, scoped to the DCR only (least privilege)

  Prints the values to paste into your .env at the end - or run
  write-env-from-azure.ps1 afterwards to have them written for you.

.NOTES
  Run from PowerShell on your host with the Azure CLI installed:
    az login
    powershell -ExecutionPolicy Bypass -File .\infra\setup-sentinel-ingestion.ps1
  Edit the variables below first if your workspace names differ.

  Safe to re-run: the table and DCR are create-or-update, and an existing
  service principal is reused rather than duplicated.

  IMPORTANT IMPLEMENTATION NOTE:
  $ErrorActionPreference = "Stop" does NOT trap failures from native commands
  such as az.cmd in Windows PowerShell 5.1. Without an explicit $LASTEXITCODE
  check after every az call, this script will happily print a success banner
  after creating nothing at all. Every az call below goes through Invoke-Az.
#>

$ResourceGroup = "jahnylabs-siem"
$Workspace     = "jahnylabs-sentinel"
$DcrName       = "dcr-claude-audit"
$SpName        = "sp-claude-slack-audit-lab"
$Table         = "ClaudeAudit_CL"
$Stream        = "Custom-ClaudeAudit_CL"

$ErrorActionPreference = "Stop"

function Invoke-Az {
    # Runs az and turns a non-zero exit code into a real terminating error.
    # Deliberately a plain function using $args (no param block): a [Parameter()]
    # attribute makes it an advanced function, which adds PowerShell common
    # parameters and then swallows az flags like -o as -OutVariable/-OutBuffer.
    $AzArgs = $args
    $output = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nFAILED: az $($AzArgs -join ' ')" -ForegroundColor Red
        Write-Host ($output | Out-String) -ForegroundColor Red
        throw "Azure CLI call failed (exit $LASTEXITCODE). Nothing further was attempted."
    }
    return ($output | Out-String)
}

$schemaPath = Join-Path $PSScriptRoot "table_schema.json"
if (-not (Test-Path $schemaPath)) { $schemaPath = ".\infra\table_schema.json" }  # $PSScriptRoot can be empty
if (-not (Test-Path $schemaPath)) { throw "table_schema.json not found. Run this from the project root." }
$columns = Get-Content $schemaPath -Raw | ConvertFrom-Json

# --- preflight --------------------------------------------------------------
$acct = Invoke-Az account show | ConvertFrom-Json
Write-Host "Subscription: $($acct.name)" -ForegroundColor Cyan
Write-Host "Tenant:       $($acct.tenantId)" -ForegroundColor Cyan

# --- workspace facts --------------------------------------------------------
$ws = Invoke-Az monitor log-analytics workspace show -g $ResourceGroup -n $Workspace | ConvertFrom-Json
$location = $ws.location
Write-Host "Workspace:    $($ws.id) ($location)`n" -ForegroundColor Cyan

# --- 1. custom table --------------------------------------------------------
Write-Host "[1/4] Creating table $Table ..." -ForegroundColor Cyan
# The Log Analytics table API and the DCR stream-declaration API disagree on type
# spelling: the table API wants camelCase "dateTime", the DCR API wants lowercase
# "datetime". table_schema.json holds the DCR spelling, so translate here only.
$tableTypeMap = @{ "datetime" = "dateTime"; "bool" = "boolean" }
$colArgs = $columns | ForEach-Object {
    $t = if ($tableTypeMap.ContainsKey($_.type)) { $tableTypeMap[$_.type] } else { $_.type }
    "$($_.name)=$t"
}
$tableArgs = @("monitor", "log-analytics", "workspace", "table", "create",
               "-g", $ResourceGroup, "--workspace-name", $Workspace, "-n", $Table,
               "--retention-time", "30", "--columns") + $colArgs
Invoke-Az @tableArgs | Out-Null
Write-Host "      table ok" -ForegroundColor Green

# --- 2. DCR (kind: Direct -> gets its own logsIngestion endpoint) -----------
Write-Host "[2/4] Creating DCR $DcrName ..." -ForegroundColor Cyan
$sub   = $acct.id
$dcrId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
# Windows PowerShell 5.1 bug: an array that came out of ConvertFrom-Json is serialized by
# ConvertTo-Json as {"value":[...],"Count":N} instead of [...]. ARM rejects that with the
# unhelpful "Resource payload is missing or invalid." Rebuild it as a plain object[].
$dcrColumns = [System.Collections.Generic.List[object]]::new()
foreach ($c in $columns) { $dcrColumns.Add([ordered]@{ name = [string]$c.name; type = [string]$c.type }) }
$dcrColumns = $dcrColumns.ToArray()

$body  = @{
    location   = $location
    kind       = "Direct"
    properties = @{
        streamDeclarations = @{ $Stream = @{ columns = $dcrColumns } }
        destinations       = @{ logAnalytics = @(@{ workspaceResourceId = $ws.id; name = "sentinelWs" }) }
        dataFlows          = @(@{
            streams      = @($Stream)
            destinations = @("sentinelWs")
            transformKql = "source"
            outputStream = $Stream
        })
    }
} | ConvertTo-Json -Depth 10

# Send the DCR straight to ARM with Invoke-RestMethod instead of "az rest --body @file".
# az.cmd is a batch wrapper, so its arguments get re-parsed by cmd.exe, and PowerShell 5.1
# file encodings add their own surprises. Sending the JSON bytes directly removes both.
$debugBody = Join-Path (Resolve-Path (Split-Path $schemaPath -Parent)).Path "dcr-body-last.json"  # absolute: .NET ignores PowerShell's cwd
[System.IO.File]::WriteAllText($debugBody, $body, (New-Object System.Text.UTF8Encoding($false)))

if ($body -match '"Count"\s*:') { throw "DCR JSON still contains a {value,Count} wrapper - see $debugBody" }

$token = (Invoke-Az account get-access-token --resource https://management.azure.com --query accessToken -o tsv).Trim()
$uri   = "https://management.azure.com$($dcrId)?api-version=2023-03-11"
try {
    $dcr = Invoke-RestMethod -Method Put -Uri $uri `
        -Headers @{ Authorization = "Bearer $token" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
} catch {
    Write-Host "`nAzure rejected the DCR. Its reason:" -ForegroundColor Red
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    else { Write-Host $_.Exception.Message -ForegroundColor Red }
    Write-Host "Payload sent is saved at: $debugBody" -ForegroundColor Yellow
    throw "DCR creation failed."
}
if (-not $dcr.properties.endpoints.logsIngestion) { throw "DCR created but has no logsIngestion endpoint - check that kind is 'Direct'." }
Write-Host "      dcr ok - $($dcr.properties.endpoints.logsIngestion)" -ForegroundColor Green

# --- 3. identity that will write to the DCR ---------------------------------
# Preferred: a dedicated service principal. Managed tenants (e.g. a university
# directory) often forbid users from registering applications; in that case fall
# back to granting the role to the signed-in user, and the bot authenticates with
# the Azure CLI session (AzureCliCredential) instead of a client secret.
Write-Host "[3/4] Identity for ingestion ..." -ForegroundColor Cyan
$appId = ""; $secret = ""; $tenant = $acct.tenantId
$assigneeArgs = $null
$mode = "sp"
try {
    $existing = Invoke-Az ad sp list --display-name $SpName | ConvertFrom-Json
    if ($existing -and $existing.Count -gt 0) {
        $appId  = $existing[0].appId
        Write-Host "      service principal exists - resetting its secret" -ForegroundColor Yellow
        $secret = (Invoke-Az ad app credential reset --id $appId | ConvertFrom-Json).password
    } else {
        $sp     = Invoke-Az ad sp create-for-rbac --name $SpName | ConvertFrom-Json
        $appId  = $sp.appId; $secret = $sp.password; $tenant = $sp.tenant
        Write-Host "      service principal created" -ForegroundColor Green
    }
    $assigneeArgs = @("--assignee", $appId)
} catch {
    $mode = "user"
    Write-Host "      cannot create a service principal in this directory (tenant policy)." -ForegroundColor Yellow
    Write-Host "      falling back to your own signed-in account + Azure CLI auth." -ForegroundColor Yellow
    $userId = (Invoke-Az ad signed-in-user show --query id --output tsv).Trim()
    $assigneeArgs = @("--assignee-object-id", $userId, "--assignee-principal-type", "User")
}

# --- 4. least-privilege role on the DCR only --------------------------------
Write-Host "[4/4] Granting Monitoring Metrics Publisher on the DCR only ..." -ForegroundColor Cyan
if ($mode -eq "sp") { Start-Sleep -Seconds 20 }   # let a new SP replicate first
$roleArgs = @("role", "assignment", "create", "--role", "Monitoring Metrics Publisher", "--scope", $dcrId) + $assigneeArgs
try {
    Invoke-Az @roleArgs | Out-Null
} catch {
    if ("$_" -match "RoleAssignmentExists|already exists") { Write-Host "      (already assigned)" -ForegroundColor Yellow } else { throw }
}
Write-Host "      role ok ($mode)" -ForegroundColor Green

if ($mode -eq "user") {
    Write-Host "`n=== Next step ===" -ForegroundColor Green
    Write-Host "Run:  powershell -ExecutionPolicy Bypass -File .\infra\write-env-from-azure.ps1"
    Write-Host "The bot will authenticate with your 'az login' session - no client secret exists or is needed."
    Write-Host "Role assignments can take a few minutes to take effect; early uploads may return 403." -ForegroundColor Yellow
    Read-Host "`nPress Enter to close"
    exit 0
}

Write-Host "`n=== Paste into .env ===" -ForegroundColor Green
Write-Host "LOGS_INGESTION_ENDPOINT=$($dcr.properties.endpoints.logsIngestion)"
Write-Host "DCR_IMMUTABLE_ID=$($dcr.properties.immutableId)"
Write-Host "AZURE_TENANT_ID=$tenant"
Write-Host "AZURE_CLIENT_ID=$appId"
Write-Host "AZURE_CLIENT_SECRET=$secret"
Write-Host "`nThe secret is shown ONCE. Store it in .env (git-ignored) and nowhere else." -ForegroundColor Yellow
Write-Host "Or just run:  powershell -ExecutionPolicy Bypass -File .\infra\write-env-from-azure.ps1" -ForegroundColor Yellow
Write-Host "which writes all five into .env for you - nothing to copy by hand." -ForegroundColor Yellow
Read-Host "`nPress Enter to close"
