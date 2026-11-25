Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredProperty {
    param($Value, [string]$Name, [string]$Context)
    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) {
        throw [ArgumentException]::new("Config inválida: falta '$Context.$Name'.")
    }
    return $Value.PSObject.Properties[$Name].Value
}

function Assert-KnownProperties {
    param($Value, [string[]]$Allowed, [string]$Context)
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.Name -notin $Allowed) {
            throw [ArgumentException]::new("Config inválida: campo desconocido '$Context.$($property.Name)'.")
        }
    }
}

function ConvertTo-PortablePath {
    param($Value, [string]$Context)
    $path = [string]$Value
    if ([string]::IsNullOrWhiteSpace($path) -or [IO.Path]::IsPathRooted($path) -or
        $path.Contains('\') -or $path.Contains(':') -or
        @($path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw [ArgumentException]::new("Config inválida: '$Context' debe ser un path relativo portable sin '.', '..', backslash ni drive.")
    }
    return $path
}

function ConvertTo-StringList {
    param($Value, [string]$Context)
    $result = [System.Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Value)) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw [ArgumentException]::new("Config inválida: '$Context' no admite valores vacíos.")
        }
        if (-not $seen.Add($text)) {
            throw [ArgumentException]::new("Config inválida: '$Context' contiene el duplicado '$text'.")
        }
        $result.Add($text)
    }
    if ($result.Count -eq 0) { throw [ArgumentException]::new("Config inválida: '$Context' no puede estar vacío.") }
    return @($result)
}

function ConvertTo-Pattern {
    param($Value, [string]$Context)
    $pattern = [string]$Value
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw [ArgumentException]::new("Config inválida: '$Context' está vacío.") }
    try { [void][regex]::new($pattern) }
    catch { throw [ArgumentException]::new("Config inválida: '$Context' no es regex válida: $($_.Exception.Message)") }
    return $pattern
}

function ConvertTo-NonNegativeInt {
    param($Value, [string]$Context)
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt 0) {
        throw [ArgumentException]::new("Config inválida: '$Context' debe ser entero >= 0.")
    }
    return $number
}

function New-BuiltinRoadmapKitConfig {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        paths = [pscustomobject][ordered]@{
            roadmaps = 'roadmaps'
            docs = 'docs'
            skillRoots = @('.kerberos/skills', '.agents/skills')
        }
        roadmaps = [pscustomobject][ordered]@{
            idPattern = '^RM-[0-9]{3}$'
            taskIdPattern = '^RM-[0-9]{3}-[A-Z0-9-]+$'
            statuses = @('proposed', 'ready', 'active', 'blocked', 'paused')
            taskStatuses = @('planned', 'ready', 'doing', 'blocked', 'done')
            priorities = @('P0', 'P1', 'P2', 'P3')
            lanes = @('feature', 'research', 'maintenance')
            wip = [pscustomobject][ordered]@{
                activeByLane = [pscustomobject][ordered]@{ feature = 2; maintenance = 1 }
                readyTasksPerRoadmap = 3
            }
        }
        docs = [pscustomobject][ordered]@{
            legacyBaseline = 'docs/.legacy-baseline.txt'
            kinds = @('architecture', 'reference', 'how-to', 'runbook', 'decision', 'generated', 'archive')
            statuses = @('current', 'superseded', 'archived')
        }
        requirements = [pscustomobject][ordered]@{ pwsh = '7.0.0'; git = '2.30.0' }
        source = 'builtin'
        sourcePath = $null
    }
}

function Get-RoadmapKitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$RequireFile
    )

    $root = [IO.Path]::GetFullPath($RepoRoot)
    $configPath = Join-Path $root '.roadmap-kit/config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        if ($RequireFile) { throw [ArgumentException]::new("Config ausente: $configPath") }
        return New-BuiltinRoadmapKitConfig
    }

    try { $raw = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json }
    catch { throw [ArgumentException]::new("Config inválida en ${configPath}: $($_.Exception.Message)") }
    Assert-KnownProperties $raw @('schemaVersion', 'paths', 'roadmaps', 'docs', 'requirements') 'root'
    if ([int](Get-RequiredProperty $raw 'schemaVersion' 'root') -ne 1) {
        throw [ArgumentException]::new("Config incompatible: schemaVersion debe ser 1.")
    }

    $pathsRaw = Get-RequiredProperty $raw 'paths' 'root'
    Assert-KnownProperties $pathsRaw @('roadmaps', 'docs', 'skillRoots') 'paths'
    $roadmapsRoot = ConvertTo-PortablePath (Get-RequiredProperty $pathsRaw 'roadmaps' 'paths') 'paths.roadmaps'
    $docsRoot = ConvertTo-PortablePath (Get-RequiredProperty $pathsRaw 'docs' 'paths') 'paths.docs'
    if ($roadmapsRoot.Equals($docsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new('Config inválida: paths.roadmaps y paths.docs deben ser distintos.')
    }
    $skillRoots = @(ConvertTo-StringList (Get-RequiredProperty $pathsRaw 'skillRoots' 'paths') 'paths.skillRoots' | ForEach-Object {
        ConvertTo-PortablePath $_ 'paths.skillRoots'
    })

    $roadmapsRaw = Get-RequiredProperty $raw 'roadmaps' 'root'
    Assert-KnownProperties $roadmapsRaw @('idPattern', 'taskIdPattern', 'statuses', 'taskStatuses', 'priorities', 'lanes', 'wip') 'roadmaps'
    $idPattern = ConvertTo-Pattern (Get-RequiredProperty $roadmapsRaw 'idPattern' 'roadmaps') 'roadmaps.idPattern'
    $taskIdPattern = ConvertTo-Pattern (Get-RequiredProperty $roadmapsRaw 'taskIdPattern' 'roadmaps') 'roadmaps.taskIdPattern'
    $statuses = @(ConvertTo-StringList (Get-RequiredProperty $roadmapsRaw 'statuses' 'roadmaps') 'roadmaps.statuses')
    $taskStatuses = @(ConvertTo-StringList (Get-RequiredProperty $roadmapsRaw 'taskStatuses' 'roadmaps') 'roadmaps.taskStatuses')
    $priorities = @(ConvertTo-StringList (Get-RequiredProperty $roadmapsRaw 'priorities' 'roadmaps') 'roadmaps.priorities')
    $lanes = @(ConvertTo-StringList (Get-RequiredProperty $roadmapsRaw 'lanes' 'roadmaps') 'roadmaps.lanes')
    foreach ($required in @('active', 'ready')) {
        if ($required -notin $statuses) { throw [ArgumentException]::new("Config inválida: roadmaps.statuses debe incluir '$required'.") }
    }
    foreach ($required in @('ready', 'doing', 'done')) {
        if ($required -notin $taskStatuses) { throw [ArgumentException]::new("Config inválida: roadmaps.taskStatuses debe incluir '$required'.") }
    }

    $wipRaw = Get-RequiredProperty $roadmapsRaw 'wip' 'roadmaps'
    Assert-KnownProperties $wipRaw @('activeByLane', 'readyTasksPerRoadmap') 'roadmaps.wip'
    $activeRaw = Get-RequiredProperty $wipRaw 'activeByLane' 'roadmaps.wip'
    $activeByLane = [ordered]@{}
    foreach ($property in @($activeRaw.PSObject.Properties)) {
        if ($property.Name -notin $lanes) {
            throw [ArgumentException]::new("Config inválida: WIP referencia lane desconocido '$($property.Name)'.")
        }
        $activeByLane[$property.Name] = ConvertTo-NonNegativeInt $property.Value "roadmaps.wip.activeByLane.$($property.Name)"
    }
    $readyLimit = ConvertTo-NonNegativeInt (Get-RequiredProperty $wipRaw 'readyTasksPerRoadmap' 'roadmaps.wip') 'roadmaps.wip.readyTasksPerRoadmap'

    $docsRaw = Get-RequiredProperty $raw 'docs' 'root'
    Assert-KnownProperties $docsRaw @('legacyBaseline', 'kinds', 'statuses') 'docs'
    $legacyBaseline = ConvertTo-PortablePath (Get-RequiredProperty $docsRaw 'legacyBaseline' 'docs') 'docs.legacyBaseline'
    $docsPrefix = $docsRoot.TrimEnd('/') + '/'
    if (-not $legacyBaseline.StartsWith($docsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new("Config inválida: docs.legacyBaseline debe vivir bajo '$docsRoot/'.")
    }
    $kinds = @(ConvertTo-StringList (Get-RequiredProperty $docsRaw 'kinds' 'docs') 'docs.kinds')
    $docStatuses = @(ConvertTo-StringList (Get-RequiredProperty $docsRaw 'statuses' 'docs') 'docs.statuses')
    if ('generated' -notin $kinds) { throw [ArgumentException]::new("Config inválida: docs.kinds debe incluir 'generated'.") }
    if ('current' -notin $docStatuses) { throw [ArgumentException]::new("Config inválida: docs.statuses debe incluir 'current'.") }

    $requirementsRaw = Get-RequiredProperty $raw 'requirements' 'root'
    Assert-KnownProperties $requirementsRaw @('pwsh', 'git') 'requirements'
    $pwshRequirement = [string](Get-RequiredProperty $requirementsRaw 'pwsh' 'requirements')
    $gitRequirement = [string](Get-RequiredProperty $requirementsRaw 'git' 'requirements')
    foreach ($pair in @(@('requirements.pwsh', $pwshRequirement), @('requirements.git', $gitRequirement))) {
        if ($pair[1] -notmatch '^\d+\.\d+\.\d+$') { throw [ArgumentException]::new("Config inválida: '$($pair[0])' debe usar x.y.z.") }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        paths = [pscustomobject][ordered]@{ roadmaps = $roadmapsRoot; docs = $docsRoot; skillRoots = $skillRoots }
        roadmaps = [pscustomobject][ordered]@{
            idPattern = $idPattern; taskIdPattern = $taskIdPattern; statuses = $statuses; taskStatuses = $taskStatuses
            priorities = $priorities; lanes = $lanes
            wip = [pscustomobject][ordered]@{ activeByLane = [pscustomobject]$activeByLane; readyTasksPerRoadmap = $readyLimit }
        }
        docs = [pscustomobject][ordered]@{ legacyBaseline = $legacyBaseline; kinds = $kinds; statuses = $docStatuses }
        requirements = [pscustomobject][ordered]@{ pwsh = $pwshRequirement; git = $gitRequirement }
        source = 'file'
        sourcePath = $configPath
    }
}

Export-ModuleMember -Function Get-RoadmapKitConfig
