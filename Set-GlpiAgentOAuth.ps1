<#
  Actualiza las credenciales OAuth del GLPI Agent, restringe su clave del
  registro, reinicia el servicio, fuerza un inventario y limpia el historial
  de PowerShell.

  Uso (PowerShell como administrador, sesion interactiva):
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    irm <URL raw de este archivo> | iex
  o en local:
    .\Set-GlpiAgentOAuth.ps1

  Requisitos: PowerShell 5 o superior y GLPI Agent 1.10 o superior.

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
    $ServiceName = 'glpi-agent'
    $MinVersion  = [version]'1.10'

    $clientId     = $null
    $clientSecret = $null
    $plain        = $null

    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Ejecuta PowerShell como administrador.'
        }

        $RegPath = $RegPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $RegPath) {
            throw 'No existe la clave del registro del agente. Esta instalado el GLPI Agent?'
        }
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            throw "No existe el servicio '$ServiceName'."
        }

        $app = Get-ItemProperty -Path $UninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'GLPI Agent*' } |
            Select-Object -First 1
        $version = $null
        if ($app -and $app.DisplayVersion) {
            $parsed = $null
            $text = $app.DisplayVersion -replace '[^0-9.].*$', ''
            if ([version]::TryParse($text, [ref]$parsed)) { $version = $parsed }
        }
        if (-not $version) {
            throw "No se pudo determinar la version del GLPI Agent. OAuth requiere $MinVersion o superior."
        }
        if ($version -lt $MinVersion) {
            throw "GLPI Agent $version no soporta OAuth. Actualizalo a $MinVersion o superior."
        }
        Write-Host "[OK] GLPI Agent $version ($RegPath)" -ForegroundColor Green

        Write-Host '=== Actualizar OAuth del GLPI Agent ===' -ForegroundColor Cyan
        $clientId = (Read-Host 'Client ID').Trim()
        if ([string]::IsNullOrWhiteSpace($clientId)) { throw 'El Client ID esta vacio.' }

        $clientSecret = Read-Host 'Client secret' -AsSecureString
        $plain = [System.Net.NetworkCredential]::new('', $clientSecret).Password
        if ([string]::IsNullOrWhiteSpace($plain)) { throw 'El secreto esta vacio.' }

        # Restringir la clave antes de escribir el secreto.
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

        Set-ItemProperty -Path $RegPath -Name 'oauth-client-id'     -Value $clientId -Type String
        Set-ItemProperty -Path $RegPath -Name 'oauth-client-secret' -Value $plain    -Type String
        Write-Host "[OK] Credenciales OAuth escritas en $RegPath" -ForegroundColor Green

        Restart-Service -Name $ServiceName
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        Write-Host "[OK] Servicio '$ServiceName' reiniciado" -ForegroundColor Green

        # El servidor HTTP del agente tarda en levantar despues del reinicio.
        $forced = $false
        $lastError = $null
        for ($i = 0; $i -lt 12 -and -not $forced; $i++) {
            Start-Sleep -Seconds 5
            try {
                Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:62354/now' -TimeoutSec 15 | Out-Null
                $forced = $true
            } catch {
                $lastError = $_.Exception.Message
                # Si el agente respondio con un error HTTP, reintentar no ayuda.
                if ($_.Exception.Response) { break }
            }
        }
        if ($forced) {
            Write-Host '[OK] Inventario forzado. Verifica en GLPI la fecha del ultimo inventario.' -ForegroundColor Green
        } else {
            Write-Warning "No se pudo forzar el inventario (http://127.0.0.1:62354/now): $lastError"
        }
    }
    catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        $patterns = @($HistoryMarkers + $clientId + $plain) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [regex]::Escape($_) }
        $rx = $patterns -join '|'

        Clear-History

        if ($rx -and (Get-Module -Name PSReadLine)) {
            try { [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() } catch { }

            $hist = (Get-PSReadLineOption).HistorySavePath
            if ($hist -and (Test-Path -LiteralPath $hist)) {
                $lines = @(Get-Content -LiteralPath $hist -Encoding UTF8)
                $keep  = @($lines | Where-Object { $_ -notmatch $rx })
                [System.IO.File]::WriteAllLines($hist, [string[]]$keep)
                Write-Host "[OK] Historial limpiado: $($lines.Count - $keep.Count) linea(s) eliminada(s) de $hist" -ForegroundColor Green
            }
        }

        $plain = $null
        if ($clientSecret) { $clientSecret.Dispose() }
        $clientSecret = $null
        [GC]::Collect()
    }
}
