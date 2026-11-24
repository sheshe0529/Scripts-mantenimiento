#requires -Version 5.1
# red_puerto_no_aut (V15)
# Detiene y deshabilita el servicio SERVICIO que mantiene abierto el puerto TCP PUERTO, si el puerto no está autorizado.
# Parámetros
#   PUERTO               (INTEGER)  puerto TCP no autorizado que se quiere cerrar
#   SERVICIO             (STRING)   nombre corto del servicio que lo abre (Own Process)
#   PUERTOS_AUTORIZADOS  (LISTA)    puertos autorizados, por ejemplo "Puertos autorizados Windows" (enteros)
#   DETENIBLES           (LISTA)    servicios que se pueden deshabilitar

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

    # Detener y deshabilitar un servicio responsable de un puerto no autorizado.
    if ($null -eq $PUERTO -or $null -eq $SERVICIO -or $null -eq $PUERTOS_AUTORIZADOS -or $null -eq $DETENIBLES) {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $puerto = [int]$PUERTO
    $servicio = [string]$SERVICIO
    if ($puerto -lt 1 -or $puerto -gt 65535 -or $servicio -notmatch '^[A-Za-z0-9][A-Za-z0-9_.@ $-]{0,255}$') {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $permitidos = @($PUERTOS_AUTORIZADOS | ForEach-Object { [string]$_ })
    if (-not $permitidos.Count -or @($permitidos | Where-Object {
        $_ -notmatch '^[1-9][0-9]{0,4}$' -or [int]$_ -gt 65535 }).Count) {
        Registrar 'ESTADO=ENTRADA motivo=puertos_invalidos'
        exit 64
    }
    if ([string]$puerto -in $permitidos) {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    if ($puerto -in @(22,3389,5985,5986)) {
        Registrar 'ESTADO=REVISION motivo=puerto_administracion'
        exit 2
    }
    $protegidos = @('WinRM','TermService','sshd','MpsSvc','BFE','RpcSs','RpcEptMapper',
        'DcomLaunch','Dhcp','Dnscache','Netlogon','NTDS','LanmanWorkstation','LanmanServer',
        'EventLog','Schedule','CryptSvc','W32Time')
    if ($servicio -in $protegidos) {
        Registrar 'ESTADO=REVISION motivo=servicio_protegido'
        exit 2
    }
    $listaDetenibles = @($DETENIBLES | ForEach-Object { [string]$_ })
    if ($servicio -notin $listaDetenibles) {
        Registrar 'ESTADO=REVISION motivo=servicio_no_autorizado'
        exit 2
    }
    $escuchas = @(Get-NetTCPConnection | Where-Object State -eq 'Listen')
    $objetivo = @($escuchas | Where-Object LocalPort -eq $puerto)
    Registrar "OBSERVADO=puerto_tcp:$puerto escuchas=$($objetivo.Count)"
    if (-not $objetivo.Count) {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    $serv = Get-CimInstance Win32_Service -Filter "Name = '$servicio'"
    if (-not $serv -or $serv.State -ne 'Running' -or $serv.ServiceType -ne 'Own Process' -or
        $serv.ProcessId -le 4 -or
        @($objetivo | Where-Object OwningProcess -ne $serv.ProcessId).Count -or
        @($escuchas | Where-Object { $_.OwningProcess -eq $serv.ProcessId -and
            [string]$_.LocalPort -in $permitidos }).Count) {
        Registrar 'ESTADO=REVISION motivo=puerto_compartido_o_titular_distinto'
        exit 2
    }
    $sc = Get-Service -Name $servicio
    if (-not $sc.CanStop -or @($sc.DependentServices | Where-Object Status -ne 'Stopped').Count) {
        Registrar 'ESTADO=REVISION motivo=servicio_no_detenible'
        exit 2
    }
    $inicioServicio = $sc.StartType
    try {
        Set-Service -Name $servicio -StartupType Disabled
        Stop-Service -Name $servicio
        (Get-Service -Name $servicio).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        if (@(Get-NetTCPConnection | Where-Object { $_.State -eq 'Listen' -and $_.LocalPort -eq $puerto }).Count -or
            (Get-CimInstance Win32_Service -Filter "Name = '$servicio'").StartMode -ne 'Disabled') {
            throw 'El puerto sigue en escucha o el servicio no quedo deshabilitado.'
        }
    }
    catch {
        # Intentar devolver el servicio a su configuracion inicial.
        try {
            Set-Service -Name $servicio -StartupType $inicioServicio
            if ((Get-Service -Name $servicio).Status -eq 'Stopped') { Start-Service -Name $servicio }
        }
        catch { Write-Error -Message "Recuperacion del servicio fallida: $($_.Exception.Message)" -ErrorAction Continue }
        throw
    }
    Registrar "CAMBIO=puerto_tcp:$puerto cerrado servicio=$servicio estado=Disabled"
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
