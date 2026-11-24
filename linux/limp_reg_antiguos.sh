#!/bin/bash
# disco_uso (V07)
# Elimina registros archivados de systemd anteriores al periodo de retencion.
# Parametros
#   DIAS (INTEGER) antiguedad minima de los registros (7 a 36500)
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p DIAS >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
dias=$DIAS

# 1. Validar parametros y disponibilidad
if [[ ! $dias =~ ^[1-9][0-9]{0,4}$ ]] || (( dias < 7 || dias > 36500 )); then
    registrar "ESTADO=ENTRADA motivo=dias_invalidos"; exit 64
fi
if ! command -v journalctl >/dev/null 2>&1; then
    registrar "ESTADO=REVISION motivo=journalctl_no_disponible"; exit 2
fi

# 2. Consultar espacio ocupado por los registros
ocupado() { du -sb /var/log/journal /run/log/journal 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }
if ! antes=$(journalctl --disk-usage 2>/dev/null); then
    registrar "ESTADO=ERROR motivo=consultar_journal"; exit 1
fi
bytes_antes=$(ocupado)
registrar "OBSERVADO=journal_antes:$antes retencion_dias:$dias"

# 3. Eliminar registros archivados antiguos
if ! salida=$(journalctl --vacuum-time="${dias}d" 2>&1); then
    registrar "ESTADO=ERROR motivo=limpieza_journal"; exit 1
fi
retirados=$(grep -c '^Deleted archived journal' <<< "$salida" || true)

# 4. Verificar operacion
if ! despues=$(journalctl --disk-usage 2>/dev/null); then
    registrar "ESTADO=ERROR motivo=verificar_journal"; exit 1
fi
bytes_despues=$(ocupado)
registrar "OBSERVADO=journal_despues:$despues"
if (( retirados == 0 && bytes_despues >= bytes_antes )); then
    registrar "ESTADO=SIN_CAMBIOS motivo=sin_registros_antiguos"; exit 0
fi
registrar "CAMBIO=registros_retirados:$retirados retencion_dias:$dias"
registrar "AVISO=volver_a_medir:disco_uso"
registrar "ESTADO=APLICADO"
