#!/bin/bash
# disco_uso (V07)
# Limpia la cache de paquetes descargados del sistema operativo.
# Compatible con Ubuntu y RHEL 9.
# No tiene parametros.
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi

# 1. Identificar sistema operativo y gestor de paquetes
if [[ ! -r /etc/os-release ]]; then
    registrar "ESTADO=REVISION motivo=so_no_identificado"; exit 2
fi
. /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        gestor=apt
        cache=/var/cache/apt/archives
        comando=apt-get ;;
    rhel|rocky|almalinux|centos|fedora|amzn)
        gestor=dnf
        cache=/var/cache/dnf
        comando=dnf ;;
    *)
        registrar "ESTADO=REVISION motivo=so_no_soportado"; exit 2 ;;
esac

if ! command -v "$comando" >/dev/null 2>&1; then
    registrar "ESTADO=REVISION motivo=gestor_no_disponible"; exit 2
fi
if [[ ! -d $cache || -L $cache ]]; then
    registrar "ESTADO=REVISION motivo=cache_no_disponible"; exit 2
fi

# 2. Medir espacio ocupado por la cache
if ! antes=$(du -sb -- "$cache" 2>/dev/null | awk '{print $1}') ||
   [[ ! $antes =~ ^[0-9]+$ ]]; then
    registrar "ESTADO=ERROR motivo=medir_cache"; exit 1
fi
registrar "OBSERVADO=gestor:$gestor cache:$cache bytes:$antes"

# 3. Ejecutar limpieza de paquetes descargados
if [[ $gestor == apt ]]; then
    if ! apt-get clean >/dev/null 2>&1; then
        registrar "ESTADO=ERROR motivo=limpieza_apt"; exit 1
    fi
else
    if ! dnf -q clean packages >/dev/null 2>&1; then
        registrar "ESTADO=ERROR motivo=limpieza_dnf"; exit 1
    fi
fi

# 4. Verificar espacio recuperado
if ! despues=$(du -sb -- "$cache" 2>/dev/null | awk '{print $1}') ||
   [[ ! $despues =~ ^[0-9]+$ ]]; then
    registrar "ESTADO=ERROR motivo=verificar_cache"; exit 1
fi
registrar "OBSERVADO=cache_despues_bytes:$despues"

if (( despues >= antes )); then
    registrar "ESTADO=SIN_CAMBIOS motivo=sin_reduccion_medible"
    exit 0
fi

liberados=$((antes - despues))
registrar "CAMBIO=cache_limpiada gestor:$gestor bytes_liberados:$liberados"
registrar "AVISO=volver_a_medir:disco_uso"
registrar "ESTADO=APLICADO"
