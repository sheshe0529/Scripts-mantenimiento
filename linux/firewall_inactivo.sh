#!/bin/bash
# firewall_inactivo (V16)
# Activa el cortafuegos local si está inactivo, permitiendo antes el puerto de sshd y los puertos indicados, para no cortar la gestión.
# Ubuntu y Debian usan ufw; RHEL 9 y derivados, firewalld. El paquete del cortafuegos debe estar instalado (la imagen de
# RHEL para EC2 no trae firewalld): si falta, el script responde REVISION.
# Parámetros
#   PUERTOS_PERMITIDOS (LISTA)  puertos TCP (enteros) que se permiten además del de sshd
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p PUERTOS_PERMITIDOS >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
for elemento in "${PUERTOS_PERMITIDOS[@]+"${PUERTOS_PERMITIDOS[@]}"}"; do
    if [[ ! $elemento =~ ^[1-9][0-9]{0,4}$ ]] || (( elemento > 65535 )); then
        registrar "ESTADO=ENTRADA motivo=puertos_invalidos"; exit 64
    fi
done

# Puertos de sshd y puertos indicados, sin repetir: se permiten antes de activar el cortafuegos
puertos_a_permitir() {
    if ! puertos_ssh=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}') || [[ -z $puertos_ssh ]]; then
        registrar "ESTADO=REVISION motivo=puerto_sshd_desconocido"; exit 2
    fi
    permitidos=$(printf '%s\n' $puertos_ssh "${PUERTOS_PERMITIDOS[@]+"${PUERTOS_PERMITIDOS[@]}"}" | sort -un)
}

activar_ufw() {
    # 1. Comprobar ufw
    if ! command -v ufw >/dev/null 2>&1; then
        registrar "ESTADO=REVISION motivo=ufw_no_instalado"; exit 2
    fi
    if systemctl is-active --quiet firewalld.service; then
        registrar "ESTADO=REVISION motivo=firewalld_activo"; exit 2
    fi
    if ! estado=$(ufw status); then registrar "ESTADO=ERROR motivo=consultar_firewall"; exit 1; fi
    registrar "OBSERVADO=ufw:$(awk -F': ' '/^Status:/ {print $2; exit}' <<< "$estado")"
    if grep -Fxq 'Status: active' <<< "$estado"; then
        if [[ $(systemctl is-enabled ufw.service 2>/dev/null || true) != enabled ]]; then
            if ! systemctl enable ufw.service >/dev/null 2>&1; then registrar "ESTADO=ERROR motivo=habilitar_firewall"; exit 1; fi
            registrar "CAMBIO=ufw:habilitado_en_el_arranque"
            registrar "ESTADO=APLICADO"; exit 0
        fi
        registrar "ESTADO=SIN_CAMBIOS"; exit 0
    fi

    # 2. Permitir la gestión (puertos de sshd) y los puertos indicados antes de activar
    puertos_a_permitir
    for puerto in $permitidos; do
        if ! ufw allow "$puerto/tcp" >/dev/null; then registrar "ESTADO=ERROR motivo=permitir_puerto puerto=$puerto"; exit 1; fi
    done
    registrar "OBSERVADO=puertos_permitidos:$(tr '\n' ',' <<< "$permitidos" | sed 's/,$//')"

    # 3. Activar y verificar
    if ! ufw --force enable >/dev/null; then registrar "ESTADO=ERROR motivo=habilitar_firewall"; exit 1; fi
    if ! ufw status | grep -Fxq 'Status: active'; then registrar "ESTADO=ERROR motivo=verificar_firewall"; exit 1; fi
    for puerto in $puertos_ssh; do
        if ! ufw status | grep -Eq "^$puerto/tcp[[:space:]]+ALLOW"; then registrar "ESTADO=ERROR motivo=verificar_ssh puerto=$puerto"; exit 1; fi
    done
    registrar "CAMBIO=ufw:activo_habilitado"
    registrar "ESTADO=APLICADO"
}

activar_firewalld() {
    # 1. Comprobar firewalld
    if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl cat firewalld.service >/dev/null 2>&1; then
        registrar "ESTADO=REVISION motivo=firewalld_no_instalado"; exit 2
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -Fxq 'Status: active'; then
        registrar "ESTADO=REVISION motivo=ufw_activo"; exit 2
    fi
    if ! estado=$(systemctl show -p LoadState -p ActiveState -p UnitFileState firewalld.service); then
        registrar "ESTADO=ERROR motivo=consultar_firewall"; exit 1
    fi
    registrar "OBSERVADO=firewalld:$(awk -F= '$1=="ActiveState" {print $2}' <<< "$estado")"
    if grep -Fxq 'ActiveState=active' <<< "$estado" &&
       grep -Fxq 'UnitFileState=enabled' <<< "$estado"; then
        if ! firewall-cmd --state >/dev/null; then
            registrar "ESTADO=REVISION motivo=firewall_sin_respuesta"; exit 2
        fi
        registrar "ESTADO=SIN_CAMBIOS"; exit 0
    fi
    if ! grep -Fxq 'LoadState=loaded' <<< "$estado" ||
       ! grep -Eq '^UnitFileState=(disabled|enabled|enabled-runtime)$' <<< "$estado" ||
       ! grep -Eq '^ActiveState=(active|inactive|failed)$' <<< "$estado"; then
        registrar "ESTADO=REVISION motivo=unidad_no_apta"; exit 2
    fi

    # 2. Permitir la gestión (puertos de sshd) y los puertos indicados antes de activar
    if ! firewall-offline-cmd --check-config >/dev/null; then
        registrar "ESTADO=REVISION motivo=configuracion_invalida"; exit 2
    fi
    ajustados=0
    if ! grep -Fxq 'ActiveState=active' <<< "$estado"; then
        puertos_a_permitir
        ajustados=1
        for puerto in $permitidos; do
            if ! firewall-offline-cmd --add-port="$puerto/tcp" >/dev/null; then
                registrar "ESTADO=ERROR motivo=permitir_puerto puerto=$puerto"; exit 1
            fi
        done
        registrar "OBSERVADO=puertos_permitidos:$(tr '\n' ',' <<< "$permitidos" | sed 's/,$//')"
    fi

    # 3. Activar y verificar
    if ! systemctl enable --now firewalld.service >/dev/null 2>&1; then
        registrar "ESTADO=ERROR motivo=habilitar_firewall"; exit 1
    fi
    if [[ $(systemctl is-enabled firewalld.service) != enabled ]] ||
       ! firewall-cmd --state >/dev/null 2>&1; then
        registrar "ESTADO=ERROR motivo=verificar_firewall"; exit 1
    fi
    if (( ajustados == 1 )); then
        for puerto in $puertos_ssh; do
            if ! firewall-cmd --query-port="$puerto/tcp" >/dev/null 2>&1; then
                registrar "ESTADO=ERROR motivo=verificar_ssh puerto=$puerto"; exit 1
            fi
        done
    fi
    registrar "CAMBIO=firewalld:activo_habilitado"
    registrar "ESTADO=APLICADO"
}

# 0. Elegir el cortafuegos según la distribución
if [[ ! -r /etc/os-release ]]; then
    registrar "ESTADO=REVISION motivo=so_no_identificado"; exit 2
fi
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian)                           activar_ufw ;;
    rhel|rocky|almalinux|centos|fedora|amzn) activar_firewalld ;;
    *) registrar "ESTADO=REVISION motivo=so_no_soportado"; exit 2 ;;
esac
