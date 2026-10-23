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

.EXAMPLE
    ./deploy.ps1 -ProjectId my-project -AuthToken $env:MCP_AUTH_TOKEN
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [string]$Service = "hsconnector-template",
    [string]$Region = "us-central1",

    # The shared key every request must carry as `Authorization: Bearer <key>`.
    # Defaults to $env:MCP_AUTH_TOKEN so the value does not have to appear on the
    # command line, where it would land in your shell history.
    #
    # Leave it empty and the service is deployed with the check OFF: anyone with
    # the URL can call it. Fine for a clock; not fine for anything else.
    [string]$AuthToken = $env:MCP_AUTH_TOKEN
)

$ErrorActionPreference = "Stop"

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT make the endpoint private — the service checks its
# own shared key instead (MCP_AUTH_TOKEN), which is the only thing standing in
# front of /mcp. See the security note in README.md.
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

# Written as a plain environment variable so it is visible in the Cloud Run
# console and changeable with `gcloud run services update --update-env-vars`.
# A secret that must stay unreadable belongs in Secret Manager and is mounted
# with --set-secrets instead.
if ($AuthToken) {
    $deployArgs += @("--set-env-vars", "MCP_AUTH_TOKEN=$AuthToken")
}

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
if ($AuthToken) {
    Write-Host "Auth:     ON — clients must send 'Authorization: Bearer <key>'" -ForegroundColor Green
} else {
    Write-Host "Auth:     OFF — anyone with the URL can call this service" -ForegroundColor Yellow
}
