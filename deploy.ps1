param(
    [string]$Version = "v1"
)

$ErrorActionPreference = "Stop"

$Network = "bgnet"
$NginxConfig = "$PWD\nginx\default.conf"

Write-Host ""
Write-Host "========================================="
Write-Host " Blue-Green Deployment"
Write-Host " Version: $Version"
Write-Host "========================================="
Write-Host ""

# --------------------------------------------------
# 1. Create Docker network if it does not exist
# --------------------------------------------------

docker network inspect $Network 2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating Docker network: $Network"
    docker network create $Network
}

# --------------------------------------------------
# 2. Make sure nginx configuration exists
# --------------------------------------------------

if (-not (Test-Path $NginxConfig)) {
    Write-Host "ERROR: nginx/default.conf not found."
    exit 1
}

# --------------------------------------------------
# 3. Determine currently active colour
# --------------------------------------------------

$content = Get-Content $NginxConfig -Raw

if ($content -match "app-blue") {
    $active = "blue"
    $new = "green"
}
else {
    $active = "green"
    $new = "blue"
}

Write-Host "Current active colour : $active"
Write-Host "New deployment colour : $new"
Write-Host "Version               : $Version"
Write-Host ""

# --------------------------------------------------
# 4. Build Docker image
# --------------------------------------------------

$image = "demo-app:$Version"

Write-Host "Building Docker image: $image"

docker build -t $image .

if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker build failed."
    exit 1
}

# --------------------------------------------------
# 5. Remove old container of the new colour
# --------------------------------------------------

docker rm -f "app-$new" 2>$null | Out-Null

# --------------------------------------------------
# 6. Start new container
# --------------------------------------------------

Write-Host "Starting app-$new..."

docker run -d `
    --name "app-$new" `
    --network $Network `
    -e "APP_VERSION=$Version" `
    $image

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to start app-$new."
    exit 1
}

# --------------------------------------------------
# 7. Health check
# --------------------------------------------------

Write-Host ""
Write-Host "Running health check..."

$healthy = $false

for ($i = 0; $i -lt 15; $i++) {

    docker run --rm `
        --network $Network `
        curlimages/curl `
        -sf "http://app-$new`:9000/health" 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        $healthy = $true
        break
    }

    Write-Host "Waiting for app-$new..."
    Start-Sleep -Seconds 2
}

# --------------------------------------------------
# 8. Rollback if health check fails
# --------------------------------------------------

if (-not $healthy) {

    Write-Host ""
    Write-Host "========================================="
    Write-Host " HEALTH CHECK FAILED"
    Write-Host " Keeping $active active."
    Write-Host "========================================="
    Write-Host ""

    docker rm -f "app-$new" 2>$null | Out-Null

    exit 1
}

Write-Host ""
Write-Host "Health check PASSED."

# --------------------------------------------------
# 9. Switch nginx to new colour
# --------------------------------------------------

$content = $content -replace "app-$active", "app-$new"

Set-Content `
    -Path $NginxConfig `
    -Value $content `
    -NoNewline

Write-Host "Traffic switched: $active -> $new"

# --------------------------------------------------
# 10. Reload nginx
# --------------------------------------------------

$running = docker ps --format "{{.Names}}" |
    Select-String "^nginx-proxy$"

if ($running) {

    Write-Host "Reloading nginx..."

    docker exec nginx-proxy nginx -s reload

}
else {

    Write-Host "Starting nginx..."

    docker run -d `
        --name nginx-proxy `
        --network $Network `
        -p 8080:80 `
        -v "${NginxConfig}:/etc/nginx/conf.d/default.conf" `
        nginx:alpine
}

# --------------------------------------------------
# 11. Remove old application
# --------------------------------------------------

docker rm -f "app-$active" 2>$null | Out-Null

Write-Host ""
Write-Host "========================================="
Write-Host " DEPLOYMENT SUCCESSFUL"
Write-Host " Active colour : $new"
Write-Host " Version       : $Version"
Write-Host " URL           : http://localhost:8080"
Write-Host "========================================="
Write-Host ""