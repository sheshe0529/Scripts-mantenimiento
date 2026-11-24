#!/bin/bash
# serv_no_perm (V20)
# Detiene y deshabilita el servicio no permitido SERVICIO, que se encuentra en ejecución.
# Parámetros
#   SERVICIO (STRING) unidad a detener y deshabilitar, con o sin el sufijo .service
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p SERVICIO >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
servicio=$SERVICIO
[[ $servicio == *.service ]] || servicio=$servicio.service

# 1. Validar el servicio indicado
if [[ ! $servicio =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*[.]service$ ]]; then
    registrar "ESTADO=ENTRADA motivo=servicio"; exit 64
fi
case "$servicio" in
    ssh*.service|sshd.service|firewalld.service|ufw.service|apparmor.service|dbus*.service|systemd-*.service|\
    NetworkManager*.service|auditd.service|polkit.service|sssd*.service|cron.service|crond.service|\
    rsyslog.service|chrony.service|chronyd.service)
        registrar "ESTADO=REVISION motivo=servicio_protegido"; exit 2 ;;
esac

# 2. Verificar estado y dependencias
if ! estado=$(systemctl show -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p CanStop \
    -p TriggeredBy -p RequiredBy -p BoundBy -p ConsistsOf -p PropagatesStopTo -- "$servicio"); then
    registrar "ESTADO=ERROR motivo=consultar_servicio"; exit 1
fi
activo=$(awk -F= '$1=="ActiveState" {print $2}' <<< "$estado")
subestado=$(awk -F= '$1=="SubState" {print $2}' <<< "$estado")
habilitado=$(awk -F= '$1=="UnitFileState" {print $2}' <<< "$estado")
registrar "OBSERVADO=servicio:$servicio estado:$activo habilitacion:$habilitado"

if grep -Fxq "Id=$servicio" <<< "$estado" &&
   [[ $activo == inactive && $habilitado == disabled ]]; then
    registrar "ESTADO=SIN_CAMBIOS"; exit 0
fi
if ! grep -Fxq "Id=$servicio" <<< "$estado" ||
   ! grep -Fxq 'LoadState=loaded' <<< "$estado" ||
   [[ ! $activo =~ ^(active|inactive|failed)$ ]] ||
   [[ ! $habilitado =~ ^(enabled|enabled-runtime|disabled)$ ]] ||
   { [[ $activo == active ]] && [[ $subestado != running ]]; } ||
   { [[ $activo == active ]] && ! grep -Fxq 'CanStop=yes' <<< "$estado"; } ||
   grep -Eq '^(TriggeredBy|RequiredBy|BoundBy|ConsistsOf|PropagatesStopTo)=.+' <<< "$estado"; then
    registrar "ESTADO=REVISION motivo=instancia_o_dependencias"; exit 2
fi

# 3. Detener, deshabilitar y verificar
if ! systemctl disable --now -- "$servicio"; then
    registrar "ESTADO=ERROR motivo=detencion_o_deshabilitacion_fallida"; exit 1
fi
if ! estado=$(systemctl show -p ActiveState -p UnitFileState -- "$servicio"); then
    registrar "ESTADO=ERROR motivo=verificacion_fallida"; exit 1
fi
if ! grep -Fxq 'ActiveState=inactive' <<< "$estado" ||
   ! grep -Fxq 'UnitFileState=disabled' <<< "$estado"; then
    registrar "ESTADO=ERROR motivo=detencion_o_deshabilitacion_no_verificada"; exit 1
fi
registrar "CAMBIO=servicio:$servicio estado:detenido habilitacion:deshabilitado"
registrar "AVISO=volver_a_medir:serv_no_perm"
registrar "ESTADO=APLICADO"
