#requires -Version 5.1
# firewall_inactivo (V16)
# Inicia BFE y MpsSvc y activa los tres perfiles del firewall.
# No tiene parámetros.

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

    # Activar servicios y perfiles de Windows Defender Firewall.
    $servicios = @(Get-Service -Name BFE, MpsSvc)
    if ($servicios.Count -ne 2 -or @($servicios | Where-Object StartType -eq 'Disabled').Count) {
        Registrar 'ESTADO=REVISION motivo=servicios_firewall_inhabilitados'
        exit 2
    }
    $perfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($perfiles.Count -ne 3) {
        Registrar 'ESTADO=REVISION motivo=perfiles_no_disponibles'
        exit 2
    }
    $inactivos = @($perfiles | Where-Object Enabled -ne 'True')
    $detenidos = @($servicios | Where-Object Status -ne 'Running')
    Registrar "OBSERVADO=firewall_perfiles_inactivos:$($inactivos.Count) servicios_detenidos:$($detenidos.Count)"
    if (-not $inactivos.Count -and -not $detenidos.Count) {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    # No cambiar firewall cuando la cuenta remota depende de WinRM inactivo.
    if ((Get-Service -Name WinRM).Status -ne 'Running') {
        Registrar 'ESTADO=REVISION motivo=winrm_inactivo'
        exit 2
    }
    foreach ($nombre in @('BFE','MpsSvc')) {
        $servicio = Get-Service -Name $nombre
        if ($servicio.Status -ne 'Running') { Start-Service -Name $nombre }
        $servicio.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    $inactivos = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object Enabled -ne 'True')
    if ($inactivos.Count) {
        Set-NetFirewallProfile -PolicyStore PersistentStore -Profile $inactivos.Name -Enabled True
    }
    $perfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($perfiles.Count -ne 3 -or @($perfiles | Where-Object Enabled -ne 'True').Count) {
        Registrar 'ESTADO=REVISION motivo=perfiles_no_aplicados_revisar_gpo'
        exit 2
    }
    Registrar 'CAMBIO=firewall:servicios_y_perfiles_activos'
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
