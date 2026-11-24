#requires -Version 5.1
# admin_no_aut (V13)
# Retira del grupo local Administradores a las cuentas locales que no figuran en AUTORIZADOS.
# Parámetros
#   AUTORIZADOS  (LISTA)    cuentas que pueden quedarse: nombre (sin equipo) o SID; por ejemplo "Cuentas administradoras
#                           Windows". No distingue mayúsculas
#   MAX_CUENTAS  (INTEGER)  si hay más cuentas no autorizadas que esta cifra no se toca ninguna (1 a 100)
# Descubre las cuentas por sí mismo: KomainOS no le entrega la cuenta infractora.
# No se retira a la cuenta integrada (RID 500), a la cuenta que ejecuta el script ni a grupos o cuentas de dominio (esos
# casos terminan en REVISION). No actúa en un controlador de dominio.

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

    if ($null -eq $AUTORIZADOS -or $null -eq $MAX_CUENTAS) {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $maximo = [int]$MAX_CUENTAS
    if ($maximo -lt 1 -or $maximo -gt 100) {
        Registrar 'ESTADO=ENTRADA motivo=grupo_o_limite'
        exit 64
    }
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
        Registrar 'ESTADO=REVISION motivo=controlador_dominio'
        exit 2
    }
    $autorizadas = @($AUTORIZADOS | ForEach-Object { [string]$_ })
    $grupo = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $miembros = @(Get-LocalGroupMember -SID $grupo)
    Registrar "OBSERVADO=grupo:Administradores miembros:$($miembros.Count)"

    # Separar las cuentas que se pueden retirar de las que requieren revision
    $candidatas = @(); $revisar = @()
    foreach ($miembro in $miembros) {
        $sid = if ($miembro.SID) { $miembro.SID.Value } else { '' }
        $corto = ([string]$miembro.Name).Split('\')[-1]
        if ($corto -in $autorizadas -or ($sid -and $sid -in $autorizadas)) { continue }
        if ($sid -match '-500$' -or $sid -eq $identidad.User.Value) { $revisar += "${corto}:cuenta_protegida"; continue }
        if ($miembro.ObjectClass -ne 'User' -or $miembro.PrincipalSource -ne 'Local') {
            $revisar += "${corto}:objetivo_no_es_usuario_local"; continue
        }
        $candidatas += $miembro
    }
    if ($candidatas.Count -gt $maximo) {
        Registrar "ESTADO=REVISION motivo=demasiadas_cuentas cuentas=$($candidatas.Count) maximo=$maximo"
        exit 2
    }
    if (-not $candidatas.Count -and -not $revisar.Count) {
        Registrar 'ESTADO=SIN_CAMBIOS motivo=sin_cuentas_no_autorizadas'
        exit 0
    }

    # Retirar y comprobar la membresia
    foreach ($miembro in $candidatas) {
        Remove-LocalGroupMember -SID $grupo -Member $miembro
        $quedan = @(Get-LocalGroupMember -SID $grupo | Where-Object { $_.SID -and $_.SID.Value -eq $miembro.SID.Value })
        if ($quedan.Count) {
            Registrar "ESTADO=ERROR motivo=membresia_persistente cuenta=$($miembro.Name)"
            exit 1
        }
        Registrar "CAMBIO=membresia_administradores:retirada cuenta=$($miembro.Name) sid=$($miembro.SID.Value)"
    }
    if ($revisar.Count) {
        Registrar "ESTADO=REVISION motivo=cuentas_sin_retirar detalle=$($revisar -join ',')"
        exit 2
    }
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
