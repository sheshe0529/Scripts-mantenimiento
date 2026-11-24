#requires -Version 5.1
# serv_no_operativo (V19)
# Inicia el servicio requerido SERVICIO si está detenido.
# Parámetros
#   SERVICIO (STRING) nombre corto del servicio (por ejemplo Spooler)

$ErrorActionPreference = 'Stop'

function Registrar([string]$Mensaje) {
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Mensaje"
}

try {
    # La cuenta usada por Ansible/WinRM debe contar con token administrativo.
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrador = [Security.Principal.WindowsPrincipal]::new($identidad)
    if (-not $administrador.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Registrar 'ESTADO=REVISION motivo=permisos_administrativos'
        exit 2
    }

    # Iniciar un servicio requerido y actualmente detenido.
    if ($null -eq $SERVICIO -or
        [string]$SERVICIO -notmatch '^[A-Za-z0-9][A-Za-z0-9_.@ $-]{0,255}$') {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $servicio = [string]$SERVICIO
    $serv = Get-CimInstance Win32_Service -Filter "Name = '$servicio'"
    if (-not $serv) {
        Registrar 'ESTADO=REVISION motivo=servicio_inexistente'
        exit 2
    }
    Registrar "OBSERVADO=servicio:$servicio estado=$($serv.State)"
    if ($serv.State -eq 'Running') {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    if ($serv.StartMode -eq 'Disabled' -or $serv.State -ne 'Stopped' -or
        $serv.ServiceType -notin @('Own Process','Share Process')) {
        Registrar 'ESTADO=REVISION motivo=servicio_no_iniciable'
        exit 2
    }
    Start-Service -Name $servicio
    (Get-Service -Name $servicio).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Registrar "CAMBIO=servicio:$servicio estado=Running"
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
