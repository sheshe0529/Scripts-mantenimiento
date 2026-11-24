#!/bin/bash
# disco_uso (V07)
# Elimina archivos *.tmp antiguos del primer nivel de CACHE.
# Parametros
#   MONTAJE      (STRING)   punto de montaje que contiene la cache
#   CACHE        (STRING)   carpeta absoluta de temporales, propiedad de root
#   DIAS         (INTEGER)  antiguedad minima en dias (1 a 36500)
#   MAX_ARCHIVOS (INTEGER)  maximo de archivos a eliminar (1 a 1000)
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p MONTAJE CACHE DIAS MAX_ARCHIVOS >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
montaje=$MONTAJE
cache=$CACHE
dias=$DIAS
max=$MAX_ARCHIVOS

# 1. Validar ruta, montaje y limites
if [[ $montaje != /* || ! -d $montaje || -L $montaje ]] ||
   [[ $(realpath -e -- "$montaje" 2>/dev/null) != "$montaje" ]] ||
   ! mountpoint -q -- "$montaje"; then
    registrar "ESTADO=ENTRADA motivo=montaje_invalido"; exit 64
fi
if [[ $cache != /* || ! $dias =~ ^[1-9][0-9]{0,4}$ || ! $max =~ ^[1-9][0-9]{0,3}$ ]] ||
   (( dias > 36500 || max > 1000 )); then
    registrar "ESTADO=ENTRADA motivo=parametros_invalidos"; exit 64
fi
case "$cache/" in
    //|/etc/*|/boot/*|/usr/*|/var/log/*|/var/lib/*|/dev/*|/proc/*|/sys/*|/run/*|/tmp/*|/root/*|/home/*)
        registrar "ESTADO=REVISION motivo=directorio_reservado"; exit 2 ;;
esac
if [[ ! -d $cache || -L $cache ]] ||
   [[ $(realpath -e -- "$cache") != "$cache" || $cache == "$montaje" ]] ||
   [[ $(findmnt -n -o TARGET -T "$cache") != "$montaje" ]] ||
   [[ ! $(findmnt -n -o FSTYPE -T "$cache") =~ ^(xfs|ext4)$ ]]; then
    registrar "ESTADO=REVISION motivo=cache_o_montaje_invalido"; exit 2
fi
padre=$cache
while [[ $padre != / ]]; do
    read -r uid bits <<< "$(stat -c '%u %a' -- "$padre")"
    if [[ $uid != 0 ]] || (( (8#$bits & 022) != 0 )); then
        registrar "ESTADO=REVISION motivo=directorio_inseguro ruta=$padre"; exit 2
    fi
    padre=$(dirname -- "$padre")
done
if ! antes=$(df -B1 --output=avail -- "$cache" | awk 'NR==2 && $1 ~ /^[0-9]+$/ {print $1}') ||
   [[ -z $antes ]]; then
    registrar "ESTADO=ERROR motivo=medir_espacio"; exit 1
fi
registrar "OBSERVADO=libres_bytes:$antes cache:$cache"

# 2. Identificar y eliminar solo archivos temporales elegibles
if ! inventario=$(mktemp /run/komainos-limpieza.XXXXXXXX); then
    registrar "ESTADO=ERROR motivo=inventario"; exit 1
fi
trap 'rm -f -- "$inventario"' EXIT
if ! find -P "$cache" -maxdepth 1 -xdev -type f -links 1 -name '*.tmp' -mtime "+$((dias - 1))" -print0 > "$inventario"; then
    registrar "ESTADO=ERROR motivo=buscar_temporales"; exit 1
fi
cantidad=0
while IFS= read -r -d '' archivo && (( cantidad < max )); do
    if [[ ! -f $archivo || -L $archivo ]] ||
       [[ $(stat -c '%h' -- "$archivo" 2>/dev/null) != 1 ]] ||
       [[ $(find -P "$archivo" -maxdepth 0 -type f -name '*.tmp' -mtime "+$((dias - 1))" -printf '1' 2>/dev/null) != 1 ]]; then
        registrar "ESTADO=REVISION motivo=archivo_modificado ruta=$archivo"; exit 2
    fi
    if ! rm -- "$archivo"; then
        registrar "ESTADO=ERROR motivo=eliminar_archivo ruta=$archivo"; exit 1
    fi
    cantidad=$((cantidad + 1))
done < "$inventario"
if (( cantidad == 0 )); then
    registrar "ESTADO=SIN_CAMBIOS motivo=sin_temporales"; exit 0
fi
registrar "CAMBIO=archivos_retirados:$cantidad"

# 3. Verificar espacio disponible
if ! despues=$(df -B1 --output=avail -- "$cache" | awk 'NR==2 && $1 ~ /^[0-9]+$/ {print $1}') ||
   [[ -z $despues ]]; then
    registrar "ESTADO=ERROR motivo=verificar_espacio"; exit 1
fi
registrar "OBSERVADO=libres_despues_bytes:$despues"
if (( despues <= antes )); then
    registrar "AVISO=espacio_no_aumento"
fi
registrar "AVISO=volver_a_medir:disco_uso"
registrar "ESTADO=APLICADO"
