#!/bin/bash
# serv_no_operativo (V19)
# Inicia el servicio requerido SERVICIO si está caído.
# Parámetros
#   SERVICIO (STRING) unidad a iniciar, con o sin el sufijo .service
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p SERVICIO >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
servicio=$SERVICIO
[[ $servicio == *.service ]] || servicio=$servicio.service
if [[ ! $servicio =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*[.]service$ ]]; then
    registrar "ESTADO=ENTRADA motivo=servicio"; exit 64
fi

# 1. Revisar estado y condiciones de inicio
if ! estado=$(systemctl show -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Type -p CanStart -- "$servicio"); then
    registrar "ESTADO=ERROR motivo=consultar_unidad"; exit 1
fi
registrar "OBSERVADO=servicio:$servicio estado:$(awk -F= '$1=="SubState" {print $2}' <<< "$estado")"
if grep -Fxq "Id=$servicio" <<< "$estado" &&
   grep -Fxq 'SubState=running' <<< "$estado"; then
    registrar "ESTADO=SIN_CAMBIOS"; exit 0
fi
if ! grep -Fxq "Id=$servicio" <<< "$estado" ||
   ! grep -Fxq 'LoadState=loaded' <<< "$estado" ||
   ! grep -Eq '^ActiveState=(inactive|failed)$' <<< "$estado" ||
   ! grep -Fxq 'CanStart=yes' <<< "$estado" ||
   ! grep -Eq '^UnitFileState=(enabled|enabled-runtime|static)$' <<< "$estado" ||
   grep -Fxq 'Type=oneshot' <<< "$estado"; then
    registrar "ESTADO=REVISION motivo=unidad_no_apta"; exit 2
fi

# 2. Iniciar y verificar
if ! systemctl start -- "$servicio"; then
    registrar "ESTADO=ERROR motivo=inicio_fallido"; exit 1
fi
if [[ $(systemctl show --value -p SubState -- "$servicio") != running ]]; then
    registrar "ESTADO=ERROR motivo=servicio_no_running"; exit 1
fi
registrar "CAMBIO=servicio:$servicio estado:running"
registrar "ESTADO=APLICADO"