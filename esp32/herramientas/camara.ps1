<#
Configura y revisa la cámara Taxiff por el cable USB (puerto UART de la placa).

  .\camara.ps1 ip                           IP de la cámara y si está conectada
  .\camara.ps1 wifi "NOMBRE_RED" "CLAVE"    la conecta a esa WiFi (tiene que ser 2.4 GHz)
  .\camara.ps1 servidor "https://..."       a dónde envía las fotos
  .\camara.ps1 redes                        redes WiFi que ve la cámara
  .\camara.ps1 guardadas                    redes WiFi que tiene guardadas (hasta 5)
  .\camara.ps1 olvidar "NOMBRE_RED"         borra una red guardada
  .\camara.ps1 portal                       abre su red Taxiff-Cam por 10 min (igual que BOOT 3 s)
  .\camara.ps1 mensajes 30                  lo que va diciendo durante 30 s
  .\camara.ps1 registro                     qué pasó mientras funcionaba sola (arranques, WiFi, estado)

Opcional: -Puerto COM5 (si no, usa el primer puerto que encuentre).
#>
param(
  [Parameter(Position = 0)][ValidateSet("ip", "wifi", "servidor", "redes", "guardadas", "olvidar", "portal", "mensajes", "registro")][string]$Accion = "ip",
  [Parameter(Position = 1)][string]$Valor1 = "",
  [Parameter(Position = 2)][string]$Valor2 = "",
  [string]$Puerto = ""
)

if (-not $Puerto) {
  $Puerto = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object | Select-Object -First 1
  if (-not $Puerto) {
    Write-Host "No hay ninguna cámara conectada por USB."
    Write-Host "Conéctala al puerto marcado UART de la placa (no al OTG) y prueba otro cable si sigue sin aparecer."
    exit 1
  }
}

# Sin DTR/RTS: abrir el puerto no reinicia la placa.
$port = New-Object System.IO.Ports.SerialPort $Puerto, 115200
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.Encoding = [Text.Encoding]::UTF8
try { $port.Open() } catch { Write-Host "No se pudo abrir $Puerto ($($_.Exception.Message)). ¿Está abierto en otro programa?"; exit 1 }

function Leer([int]$segundos, [string]$hasta = "") {
  $texto = ""
  $fin = (Get-Date).AddSeconds($segundos)
  while ((Get-Date) -lt $fin) {
    try { $texto += $port.ReadExisting() } catch { break }
    if ($hasta -and $texto -match $hasta) { break }
    Start-Sleep -Milliseconds 200
  }
  return $texto
}

function Mensajes($texto) { $texto -split "`n" | Where-Object { $_ -match "^#" } | ForEach-Object { $_.TrimEnd() } }

# Qué significa cada motivo con que el router rechaza la conexión.
$motivos = @{
  "201" = "no encuentra la red (¿es solo 5 GHz? ¿el nombre está bien escrito?)"
  "15"  = "clave incorrecta"
  "204" = "clave incorrecta"
  "2"   = "el router no la aceptó (clave o seguridad)"
  "8"   = "se desconectó (normal al reiniciar)"
}

try {
  switch ($Accion) {
    "ip" {
      Write-Host "Leyendo la cámara en $Puerto (hasta 25 s)..."
      $t = Leer 25 "(?m)^# (AP )?\d+\.\d+\.\d+\.\d+ "
      if ($t -match "(?m)^# AP 192\.168\.4\.1") {
        Write-Host ""
        Write-Host "La cámara NO está conectada a ninguna WiFi: creó su propia red."
        Write-Host "Conéctala a tu red con:  .\camara.ps1 wifi `"NOMBRE_RED`" `"CLAVE`""
      } elseif ($t -match "(?m)^# (\d+\.\d+\.\d+\.\d+) ") {
        Write-Host ""
        Write-Host "IP de la cámara: $($Matches[1])"
        Write-Host "Página de la cámara: http://$($Matches[1])   (desde la misma red)"
      } else {
        Write-Host "La cámara no dijo nada. ¿Está encendida? Prueba desconectar y conectar el cable."
      }
    }

    "wifi" {
      if (-not $Valor1) { Write-Host 'Uso: .\camara.ps1 wifi "NOMBRE_RED" "CLAVE"'; exit 1 }
      Write-Host "Enviando la red '$Valor1' a la cámara..."
      # Mientras la cámara intenta conectarse a otra red no escucha: se repite hasta que la acepta.
      $t = ""
      $fin = (Get-Date).AddSeconds(180)
      $guardada = $false
      while (-not $guardada -and (Get-Date) -lt $fin) {
        $port.Write("WIFI $Valor1`t$Valor2`n")
        $t += Leer 8 "WiFi guardada"
        $guardada = $t -match "WiFi guardada"
        if (-not $guardada) { Write-Host "  (la cámara está ocupada buscando otra red, reintentando...)" }
      }
      if (-not $guardada) { Write-Host "La cámara no respondió. Desconecta y conecta el cable y prueba otra vez."; exit 1 }
      Write-Host "Red guardada. La cámara se reinicia y se conecta (hasta 1 minuto)..."
      $t = Leer 90 "WiFi OK|Sin WiFi"
      foreach ($m in [regex]::Matches($t, "motivo (\d+)")) {
        $motivo = $m.Groups[1].Value
        if ($motivos.ContainsKey($motivo) -and $motivo -ne "8") { Write-Host "  router: $($motivos[$motivo])" }
      }
      if ($t -match "WiFi OK: abre http://([\d\.]+)") {
        Write-Host ""
        Write-Host "CONECTADA. IP de la cámara: $($Matches[1])"
        Write-Host "Página de la cámara: http://$($Matches[1])"
      } else {
        Write-Host ""
        Write-Host "No se pudo conectar a '$Valor1'. Revisa:"
        Write-Host "  - que la red sea de 2.4 GHz (con .\camara.ps1 redes ves las que la cámara puede usar)"
        Write-Host "  - el nombre exacto (mayúsculas, guiones) y la clave"
      }
    }

    "servidor" {
      if (-not $Valor1) { Write-Host 'Uso: .\camara.ps1 servidor "https://..."'; exit 1 }
      $port.Write("SERVER $Valor1`n")
      $t = Leer 5 "# servidor:"
      if ($t -match "# servidor: (.*)") { Write-Host "Servidor guardado: $($Matches[1].Trim())" }
      else { Write-Host "La cámara no confirmó. Si está buscando WiFi, espera 1 minuto y repite." }
    }

    "redes" {
      Write-Host "Buscando redes (unos segundos)..."
      $port.Write("SCAN`n")
      $t = Leer 20 "SCAN: \d+ redes[\s\S]*\n#[^\n]*fps"
      $redes = Mensajes $t | Where-Object { $_ -match "^#   \S" }
      if ($redes) {
        Write-Host "Redes que ve la cámara (solo 2.4 GHz, más cerca de 0 dBm = mejor señal):"
        $redes | ForEach-Object { Write-Host ($_ -replace "^#\s+", "  ") }
      } else { Write-Host "La cámara no respondió (puede estar ocupada conectándose). Repite en 1 minuto." }
    }

    "guardadas" {
      $port.Write("REDES`n")
      $t = Leer 6 "REDES guardadas: (\d+)[\s\S]*\n#[^\n]*fps"
      if ($t -match "REDES guardadas: (\d+)") {
        Write-Host "Redes guardadas: $($Matches[1])"
        Mensajes $t | Where-Object { $_ -match "^#   \S" } | ForEach-Object { Write-Host ($_ -replace "^#\s+", "  ") }
      } else { Write-Host "La cámara no respondió (puede estar conectándose). Repite en 1 minuto." }
    }

    "olvidar" {
      if (-not $Valor1) { Write-Host 'Uso: .\camara.ps1 olvidar "NOMBRE_RED"'; exit 1 }
      $port.Write("OLVIDAR $Valor1`n")
      $t = Leer 5 "red olvidada"
      if ($t -match "red olvidada") { Write-Host "Red '$Valor1' borrada." }
      else { Write-Host "La cámara no confirmó. Espera 1 minuto y repite." }
    }

    "portal" {
      $port.Write("PORTAL`n")
      $t = Leer 8 "Taxiff-Cam"
      if ($t -match "Taxiff-Cam") {
        Write-Host "Red de configuración abierta por 10 minutos."
        Write-Host "En el celular: conéctate a Taxiff-Cam (clave taxiff123) y la página se abre sola."
      } else { Write-Host "La cámara no confirmó (quizás ya estaba abierta). Mira con .\camara.ps1 mensajes 10" }
    }

    "registro" {
      Write-Host "Leyendo el registro de la cámara..."
      $t = ""
      for ($i = 0; $i -lt 6 -and $t -notmatch "fin del registro|registro vac"; $i++) {
        $port.Write("LOG`n")
        $t += Leer 6 "fin del registro|registro vac"
      }
      $lineas = $t -split "`n" | Where-Object { $_ -notmatch "^#" -and $_.Trim() } | ForEach-Object { $_.TrimEnd() }
      if ($lineas) { $lineas | ForEach-Object { Write-Host "  $_" } }
      elseif ($t -match "registro vac") { Write-Host "El registro está vacío." }
      else { Write-Host "La cámara no respondió (puede estar conectándose). Repite en 1 minuto." }
    }

    "mensajes" {
      $seg = if ($Valor1) { [int]$Valor1 } else { 30 }
      Write-Host "Mensajes de la cámara durante $seg s:"
      Mensajes (Leer $seg) | ForEach-Object { Write-Host "  $_" }
    }
  }
} finally {
  $port.Close()
}
