#requires -Version 5.1
# admin_block_passwd (V12)
# Deshabilita la cuenta integrada de administrador (RID 500). En Windows también resuelve admin_acceso (V11), que exige
# esa cuenta habilitada.
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

    # Deshabilitar la cuenta integrada de administrador local (RID 500).
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
        Registrar 'ESTADO=REVISION motivo=controlador_dominio'
        exit 2
    }
    $cuentas = @(Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' })
    if ($cuentas.Count -ne 1) {
        Registrar 'ESTADO=REVISION motivo=cuenta_integrada_no_identificada'
        exit 2
    }
    $cuenta = $cuentas[0]
    if ($identidad.User.Value -eq $cuenta.SID.Value) {
        Registrar 'ESTADO=REVISION motivo=ejecucion_con_cuenta_objetivo'
        exit 2
    }
    Registrar "OBSERVADO=administrador_integrado:$($cuenta.Enabled)"
    if (-not $cuenta.Enabled) {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    Disable-LocalUser -SID $cuenta.SID
    if ((Get-LocalUser -SID $cuenta.SID).Enabled) {
        Registrar 'ESTADO=ERROR motivo=cuenta_sigue_habilitada'
        exit 1
    }
    Registrar 'CAMBIO=administrador_integrado:deshabilitado'
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
