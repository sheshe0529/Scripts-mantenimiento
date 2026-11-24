#!/bin/bash
# admin_block_passwd (V12)
# Bloquea la contraseña de la cuenta root (passwd -l). Impide la autenticación mediante contraseña de root.
# No actúa si la sesión de KomainOS se elevó con su (usa esa contraseña): responde REVISION.
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# 1. Validar permisos y disponibilidad
if [[ $EUID -ne 0 ]]; then
    registrar "ESTADO=ERROR motivo=requiere_root"; exit 1
fi
if ! command -v passwd >/dev/null 2>&1; then
    registrar "ESTADO=REVISION motivo=passwd_no_disponible"; exit 2
fi

# La elevación con su usa la contraseña de root: bloquearla dejaría a KomainOS sin acceso administrativo al servidor
pid=$PPID
while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    if [[ $(cat "/proc/$pid/comm" 2>/dev/null || true) == su ]]; then
        registrar "ESTADO=REVISION motivo=sesion_elevada_con_su"; exit 2
    fi
    pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
done

# 2. Consultar estado de la contraseña root
if ! estado=$(passwd -S root 2>/dev/null); then
    registrar "ESTADO=ERROR motivo=consultar_root"; exit 1
fi
situacion=$(awk '$1=="root" {print $2}' <<< "$estado")

case "$situacion" in
    L|LK)
        registrar "OBSERVADO=root_contrasena:bloqueada"
        registrar "ESTADO=SIN_CAMBIOS"
        exit 0 ;;
    P|PS|NP)
        registrar "OBSERVADO=root_contrasena:no_bloqueada" ;;
    *)
        registrar "ESTADO=REVISION motivo=estado_root_desconocido"
        exit 2 ;;
esac

# 3. Bloquear contraseña de root
if ! passwd -l root >/dev/null 2>&1; then
    registrar "ESTADO=ERROR motivo=bloqueo_fallido"; exit 1
fi

# 4. Verificar bloqueo
if ! estado=$(passwd -S root 2>/dev/null); then
    registrar "ESTADO=ERROR motivo=verificar_root"; exit 1
fi
situacion=$(awk '$1=="root" {print $2}' <<< "$estado")
if [[ $situacion != L && $situacion != LK ]]; then
    registrar "ESTADO=ERROR motivo=bloqueo_no_verificado"; exit 1
fi

registrar "CAMBIO=root_contrasena:bloqueada"
registrar "ESTADO=APLICADO"