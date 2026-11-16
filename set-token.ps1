<#
.SYNOPSIS
    Set the MCP token that the apex auth server issued for a deployed service.

.DESCRIPTION
    Step 3 of the flow. The service was deployed with no token (deploy.ps1), so it
    answers 503 to everything; its URL was registered with the auth server, which
    issued the token. This writes that token into MCP_AUTH_TOKEN, releases a new
    revision, and then checks the result the same way the auth server will:

      * GET /health WITH the token must return 200.
      * GET /health WITHOUT it must return 401, which proves the gate is on.

    Nothing is sent to the auth server from here. Step 4 is the auth server's own
    GET: a 200 approves the deployment, and a 401 means it holds a different token
    than the one set here.

.EXAMPLE
    ./set-token.ps1 -ProjectId my-project -AuthToken $env:MCP_TOKEN

.EXAMPLE
    $env:MCP_AUTH_TOKEN = "mcp_issued_by_the_auth_server"
    ./set-token.ps1 -ProjectId my-project

.EXAMPLE
    ./set-token.ps1 -ProjectId my-project -SkipVerify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [string]$Service = "hsconnector-template",
    [string]$Region = "us-central1",

    # Defaults to $env:MCP_AUTH_TOKEN so the token does not appear on the command
    # line, where it would land in your shell history.
    [string]$AuthToken = $env:MCP_AUTH_TOKEN,

    # Write the variable and stop, without the two GET /health checks.
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

if (-not $AuthToken) {
    throw "No MCP token given. Pass -AuthToken <token>, or set the MCP_AUTH_TOKEN environment variable first."
}

# The value deploy.ps1 writes when it has no token. It is public, so writing it
# here would deploy a revision that still refuses everything; that is a mistake
# worth naming rather than a value worth sending.
if ($AuthToken -eq "replace-with-issued-token") {
    throw "That is the deploy placeholder, not the issued token. Pass the token the auth server issued for this URL."
}

# --update-env-vars parses a comma-separated KEY=VALUE list. A token containing a
# comma or whitespace cannot survive that, and a quote would end up inside the
# value; better to refuse than to deploy a token that silently differs.
if ($AuthToken -match '[,\s"]') {
    throw "The token contains a comma, a quote, or whitespace. Check what you copied; gcloud cannot carry those in --update-env-vars."
}

# --update-env-vars keeps every other variable on the service and replaces only
# MCP_AUTH_TOKEN, so rotating the token does not touch anything else.
#
# gcloud writes its progress to stderr. Windows PowerShell turns stderr from a
# native command into an error record, and with ErrorActionPreference = "Stop"
# that terminates the script mid-update. Relax the preference for these calls and
# decide by exit code instead.
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$updateExit = 1
$url = ""
try {
    & gcloud run services update $Service `
        --project $ProjectId `
        --region $Region `
        --update-env-vars "MCP_AUTH_TOKEN=$AuthToken" `
        --quiet
    $updateExit = $LASTEXITCODE

    if ($updateExit -eq 0) {
        $url = gcloud run services describe $Service `
            --project $ProjectId --region $Region --format "value(status.url)"
    }
} finally {
    $ErrorActionPreference = $previousPreference
}
if ($updateExit -ne 0) { throw "gcloud run services update failed with exit code $updateExit" }

$url = "$url".Trim()
if (-not $url) { throw "Could not read the URL of $Service." }

Write-Host ""
Write-Host "Service: $url" -ForegroundColor Green

if ($SkipVerify) {
    Write-Host "Token written. Now have the auth server GET $url/health with it." -ForegroundColor Cyan
    exit 0
}

# Windows PowerShell 5.1 negotiates TLS 1.0 by default, which *.run.app refuses.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # Newer PowerShell ignores this; nothing to do.
}

function Get-Health([string]$HealthUrl, [hashtable]$RequestHeaders) {
    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -Headers $RequestHeaders `
            -UseBasicParsing -TimeoutSec 30
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $response.Content }
    } catch {
        $response = $_.Exception.Response
        if (-not $response) { throw }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = "" }
    }
}

# A new revision takes a few seconds to serve, and until then Cloud Run keeps
# routing to the previous one, which has no token and answers 503. Retry briefly
# instead of reporting a failure that only means "not rolled out yet".
$authorized = [pscustomobject]@{ Status = 0; Body = "" }
for ($attempt = 1; $attempt -le 12; $attempt++) {
    $authorized = Get-Health "$url/health" @{ Authorization = "Bearer $AuthToken" }
    if ($authorized.Status -eq 200) { break }
    if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
}

$anonymous = Get-Health "$url/health" @{}

Write-Host "GET /health with the token:    $($authorized.Status)"
Write-Host "GET /health without the token: $($anonymous.Status)"

if ($authorized.Status -ne 200) {
    throw "GET /health with the token returned $($authorized.Status), not 200. The revision may not be serving yet; check 'gcloud run services logs read $Service --region $Region --limit 20'."
}
Write-Host "This deployment accepts the token." -ForegroundColor Green

if ($anonymous.Status -ne 401) {
    Write-Warning "A request with no token returned $($anonymous.Status) instead of 401. Expected 401 once a token is set; check which revision is serving."
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  Have the auth server GET $url/health with this token."
Write-Host "  A 200 approves the server. A 401 means the auth server holds a"
Write-Host "  different token: re-run this script with the token it issued."