#!/bin/bash
# admin_no_aut (V13)
# Retira del grupo administrador GRUPO a las cuentas locales que no figuran en AUTORIZADOS.
# Parámetros
#   GRUPO        (STRING)   grupo administrador
#   AUTORIZADOS  (LISTA)    cuentas que pueden pertenecer al grupo
#   MAX_CUENTAS  (INTEGER)  si hay más cuentas no autorizadas que esta cifra no se toca ninguna (1 a 100)
# No se modifica root, la sesión de KomainOS ni usuarios con dicho grupo como primario
set -euo pipefail

# Formato comun de salida para KomainOS
registrar() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if ! declare -p GRUPO AUTORIZADOS MAX_CUENTAS >/dev/null 2>&1; then registrar "ESTADO=ENTRADA motivo=parametros"; exit 64; fi
if [[ $EUID -ne 0 ]]; then registrar "ESTADO=ERROR motivo=requiere_root"; exit 1; fi
grupo=$GRUPO
max=$MAX_CUENTAS
if [[ ! $grupo =~ ^(root|wheel|sudo|admin)$ || ! $max =~ ^[1-9][0-9]{0,2}$ ]] || (( max > 100 )); then
    registrar "ESTADO=ENTRADA motivo=grupo_o_limite"
    exit 64
fi

# 1. Consultar el grupo local y sus miembros suplementarios
if ! grupo_local=$(getent -s files group "$grupo") ||
   [[ $(getent group "$grupo") != "$grupo_local" ]]; then
    registrar "ESTADO=REVISION motivo=grupo_no_local"
    exit 2
fi
IFS=: read -r _ _ gid miembros <<< "$grupo_local"
IFS=, read -r -a actuales <<< "$miembros"
registrar "OBSERVADO=grupo:$grupo miembros:${miembros:-ninguno}"

# 2. Separar las cuentas que se pueden retirar de las que requieren revisión
candidatas=()
revisar=()
for cuenta in "${actuales[@]+"${actuales[@]}"}"; do
    [[ -n $cuenta ]] || continue
    autorizada=0
    for elemento in "${AUTORIZADOS[@]+"${AUTORIZADOS[@]}"}"; do
        if [[ $elemento == "$cuenta" ]]; then autorizada=1; fi
    done
    if (( autorizada == 1 )); then continue; fi
    if [[ $cuenta == root || $cuenta == "${SUDO_USER:-}" ]]; then
        revisar+=("$cuenta:cuenta_protegida"); continue
    fi
    if ! cuenta_local=$(getent -s files passwd "$cuenta") ||
       [[ $(getent passwd "$cuenta") != "$cuenta_local" ]]; then
        revisar+=("$cuenta:cuenta_no_local"); continue
    fi
    IFS=: read -r _ _ uid gid_primario _ <<< "$cuenta_local"
    if (( uid == 0 || gid_primario == gid )); then
        revisar+=("$cuenta:uid_o_grupo_primario"); continue
    fi
    candidatas+=("$cuenta")
done
if (( ${#candidatas[@]} > max )); then
    registrar "ESTADO=REVISION motivo=demasiadas_cuentas cuentas=${#candidatas[@]} maximo=$max"
    exit 2
fi
if (( ${#candidatas[@]} == 0 && ${#revisar[@]} == 0 )); then
    registrar "ESTADO=SIN_CAMBIOS motivo=sin_cuentas_no_autorizadas"
    exit 0
fi

# 3. Retirar y comprobar la membresía
for cuenta in "${candidatas[@]+"${candidatas[@]}"}"; do
    if ! gpasswd -d "$cuenta" "$grupo"; then
        registrar "ESTADO=ERROR motivo=retirar_membresia cuenta=$cuenta"
        exit 1
    fi
    if ! grupo_local=$(getent -s files group "$grupo") ||
       [[ ,${grupo_local##*:}, == *",$cuenta,"* ]]; then
        registrar "ESTADO=ERROR motivo=verificar_membresia cuenta=$cuenta"
        exit 1
    fi
    registrar "CAMBIO=cuenta:$cuenta grupo:$grupo accion:retirada"
done
if (( ${#revisar[@]} > 0 )); then
    registrar "ESTADO=REVISION motivo=cuentas_sin_retirar detalle=${revisar[*]}"
    exit 2
fi
registrar "ESTADO=APLICADO"
