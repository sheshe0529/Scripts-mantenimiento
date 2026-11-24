#!/bin/bash
# admin_acceso (V11)
# Fija PermitRootLogin no en /etc/ssh/sshd_config con respaldo, validación y recuperación. No tiene parámetros.
# Solo cierra el acceso directo por SSH (V11): el bloqueo de la contraseña de root (V12) es de admin_block_passwd.sh.
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

config=/etc/ssh/sshd_config

# 1. Validar archivo y permisos
if [[ $EUID -ne 0 || ! -f "$config" || -L "$config" ]]; then
    registrar "ESTADO=REVISION motivo=archivo_o_permisos"
    exit 2
fi
if [[ $(stat -c '%u' "$config") != 0 ]]; then
    registrar "ESTADO=REVISION motivo=propietario"
    exit 2
fi

# 2. Validar SSH
if ! /usr/sbin/sshd -t -f "$config" ||
   ! systemctl is-active --quiet sshd.service; then
    registrar "ESTADO=REVISION motivo=sshd_invalido"
    exit 2
fi
if grep -Eiq '^[[:space:]]*Match([[:space:]]|$)' "$config"; then
    registrar "ESTADO=REVISION motivo=match"
    exit 2
fi

# 3. Consultar valor inicial
if ! estado=$(/usr/sbin/sshd -T -f "$config"); then
    registrar "ESTADO=ERROR motivo=consulta_ssh"
    exit 1
fi
inicial=$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "$estado")
registrar "OBSERVADO=PermitRootLogin:$inicial"
if [[ "$inicial" == no ]]; then
    registrar "ESTADO=SIN_CAMBIOS"
    exit 0
fi
if ! grep -Eiq '^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]=]+' "$config"; then
    registrar "ESTADO=REVISION motivo=directiva_ausente"
    exit 2
fi

# 4. Crear respaldo protegido
if ! respaldo=$(mktemp /etc/ssh/.komainos.XXXXXXXX); then
    registrar "ESTADO=ERROR motivo=crear_respaldo"
    exit 1
fi
if ! cp -- "$config" "$respaldo" || ! chmod 600 "$respaldo"; then
    rm -f -- "$respaldo" || true
    registrar "ESTADO=ERROR motivo=respaldo"
    exit 1
fi

# 5. Modificar y validar
if sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]=]+.*/PermitRootLogin no/I' "$config" &&
   /usr/sbin/sshd -t -f "$config" &&
   estado=$(/usr/sbin/sshd -T -f "$config") &&
   grep -Fxq "permitrootlogin no" <<< "$estado" &&
   systemctl reload sshd.service &&
   systemctl is-active --quiet sshd.service; then
    registrar "CAMBIO=PermitRootLogin:no"
    rm -f -- "$respaldo" || registrar "AVISO=limpieza_pendiente:$respaldo"
    registrar "ESTADO=APLICADO"
    exit 0
fi

# 6. Recuperar si falla
if cp -- "$respaldo" "$config" &&
   /usr/sbin/sshd -t -f "$config" &&
   systemctl reload sshd.service &&
   systemctl is-active --quiet sshd.service; then
    rm -f -- "$respaldo" || registrar "AVISO=limpieza_pendiente:$respaldo"
    registrar "ESTADO=ERROR recuperacion=OK"
else
    registrar "ESTADO=ERROR recuperacion=FALLIDA respaldo=$respaldo"
fi
exit 1
