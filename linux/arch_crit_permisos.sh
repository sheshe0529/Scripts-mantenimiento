#!/bin/bash
# arch_crit_permisos (V14)
# Quita permisos a los archivos críticos que tienen más de los que fija la política. Nunca concede permisos nuevos.
# Parámetros
#   POLITICA_ARCHIVOS (LISTA)  elementos ruta:modo con el modo octal sin ceros a la izquierda.
# Usa getfacl (paquete acl) para descubrir ACL extendidas y, si no está instalado, la marca «+» de ls -l.
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p POLITICA_ARCHIVOS >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
if (( ${#POLITICA_ARCHIVOS[@]} == 0 )); then registrar "ESTADO=ENTRADA motivo=lista_vacia_o_invalida"; exit 64; fi

# 0: el archivo tiene una ACL extendida; 1: no la tiene; 2: no se pudo consultar
acl_extendida() {
    local acl
    if command -v getfacl >/dev/null 2>&1; then
        acl=$(getfacl -cp -- "$1") || return 2
        if grep -Eq '^(mask:|default:|user:[^:]|group:[^:])' <<< "$acl"; then return 0; fi
        return 1
    fi
    acl=$(ls -ld -- "$1") || return 2
    [[ ${acl:10:1} == + ]]
}

declare -A cambios=() vistos=()
declare -a ordenadas=()
for elemento in "${POLITICA_ARCHIVOS[@]}"; do
    ruta=${elemento%:*}
    modo=${elemento##*:}
    if [[ $elemento != *:* || ! $ruta =~ ^/[A-Za-z0-9_./-]+$ || ! $modo =~ ^[0-7]{1,4}$ ]] ||
       (( (8#$modo & 022) != 0 )) || [[ -n ${vistos[$ruta]:-} ]]; then
        registrar "ESTADO=ENTRADA motivo=ruta_o_modo_invalido"
        exit 64
    fi
    vistos[$ruta]=1
    # Una ruta que no existe en este servidor no se puede corregir: se informa y se sigue
    if [[ ! -e $ruta && ! -L $ruta ]]; then
        registrar "AVISO=ruta_inexistente:$ruta"
        continue
    fi
    if [[ ! -f $ruta || -L $ruta ]] ||
       [[ $(realpath -e -- "$ruta") != "$ruta" ]] ||
       [[ $(stat -c '%u:%h' -- "$ruta") != 0:1 ]]; then
        registrar "ESTADO=REVISION motivo=archivo_inseguro ruta=$ruta"
        exit 2
    fi
    padre=$(dirname -- "$ruta")
    while [[ $padre != / ]]; do
        read -r uid bits <<< "$(stat -c '%u %a' -- "$padre")"
        if [[ $uid != 0 ]] || (( (8#$bits & 022) != 0 )); then
            registrar "ESTADO=REVISION motivo=directorio_inseguro ruta=$padre"
            exit 2
        fi
        padre=$(dirname -- "$padre")
    done
    codigo=0
    acl_extendida "$ruta" || codigo=$?
    if (( codigo == 2 )); then
        registrar "ESTADO=ERROR motivo=consultar_acl ruta=$ruta"
        exit 1
    fi
    if (( codigo == 0 )); then
        registrar "ESTADO=REVISION motivo=acl_extendida ruta=$ruta"
        exit 2
    fi
    anterior=$(stat -c '%a' -- "$ruta")
    registrar "OBSERVADO=archivo:$ruta modo:$anterior"
    # La política solo puede quitar permisos: si exige un bit que el archivo no tiene, no se toca nada
    if (( (8#$modo & ~8#$anterior) != 0 )); then
        registrar "ESTADO=REVISION motivo=politica_concede_permisos ruta=$ruta modo_actual=$anterior modo_politica=$modo"
        exit 2
    fi
    if (( 8#$anterior != 8#$modo )); then cambios[$ruta]=$modo; ordenadas+=("$ruta"); fi
done

if (( ${#cambios[@]} == 0 )); then registrar "ESTADO=SIN_CAMBIOS"; exit 0; fi
for ruta in "${ordenadas[@]}"; do
    if ! chmod -- "${cambios[$ruta]}" "$ruta"; then
        registrar "ESTADO=ERROR motivo=chmod ruta=$ruta"
        exit 1
    fi
    actual=$(stat -c '%a' -- "$ruta")
    if (( 8#$actual != 8#${cambios[$ruta]} )); then
        registrar "ESTADO=ERROR motivo=verificacion_modo ruta=$ruta"
        exit 1
    fi
    registrar "CAMBIO=archivo:$ruta modo:$actual"
done
registrar "ESTADO=APLICADO"
