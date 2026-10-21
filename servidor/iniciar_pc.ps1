# Starts the Taxiff server on this PC for testing.
#   .\iniciar_pc.ps1                     server on http://<this PC IP>:8000 (same WiFi only)
#   .\iniciar_pc.ps1 -Tunel              plus a public https address (Cloudflare quick tunnel),
#                                        reachable from the taxi through the driver's mobile data
#   .\iniciar_pc.ps1 -Tunel -Esp 192.168.1.61   also tells that ESP32 to send to the new address
# Ctrl+C stops everything. The quick-tunnel address changes every time it starts.
param([switch]$Tunel, [string]$Esp = "", [int]$Puerto = 8000)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$py = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
  Write-Host "Falta el entorno de Python. Créalo una vez con:"
  Write-Host "  py -3.12 -m venv .venv"
  Write-Host "  .venv\Scripts\python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu"
  Write-Host "  .venv\Scripts\python -m pip install -r requirements-dev.txt"
  exit 1
}

# Variables del archivo .env (si existe).
if (Test-Path ".env") {
  Get-Content ".env" | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match "Wi-Fi|Ethernet" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
$server = Start-Process $py -ArgumentList "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", $Puerto -PassThru -NoNewWindow
$procs = @($server)
Start-Sleep 4
Write-Host ""
Write-Host "Servidor:  http://localhost:$Puerto   (en la misma WiFi: http://${ip}:$Puerto)"
Write-Host "Panel:     usuario admin, clave = TAXIFF_CLAVE_PANEL (por defecto 'taxiff')"
$publica = "http://${ip}:$Puerto"

if ($Tunel) {
  $cf = Join-Path $PSScriptRoot "herramientas\cloudflared.exe"
  if (-not (Test-Path $cf)) {
    New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null
    Write-Host "Descargando cloudflared (una sola vez)..."
    Invoke-WebRequest "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cf -UseBasicParsing
  }
  $log = Join-Path $env:TEMP "taxiff_tunel.log"
  Remove-Item $log -ErrorAction SilentlyContinue
  $procs += Start-Process $cf -ArgumentList "tunnel", "--no-autoupdate", "--url", "http://localhost:$Puerto" -RedirectStandardError $log -PassThru -WindowStyle Hidden
  $publica = $null
  for ($i = 0; $i -lt 40 -and -not $publica; $i++) {
    Start-Sleep 1
    if (Test-Path $log) { $m = Select-String -Path $log -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" | Select-Object -First 1; if ($m) { $publica = $m.Matches[0].Value } }
  }
  if ($publica) { Write-Host "Pública:   $publica   (úsala en el ESP32: página de la cámara > Servidor Taxiff)" }
  else { Write-Host "No se pudo abrir el túnel; revisa $log" }
}

if ($Esp -and $publica) {
  try {
    Invoke-RestMethod "http://$Esp/set?srv=$([uri]::EscapeDataString($publica))" -TimeoutSec 8 | Out-Null
    Write-Host "ESP32 $Esp configurado para enviar a $publica"
  } catch { Write-Host "No se pudo configurar el ESP32 en $Esp ($_)" }
}

Write-Host ""
Write-Host "Ctrl+C para detener."
try { Wait-Process -Id $server.Id } finally { $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
