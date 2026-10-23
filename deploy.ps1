<#
.SYNOPSIS
    Deploy this MCP server to Google Cloud Run.

.DESCRIPTION
    Builds the image in the cloud with `gcloud run deploy --source .`, so Docker
    does not need to be installed locally.

.EXAMPLE
    ./deploy.ps1 -ProjectId my-project

.EXAMPLE
    ./deploy.ps1 -ProjectId my-project -Service my-mcp -Region europe-west1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [string]$Service = "hsconnector-template",
    [string]$Region = "us-central1"
)

$ErrorActionPreference = "Stop"

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT make the endpoint private — see the security note in
# README.md, and add your own auth (for example a shared header) before putting
# anything sensitive behind it.
$deployArgs = @(
    "run", "deploy", $Service,
    "--project", $ProjectId,
    "--region", $Region,
    "--source", ".",
    "--allow-unauthenticated",
    "--port", "8080",
    "--memory", "512Mi",
    "--cpu", "1",
    "--timeout", "300",
    "--min-instances", "0",
    "--max-instances", "10",
    "--quiet"
)

# gcloud writes its progress to stderr. Windows PowerShell turns stderr from a
# native command into an error record, and with ErrorActionPreference = "Stop"
# that terminates the script mid-deploy. Relax the preference for this one call
# and decide by exit code instead.
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & gcloud @deployArgs
    $deployExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousPreference
}
if ($deployExit -ne 0) { throw "gcloud run deploy failed with exit code $deployExit" }

$url = gcloud run services describe $Service `
    --project $ProjectId --region $Region --format "value(status.url)"

Write-Host ""
Write-Host "Deployed: $url/mcp" -ForegroundColor Green
Write-Host "Health:   $url/health" -ForegroundColor Green
