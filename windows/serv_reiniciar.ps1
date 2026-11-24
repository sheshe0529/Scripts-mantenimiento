#requires -Version 5.1
# cpu_uso (V01), mem_uso (V04), swap_uso (V05), swap_act (V06) y disco_latencia (V08)
# Reinicia el servicio SERVICIO, que es el que degrada el servidor, y verifica que arrancó un proceso nuevo.
# Parámetros
#   SERVICIO (STRING) nombre corto del servicio (por ejemplo Spooler), de tipo Own Process

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

    # Reiniciar un servicio concreto y autorizado.
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
    if (-not $serv -or $serv.State -ne 'Running' -or $serv.ServiceType -ne 'Own Process' -or
        $serv.ProcessId -le 4) {
        Registrar 'ESTADO=REVISION motivo=instancia_o_servicio'
        exit 2
    }
    $pidAntes = [int]$serv.ProcessId
    $inicioAntes = (Get-Process -Id $pidAntes).StartTime.ToUniversalTime().Ticks
    $sc = Get-Service -Name $servicio
    if (-not $sc.CanStop -or @($sc.DependentServices | Where-Object Status -ne 'Stopped').Count) {
        Registrar 'ESTADO=REVISION motivo=proceso_o_dependencias'
        exit 2
    }
    Registrar "OBSERVADO=servicio:$servicio pid=$pidAntes inicio_utc_ticks=$inicioAntes"
    Restart-Service -Name $servicio
    (Get-Service -Name $servicio).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    $nuevo = Get-CimInstance Win32_Service -Filter "Name = '$servicio'"
    if ($nuevo.State -ne 'Running' -or $nuevo.ProcessId -le 4) {
        Registrar 'ESTADO=ERROR motivo=reinicio_no_verificado'
        exit 1
    }
    if ($nuevo.ProcessId -eq $pidAntes -and
        (Get-Process -Id $pidAntes).StartTime.ToUniversalTime().Ticks -eq $inicioAntes) {
        Registrar 'ESTADO=ERROR motivo=proceso_no_reiniciado'
        exit 1
    }
    Registrar "CAMBIO=servicio:$servicio reiniciado nuevo_pid=$($nuevo.ProcessId)"
    Registrar "AVISO=volver_a_medir:cpu_uso"
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
