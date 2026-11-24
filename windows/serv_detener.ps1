#requires -Version 5.1
# serv_no_perm (V20)
# Detiene y deshabilita el servicio no permitido SERVICIO, que se encuentra en ejecución.
# Parámetros
#   SERVICIO (STRING) nombre corto del servicio (por ejemplo Spooler), de tipo Own Process o Share Process

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

    # Detener y deshabilitar un servicio concreto que no esta permitido.
    if ($null -eq $SERVICIO -or
        [string]$SERVICIO -notmatch '^[A-Za-z0-9][A-Za-z0-9_.@ $-]{0,255}$') {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $servicio = [string]$SERVICIO
    $protegidos = @('WinRM','TermService','sshd','MpsSvc','BFE','RpcSs','RpcEptMapper',
        'DcomLaunch','Dhcp','Dnscache','Netlogon','NTDS','LanmanWorkstation','LanmanServer',
        'EventLog','Schedule','CryptSvc','W32Time')
    if ($servicio -in $protegidos) {
        Registrar 'ESTADO=REVISION motivo=servicio_protegido'
        exit 2
    }
    # El nombre esta validado antes de utilizarlo en la consulta CIM.
    $serv = Get-CimInstance Win32_Service -Filter "Name = '$servicio'"
    if (-not $serv) {
        Registrar 'ESTADO=REVISION motivo=servicio_inexistente'
        exit 2
    }
    Registrar "OBSERVADO=servicio:$servicio estado=$($serv.State) inicio=$($serv.StartMode)"
    if ($serv.State -eq 'Stopped' -and $serv.StartMode -eq 'Disabled') {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    $sc = Get-Service -Name $servicio
    if ($serv.ServiceType -notin @('Own Process','Share Process') -or
        ($serv.State -eq 'Running' -and -not $sc.CanStop) -or
        @($sc.DependentServices | Where-Object Status -ne 'Stopped').Count) {
        Registrar 'ESTADO=REVISION motivo=proceso_o_dependencias'
        exit 2
    }
    Set-Service -Name $servicio -StartupType Disabled
    if ((Get-Service -Name $servicio).Status -ne 'Stopped') {
        Stop-Service -Name $servicio
        (Get-Service -Name $servicio).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    $despues = Get-CimInstance Win32_Service -Filter "Name = '$servicio'"
    if ($despues.State -ne 'Stopped' -or $despues.StartMode -ne 'Disabled') {
        Registrar 'ESTADO=ERROR motivo=detencion_no_verificada'
        exit 1
    }
    Registrar "CAMBIO=servicio:$servicio estado=Stopped inicio=Disabled"
    Registrar 'AVISO=volver_a_medir:serv_no_perm'
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
