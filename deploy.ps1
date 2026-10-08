param([string]$Version = "v1")
$ErrorActionPreference = "Stop"
$conf = "$PWD\nginx\default.conf"

docker network inspect bgnet 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { docker network create bgnet }

$content = Get-Content $conf -Raw
if ($content -match "app-blue") { $active = "blue"; $new = "green" } else { $active = "green"; $new = "blue" }
Write-Host "Active: $active -> Deploying to: $new (version $Version)"

docker build -t demo-app:$Version .
docker rm -f app-$new 2>$null | Out-Null
docker run -d --name app-$new --network bgnet -e APP_VERSION=$Version demo-app:$Version

$healthy = $false
for ($i = 0; $i -lt 15; $i++) {
  docker run --rm --network bgnet curlimages/curl -sf http://app-${new}:5000/health 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $healthy = $true; break }
  Start-Sleep -Seconds 2
}

if (-not $healthy) {
  Write-Host "NEW VERSION FAILED HEALTH CHECK. Keeping $active live."
  docker rm -f app-$new | Out-Null
  exit 1
}

$content = $content -replace "app-$active", "app-$new"
Set-Content -Path $conf -Value $content -NoNewline

$running = docker ps --format "{{.Names}}" | Select-String "^nginx-proxy$"
if ($running) {
  docker exec nginx-proxy nginx -s reload
} else {
  docker run -d --name nginx-proxy --network bgnet -p 8080:80 -v "${conf}:/etc/nginx/conf.d/default.conf" nginx:alpine
}

docker rm -f app-$active 2>$null | Out-Null
Write-Host "Done. $new is live on http://localhost:8080"
