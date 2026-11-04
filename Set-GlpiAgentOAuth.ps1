<#
  Configura las credenciales OAuth del GLPI Agent en Windows. Si el agente falta
  o es demasiado antiguo, ofrece instalarlo con winget o con el MSI oficial.
  Comprueba las credenciales contra GLPI antes de escribirlas, restringe la clave
  del registro, reinicia el servicio, solicita un inventario y retira del historial
  de PowerShell las lineas relacionadas.

  Uso (PowerShell como administrador, sesion interactiva):
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    irm https://raw.githubusercontent.com/MOT4R0/glpi-agent-oauth/<commit>/Set-GlpiAgentOAuth.ps1 | iex
  o en local:
    .\Set-GlpiAgentOAuth.ps1

  Requisitos: PowerShell 5 o superior y GLPI 11 o superior. Versiones del agente:
    1.10 para OAuth y 1.16 para URLs terminadas en /front/inventory.php.
    Admite un solo servidor GLPI por agente.

  Si el servidor GLPI no esta configurado, el script pide su URL.

  Al terminar, LASTEXITCODE vale 0 si todo fue bien y 1 si hubo un error.

  La clave queda accesible solo para SYSTEM y Administradores, por lo que
  GLPI Agent Monitor debe ejecutarse como administrador. Sin elevar muestra
  "Error loading GLPI Agent settings" (0x00000002).
#>
& {
    $ErrorActionPreference = 'Stop'

    # Textos que identifican la invocacion en el historial. Nunca dejar un valor vacio.
    $HistoryMarkers = @('Set-GlpiAgentOAuth', 'glpi-agent-oauth')

    # La segunda ruta corresponde a un agente de 32 bits en Windows de 64 bits.
    $RegPaths    = @('HKLM:\SOFTWARE\GLPI-Agent', 'HKLM:\SOFTWARE\Wow6432Node\GLPI-Agent')
    $UninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $ServiceName    = 'glpi-agent'
    $MinVersion     = [version]'1.10'
    $InventoryPhpVersion = [version]'1.16'   # OAuth con URLs .../front/inventory.php
    $BrokenOAuthVersion  = [version]'1.20'   # Regresion del token corregida en 1.21 (#1247)
    $WingetId       = 'GLPI-Project.GLPI-Agent'
    $ReleasesUrl    = 'https://github.com/glpi-project/glpi-agent/releases'
    $LatestApiUrl   = 'https://api.github.com/repos/glpi-project/glpi-agent/releases/latest'
    $DefaultHttpdPort = 62354

    function Confirm-Step([string]$Message, [switch]$DefaultNo) {
        $suffix = if ($DefaultNo) { '[s/N]' } else { '[S/n]' }
        $answer = (Read-Host "$Message $suffix").Trim()
        if (-not $answer) { return (-not $DefaultNo) }
        return ($answer -match '^[sy]')
    }

    function Get-AgentInstall {
        $best = $null
        $apps = @(Get-ItemProperty -Path $UninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'GLPI Agent*' })
        foreach ($app in $apps) {
            $parsed = $null
            $text = "$($app.DisplayVersion)" -replace '[^0-9.].*$', ''
            if ([version]::TryParse($text, [ref]$parsed) -and (-not $best -or $parsed -gt $best.Version)) {
                $best = [pscustomobject]@{
                    Version = $parsed
                    Is32Bit = ($app.PSPath -match 'WOW6432Node')
                }
            }
        }
        return $best
    }

    function Get-AgentRegPath {
        return ($RegPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
    }

    function Install-WithWinget {
        $winget = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-Host '[INFO] winget no esta disponible para esta cuenta.' -ForegroundColor Yellow
            return
        }
        Write-Host "[INFO] Instalando $WingetId con winget..." -ForegroundColor Cyan
        try {
            & $winget.Source install --id $WingetId --exact --source winget --silent `
                --accept-source-agreements --accept-package-agreements | Out-Host
            Write-Host "[INFO] winget termino con codigo $LASTEXITCODE" -ForegroundColor Cyan
        } catch {
            Write-Warning "winget fallo: $($_.Exception.Message)"
        }
    }

    function Install-WithMsi {
        Write-Host '[INFO] Descargando el MSI oficial desde GitHub...' -ForegroundColor Cyan
        $ProgressPreference = 'SilentlyContinue'
        $release = Invoke-RestMethod -Uri $LatestApiUrl -Headers @{ 'User-Agent' = 'Set-GlpiAgentOAuth' } -UseBasicParsing
        $msiAsset = $release.assets | Where-Object { $_.name -match '^GLPI-Agent-.*-x64\.msi$' } | Select-Object -First 1
        $shaAsset = $release.assets | Where-Object { $_.name -match '^glpi-agent-.*\.sha256$' } | Select-Object -First 1
        if (-not $msiAsset -or -not $shaAsset) {
            throw "La release $($release.tag_name) no publica el MSI x64 y su SHA-256."
        }

        $dir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $msiPath = Join-Path $dir $msiAsset.name
            Invoke-WebRequest -UseBasicParsing -Uri $msiAsset.browser_download_url -OutFile $msiPath
            $shaText = (Invoke-WebRequest -UseBasicParsing -Uri $shaAsset.browser_download_url).Content
            if ($shaText -is [byte[]]) { $shaText = [Text.Encoding]::ASCII.GetString($shaText) }

            $expected = $null
            foreach ($line in ($shaText -split "`r?`n")) {
                $parts = $line.Trim() -split '\s+'
                if ($parts.Count -ge 2 -and $parts[1].TrimStart('*') -eq $msiAsset.name) { $expected = $parts[0] }
            }
            if (-not $expected) { throw "No se encontro el SHA-256 de $($msiAsset.name)." }
            $actual = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
            if ($actual -ine $expected) {
                throw "El SHA-256 de $($msiAsset.name) no coincide. No se instalo."
            }
            Write-Host '[OK] SHA-256 del MSI verificado' -ForegroundColor Green

            # La documentacion de GLPI desaconseja usar PowerShell como interprete del MSI.
            # Sin log detallado: el MSI carga las credenciales existentes como propiedades.
            $msiArgs = "/c start `"`" /wait msiexec.exe /i `"$msiPath`" /quiet /norestart"
            $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $msiArgs `
                -Wait -PassThru -WindowStyle Hidden
            Write-Host "[INFO] msiexec termino con codigo $($process.ExitCode)" -ForegroundColor Cyan
            if ($process.ExitCode -in 1641, 3010) {
                Write-Warning 'El instalador pide reiniciar Windows para completar la instalacion.'
            }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Ofrece instalar o actualizar. Con -Optional, rechazarlo permite continuar.
    function Request-AgentUpdate([version]$Required, [string]$Reason, [switch]$Optional) {
        $current = Get-AgentInstall
        if (-not [Environment]::Is64BitOperatingSystem -or ($current -and $current.Is32Bit)) {
            $message = "$Reason Las versiones actuales solo publican MSI de 64 bits; revisa este equipo manualmente: $ReleasesUrl"
            if ($Optional) { Write-Warning $message; return }
            throw $message
        }

        Write-Host "[INFO] $Reason" -ForegroundColor Yellow
        if ($Optional) {
            $accepted = Confirm-Step 'Actualizar GLPI Agent ahora?'
        } else {
            $accepted = Confirm-Step 'Instalar la ultima version de GLPI Agent ahora?'
        }
        if (-not $accepted) {
            if ($Optional) { return }
            throw "Instalacion cancelada. Descarga GLPI Agent desde $ReleasesUrl"
        }

        Install-WithWinget
        $after = Get-AgentInstall
        if (-not $after -or $after.Version -lt $Required) {
            try {
                Install-WithMsi
            } catch {
                Write-Warning "La descarga directa fallo: $($_.Exception.Message)"
            }
            $after = Get-AgentInstall
        }
        if (-not $after -or $after.Version -lt $Required) {
            $message = "No se pudo instalar GLPI Agent $Required o superior. Descargalo desde $ReleasesUrl"
            if ($Optional) { Write-Warning $message; return }
            throw $message
        }
        Write-Host "[OK] GLPI Agent $($after.Version) instalado" -ForegroundColor Green
    }

    function Read-ServerUrl {
        Write-Host ''
        Write-Host 'El agente no tiene servidor GLPI configurado.' -ForegroundColor Cyan
        Write-Host '  Ejemplo:        https://glpi.ejemplo.com/front/inventory.php'
        Write-Host '  En subcarpeta:  https://ejemplo.com/glpi/front/inventory.php'
        while ($true) {
            $value = (Read-Host 'URL del servidor GLPI').Trim()
            if (-not $value) { throw 'La URL del servidor esta vacia.' }

            $uri = $null
            if ($value -notmatch '[\s,]' -and
                [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -in 'http', 'https' -and
                $uri.Host) {
                return $value
            }
            Write-Host "[ERROR] URL no valida: $value. Debe empezar por https:// o http://" -ForegroundColor Red
        }
    }

    # Misma ruta que calcula el agente (GLPI::Agent::HTTP::Client::_getOauthAccessToken).
    # Un valor sin esquema es un nombre de host: el agente usa http://<host>/inventory.
    function Get-TokenUrl([string]$Server) {
        $full = if ($Server -match '^https?://') { $Server } else { "http://$Server/inventory" }
        $uri  = [uri]$full
        $path = $uri.AbsolutePath
        if ($path -cmatch '^(.*)front/inventory\.php$') { $path = $Matches[1] }
        if ($path -cmatch '^(.*)(marketplace|plugins).*$') { $path = $Matches[1] }
        return "$($uri.Scheme)://$($uri.Authority)$($path.TrimEnd('/'))/api.php/token"
    }

    # Lanza un error si GLPI rechaza las credenciales. Si no se pudo comprobar, pregunta.
    function Assert-OAuthCredential([string]$Server, [string]$Id, [string]$Secret) {
        $tokenUrl = Get-TokenUrl $Server
        $json = @{
            grant_type    = 'client_credentials'
            client_id     = $Id
            client_secret = $Secret
            scope         = 'inventory'
        } | ConvertTo-Json -Compress
        $body = [Text.Encoding]::UTF8.GetBytes($json)

        $problem = $null
        try {
            $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType 'application/json' `
                -Body $body -TimeoutSec 20 -UseBasicParsing
            if ($response.access_token) {
                Write-Host "[OK] GLPI acepto las credenciales ($tokenUrl)" -ForegroundColor Green
                return
            }
            $problem = 'la respuesta no incluye un token'
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -in 400, 401) {
                throw "GLPI rechazo las credenciales (HTTP $status en $tokenUrl). Revisa Client ID, secreto, Grants 'Client credentials' y Scope 'inventory'. No se escribio nada."
            }
            $problem = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        } finally {
            $json = $null
            $body = $null
        }

        Write-Warning "No se pudieron comprobar las credenciales en ${tokenUrl}: $problem"
        if (-not (Confirm-Step 'Guardarlas de todos modos?' -DefaultNo)) {
            throw 'Cancelado. No se escribio nada.'
        }
    }

    $clientId = $null
    $plain    = $null
    $exitCode  = 1

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Ejecuta PowerShell como administrador.'
        }

        # 1. Agente instalado en una version compatible.
        $agent = Get-AgentInstall
        $hasService = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
        if (-not $agent -or -not $hasService -or -not (Get-AgentRegPath)) {
            Request-AgentUpdate -Required $MinVersion -Reason 'GLPI Agent no esta instalado o su instalacion esta incompleta.'
        } elseif ($agent.Version -lt $MinVersion) {
            Request-AgentUpdate -Required $MinVersion -Reason "GLPI Agent $($agent.Version) no soporta OAuth; requiere $MinVersion o superior."
        } elseif ($agent.Version -eq $BrokenOAuthVersion) {
            Request-AgentUpdate -Required ([version]'1.21') -Optional `
                -Reason "GLPI Agent $($agent.Version) tiene una regresion de OAuth corregida en 1.21."
        }

        $agent   = Get-AgentInstall
        $RegPath = Get-AgentRegPath
        if (-not $agent) { throw "No se pudo determinar la version del GLPI Agent. Descargalo desde $ReleasesUrl" }
        if (-not $RegPath) { throw 'No existe la clave del registro del agente.' }
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            throw "No existe el servicio '$ServiceName'. Instala el agente en modo servicio."
        }
        Write-Host "[OK] GLPI Agent $($agent.Version) ($RegPath)" -ForegroundColor Green

        # 2. Servidor GLPI. Solo se pregunta si no hay uno configurado.
        $settings    = Get-ItemProperty -Path $RegPath
        $server      = "$($settings.server)".Trim()
        $serverIsNew = -not $server
        if ($serverIsNew) {
            $server = Read-ServerUrl
        } elseif ($server.Contains(',')) {
            throw "El agente tiene varios servidores configurados ($server). Este script admite uno solo."
        } else {
            Write-Host "[OK] Servidor configurado: $server" -ForegroundColor Green
        }

        if ($server -match 'front/inventory\.php$' -and $agent.Version -lt $InventoryPhpVersion) {
            Request-AgentUpdate -Required $InventoryPhpVersion -Reason "Esta URL de servidor requiere GLPI Agent $InventoryPhpVersion o superior."
            $agent = Get-AgentInstall
        }

        if ($server -notmatch '^https://') {
            Write-Warning "Sin HTTPS el secreto viajaria sin cifrar: $server"
            if (-not (Confirm-Step 'Continuar sin HTTPS?' -DefaultNo)) { throw 'Cancelado. No se escribio nada.' }
        }

        # 3. Credenciales.
        Write-Host '=== Actualizar OAuth del GLPI Agent ===' -ForegroundColor Cyan
        $clientId = (Read-Host 'Client ID').Trim()
        if ([string]::IsNullOrWhiteSpace($clientId)) { throw 'El Client ID esta vacio.' }

        $secure = Read-Host 'Client secret' -AsSecureString
        try {
            $plain = [System.Net.NetworkCredential]::new('', $secure).Password
        } finally {
            $secure.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($plain)) { throw 'El secreto esta vacio.' }
        # Desde 1.20 el agente interpreta la coma como separador de valores.
        if ($clientId.Contains(',') -or $plain.Contains(',')) {
            throw 'El Client ID y el secreto no pueden contener comas.'
        }

        Assert-OAuthCredential -Server $server -Id $clientId -Secret $plain

        # 4. Restringir la clave antes de escribir el secreto.
        $acl = New-Object System.Security.AccessControl.RegistrySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {   # SYSTEM, Administradores
            $identity = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $sid
            $rule = [System.Security.AccessControl.RegistryAccessRule]::new(
                $identity,
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path $RegPath -AclObject $acl
        Write-Host '[OK] Clave restringida a SYSTEM y Administradores' -ForegroundColor Green

        if ($serverIsNew) {
            Set-ItemProperty -Path $RegPath -Name 'server' -Value $server -Type String
            Write-Host "[OK] Servidor escrito en $RegPath" -ForegroundColor Green
        }
        Set-ItemProperty -Path $RegPath -Name 'oauth-client-id'     -Value $clientId -Type String
        Set-ItemProperty -Path $RegPath -Name 'oauth-client-secret' -Value $plain    -Type String
        Write-Host "[OK] Credenciales OAuth escritas en $RegPath" -ForegroundColor Green

        Restart-Service -Name $ServiceName
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        Write-Host "[OK] Servicio '$ServiceName' reiniciado" -ForegroundColor Green

        # 5. Solicitar inventario. El servidor HTTP del agente tarda en levantar despues del reinicio.
        $noHttpd = "$($settings.'no-httpd')".Trim()
        if ($noHttpd -and $noHttpd -ne '0') {
            Write-Warning 'El servidor HTTP del agente esta desactivado (no-httpd). El inventario se enviara en la proxima ejecucion programada.'
        } else {
            $port = "$($settings.'httpd-port')".Trim()
            if (-not $port -or $port -eq '0') { $port = $DefaultHttpdPort }
            $nowUrl = "http://127.0.0.1:$port/now"

            $forced = $false
            $lastError = $null
            for ($i = 0; $i -lt 12 -and -not $forced; $i++) {
                Start-Sleep -Seconds 5
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $nowUrl -TimeoutSec 15 | Out-Null
                    $forced = $true
                } catch {
                    $lastError = $_.Exception.Message
                    # Si el agente respondio con un error HTTP, reintentar no ayuda.
                    if ($_.Exception.Response) { break }
                }
            }
            if ($forced) {
                Write-Host '[OK] Inventario solicitado. Verifica en GLPI la fecha del ultimo inventario.' -ForegroundColor Green
            } else {
                Write-Warning "No se pudo solicitar el inventario ($nowUrl): $lastError"
            }
        }
        $exitCode = 0
    }
    catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        try {
            # Los valores cortos podrian coincidir con lineas ajenas al script.
            $sensitive = @($clientId, $plain | Where-Object { $_ -and $_.Length -ge 8 } | ForEach-Object { [regex]::Escape($_) })
            $markers   = @($HistoryMarkers | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
            $rx = @($markers + $sensitive) -join '|'
            $sensitiveRx = $sensitive -join '|'

            if ($rx) {
                Get-History | Where-Object { $_.CommandLine -match $rx } | ForEach-Object { Clear-History -Id $_.Id }
            }

            if ($rx -and (Get-Module -Name PSReadLine)) {
                $hist = (Get-PSReadLineOption).HistorySavePath
                if ($hist -and (Test-Path -LiteralPath $hist)) {
                    $lines = @(Get-Content -LiteralPath $hist -Encoding UTF8)
                    $keep  = @($lines | Where-Object { $_ -notmatch $rx })
                    if ($keep.Count -ne $lines.Count) {
                        [System.IO.File]::WriteAllLines($hist, [string[]]$keep)
                        Write-Host "[OK] Historial limpiado: $($lines.Count - $keep.Count) linea(s) eliminada(s) de $hist" -ForegroundColor Green
                    }
                    # La memoria de PSReadLine solo se borra entera: unicamente si se pego un secreto.
                    if ($sensitiveRx -and @($lines | Where-Object { $_ -match $sensitiveRx }).Count -gt 0) {
                        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
                    }
                }
            }
        } catch {
            Write-Warning "No se pudo limpiar el historial: $($_.Exception.Message)"
        } finally {
            $plain     = $null
            $clientId  = $null
            $sensitive = $null
            $rx        = $null
            $sensitiveRx = $null
            [GC]::Collect()
            $global:LASTEXITCODE = $exitCode
        }
    }
}
