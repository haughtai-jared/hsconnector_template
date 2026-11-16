<#
.SYNOPSIS
    Deploy this MCP server to Google Cloud Run with a placeholder MCP token.

.DESCRIPTION
    Builds the image in the cloud with `gcloud run deploy --source .`, so Docker
    does not need to be installed locally.

    MCP_AUTH_TOKEN is always populated on the result. There is no token to deploy
    yet, so a first deploy writes the placeholder value "replace-with-issued-token"
    rather than nothing at all: a revision that omits the variable makes its state
    ambiguous, and the later `--update-env-vars` step would have to guess whether a
    missing value means "never deployed" or "cleared". The placeholder is neither a
    credential nor an opening: app/main.py treats it exactly like empty and answers
    503 to every request. A service that already carries a real token keeps it.

    That is step 1 of the flow:

      1. deploy    this script, with the placeholder token.
      2. register  the deployed /mcp URL with the apex auth server, which issues
                   the MCP token for it.
      3. set it    ./set-token.ps1 -ProjectId <project> -AuthToken <token>
      4. approve   have the auth server GET <url>/health carrying that token.
                   A 200 approves the server.

    Step 3 onwards is set-token.ps1; this script only prints the next step.

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

# Must match PLACEHOLDER_TOKEN in app/main.py and the ENV default in the
# Dockerfile. The app refuses to authorize it, so it is safe in plain sight.
$PlaceholderToken = "replace-with-issued-token"

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT make the endpoint usable. Every request still has to
# carry the MCP token set in step 3, which is the only thing standing in front of
# /mcp. See the security note in README.md.
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
# that terminates the script mid-deploy. Relax the preference for these calls and
# decide by exit code instead.
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$deployExit = 1
$url = ""
$envVars = ""
$existingEnv = ""
try {
    # Read the service that is already there, if any. A failed describe means "no
    # such service yet", which is the normal first run and not an error here.
    $existingEnv = (gcloud run services describe $Service `
        --project $ProjectId --region $Region `
        --format "value(spec.template.spec.containers[0].env)" 2>$null) -join "`n"

    if (-not ("$existingEnv" -match "MCP_AUTH_TOKEN")) {
        # Nothing to preserve, so declare it now. --update-env-vars merges rather
        # than replaces, so any other variable on the service is left alone.
        $deployArgs += @("--update-env-vars", "MCP_AUTH_TOKEN=$PlaceholderToken")
        Write-Host "MCP_AUTH_TOKEN: deploying with the placeholder value." -ForegroundColor Gray
    } else {
        Write-Host "MCP_AUTH_TOKEN: already on the service; leaving it untouched." -ForegroundColor Gray
    }

    & gcloud @deployArgs
    $deployExit = $LASTEXITCODE

    if ($deployExit -eq 0) {
        $url = gcloud run services describe $Service `
            --project $ProjectId --region $Region --format "value(status.url)"
        # Read what actually landed on the new revision instead of assuming the
        # flags took effect.
        $envVars = (gcloud run services describe $Service `
            --project $ProjectId --region $Region `
            --format "value(spec.template.spec.containers[0].env)") -join "`n"
    }
} finally {
    $ErrorActionPreference = $previousPreference
}
if ($deployExit -ne 0) { throw "gcloud run deploy failed with exit code $deployExit" }

$url = "$url".Trim()
if ("$envVars" -notmatch "MCP_AUTH_TOKEN") {
    throw "The revision that was just deployed does not declare MCP_AUTH_TOKEN. Set it with: ./set-token.ps1 -ProjectId $ProjectId -AuthToken <token>"
}

Write-Host ""
Write-Host "Deployed: $url/mcp" -ForegroundColor Green
Write-Host "Health:   $url/health" -ForegroundColor Green

if ("$envVars" -match [regex]::Escape($PlaceholderToken)) {
    Write-Host "Token:    placeholder - every request answers 503 until step 2 below." -ForegroundColor Yellow
} else {
    Write-Host "Token:    already set on this revision - authorized traffic works." -ForegroundColor Green
    Write-Host ""
    Write-Host "Confirm it is the token the auth server holds with step 2 below." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Register $url/mcp with the auth server; it issues the MCP token."
if ("$envVars" -match [regex]::Escape($PlaceholderToken)) {
    Write-Host "  2. ./set-token.ps1 -ProjectId $ProjectId -Service $Service -Region $Region -AuthToken <token>"
    Write-Host "  3. Have the auth server GET $url/health with that token."
    Write-Host "     A 200 approves this server; a 401 means it holds a different token."
} else {
    Write-Host "  2. Have the auth server GET $url/health with that token."
    Write-Host "     A 200 approves this server; a 401 means it holds a different token."
}