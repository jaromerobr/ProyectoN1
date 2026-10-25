<#
Configura UNA VEZ el túnel fijo de Cloudflare: taxiff.site (y www) llevan a este
servidor en esta PC, siempre, aunque cambie la IP o la WiFi de la casa.

Antes: el dominio tiene que estar activo en Cloudflare (nameservers de Hostinger
cambiados a los de Cloudflare). Ver docs/DESPLIEGUE.md.

  .\tunel_fijo.ps1                   (abre el navegador para autorizar el dominio la primera vez)
  .\tunel_fijo.ps1 -Dominio otro.com

Después, el túnel lo mantiene funcionando servidor_siempre.ps1.
#>
param([string]$Dominio = "taxiff.site", [string]$Nombre = "taxiff", [int]$Puerto = 8000)

$ErrorActionPreference = "Stop"
$cf = Join-Path $PSScriptRoot "..\herramientas\cloudflared.exe"
if (-not (Test-Path $cf)) {
  New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null
  Write-Host "Descargando cloudflared…"
  Invoke-WebRequest "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cf -UseBasicParsing
}
$dir = Join-Path $HOME ".cloudflared"

# 1. Permiso de Cloudflare para manejar el dominio (se abre el navegador: elegir el dominio y "Authorize").
if (-not (Test-Path "$dir\cert.pem")) {
  Write-Host "Se abre el navegador: inicia sesión en Cloudflare, elige $Dominio y pulsa Authorize."
  & $cf tunnel login
  if (-not (Test-Path "$dir\cert.pem")) { Write-Host "No se completó la autorización."; exit 1 }
}

# 2. El túnel (se crea una sola vez; si ya existe, se reutiliza).
$t = & $cf tunnel list --output json | ConvertFrom-Json | Where-Object { $_.name -eq $Nombre -and -not $_.deleted_at }
if (-not $t) {
  & $cf tunnel create $Nombre | Out-Host
  $t = & $cf tunnel list --output json | ConvertFrom-Json | Where-Object { $_.name -eq $Nombre }
}
$id = @($t)[0].id
Write-Host "Túnel '$Nombre': $id"

# 3. El dominio apunta al túnel (reemplaza lo que hubiera, p. ej. la página de estacionamiento).
& $cf tunnel route dns --overwrite-dns $Nombre $Dominio | Out-Host
& $cf tunnel route dns --overwrite-dns $Nombre "www.$Dominio" | Out-Host

# 4. Qué atiende el túnel: todo va al servidor Taxiff de esta PC. (La ruta va entre
#    comillas simples: con dobles, YAML lee "\U" de "C:\Users" como un código especial.)
$cred = Join-Path $dir "$id.json"
@"
tunnel: $id
credentials-file: '$cred'
ingress:
  - hostname: $Dominio
    service: http://localhost:$Puerto
  - hostname: www.$Dominio
    service: http://localhost:$Puerto
  - service: http_status:404
"@ | Set-Content (Join-Path $dir "config.yml") -Encoding ascii

Write-Host ""
Write-Host "Listo. https://$Dominio llevará a esta PC cuando el túnel esté corriendo (servidor_siempre.ps1)."
