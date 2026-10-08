<#
.SYNOPSIS
    Local Blue-Green deployment of demo-app with Docker + nginx.

.DESCRIPTION
    deploy   : build the image, start it on the idle colour, wait for its
               health check, switch nginx to it, verify through the proxy.
               The previous colour stays running as a standby for rollback.
               If anything fails, traffic stays on (or returns to) the old colour.
    rollback : switch traffic back to the standby colour (instant, no rebuild).
    status   : show which colour is live and the state of every container.
    destroy  : remove both colours, the proxy, the network and local state.

.EXAMPLE
    .\deploy.ps1 -Version v1
    .\deploy.ps1 -Version v2
    .\deploy.ps1 -Action rollback
    .\deploy.ps1 -Action status
    .\deploy.ps1 -Version v3 -RemoveOld
#>
[CmdletBinding()]
param(
    [ValidateSet("deploy", "rollback", "status", "destroy")]
    [string]$Action = "deploy",

    [string]$Version = "v1",

    [int]$Port = 8080,

    # Remove the previous colour after a successful switch (no rollback target).
    [switch]$RemoveOld
)

$ErrorActionPreference = "Stop"

$Network   = "bgnet"
$ImageName = "demo-app"
$Proxy     = "nginx-proxy"
$Colours   = @("blue", "green")
$NginxConf = Join-Path $PSScriptRoot "nginx\default.conf"
$StateDir  = Join-Path $PSScriptRoot ".bluegreen"
$StateFile = Join-Path $StateDir "active.conf"
$ProxyUrl  = "http://localhost:$Port"

# --------------------------------------------------
# Helpers
# --------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Banner([string[]]$Lines, [string]$Colour = "Green") {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor $Colour
    foreach ($l in $Lines) { Write-Host " $l" -ForegroundColor $Colour }
    Write-Host "=========================================" -ForegroundColor $Colour
    Write-Host ""
}

# Runs docker and captures output + exit code without letting stderr turn
# into a terminating error (Windows PowerShell 5.1 does that under "Stop").
function Invoke-Docker {
    $ErrorActionPreference = "Continue"
    $out = & docker @args 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{
        Code = $LASTEXITCODE
        Out  = (($out | Out-String).Trim())
    }
}

function Get-Other([string]$Colour) {
    if ($Colour -eq "blue") { "green" } else { "blue" }
}

function Test-ContainerExists([string]$Name) {
    (Invoke-Docker container inspect $Name).Code -eq 0
}

function Test-ContainerRunning([string]$Name) {
    $r = Invoke-Docker container inspect -f "{{.State.Running}}" $Name
    ($r.Code -eq 0) -and ($r.Out -eq "true")
}

function Get-ContainerHealth([string]$Name) {
    $r = Invoke-Docker container inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $Name
    if ($r.Code -ne 0) { return "missing" }
    $r.Out
}

function Get-ContainerVersion([string]$Name) {
    $r = Invoke-Docker container inspect -f "{{range .Config.Env}}{{println .}}{{end}}" $Name
    if ($r.Code -ne 0) { return "" }
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -like "APP_VERSION=*") { return $line.Substring(12) }
    }
    ""
}

function Remove-Container([string]$Name) {
    if (Test-ContainerExists $Name) {
        $null = Invoke-Docker rm -f $Name
    }
}

function Wait-Healthy([string]$Name, [int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ContainerRunning $Name)) { return $false }
        $health = Get-ContainerHealth $Name
        if ($health -eq "healthy") { return $true }
        if ($health -eq "unhealthy") { return $false }
        Write-Host "    $Name is '$health', waiting..."
        Start-Sleep -Seconds 2
    }
    $false
}

# --------------------------------------------------
# State: which colour nginx is routing to
# --------------------------------------------------

function Get-ActiveColour {
    if (Test-Path $StateFile) {
        $text = [IO.File]::ReadAllText($StateFile)
        if ($text -match "app-(blue|green)") { return $Matches[1] }
    }

    # No state yet (first run, or migrating from the old script): if exactly
    # one colour is running, treat it as live so we deploy to the other one.
    $running = @($Colours | Where-Object { Test-ContainerRunning "app-$_" })
    if ($running.Count -eq 1) { return $running[0] }
    $null
}

function Set-ActiveColour([string]$Colour) {
    if (-not (Test-Path $StateDir)) {
        $null = New-Item -ItemType Directory -Path $StateDir
    }
    # UTF-8 without BOM - nginx rejects a BOM.
    [IO.File]::WriteAllText($StateFile, "set `$app_upstream app-$Colour;`n")
}

# --------------------------------------------------
# Infrastructure
# --------------------------------------------------

function Initialize-Network {
    if ((Invoke-Docker network inspect $Network).Code -ne 0) {
        Write-Host "    Creating Docker network: $Network"
        $r = Invoke-Docker network create $Network
        if ($r.Code -ne 0) { throw "Could not create network $Network`n$($r.Out)" }
    }
}

function Initialize-Proxy {
    if (Test-ContainerExists $Proxy) {
        # Recreate a proxy from the old setup (single-file mount, no state dir).
        $mounts = (Invoke-Docker container inspect -f "{{range .Mounts}}{{.Destination}} {{end}}" $Proxy).Out
        if ($mounts -notmatch "/etc/nginx/bluegreen") {
            Write-Host "    Replacing old-style $Proxy container"
            Remove-Container $Proxy
        }
        elseif (-not (Test-ContainerRunning $Proxy)) {
            Write-Host "    Starting stopped $Proxy"
            $r = Invoke-Docker start $Proxy
            if ($r.Code -ne 0) { throw "Could not start $Proxy`n$($r.Out)" }
            return
        }
        else {
            return
        }
    }

    Write-Host "    Starting $Proxy on port $Port"
    $r = Invoke-Docker run -d `
        --name $Proxy `
        --network $Network `
        --restart unless-stopped `
        -p "${Port}:80" `
        -v "${NginxConf}:/etc/nginx/conf.d/default.conf:ro" `
        -v "${StateDir}:/etc/nginx/bluegreen:ro" `
        nginx:alpine
    if ($r.Code -ne 0) { throw "Could not start $Proxy`n$($r.Out)" }

    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ContainerRunning $Proxy) { return }
    }
    $logs = (Invoke-Docker logs --tail 20 $Proxy).Out
    throw "$Proxy did not start:`n$logs"
}

# Returns the colour nginx actually served the request from, or $null.
function Get-ServedColour {
    try {
        $resp = Invoke-WebRequest -Uri "$ProxyUrl/" -UseBasicParsing -TimeoutSec 5
        $servedBy = "$($resp.Headers['X-Served-By'])"
        if ($servedBy -match "app-(blue|green)") { return $Matches[1] }
    }
    catch { }
    $null
}

function Invoke-NginxReload {
    $test = Invoke-Docker exec $Proxy nginx -t
    if ($test.Code -ne 0) { throw "nginx config test failed:`n$($test.Out)" }
    $reload = Invoke-Docker exec $Proxy nginx -s reload
    if ($reload.Code -ne 0) { throw "nginx reload failed:`n$($reload.Out)" }
}

# Points nginx at $To and proves it through the proxy. On failure, puts
# traffic back on $From (if any) and throws.
function Switch-Traffic([string]$To, [string]$From) {
    Set-ActiveColour $To

    try {
        Initialize-Proxy

        # Make sure the container sees the new state file (bind mount on
        # Docker Desktop can lag a moment) before reloading.
        $synced = $false
        for ($i = 0; $i -lt 20; $i++) {
            $r = Invoke-Docker exec $Proxy cat /etc/nginx/bluegreen/active.conf
            if ($r.Code -eq 0 -and $r.Out -match "app-$To;") { $synced = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $synced) { throw "$Proxy did not pick up the new active colour" }

        Invoke-NginxReload

        $served = $null
        for ($i = 0; $i -lt 10; $i++) {
            $served = Get-ServedColour
            if ($served -eq $To) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($served -ne $To) {
            throw "Proxy check failed: expected app-$To, got '$served'"
        }
    }
    catch {
        $err = $_
        if ($From) {
            Write-Host "    Switch failed - restoring traffic to $From" -ForegroundColor Yellow
            Set-ActiveColour $From
            try { Invoke-NginxReload } catch { }
        }
        throw $err
    }
}

# --------------------------------------------------
# Actions
# --------------------------------------------------

function Show-Status {
    $active = Get-ActiveColour
    Write-Host ""
    Write-Host "Live colour : $(if ($active) { $active } else { '(none)' })"
    foreach ($c in $Colours) {
        $name = "app-$c"
        if (Test-ContainerExists $name) {
            $state = if (Test-ContainerRunning $name) { "running" } else { "stopped" }
            $role = if ($c -eq $active) { "LIVE" } else { "standby" }
            Write-Host ("  {0,-10} {1,-8} {2,-8} health={3,-10} version={4}" -f `
                $name, $role, $state, (Get-ContainerHealth $name), (Get-ContainerVersion $name))
        }
        else {
            Write-Host ("  {0,-10} (not deployed)" -f $name)
        }
    }
    $proxyState = if (Test-ContainerRunning $Proxy) { "running on $ProxyUrl" } else { "not running" }
    Write-Host "  $Proxy  $proxyState"
    if (Test-ContainerRunning $Proxy) {
        try {
            $body = (Invoke-WebRequest -Uri "$ProxyUrl/" -UseBasicParsing -TimeoutSec 5).Content
            Write-Host "  GET $ProxyUrl/ -> $("$body".Trim())"
        }
        catch {
            Write-Host "  GET $ProxyUrl/ -> FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

function Invoke-Deploy {
    Write-Banner @("Blue-Green Deployment", "Version: $Version") "Cyan"

    Write-Step "Preparing network"
    Initialize-Network

    $active = Get-ActiveColour
    if ($active -and -not (Test-ContainerRunning "app-$active")) {
        Write-Host "    Live colour $active is not running - it will be replaced." -ForegroundColor Yellow
    }
    $target = if ($active) { Get-Other $active } else { "blue" }
    $targetName = "app-$target"

    Write-Host "    Live colour   : $(if ($active) { $active } else { '(none)' })"
    Write-Host "    Deploying to  : $target"

    Write-Step "Building image ${ImageName}:$Version"
    & docker build -t "${ImageName}:$Version" $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }

    Write-Step "Starting $targetName"
    Remove-Container $targetName
    $r = Invoke-Docker run -d `
        --name $targetName `
        --network $Network `
        --restart unless-stopped `
        -e "APP_VERSION=$Version" `
        -e "APP_COLOR=$target" `
        "${ImageName}:$Version"
    if ($r.Code -ne 0) { throw "Could not start $targetName`n$($r.Out)" }

    Write-Step "Waiting for $targetName to become healthy"
    if (-not (Wait-Healthy $targetName)) {
        $logs = (Invoke-Docker logs --tail 30 $targetName).Out
        Remove-Container $targetName
        Write-Host $logs
        Write-Banner @("HEALTH CHECK FAILED", "$targetName removed.",
            "Traffic unchanged: $(if ($active) { $active } else { 'nothing live' })") "Red"
        exit 1
    }
    Write-Host "    $targetName is healthy."

    Write-Step "Switching traffic to $target"
    try {
        Switch-Traffic -To $target -From $active
    }
    catch {
        Write-Host $_ -ForegroundColor Red
        Write-Banner @("TRAFFIC SWITCH FAILED",
            "Traffic restored to: $(if ($active) { $active } else { 'nothing live' })",
            "$targetName left running for debugging.") "Red"
        exit 1
    }
    Write-Host "    Traffic switched: $(if ($active) { $active } else { '(none)' }) -> $target"

    if ($active -and $RemoveOld) {
        Write-Step "Removing old colour app-$active"
        Remove-Container "app-$active"
    }

    Write-Banner @("DEPLOYMENT SUCCESSFUL",
        "Live colour : $target",
        "Version     : $Version",
        "URL         : $ProxyUrl",
        $(if ($active -and -not $RemoveOld) { "Rollback    : .\deploy.ps1 -Action rollback" } else { "Rollback    : (no standby)" }))
    Show-Status
}

function Invoke-Rollback {
    $active = Get-ActiveColour
    if (-not $active) { throw "Nothing is live - deploy first." }

    $standby = Get-Other $active
    $standbyName = "app-$standby"

    Write-Banner @("Blue-Green Rollback", "$active -> $standby") "Yellow"

    if (-not (Test-ContainerRunning $standbyName)) {
        throw "No standby to roll back to: $standbyName is not running."
    }

    Write-Step "Checking $standbyName health"
    if (-not (Wait-Healthy $standbyName 20)) {
        throw "$standbyName is not healthy - rollback aborted, traffic stays on $active."
    }

    Write-Step "Switching traffic to $standby"
    Switch-Traffic -To $standby -From $active

    Write-Banner @("ROLLBACK SUCCESSFUL",
        "Live colour : $standby (version $(Get-ContainerVersion $standbyName))",
        "Standby     : $active (run rollback again to switch back)")
    Show-Status
}

function Invoke-Destroy {
    Write-Step "Removing Blue-Green environment"
    foreach ($c in $Colours) { Remove-Container "app-$c" }
    Remove-Container $Proxy
    $null = Invoke-Docker network rm $Network
    if (Test-Path $StateDir) { Remove-Item -Recurse -Force $StateDir }
    Write-Host "    Done."
}

# --------------------------------------------------
# Main
# --------------------------------------------------

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker CLI not found."
}
if ((Invoke-Docker info).Code -ne 0) {
    throw "Docker daemon is not running."
}

switch ($Action) {
    "deploy"   { Invoke-Deploy }
    "rollback" { Invoke-Rollback }
    "status"   { Show-Status }
    "destroy"  { Invoke-Destroy }
}
