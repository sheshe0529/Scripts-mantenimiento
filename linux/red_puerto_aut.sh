#!/bin/bash
# red_puerto_no_aut (V15)
# Deshabilita y detiene el servicio SERVICIO que mantiene abierto el puerto TCP PUERTO
# Parámetros
#   PUERTO              (INTEGER)  puerto TCP no autorizado que se quiere cerrar
#   SERVICIO            (STRING)   unidad que lo abre, con o sin el sufijo .service
#   PUERTOS_AUTORIZADOS (LISTA)    puertos autorizados
#   DETENIBLES          (LISTA)    servicios que se pueden deshabilitar (nombres con o sin .service)
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p PUERTO SERVICIO PUERTOS_AUTORIZADOS DETENIBLES >/dev/null 2>&1; then
    registrar "ESTADO=ENTRADA motivo=parametros"; exit 64
fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
puerto=$PUERTO
servicio=$SERVICIO
[[ $servicio == *.service ]] || servicio=$servicio.service
if [[ ! $puerto =~ ^[1-9][0-9]{0,4}$ ||
      ! $servicio =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*[.]service$ ]] ||
   (( puerto > 65535 )); then
    registrar "ESTADO=ENTRADA motivo=puerto_o_servicio"; exit 64
fi
if (( ${#PUERTOS_AUTORIZADOS[@]} == 0 )); then
    registrar "ESTADO=ENTRADA motivo=lista_puertos_invalida"; exit 64
fi
permitidos=
for elemento in "${PUERTOS_AUTORIZADOS[@]}"; do
    if [[ ! $elemento =~ ^[1-9][0-9]{0,4}$ ]] || (( elemento > 65535 )); then
        registrar "ESTADO=ENTRADA motivo=lista_puertos_invalida"; exit 64
    fi
    permitidos+="$elemento"$'\n'
done
registrar "OBSERVADO=puerto:$puerto servicio:$servicio"
if grep -Fxq -- "$puerto" <<< "$permitidos"; then
    registrar "ESTADO=SIN_CAMBIOS motivo=puerto_autorizado"; exit 0
fi
case "$puerto:$servicio" in
    22:*|3389:*|5985:*|5986:*|*:ssh*.service|*:sshd.service|*:firewalld.service|*:ufw.service|*:apparmor.service|\
    *:dbus*.service|*:systemd-*.service|*:NetworkManager*.service|*:auditd.service|*:polkit.service|\
    *:sssd*.service|*:cron.service|*:crond.service|*:rsyslog.service|*:chrony.service|*:chronyd.service)
        registrar "ESTADO=REVISION motivo=servicio_o_puerto_protegido"; exit 2 ;;
esac
detenible=0
for elemento in "${DETENIBLES[@]+"${DETENIBLES[@]}"}"; do
    if [[ ${elemento%.service} == "${servicio%.service}" ]]; then detenible=1; fi
done
if (( detenible == 0 )); then
    registrar "ESTADO=REVISION motivo=servicio_no_detenible"; exit 2
fi

# 1. Comprobar la escucha y su proceso titular
if ! escuchas=$(ss -H -ltnp "sport = :$puerto"); then
    registrar "ESTADO=ERROR motivo=consultar_puerto"; exit 1
fi
if [[ -z $escuchas ]]; then registrar "ESTADO=SIN_CAMBIOS"; exit 0; fi
if ! pid=$(systemctl show --value -p MainPID -- "$servicio") ||
   ! estado=$(systemctl show -p Id -p CanStop -p UnitFileState -p TriggeredBy -p RequiredBy -p BoundBy -p ConsistsOf -p PropagatesStopTo -- "$servicio"); then
    registrar "ESTADO=ERROR motivo=consultar_unidad"; exit 1
fi
if [[ ! $pid =~ ^[1-9][0-9]*$ || $pid == 1 ]] ||
   ! grep -Fxq "Id=$servicio" <<< "$estado" ||
   ! grep -Fxq 'CanStop=yes' <<< "$estado" ||
   ! grep -Eq '^UnitFileState=(enabled|disabled)$' <<< "$estado" ||
   grep -Eq '^(TriggeredBy|RequiredBy|BoundBy|ConsistsOf|PropagatesStopTo)=.+' <<< "$estado"; then
    registrar "ESTADO=REVISION motivo=unidad_no_segura"; exit 2
fi
while IFS= read -r linea; do
    titulares=$(grep -oE 'pid=[0-9]+,' <<< "$linea" | sort -u || true)
    if [[ $titulares != "pid=$pid," ]]; then
        registrar "ESTADO=REVISION motivo=puerto_compartido"; exit 2
    fi
done <<< "$escuchas"
if ! todas=$(ss -H -ltnp); then
    registrar "ESTADO=ERROR motivo=consultar_escuchas"; exit 1
fi
while read -r _ _ _ local_addr _ procesos; do
    if [[ $procesos == *"pid=$pid,"* ]] &&
       grep -Fxq -- "${local_addr##*:}" <<< "$permitidos"; then
        registrar "ESTADO=REVISION motivo=servicio_atiende_puerto_permitido"
        exit 2
    fi
done <<< "$todas"

# 2. Deshabilitar y verificar
if ! systemctl disable --now -- "$servicio"; then
    registrar "ESTADO=ERROR motivo=detener_servicio"; exit 1
fi
if ! escuchas=$(ss -H -ltn "sport = :$puerto") ||
   [[ -n $escuchas ]] ||
   [[ $(systemctl show --value -p UnitFileState -- "$servicio") != disabled ]]; then
    registrar "ESTADO=ERROR motivo=puerto_no_cerrado"; exit 1
fi
registrar "CAMBIO=puerto:TCP/$puerto servicio:$servicio accion:deshabilitado"
registrar "ESTADO=APLICADO"
