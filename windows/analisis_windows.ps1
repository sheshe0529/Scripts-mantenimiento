# Solo lectura. Informa las 16 variables del R3.1 que se miden en Windows y la última línea es el objeto
# Usa clases CIM y no rutas de contadores, que cambian con el idioma del sistema. Compatible con PowerShell 5.1.
# Parámetros
#   $MUESTREO_SEGUNDOS  ventana en la que se miden CPU, discos y paginación
#   $VENTANA_HORAS      periodo de los registros: autenticaciones fallidas y errores de disco

$ErrorActionPreference = 'Stop'
if ($null -eq $MUESTREO_SEGUNDOS) { $MUESTREO_SEGUNDOS = 5 }
if ($null -eq $VENTANA_HORAS) { $VENTANA_HORAS = 24 }
[int]$muestreo = 0
[int]$ventana = 0
if (-not [int]::TryParse([string]$MUESTREO_SEGUNDOS, [ref]$muestreo) -or $muestreo -lt 1 -or
    -not [int]::TryParse([string]$VENTANA_HORAS, [ref]$ventana) -or $ventana -lt 1) {
    throw 'MUESTREO_SEGUNDOS y VENTANA_HORAS deben ser enteros positivos'
}
$MUESTREO_SEGUNDOS = $muestreo
$VENTANA_HORAS = $ventana

$metricas = New-Object System.Collections.Generic.List[object]

function Valor($codigo, $valor, $instancia) {
    $metrica = [ordered]@{ codigo = $codigo }
    if ($instancia) { $metrica.instancia = [string]$instancia }
    $metrica.valor = $valor
    $metricas.Add($metrica)
}

function Elementos($codigo, $elementos) {
    $lista = @($elementos | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $metricas.Add([ordered]@{ codigo = $codigo; elementos = $lista })
}

function Porcentaje($parte, $total) {
    if (-not $total) { return 0 }
    return [math]::Round(([double]$parte / [double]$total) * 100, 2)
}

# Eventos del periodo; ninguno no es un error. Sin permiso para leer el registro, el análisis falla con el motivo
function ContarEventos($filtro) {
    $filtro.StartTime = (Get-Date).AddHours(-$VENTANA_HORAS)
    try {
        return @(Get-WinEvent -FilterHashtable $filtro -ErrorAction Stop).Count
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatching*') { return 0 }
        throw
    }
}

# Los contadores en bruto de PhysicalDisk (DiskTransfersPersec, AvgDisksecPerTransfer y su base) y de Memory (PagesPersec)
# son UInt32 y dan la vuelta al llegar a 2^32: con el disco saturado la suma de tiempos de espera la cruza en segundos y la
# resta simple sale negativa. La diferencia se toma módulo 2^32 (válida mientras el contador avance menos de 2^32 entre las
# dos lecturas; con muestreos largos y colas muy profundas conviene acortar MUESTREO_SEGUNDOS)
function Diferencia32($despues, $antes) {
    $d = [double]$despues - [double]$antes
    if ($d -lt 0) { $d += 4294967296 }
    return $d
}

# ---- Muestreo: CPU, discos y paginación en dos lecturas separadas por $MUESTREO_SEGUNDOS ----

function LeerMuestra {
    @{
        Cpu     = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"
        Memoria = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory
        Discos  = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk | Where-Object Name -ne '_Total')
    }
}

$antes = LeerMuestra
Start-Sleep -Seconds $MUESTREO_SEGUNDOS
$despues = LeerMuestra

# V01: el contador de procesador mide el tiempo ocioso en unidades de 100 ns; el uso es su complemento
$ocioso = [double]$despues.Cpu.PercentProcessorTime - [double]$antes.Cpu.PercentProcessorTime
$transcurrido = [double]$despues.Cpu.Timestamp_Sys100NS - [double]$antes.Cpu.Timestamp_Sys100NS
Valor 'cpu_uso' ([math]::Max(0, [math]::Round(100 - (Porcentaje $ocioso $transcurrido), 2)))

# V08: milisegundos promedio por operación de lectura o escritura, por disco físico
foreach ($disco in $despues.Discos) {
    $previo = $antes.Discos | Where-Object Name -eq $disco.Name
    if (-not $previo) { continue }
    $tiempo = (Diferencia32 $disco.AvgDisksecPerTransfer $previo.AvgDisksecPerTransfer) / [double]$disco.Frequency_PerfTime
    $base = Diferencia32 $disco.AvgDisksecPerTransfer_Base $previo.AvgDisksecPerTransfer_Base
    Valor 'disco_latencia' ($(if ($base -gt 0) { [math]::Round($tiempo / $base * 1000, 2) } else { 0 })) $disco.Name
}

# V06: páginas leídas o escritas en disco para resolver fallos de página, convertidas a KiB por segundo
$segundos = ([double]$despues.Memoria.Timestamp_PerfTime - [double]$antes.Memoria.Timestamp_PerfTime) / [double]$despues.Memoria.Frequency_PerfTime
$paginas = Diferencia32 $despues.Memoria.PagesPersec $antes.Memoria.PagesPersec
Valor 'swap_act' ($(if ($segundos -gt 0) { [math]::Round($paginas * [Environment]::SystemPageSize / 1KB / $segundos, 2) } else { 0 }))

# ---- Uso de recursos ----

$sistema = Get-CimInstance -ClassName Win32_OperatingSystem

# V04: memoria usada sin contar la disponible (libre más la en espera, que el sistema reutiliza al instante)
$total = [double]$sistema.TotalVisibleMemorySize * 1KB
Valor 'mem_uso' (Porcentaje ($total - [double]$despues.Memoria.AvailableBytes) $total)

# V05: archivo de paginación ocupado; 0 si no hay archivo de paginación
$paginacion = @(Get-CimInstance -ClassName Win32_PageFileUsage)
Valor 'swap_uso' (Porcentaje ($paginacion | Measure-Object -Property CurrentUsage -Sum).Sum ($paginacion | Measure-Object -Property AllocatedBaseSize -Sum).Sum)

# V07: por volumen local
foreach ($unidad in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
    if ($unidad.Size) {
        Valor 'disco_uso' (Porcentaje ([double]$unidad.Size - [double]$unidad.FreeSpace) $unidad.Size) $unidad.DeviceID
    }
}

# V18: días desde el último arranque
Valor 'uptime_dias' ([math]::Round(((Get-Date) - $sistema.LastBootUpTime).TotalDays, 2))

# ---- Registros del periodo ----

# V09: errores de E/S de los discos (bloques dañados, controlador, dispositivo no listo, paginación, reintentos)
# y corrupción del sistema de archivos
Valor 'disco_errores' (ContarEventos @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs'; Id = 7, 11, 15, 51, 55, 153 })

# V10: inicios de sesión fallidos
Valor 'aut_fallidas' (ContarEventos @{ LogName = 'Security'; Id = 4625 })

# ---- Seguridad ----

# V12: 1 si la cuenta de administrador integrada (identificador relativo 500) está habilitada
$integrada = Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object SID -like 'S-1-5-*-500'
$integradaHabilitada = [bool]($integrada -and -not $integrada.Disabled)
Valor 'admin_block_passwd' ($(if ($integradaHabilitada) { 1 } else { 0 }))

# V11: 1 si el administrador puede iniciar sesión de forma directa: la cuenta integrada está habilitada y el servidor acepta
# conexiones de Escritorio remoto (fDenyTSConnections = 0)
$escritorioRemoto = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections -eq 0
Valor 'admin_acceso' ($(if ($integradaHabilitada -and $escritorioRemoto) { 1 } else { 0 }))

# V13: miembros del grupo Administradores (S-1-5-32-544, su nombre depende del idioma). Las cuentas locales se informan
# sin prefijo y solo si están habilitadas; las del dominio, como DOMINIO\cuenta; una cuenta eliminada, por su SID
$grupo = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
$administradores = foreach ($miembro in @(([ADSI]"WinNT://$env:COMPUTERNAME/$grupo,group").Invoke('Members'))) {
    $cuenta = [ADSI]$miembro
    $partes = $cuenta.Path.Substring('WinNT://'.Length).Split('/')
    if ($partes.Count -eq 1) {
        $partes[0]
    } elseif ($partes.Count -eq 2) {
        '{0}\{1}' -f $partes[0], $partes[1]
    } elseif (-not ($cuenta.SchemaClassName -eq 'User' -and ([int]$cuenta.UserFlags.Value -band 2))) {
        $partes[-1]
    }
}
Elementos 'admin_no_aut' $administradores

# V15: puertos TCP en escucha fuera de la interfaz de bucle local, sin el rango dinámico: Windows asigna esos puertos a
# los servicios RPC al azar y cambian en cada arranque, así que no se pueden autorizar en una lista
$dinamico = @{ Inicio = 49152; Fin = 65535 }
try {
    $tcp = Get-NetTCPSetting -SettingName Internet
    $dinamico = @{ Inicio = $tcp.DynamicPortRangeStartPort; Fin = $tcp.DynamicPortRangeStartPort + $tcp.DynamicPortRangeNumberOfPorts - 1 }
} catch {
    # Sin la configuración TCP se usa el rango dinámico por defecto
}
$puertos = Get-NetTCPConnection -State Listen | Where-Object {
    $_.LocalAddress -notmatch '^(127\.|::1$|::ffff:127\.)' -and
    -not ($_.LocalPort -ge $dinamico.Inicio -and $_.LocalPort -le $dinamico.Fin)
} | ForEach-Object { $_.LocalPort }
$metricas.Add([ordered]@{ codigo = 'red_puerto_no_aut'; elementos = @($puertos | Sort-Object -Unique) })

# V16: 1 si el servicio de firewall no está en ejecución o algún perfil efectivo (dominio, privado, público) está desactivado
$servicioFirewall = Get-Service -Name MpsSvc
$perfilesInactivos = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { $_.Enabled -ne 'True' })
Valor 'firewall_inactivo' ($(if ($servicioFirewall.Status -ne 'Running' -or $perfilesInactivos.Count -gt 0) { 1 } else { 0 }))

# ---- Disponibilidad ----

# V19 y V20: servicios en ejecución. KomainOS contrasta esa lista con la de servicios requeridos (los que faltan son los
# no operativos) y con la de servicios no permitidos (los que figuran en ella y están en ejecución)
$servicios = @(Get-Service | Where-Object Status -eq 'Running' | ForEach-Object { $_.Name })
Elementos 'serv_no_operativo' $servicios
Elementos 'serv_no_perm' $servicios

Write-Output "Análisis de $env:COMPUTERNAME`: $($metricas.Count) mediciones en una ventana de $MUESTREO_SEGUNDOS s"
@{ metricas = $metricas.ToArray() } | ConvertTo-Json -Depth 5 -Compress
