#requires -Version 5.1
# disco_uso (V07)
# Elimina archivos .tmp antiguos (solo del primer nivel) de la carpeta de temporales autorizada.
# Parámetros
#   VOLUMEN       (STRING)   unidad, por ejemplo C: (el volumen que informa disco_uso)
#   DIRECTORIO    (STRING)   carpeta absoluta de temporales dentro del volumen, por ejemplo D:\Cache\Temp
#   DIAS          (INTEGER)  antigüedad mínima en días (1 a 36500)
#   MAX_ARCHIVOS  (INTEGER)  máximo de archivos a eliminar en la ejecución (1 a 1000)

$ErrorActionPreference = 'Stop'

function Registrar([string]$Mensaje) {
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Mensaje"
}

try {
    # La cuenta usada por Ansible/WinRM debe contar con token administrativo.
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrador = [Security.Principal.WindowsPrincipal]::new($identidad)
    if (-not $administrador.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Registrar 'ESTADO=REVISION motivo=permisos_administrativos'
        exit 2
    }

    # Eliminar solo temporales .tmp antiguos en una ruta validada.
    if ($null -eq $VOLUMEN -or $null -eq $DIRECTORIO -or $null -eq $DIAS -or $null -eq $MAX_ARCHIVOS) {
        Registrar 'ESTADO=ENTRADA motivo=parametros'
        exit 64
    }
    $volumen = [string]$VOLUMEN
    $directorio = [string]$DIRECTORIO
    $dias = [int]$DIAS
    $maximo = [int]$MAX_ARCHIVOS
    if ($volumen -notmatch '^[A-Za-z]:$' -or $directorio -notmatch '^[A-Za-z]:\\[^\\]' -or
        $directorio.Substring(2) -match '[:*?<>|/]' -or
        $dias -lt 1 -or $dias -gt 36500 -or $maximo -lt 1 -or $maximo -gt 1000) {
        Registrar 'ESTADO=ENTRADA motivo=ruta_o_limites'
        exit 64
    }
    $raiz = "$volumen\"
    $cache = [IO.Path]::GetFullPath($directorio).TrimEnd('\')
    if ($cache -ne $directorio.TrimEnd('\') -or
        [IO.Path]::GetPathRoot($cache) -ne $raiz -or $cache -eq $volumen) {
        Registrar 'ESTADO=REVISION motivo=directorio_no_canonico'
        exit 2
    }
    $reservadas = @($env:windir, $env:ProgramFiles,
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
        "$env:SystemDrive\Users", ($raiz + '$Recycle.Bin'), ($raiz + 'System Volume Information'))
    foreach ($ruta in $reservadas) {
        if ($ruta -and ($cache -eq $ruta -or
            $cache.StartsWith("$ruta\", [StringComparison]::OrdinalIgnoreCase))) {
            Registrar 'ESTADO=REVISION motivo=directorio_reservado'
            exit 2
        }
    }
    for ($ruta = $cache; $ruta -ne $raiz; $ruta = $item.Parent.FullName) {
        $item = Get-Item -LiteralPath $ruta -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Registrar 'ESTADO=REVISION motivo=directorio_o_enlace'
            exit 2
        }
    }
    $unidad = [IO.DriveInfo]::new($raiz)
    if ($unidad.DriveType -ne 'Fixed' -or -not $unidad.IsReady -or $unidad.DriveFormat -ne 'NTFS') {
        Registrar 'ESTADO=REVISION motivo=volumen_no_apto'
        exit 2
    }
    $antes = $unidad.TotalFreeSpace
    $corte = [DateTime]::UtcNow.AddDays(-$dias)
    $archivos = @(Get-ChildItem -LiteralPath $cache -File -Filter '*.tmp' |
        Where-Object { $_.Extension -eq '.tmp' -and $_.LastWriteTimeUtc -le $corte -and
            $_.LinkType -ne 'HardLink' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Select-Object -First $maximo)
    Registrar "OBSERVADO=temporales_elegibles:$($archivos.Count) bytes_libres:$antes"
    if (-not $archivos.Count) {
        Registrar 'ESTADO=SIN_CAMBIOS'
        exit 0
    }
    $eliminados = 0
    foreach ($archivo in $archivos) {
        Remove-Item -LiteralPath $archivo.FullName
        $eliminados++
    }
    $despues = $unidad.TotalFreeSpace
    Registrar "CAMBIO=temporales_eliminados:$eliminados bytes_libres:$despues"
    if ($despues -le $antes) {
        Registrar 'ESTADO=REVISION motivo=espacio_no_incrementado'
        exit 2
    }
    Registrar 'ESTADO=APLICADO'
    exit 0
}
catch {
    # Mensaje tecnico al canal de error de Ansible (stderr).
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    Registrar 'ESTADO=ERROR motivo=excepcion'
    exit 1
}
