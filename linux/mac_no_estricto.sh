#!/bin/bash
# mac_no_estricto (V17)
# Devuelve el control de acceso obligatorio a un estado estricto. Ubuntu y Debian usan AppArmor; RHEL 9 y derivados, SELinux.
# AppArmor: inicia y habilita apparmor.service y, si el servicio figura activo pero no hay perfiles en enforce (por ejemplo tras
# aa-teardown), lo reinicia para recargar /etc/apparmor.d. No cambia el modo de ningún perfil (aa-complain/aa-enforce modifican
# archivos de /etc/apparmor.d): si los perfiles instalados están todos en complain, o AppArmor está deshabilitado en el kernel
# (apparmor=0), responde REVISION.
# SELinux: lo devuelve a Enforcing (en ejecución y en /etc/selinux/config). No actúa si SELinux está deshabilitado (exige reinicio
# y reetiquetado) ni si el arranque lleva enforcing=0 o selinux=0: responde REVISION.
# No tiene parámetros.
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

perfiles=/sys/kernel/security/apparmor/profiles
enforce() { grep -c ' (enforce)$' "$perfiles" 2>/dev/null || true; }

restaurar_apparmor() {
    # 1. AppArmor debe estar habilitado en el kernel
    if [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true) != Y ]]; then
        registrar "ESTADO=REVISION motivo=apparmor_no_habilitado_en_kernel"; exit 2
    fi
    if grep -Eq '(^|[[:space:]])apparmor=0([[:space:]]|$)' /proc/cmdline; then
        registrar "ESTADO=REVISION motivo=parametros_arranque"; exit 2
    fi
    if ! systemctl cat apparmor.service >/dev/null 2>&1; then registrar "ESTADO=REVISION motivo=servicio_apparmor_ausente"; exit 2; fi
    cambios=0
    registrar "OBSERVADO=perfiles_enforce:$(enforce) apparmor:$(systemctl is-active apparmor.service || true)/$(systemctl is-enabled apparmor.service 2>/dev/null || true)"

    # 2. Servicio activo y habilitado: carga los perfiles instalados
    if ! systemctl is-active --quiet apparmor.service || [[ $(systemctl is-enabled apparmor.service 2>/dev/null || true) != enabled ]]; then
        if ! systemctl enable --now apparmor.service >/dev/null 2>&1; then registrar "ESTADO=ERROR motivo=iniciar_apparmor"; exit 1; fi
        registrar "CAMBIO=apparmor:servicio_activo_habilitado"
        cambios=1
    fi

    # 3. Servicio activo pero sin perfiles en enforce: recargar
    if (( $(enforce) == 0 )); then
        if ! systemctl restart apparmor.service; then registrar "ESTADO=ERROR motivo=recargar_apparmor"; exit 1; fi
        registrar "CAMBIO=apparmor:perfiles_recargados perfiles_enforce:$(enforce)"
        cambios=1
    fi
    if (( $(enforce) == 0 )); then
        registrar "ESTADO=REVISION motivo=sin_perfiles_en_enforce"; exit 2
    fi
    if (( cambios == 0 )); then registrar "ESTADO=SIN_CAMBIOS"; exit 0; fi
    registrar "ESTADO=APLICADO"
}

restaurar_selinux() {
    config=/etc/selinux/config

    # 1. Verificar SELinux y archivo principal
    if ! command -v getenforce >/dev/null 2>&1; then registrar "ESTADO=REVISION motivo=selinux_no_instalado"; exit 2; fi
    if ! modo=$(getenforce); then registrar "ESTADO=ERROR motivo=consultar_selinux"; exit 1; fi
    if [[ $modo != Permissive && $modo != Enforcing ]]; then
        registrar "ESTADO=REVISION motivo=selinux_deshabilitado"; exit 2
    fi
    if [[ ! -f $config || -L $config || $(stat -c '%u' -- "$config") != 0 ]]; then
        registrar "ESTADO=REVISION motivo=archivo_selinux_invalido"; exit 2
    fi
    ajuste=$(sed -nE 's/^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' "$config")
    if [[ $ajuste != permissive && $ajuste != enforcing ]]; then
        registrar "ESTADO=REVISION motivo=directiva_selinux_invalida"; exit 2
    fi
    if ! arranques=$(grubby --info=ALL) || [[ -z $arranques ]] ||
       grep -Eq '(^|[[:space:]"])(enforcing|selinux)=0([[:space:]"]|$)' <<< "$arranques" ||
       grep -Eq '(^|[[:space:]])(enforcing|selinux)=0([[:space:]]|$)' /proc/cmdline; then
        registrar "ESTADO=REVISION motivo=parametros_arranque"; exit 2
    fi
    registrar "OBSERVADO=selinux_runtime:$modo configuracion:$ajuste"
    if [[ $modo == Enforcing && $ajuste == enforcing ]]; then
        registrar "ESTADO=SIN_CAMBIOS"; exit 0
    fi

    # 2. Respaldar solo cuando cambie la configuracion persistente
    respaldo=
    if [[ $ajuste != enforcing ]]; then
        if ! respaldo=$(mktemp /etc/selinux/.komainos.XXXXXXXX); then
            registrar "ESTADO=ERROR motivo=crear_respaldo"; exit 1
        fi
        if ! cp -- "$config" "$respaldo"; then
            rm -f -- "$respaldo" || true
            registrar "ESTADO=ERROR motivo=copiar_respaldo"; exit 1
        fi
        if ! sed -i -E 's/^[[:space:]]*SELINUX[[:space:]]*=.*/SELINUX=enforcing/' "$config"; then
            cp -- "$respaldo" "$config" || true
            registrar "ESTADO=ERROR motivo=editar_config respaldo=$respaldo"; exit 1
        fi
    fi

    # 3. Aplicar y verificar el modo Enforcing
    if [[ $modo == Permissive ]] && ! setenforce 1; then
        if [[ -n $respaldo ]] && ! cp -- "$respaldo" "$config"; then
            registrar "ESTADO=ERROR motivo=recuperacion_fallida respaldo=$respaldo"; exit 1
        fi
        [[ -z $respaldo ]] || rm -f -- "$respaldo" || true
        registrar "ESTADO=ERROR motivo=setenforce"; exit 1
    fi
    if [[ $(getenforce) != Enforcing ]]; then
        if [[ -n $respaldo ]] && ! cp -- "$respaldo" "$config"; then
            registrar "ESTADO=ERROR motivo=recuperacion_fallida respaldo=$respaldo"; exit 1
        fi
        [[ -z $respaldo ]] || rm -f -- "$respaldo" || true
        registrar "ESTADO=ERROR motivo=verificar_enforcing"; exit 1
    fi
    if [[ -n $respaldo ]]; then
        rm -f -- "$respaldo" || registrar "AVISO=limpieza_pendiente:$respaldo"
    fi
    registrar "CAMBIO=selinux:Enforcing"
    registrar "ESTADO=APLICADO"
}

if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi

# 0. Elegir el mecanismo según la distribución
if [[ ! -r /etc/os-release ]]; then
    registrar "ESTADO=REVISION motivo=so_no_identificado"; exit 2
fi
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian)                           restaurar_apparmor ;;
    rhel|rocky|almalinux|centos|fedora|amzn) restaurar_selinux ;;
    *) registrar "ESTADO=REVISION motivo=so_no_soportado"; exit 2 ;;
esac
