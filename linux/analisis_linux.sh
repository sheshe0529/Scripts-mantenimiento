#!/usr/bin/env bash
# Solo lectura. Informa las 20 variables del R3.1 (V01 a V20) y la última línea es el objeto
# Parámetros
#   MUESTREO_SEGUNDOS  ventana en la que se miden CPU, disco e intercambio
#   VENTANA_HORAS      periodo de los registros: autenticaciones fallidas y errores de disco
#   ARCHIVOS_CRITICOS  arreglo de elementos ruta:modo; se usa cada ruta para medir su permiso actual
set -u

shopt -s lastpipe
export LC_ALL=C
: "${MUESTREO_SEGUNDOS:=5}"
: "${VENTANA_HORAS:=24}"
if ! [ "$MUESTREO_SEGUNDOS" -ge 1 ] 2>/dev/null || ! [ "$VENTANA_HORAS" -ge 1 ] 2>/dev/null; then
    echo "MUESTREO_SEGUNDOS y VENTANA_HORAS deben ser enteros positivos" >&2
    exit 2
fi
if ! declaracion=$(declare -p ARCHIVOS_CRITICOS 2>/dev/null) ||
   ! [[ $declaracion =~ ^declare[[:space:]]+-[[:alpha:]]*a[[:alpha:]]*[[:space:]] ]]; then
    echo "Declare ARCHIVOS_CRITICOS como parámetro Lista y seleccione el catálogo" >&2
    exit 2
fi
# La expansión con + admite un arreglo vacío en Bash 4.2 con set -u.
for entrada in "${ARCHIVOS_CRITICOS[@]+"${ARCHIVOS_CRITICOS[@]}"}"; do
    if ! [[ $entrada =~ ^/.+:[0-7]{1,4}$ ]]; then
        echo "ARCHIVOS_CRITICOS debe contener rutas absolutas con modo octal (ruta:modo)" >&2
        exit 2
    fi
done
# V11 a V14 leen /etc/shadow, sshd -T y los permisos de los archivos críticos: sin privilegios de administrador darían un
# valor falso en lugar de un error
if [ ! -r /etc/shadow ]; then
    echo "El análisis necesita privilegios de administrador (no puede leer /etc/shadow)" >&2
    exit 2
fi

metricas=()

# Texto JSON con comillas y barras invertidas escapadas
json_texto() {
    local s=${1//\\/\\\\}
    printf '"%s"' "${s//\"/\\\"}"
}

# Lista JSON con una entrada por línea de la entrada estándar
json_lista() {
    local primero=1 elemento
    printf '['
    while IFS= read -r elemento; do
        [ -z "$elemento" ] && continue
        [ "$primero" -eq 1 ] || printf ','
        json_texto "$elemento"
        primero=0
    done
    printf ']'
}

# valor CODIGO VALOR [INSTANCIA]
valor() {
    if [ -n "${3:-}" ]; then
        metricas+=("{\"codigo\":\"$1\",\"instancia\":$(json_texto "$3"),\"valor\":$2}")
    else
        metricas+=("{\"codigo\":\"$1\",\"valor\":$2}")
    fi
}

# elementos CODIGO < un elemento por línea
elementos() {
    metricas+=("{\"codigo\":\"$1\",\"elementos\":$(json_lista)}")
}

# Porcentaje con dos decimales; 0 si no hubo actividad en la ventana
porcentaje() {
    awk -v p="$1" -v t="$2" 'BEGIN { printf "%.2f", (t > 0 ? p / t * 100 : 0) }'
}

# Registros del periodo: núcleo (-k) o los campos que se indiquen; vacío si no hay journald
registro() {
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl --no-pager -q --since "${VENTANA_HORAS} hours ago" "$@" 2>/dev/null
}

# ---- Muestreo: CPU, discos e intercambio en dos lecturas separadas por MUESTREO_SEGUNDOS ----
# Los contadores se imprimen con %.0f: algunos awk (mawk) abrevian los enteros grandes en notación científica

# total, ociosa e iowait: user nice system idle iowait irq softirq steal (guest ya está incluido en user)
leer_cpu() {
    awk '/^cpu / { printf "%.0f %.0f %.0f\n", $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9, $5, $6 }' /proc/stat
}

# Discos con dispositivo real: excluye loop, ram, zram, md y los volúmenes lógicos (dm-*), que repetirían la medición
discos=" $(for d in /sys/block/*; do [ -e "$d/device" ] && basename "$d"; done | tr '\n' ' ')"
# nombre, operaciones completadas (lecturas + escrituras) y milisegundos dedicados a ellas
leer_discos() {
    awk -v lista="$discos " 'index(lista, " " $3 " ") { printf "%s %.0f %.0f\n", $3, $4 + $8, $7 + $11 }' /proc/diskstats
}

leer_intercambio() {
    awk '$1 == "pswpin" || $1 == "pswpout" { n += $2 } END { printf "%.0f\n", n }' /proc/vmstat
}

read -r cpu_total_1 cpu_ociosa_1 cpu_espera_1 < <(leer_cpu)
declare -A disco_ops_1 disco_ms_1
while read -r d ops ms; do disco_ops_1[$d]=$ops; disco_ms_1[$d]=$ms; done < <(leer_discos)
intercambio_1=$(leer_intercambio)

sleep "$MUESTREO_SEGUNDOS"

read -r cpu_total_2 cpu_ociosa_2 cpu_espera_2 < <(leer_cpu)
cpu_total=$((cpu_total_2 - cpu_total_1))
cpu_espera=$((cpu_espera_2 - cpu_espera_1))

# V01 y V03: tiempo ocupado y tiempo en espera de E/S sobre el total de la ventana
valor cpu_uso "$(porcentaje $((cpu_total - (cpu_ociosa_2 - cpu_ociosa_1) - cpu_espera)) $cpu_total)"
valor cpu_iowait "$(porcentaje $cpu_espera $cpu_total)"

# V08: milisegundos promedio por operación de lectura o escritura, por disco
while read -r d ops ms; do
    delta_ops=$((ops - ${disco_ops_1[$d]:-$ops}))
    delta_ms=$((ms - ${disco_ms_1[$d]:-$ms}))
    valor disco_latencia "$(awk -v m=$delta_ms -v o=$delta_ops 'BEGIN { printf "%.2f", (o > 0 ? m / o : 0) }')" "$d"
done < <(leer_discos)

# V06: páginas intercambiadas (entrada y salida) convertidas a KiB por segundo
pagina_kib=$(( $(getconf PAGESIZE) / 1024 ))
valor swap_act "$(awk -v p=$(( $(leer_intercambio) - intercambio_1 )) -v k=$pagina_kib -v s="$MUESTREO_SEGUNDOS" \
    'BEGIN { printf "%.2f", p * k / s }')"

# ---- Uso de recursos ----

# V02: carga promedio de 5 minutos por CPU lógica
valor cpu_load "$(awk -v n="$(nproc)" '{ printf "%.2f", $2 / n }' /proc/loadavg)"

# V04: memoria usada sin contar la que el sistema puede recuperar (MemAvailable)
valor mem_uso "$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { d = $2 } END { printf "%.2f", (t > 0 ? (1 - d / t) * 100 : 0) }' /proc/meminfo)"

# V05: área de intercambio ocupada; 0 si el servidor no tiene swap
valor swap_uso "$(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { l = $2 } END { printf "%.2f", (t > 0 ? (1 - l / t) * 100 : 0) }' /proc/meminfo)"

# V07: por sistema de archivos montado, sin los virtuales en memoria; el punto de montaje puede tener espacios
while read -r uso montaje; do
    valor disco_uso "$uso" "$montaje"
done < <(df --output=pcent,target -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR > 1 {
    uso = $1; sub(/%/, "", uso); $1 = ""; sub(/^ +/, "")
    if (uso ~ /^[0-9]+$/ && !visto[$0]++) print uso, $0
}')

# V18: días desde el último arranque
valor uptime_dias "$(awk '{ printf "%.2f", $1 / 86400 }' /proc/uptime)"

# ---- Registros del periodo ----

# V09: errores de E/S de los dispositivos en el registro del núcleo
valor disco_errores "$(registro -k | grep -ciE 'I/O error|medium error|critical target error' || true)"

# V10: inicios de sesión fallidos (auth y authpriv). Un intento por SSH deja la línea de sshd y la de PAM: se cuenta
# la de sshd, y la de PAM solo para los demás accesos (consola, su, sudo)
valor aut_fallidas "$(registro SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 \
    | grep -E 'sshd(-session)?\[[0-9]+\]: Failed |authentication failure' | grep -vc '(sshd:auth): authentication failure' || true)"

# ---- Seguridad ----

# V11: 1 si root puede iniciar sesión de forma directa por SSH (PermitRootLogin distinto de no, incluida la llave)
acceso=0
if command -v sshd >/dev/null 2>&1; then
    raiz_ssh=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }')
    # Sin sshd -T se lee la configuración; si no lo indica, el valor por omisión de OpenSSH permite entrar con llave
    [ -z "$raiz_ssh" ] && raiz_ssh=$(awk 'tolower($1) == "permitrootlogin" { print tolower($2); exit }' /etc/ssh/sshd_config 2>/dev/null)
    [ "${raiz_ssh:-prohibit-password}" != "no" ] && acceso=1
fi
valor admin_acceso "$acceso"

# V12: 1 si la cuenta de administrador integrada (root) está habilitada, es decir, su contraseña no está bloqueada
# (! o *); un campo vacío permite entrar sin contraseña
case "$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)" in
    '!'* | '*'*) valor admin_block_passwd 0 ;;
    *) valor admin_block_passwd 1 ;;
esac

# V13: cuentas con uid 0 o miembros de sudo, wheel o admin que pueden iniciar sesión (shell distinta de nologin y false)
{
    awk -F: '$3 == 0 { print $1 }' /etc/passwd
    for grupo in sudo wheel admin; do
        getent group "$grupo" | awk -F: '{ n = split($4, m, ","); for (i = 1; i <= n; i++) print m[i] }'
    done
} | sort -u | while IFS= read -r cuenta; do
    case "$(getent passwd "$cuenta" | cut -d: -f7)" in
        */nologin | */false | "") ;;
        *) echo "$cuenta" ;;
    esac
done | elementos admin_no_aut

# V14: informa el modo observado de cada ruta. KomainOS lo compara con la política.
# La expansión con + evita el error de set -u con un arreglo vacío en Bash 4.2
for entrada in "${ARCHIVOS_CRITICOS[@]+"${ARCHIVOS_CRITICOS[@]}"}"; do
    archivo=${entrada%:*}
    [ -e "$archivo" ] && printf '%s:%s\n' "$archivo" "$(stat -c '%a' -- "$archivo")"
done | elementos arch_crit_permisos

# V15: puertos TCP en escucha fuera de la interfaz de bucle local (127.0.0.0/8 y ::1 no son accesibles desde la red)
ss -lnt 2>/dev/null | awk 'NR > 1 {
    direccion = $4; n = split(direccion, partes, ":"); puerto = partes[n]
    sub(":" puerto "$", "", direccion)
    if (direccion ~ /^127\./ || direccion ~ /^\[::(ffff:127\.[0-9.]+|1)\]$/ || direccion ~ /%lo$/) next
    print puerto
}' | sort -un | elementos red_puerto_no_aut

# V16: 1 si no está activo ninguno de los cortafuegos habituales (firewalld, ufw, nftables o iptables)
firewall=1
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall=0
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    firewall=0
elif systemctl is-active --quiet nftables 2>/dev/null || systemctl is-active --quiet iptables 2>/dev/null; then
    firewall=0
fi
valor firewall_inactivo "$firewall"

# V17: 1 si SELinux no está en Enforcing o AppArmor no tiene perfiles en modo estricto (enforce)
mac=1
if command -v getenforce >/dev/null 2>&1; then
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] && mac=0
elif [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = "Y" ]; then
    estrictos=$(grep -c ' (enforce)$' /sys/kernel/security/apparmor/profiles 2>/dev/null || true)
    [ "${estrictos:-0}" -gt 0 ] && mac=0
fi
valor mac_no_estricto "$mac"

# ---- Disponibilidad ----

# V19 y V20: servicios en ejecución. KomainOS contrasta esa lista con la de servicios requeridos (los que faltan son los
# no operativos) y con la de servicios no permitidos (los que figuran en ella y están en ejecución)
servicios=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
    | awk '{ sub(/\.service$/, "", $1); print $1 }')
elementos serv_no_operativo <<< "$servicios"
elementos serv_no_perm <<< "$servicios"

echo "Análisis de $(hostname): ${#metricas[@]} mediciones en una ventana de ${MUESTREO_SEGUNDOS} s"
printf '{"metricas":[%s]}\n' "$(IFS=,; echo "${metricas[*]}")"
