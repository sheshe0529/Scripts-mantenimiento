#!/bin/bash
# cpu_uso (V01), cpu_load (V02), cpu_iowait (V03), mem_uso (V04), swap_uso (V05), swap_act (V06) y disco_latencia (V08)
# Reinicia el servicio SERVICIO, que es el que degrada el servidor, y verifica que arranque una instancia nueva.
# Parámetros
#   SERVICIO (STRING) unidad a reiniciar, con o sin el sufijo .service
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

# 2. Verificar estado, permisos y dependencias
if ! estado=$(systemctl show -p Id -p LoadState -p ActiveState -p SubState -p InvocationID \
    -p CanStart -p CanStop -p TriggeredBy -p RequiredBy -p BoundBy \
    -p ConsistsOf -p PropagatesStopTo -- "$servicio"); then
    registrar "ESTADO=ERROR motivo=consultar_servicio"; exit 1
fi

activo=$(awk -F= '$1=="ActiveState" {print $2}' <<< "$estado")
invocacion=$(awk -F= '$1=="InvocationID" {print $2}' <<< "$estado")
registrar "OBSERVADO=servicio:$servicio estado:$activo invocacion:$invocacion"

if ! grep -Fxq "Id=$servicio" <<< "$estado" ||
   ! grep -Fxq 'LoadState=loaded' <<< "$estado" ||
   ! grep -Fxq 'ActiveState=active' <<< "$estado" ||
   ! grep -Fxq 'SubState=running' <<< "$estado" ||
   [[ ! $invocacion =~ ^[a-f0-9]{32}$ ]] ||
   ! grep -Fxq 'CanStart=yes' <<< "$estado" ||
   ! grep -Fxq 'CanStop=yes' <<< "$estado" ||
   grep -Eq '^(TriggeredBy|RequiredBy|BoundBy|ConsistsOf|PropagatesStopTo)=.+' <<< "$estado"; then
    registrar "ESTADO=REVISION motivo=instancia_o_dependencias"; exit 2
fi

# 3. Reiniciar y verificar
if ! systemctl restart -- "$servicio"; then
    registrar "ESTADO=ERROR motivo=reinicio_fallido"; exit 1
fi
if ! nueva=$(systemctl show --value -p InvocationID -- "$servicio") ||
   [[ ! $nueva =~ ^[a-f0-9]{32}$ || $nueva == "$invocacion" ]] ||
   ! systemctl is-active --quiet "$servicio" ||
   [[ $(systemctl show --value -p SubState -- "$servicio") != running ]]; then
    registrar "ESTADO=ERROR motivo=reinicio_no_verificado"; exit 1
fi

registrar "CAMBIO=servicio:$servicio nueva_invocacion:$nueva"
registrar "AVISO=volver_a_medir:cpu_uso"
registrar "ESTADO=APLICADO"
