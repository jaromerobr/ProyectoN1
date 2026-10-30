<#
Mantiene funcionando, en esta PC, el servidor Taxiff y el túnel fijo de Cloudflare
(https://taxiff.site). Si alguno se cae, lo vuelve a levantar a los pocos segundos.
Mientras corre, Windows no suspende la PC.

Lo arranca solo la tarea programada que crea instalar_arranque.ps1 (al iniciar
sesión). También se puede correr a mano:
  powershell -ExecutionPolicy Bypass -File .\servidor_siempre.ps1

Lo que pasa queda en servidor\datos\logs\siempre.log.
#>
param([int]$Puerto = 8000, [string]$Tunel = "taxiff")

$servidor = Split-Path $PSScriptRoot
Set-Location $servidor
$py = Join-Path $servidor ".venv\Scripts\python.exe"
$cf = Join-Path $servidor "herramientas\cloudflared.exe"
$cfg = Join-Path $HOME ".cloudflared\config.yml"
$logs = Join-Path $servidor "datos\logs"
New-Item -ItemType Directory -Force $logs | Out-Null
$log = Join-Path $logs "siempre.log"
function Anotar($t) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $t" | Add-Content $log -Encoding UTF8 }

# Una sola copia a la vez.
$mutex = New-Object Threading.Mutex($false, "Global\TaxiffServidorSiempre")
if (-not $mutex.WaitOne(0)) { Anotar "ya hay otra copia corriendo: esta se cierra"; exit 0 }

# Variables del archivo .env (clave del panel, etc.).
if (Test-Path ".env") {
  Get-Content ".env" | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

# Que Windows no suspenda la PC mientras esto corre (no cambia ningún ajuste).
Add-Type -Namespace Taxiff -Name Energia -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[Taxiff.Energia]::SetThreadExecutionState(0x80000001) | Out-Null

$srv = $null; $tun = $null; $sinPuerto = 0
Anotar "inicio: servidor en el puerto $Puerto y túnel '$Tunel'"
try {
  while ($true) {
    if (-not $srv -or $srv.HasExited) {
      if ($srv) { Anotar "el servidor se detuvo (código $($srv.ExitCode)): se vuelve a levantar" }
      # --no-access-log: cada foto no llena la salida; los eventos importantes van a servidor.log.
      $srv = Start-Process $py -ArgumentList "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", $Puerto, "--no-access-log" `
        -WorkingDirectory $servidor -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logs "uvicorn_salida.log") -RedirectStandardError (Join-Path $logs "uvicorn_errores.log")
      Anotar "servidor levantado (proceso $($srv.Id))"
      $sinPuerto = 0
    } elseif (-not (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue)) {
      # El lanzador del .venv puede quedar vivo minutos con el servidor real ya
      # muerto: si pasa 1 min sin nadie en el puerto (ya arrancado), se reinicia.
      $sinPuerto++
      if ($sinPuerto -ge 4 -and ((Get-Date) - $srv.StartTime).TotalSeconds -gt 60) {
        Anotar "el servidor no responde en el puerto ${Puerto}: se reinicia"
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($srv.Id)" |
          ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
        $sinPuerto = 0
      }
    } else { $sinPuerto = 0 }
    if ((Test-Path $cfg) -and (-not $tun -or $tun.HasExited)) {
      if ($tun) { Anotar "el túnel se detuvo (código $($tun.ExitCode)): se vuelve a levantar" }
      $tun = Start-Process $cf -ArgumentList "tunnel", "--no-autoupdate", "--config", "`"$cfg`"", "run", $Tunel `
        -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $logs "tunel.log")
      Anotar "túnel levantado (proceso $($tun.Id))"
    }
    Start-Sleep 15
  }
} finally {
  foreach ($p in $srv, $tun) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  Anotar "detenido"
  $mutex.ReleaseMutex()
}
