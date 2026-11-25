[CmdletBinding()]
param(
    [ValidateSet('check', 'index', 'next', 'portfolio', 'resume', 'new', 'close-check', 'close')]
    [string]$Command = 'check',

    [string]$Roadmap,

    [string]$RepoRoot,

    [string]$Title,

    [string]$RoadmapSlug,

    [string]$Priority,

    [string]$Lane,

    [string]$Now,

    [string]$NextGate,

    [string]$Task,

    [string]$TaskTitle,

    [string]$TaskSlug,

    [string]$TaskType = 'implementation',

    [string]$Workflow = 'roadmap-delivery',

    [string]$ExecutorSkill = 'roadmap-execute',

    [string]$VerificationSkills = 'roadmap-verify',

    [string]$DocsImpact,

    [string]$DocsTargets,

    [string]$DocsImpactReason,

    [string]$ClosingCommit = 'HEAD',

    [string]$ClosedDate = (Get-Date -Format 'yyyy-MM-dd'),

    [string]$Documentation,

    [ValidateSet('text', 'json')]
    [string]$OutputFormat = 'text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$ConfigModule = Join-Path $PSScriptRoot 'roadmap-kit-config.psm1'
if (-not (Test-Path -LiteralPath $ConfigModule -PathType Leaf)) { throw "Falta el loader de configuración: $ConfigModule" }
Import-Module $ConfigModule -Force
$KitConfig = Get-RoadmapKitConfig -RepoRoot $RepoRoot
$RoadmapsRelativeRoot = [string]$KitConfig.paths.roadmaps
$RoadmapsRoot = Join-Path $RepoRoot $RoadmapsRelativeRoot
$OpenRoot = Join-Path $RoadmapsRoot 'open'
$ArchiveRoot = Join-Path $RoadmapsRoot 'archive'
$WorkflowRoot = Join-Path $RoadmapsRoot 'workflows'
$SkillRoots = @($KitConfig.paths.skillRoots | ForEach-Object { Join-Path $RepoRoot ([string]$_) })
$RoadmapIdPattern = [string]$KitConfig.roadmaps.idPattern
$TaskIdPattern = [string]$KitConfig.roadmaps.taskIdPattern
$ValidRoadmapStatuses = @($KitConfig.roadmaps.statuses)
$ValidTaskStatuses = @($KitConfig.roadmaps.taskStatuses)
$ValidPriorities = @($KitConfig.roadmaps.priorities)
$ValidLanes = @($KitConfig.roadmaps.lanes)
$ActiveWipByLane = $KitConfig.roadmaps.wip.activeByLane
$ReadyTaskLimit = [int]$KitConfig.roadmaps.wip.readyTasksPerRoadmap
$IndexPath = Join-Path $RoadmapsRoot 'README.md'
$ArchiveIndexPath = Join-Path $ArchiveRoot 'README.md'
$DocsScript = Join-Path $RepoRoot 'scripts/docs.ps1'
$script:LifecycleWriteCount = 0

function Read-FrontMatter {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "Frontmatter ausente en $Path"
    }

    $metadata = [ordered]@{}
    $closed = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') {
            $closed = $true
            break
        }
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf(':')
        if ($separator -lt 1) {
            throw "Frontmatter inválido en ${Path}: $line"
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $metadata[$key] = $value
    }
    if (-not $closed) {
        throw "Frontmatter sin cierre en $Path"
    }
    return $metadata
}

function Get-OpenRoadmaps {
    if (-not (Test-Path -LiteralPath $OpenRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $OpenRoot -Directory | ForEach-Object {
        $readme = Join-Path $_.FullName 'README.md'
        if (-not (Test-Path -LiteralPath $readme)) {
            throw "Falta README.md en $($_.FullName)"
        }
        [pscustomobject]@{
            Folder = $_.Name
            Path = $readme
            Root = $_.FullName
            Meta = Read-FrontMatter -Path $readme
        }
    })
}

function Get-MetaValue {
    param($Roadmap, [string]$Key)
    if ($Roadmap.Meta.Contains($Key)) { return [string]$Roadmap.Meta[$Key] }
    return ''
}

function Get-ConfiguredRank {
    param([object[]]$Values, [string]$Value)
    $rank = [array]::IndexOf($Values, $Value)
    if ($rank -lt 0) { return [int]::MaxValue }
    return $rank
}

function Escape-MarkdownCell {
    param([string]$Value)
    return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Assert-SingleLineValue {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw [ArgumentException]::new("$Name es obligatorio y debe ocupar una sola línea.")
    }
}

function Assert-PortableSlug {
    param([string]$Value, [string]$Name)
    Assert-SingleLineValue $Value $Name
    if ($Value -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw [ArgumentException]::new("$Name debe usar minúsculas ASCII, números y guiones simples.")
    }
}

function Assert-PortableName {
    param([string]$Value, [string]$Name)
    Assert-SingleLineValue $Value $Name
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Value.Contains('..')) {
        throw [ArgumentException]::new("$Name contiene caracteres no portables.")
    }
}

function Write-Utf8Text {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n").Replace("`r", "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-FileSnapshot {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [pscustomobject]@{ Exists = $true; Bytes = [IO.File]::ReadAllBytes($Path) }
    }
    return [pscustomobject]@{ Exists = $false; Bytes = $null }
}

function Restore-FileSnapshot {
    param([string]$Path, $Snapshot)
    if ($Snapshot.Exists) {
        $parent = Split-Path -Parent $Path
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        [IO.File]::WriteAllBytes($Path, $Snapshot.Bytes)
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Invoke-LifecycleFaultIfRequested {
    $script:LifecycleWriteCount++
    $requested = 0
    if ([int]::TryParse([string]$env:ROADMAP_KIT_TEST_FAIL_AFTER_LIFECYCLE_WRITE, [ref]$requested) -and
        $requested -gt 0 -and $script:LifecycleWriteCount -eq $requested) {
        throw [InvalidOperationException]::new("Fallo de lifecycle inyectado después de la escritura $requested.")
    }
}

function Get-TemplateBody {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [ArgumentException]::new("Template inexistente: $Path")
    }
    $raw = (Get-Content -Raw -LiteralPath $Path).Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $raw.StartsWith("---`n")) { throw [ArgumentException]::new("Template sin frontmatter: $Path") }
    $end = $raw.IndexOf("`n---`n", 4, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw [ArgumentException]::new("Template con frontmatter sin cierre: $Path") }
    return $raw.Substring($end + 5).TrimStart("`n")
}

function Get-ArchivedRoadmapById {
    param([string]$RoadmapId)
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) { return $null }
    foreach ($closeout in Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter 'CLOSEOUT.md') {
        try {
            $meta = Read-FrontMatter -Path $closeout.FullName
            if ($meta.Contains('id') -and [string]$meta['id'] -eq $RoadmapId) {
                return [pscustomobject]@{ Path = $closeout.FullName; Meta = $meta }
            }
        }
        catch { continue }
    }
    return $null
}

function Test-SkillExists {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($root in $SkillRoots) {
        if (Test-Path -LiteralPath (Join-Path $root "$Name/SKILL.md")) { return $true }
    }
    return $false
}

function Test-LocalMarkdownLinks {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        [switch]$SkipGeneratedIndex
    )

    $roots = @(
        (Join-Path $RepoRoot 'AGENTS.md'),
        (Join-Path $RoadmapsRoot 'README.md'),
        (Join-Path $RoadmapsRoot 'AGENTS.md'),
        (Join-Path $RoadmapsRoot 'open'),
        (Join-Path $RoadmapsRoot 'archive'),
        (Join-Path $RoadmapsRoot 'workflows'),
        (Join-Path $RepoRoot '.agents/roles')
    ) + $SkillRoots
    $files = foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root -PathType Leaf) { Get-Item -LiteralPath $root }
        elseif (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md'
        }
    }

    foreach ($file in $files) {
        if ($SkipGeneratedIndex -and $file.FullName -eq $IndexPath) { continue }
        $content = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in [regex]::Matches($content, '(?<!!)\[[^\]]+\]\((?<target>[^)]+)\)')) {
            $target = $match.Groups['target'].Value.Trim().Trim('<', '>')
            if (-not $target -or $target.StartsWith('#') -or $target -match '^[a-z][a-z0-9+.-]*:') { continue }
            $pathPart = ($target -split '#', 2)[0]
            if (-not $pathPart) { continue }
            $resolved = Join-Path $file.DirectoryName ([uri]::UnescapeDataString($pathPart))
            if (-not (Test-Path -LiteralPath $resolved)) {
                $relativeFile = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName)
                $Errors.Add("${relativeFile}: enlace local inexistente '$target'")
            }
        }
    }
}

function Test-ArchiveCloseouts {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        [hashtable]$SeenIds
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot)) { return }
    $required = @('id', 'title', 'status', 'closed', 'closing_commit', 'documentation')
    foreach ($closeout in Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter 'CLOSEOUT.md') {
        try {
            $meta = Read-FrontMatter -Path $closeout.FullName
            foreach ($key in $required) {
                if (-not $meta.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$meta[$key])) {
                    $Errors.Add("$($closeout.FullName): falta metadata '$key'")
                }
            }
            $id = if ($meta.Contains('id')) { [string]$meta['id'] } else { '' }
            if ($id) {
                if ($SeenIds.ContainsKey($id)) { $Errors.Add("ID duplicado: $id") }
                else { $SeenIds[$id] = $closeout.FullName }
            }
            if ($meta.Contains('status') -and [string]$meta['status'] -ne 'closed') {
                $Errors.Add("${id}: closeout debe tener status 'closed'")
            }
            $closed = [datetime]::MinValue
            if ($meta.Contains('closed') -and -not [datetime]::TryParseExact([string]$meta['closed'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$closed)) {
                $Errors.Add("${id}: closed debe usar yyyy-MM-dd")
            }
            if ($meta.Contains('closing_commit')) {
                $commit = [string]$meta['closing_commit']
                & git -C $RepoRoot cat-file -e "${commit}^{commit}" 2>$null
                if ($LASTEXITCODE -ne 0) { $Errors.Add("${id}: closing_commit inexistente '$commit'") }
            }
            if ($meta.Contains('documentation')) {
                foreach ($documentationPath in @(([string]$meta['documentation']) -split ',' |
                    ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ })) {
                    $documentation = Join-Path $RepoRoot $documentationPath
                    if (-not (Test-Path -LiteralPath $documentation)) {
                        $Errors.Add("${id}: documentation inexistente '$documentationPath'")
                    }
                }
            }
        }
        catch { $Errors.Add($_.Exception.Message) }
    }
}

function Invoke-Check {
    param(
        [switch]$SkipGeneratedIndexLinks,
        [switch]$Quiet
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $roadmaps = @(Get-OpenRoadmaps)
    $required = @('id', 'title', 'status', 'priority', 'lane', 'updated', 'last_verified_commit', 'next_task', 'depends_on', 'now', 'next_gate')
    $validTaskTypes = @('implementation', 'research', 'verification', 'maintenance')
    $seenIds = @{}
    $seenTaskIds = @{}

    foreach ($roadmap in $roadmaps) {
        foreach ($key in $required) {
            if (-not $roadmap.Meta.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$roadmap.Meta[$key])) {
                $errors.Add("$($roadmap.Folder): falta metadata '$key'")
            }
        }

        $id = Get-MetaValue $roadmap 'id'
        if ($id) {
            if ($id -notmatch $RoadmapIdPattern) { $errors.Add("ID de roadmap inválido: '$id'") }
            elseif ($seenIds.ContainsKey($id)) { $errors.Add("ID duplicado: $id") }
            else { $seenIds[$id] = $roadmap.Folder }
        }

        $status = Get-MetaValue $roadmap 'status'
        if ($status -and $status -notin $ValidRoadmapStatuses) { $errors.Add("${id}: status inválido '$status'") }
        $priority = Get-MetaValue $roadmap 'priority'
        if ($priority -and $priority -notin $ValidPriorities) { $errors.Add("${id}: priority inválida '$priority'") }
        $lane = Get-MetaValue $roadmap 'lane'
        if ($lane -and $lane -notin $ValidLanes) { $errors.Add("${id}: lane inválido '$lane'") }

        $updatedText = Get-MetaValue $roadmap 'updated'
        $updated = [datetime]::MinValue
        if ($updatedText -and -not [datetime]::TryParseExact($updatedText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$updated)) {
            $errors.Add("${id}: updated debe usar yyyy-MM-dd")
        }
        elseif ($updated -ne [datetime]::MinValue -and ((Get-Date).Date - $updated.Date).TotalDays -gt 45) {
            $warnings.Add("${id}: no se verifica hace más de 45 días ($updatedText)")
        }

        $commit = Get-MetaValue $roadmap 'last_verified_commit'
        if ($commit -and $commit -ne 'HEAD') {
            & git -C $RepoRoot cat-file -e "${commit}^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) { $errors.Add("${id}: commit inexistente '$commit'") }
        }

        $taskRel = Get-MetaValue $roadmap 'next_task'
        if ($taskRel -and $taskRel -ne 'none') {
            $taskPath = Join-Path $roadmap.Root $taskRel
            if (-not (Test-Path -LiteralPath $taskPath)) {
                $errors.Add("${id}: next_task no existe: $taskRel")
            }
            else {
                try {
                    $taskMeta = Read-FrontMatter -Path $taskPath
                    $taskStatus = if ($taskMeta.Contains('status')) { [string]$taskMeta['status'] } else { '' }
                    if ($taskStatus -notin $ValidTaskStatuses) { $errors.Add("${id}: status inválido en next_task '$taskStatus'") }
                    if ($status -in @('active', 'ready') -and $taskStatus -notin @('ready', 'doing')) {
                        $errors.Add("${id}: next_task debe estar ready/doing mientras el roadmap esté '$status'")
                    }
                    if ($taskMeta.Contains('roadmap') -and [string]$taskMeta['roadmap'] -ne $id) {
                        $errors.Add("${id}: next_task declara roadmap '$($taskMeta['roadmap'])'")
                    }
                }
                catch { $errors.Add($_.Exception.Message) }
            }
        }

        $tasksRoot = Join-Path $roadmap.Root 'tasks'
        if (Test-Path -LiteralPath $tasksRoot) {
            $doing = 0
            $ready = 0
            foreach ($task in Get-ChildItem -LiteralPath $tasksRoot -File -Filter '*.md') {
                try {
                    $taskMeta = Read-FrontMatter -Path $task.FullName
                    $taskRequired = @('id', 'roadmap', 'title', 'status', 'type', 'workflow', 'executor_skill', 'verification_skills', 'depends_on', 'updated')
                    foreach ($key in $taskRequired) {
                        if (-not $taskMeta.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$taskMeta[$key])) {
                            $errors.Add("$($task.FullName): falta metadata '$key'")
                        }
                    }
                    $taskId = if ($taskMeta.Contains('id')) { [string]$taskMeta['id'] } else { '' }
                    if ($taskId) {
                        if ($taskId -notmatch $TaskIdPattern) { $errors.Add("ID de tarea inválido: '$taskId'") }
                        elseif ($seenTaskIds.ContainsKey($taskId)) { $errors.Add("ID de tarea duplicado: $taskId") }
                        else { $seenTaskIds[$taskId] = $task.FullName }
                    }
                    if ($taskMeta.Contains('roadmap') -and [string]$taskMeta['roadmap'] -ne $id) {
                        $errors.Add("${taskId}: declara roadmap '$($taskMeta['roadmap'])', esperado '$id'")
                    }
                    if ($taskMeta.Contains('status')) {
                        $taskStatus = [string]$taskMeta['status']
                        if ($taskStatus -notin $ValidTaskStatuses) { $errors.Add("${taskId}: status inválido '$taskStatus'") }
                        if ($taskStatus -eq 'doing') { $doing++ }
                        if ($taskStatus -eq 'ready') { $ready++ }
                    }
                    if ($taskMeta.Contains('type') -and [string]$taskMeta['type'] -notin $validTaskTypes) {
                        $errors.Add("${taskId}: type inválido '$($taskMeta['type'])'")
                    }
                    if ($taskMeta.Contains('workflow')) {
                        $workflow = [string]$taskMeta['workflow']
                        if (-not (Test-Path -LiteralPath (Join-Path $WorkflowRoot "$workflow.md"))) {
                            $errors.Add("${taskId}: workflow inexistente '$workflow'")
                        }
                    }
                    $skillNames = @()
                    if ($taskMeta.Contains('executor_skill')) { $skillNames += [string]$taskMeta['executor_skill'] }
                    if ($taskMeta.Contains('verification_skills')) { $skillNames += ([string]$taskMeta['verification_skills'] -split ',') }
                    foreach ($skill in ($skillNames | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)) {
                        if (-not (Test-SkillExists -Name $skill)) { $errors.Add("${taskId}: skill inexistente '$skill'") }
                    }
                    if ($taskMeta.Contains('updated')) {
                        $taskUpdated = [datetime]::MinValue
                        if (-not [datetime]::TryParseExact([string]$taskMeta['updated'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$taskUpdated)) {
                            $errors.Add("${taskId}: updated debe usar yyyy-MM-dd")
                        }
                    }
                }
                catch { $errors.Add($_.Exception.Message) }
            }
            if ($doing -gt 1) { $errors.Add("${id}: tiene $doing tareas doing; máximo 1") }
            if ($ready -gt $ReadyTaskLimit) { $errors.Add("${id}: tiene $ready tareas ready; máximo $ReadyTaskLimit") }
        }
    }

    foreach ($roadmap in $roadmaps) {
        $id = Get-MetaValue $roadmap 'id'
        $deps = Get-MetaValue $roadmap 'depends_on'
        if ($deps -and $deps -ne 'none') {
            foreach ($dep in ($deps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if (-not $seenIds.ContainsKey($dep)) { $errors.Add("${id}: dependencia abierta inexistente '$dep'") }
                if ($dep -eq $id) { $errors.Add("${id}: no puede depender de sí mismo") }
            }
            $status = Get-MetaValue $roadmap 'status'
            if ($status -in @('active', 'ready')) {
                $errors.Add("${id}: no puede estar '$status' mientras depends_on siga abierto ($deps)")
            }
        }
    }

    Test-ArchiveCloseouts -Errors $errors -SeenIds $seenIds

    foreach ($limit in @($ActiveWipByLane.PSObject.Properties)) {
        $active = @($roadmaps | Where-Object { (Get-MetaValue $_ 'status') -eq 'active' -and (Get-MetaValue $_ 'lane') -eq $limit.Name })
        if ($active.Count -gt [int]$limit.Value) { $errors.Add("WIP: hay $($active.Count) roadmaps lane '$($limit.Name)' activos; máximo $($limit.Value)") }
    }

    Test-LocalMarkdownLinks -Errors $errors -SkipGeneratedIndex:$SkipGeneratedIndexLinks

    if (Test-Path -LiteralPath $DocsScript -PathType Leaf) {
        $docsJson = @(& pwsh -NoProfile -File $DocsScript check -Format json -RepoRoot $RepoRoot 2>$null)
        $docsExit = $LASTEXITCODE
        if ($docsExit -ne 0) {
            try {
                $docsResult = ($docsJson -join "`n") | ConvertFrom-Json
                $docsErrors = if ($null -ne $docsResult.PSObject.Properties['errors']) { @($docsResult.errors) } else { @() }
                $docsError = if ($null -ne $docsResult.PSObject.Properties['error']) { [string]$docsResult.error } else { $null }
                foreach ($problem in $docsErrors) {
                    $errors.Add("Living Docs $($problem.path):$($problem.line) [$($problem.code)] $($problem.message)")
                }
                if ($docsError) { $errors.Add("Living Docs: $docsError") }
                if ($docsErrors.Count -eq 0 -and -not $docsError) {
                    $errors.Add("Living Docs check falló con exit $docsExit.")
                }
            }
            catch { $errors.Add("Living Docs check devolvió una salida inválida (exit $docsExit).") }
        }
    }

    foreach ($warning in $warnings) { Write-Warning $warning }
    if ($errors.Count -gt 0) {
        foreach ($problem in $errors) { Write-Error $problem -ErrorAction Continue }
        if (-not $Quiet) { Write-Host "Roadmap check: $($errors.Count) error(es), $($warnings.Count) advertencia(s)." }
        return $false
    }

    if (-not $Quiet) { Write-Host "Roadmap check: OK ($($roadmaps.Count) abiertos, $($warnings.Count) advertencia(s))." }
    return $true
}

function Write-Index {
    $roadmaps = @(Get-OpenRoadmaps)
    $statusRank = @{}
    for ($i = 0; $i -lt $ValidRoadmapStatuses.Count; $i++) { $statusRank[$ValidRoadmapStatuses[$i]] = $i }
    $priorityRank = @{}
    for ($i = 0; $i -lt $ValidPriorities.Count; $i++) { $priorityRank[$ValidPriorities[$i]] = $i }
    $ordered = @($roadmaps | Sort-Object `
        @{ Expression = { $statusRank[(Get-MetaValue $_ 'status')] } },
        @{ Expression = { $priorityRank[(Get-MetaValue $_ 'priority')] } },
        @{ Expression = { Get-MetaValue $_ 'id' } })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Roadmaps abiertos')
    $lines.Add('')
    $lines.Add("> Índice generado por ``scripts/roadmap.ps1 index``. La metadata canónica vive en cada ``$RoadmapsRelativeRoot/open/*/README.md``.")
    $lines.Add('> Los cierres están fuera del contexto normal en [`archive/`](archive/README.md).')
    $lines.Add('')
    $lines.Add('| ID | Roadmap | Estado | Prioridad | Lane | Ahora | Próximo gate | Verificado |')
    $lines.Add('|---|---|---|---|---|---|---|---|')
    foreach ($roadmap in $ordered) {
        $id = Escape-MarkdownCell (Get-MetaValue $roadmap 'id')
        $title = Escape-MarkdownCell (Get-MetaValue $roadmap 'title')
        $status = Escape-MarkdownCell (Get-MetaValue $roadmap 'status')
        $priority = Escape-MarkdownCell (Get-MetaValue $roadmap 'priority')
        $lane = Escape-MarkdownCell (Get-MetaValue $roadmap 'lane')
        $now = Escape-MarkdownCell (Get-MetaValue $roadmap 'now')
        $gate = Escape-MarkdownCell (Get-MetaValue $roadmap 'next_gate')
        $commit = Escape-MarkdownCell (Get-MetaValue $roadmap 'last_verified_commit')
        $lines.Add("| $id | [$title](open/$($roadmap.Folder)/) | $status | $priority | $lane | $now | $gate | ``$commit`` |")
    }
    $lines.Add('')
    $lines.Add('## Cómo retomar trabajo')
    $lines.Add('')
    $lines.Add('1. Ejecutar `pwsh -NoProfile -File scripts/roadmap.ps1 next`.')
    $lines.Add('2. Generar el paquete mínimo con `pwsh -NoProfile -File scripts/roadmap.ps1 resume -Roadmap RM-###`.')
    $lines.Add('3. Leer sólo los archivos indicados, cargar las skills declaradas y seguir el workflow.')
    $lines.Add('4. Antes de terminar, ejecutar `pwsh -NoProfile -File scripts/roadmap.ps1 check` e `index`.')
    $lines.Add('')
    $lines.Add("Estados y límites de WIP están definidos en [``$RoadmapsRelativeRoot/AGENTS.md``](AGENTS.md).")

    Set-Content -LiteralPath $IndexPath -Value $lines -Encoding utf8
    Write-Host "Índice regenerado: $IndexPath"
}

function Get-NewRoadmapContent {
    param(
        [string]$RoadmapId,
        [string]$RoadmapTitle,
        [string]$RoadmapPriority,
        [string]$RoadmapLane,
        [string]$RoadmapNow,
        [string]$RoadmapNextGate,
        [string]$TaskRelativePath,
        [string]$FirstTaskSlug,
        [string]$FirstTaskTitle
    )
    $templatePath = Join-Path $RoadmapsRoot 'templates/ROADMAP.md'
    $body = Get-TemplateBody $templatePath
    $body = $body.Replace('RM-000', $RoadmapId).Replace('Nombre del roadmap', $RoadmapTitle)
    $body = $body.Replace('primer-corte', $FirstTaskSlug).Replace('Primer corte', $FirstTaskTitle)
    $frontMatter = @(
        '---',
        "id: $RoadmapId",
        "title: $RoadmapTitle",
        'status: ready',
        "priority: $RoadmapPriority",
        "lane: $RoadmapLane",
        "updated: $((Get-Date).ToString('yyyy-MM-dd'))",
        'last_verified_commit: HEAD',
        "next_task: $TaskRelativePath",
        'depends_on: none',
        "now: $RoadmapNow",
        "next_gate: $RoadmapNextGate",
        '---',
        ''
    ) -join "`n"
    return $frontMatter + $body.TrimEnd() + "`n"
}

function Get-NewTaskContent {
    param(
        [string]$RoadmapId,
        [string]$TaskId,
        [string]$NewTaskTitle,
        [string]$NewTaskType,
        [string]$TaskWorkflow,
        [string]$TaskExecutorSkill,
        [string]$TaskVerificationSkills,
        [string]$TaskDocsImpact,
        [string]$TaskDocsTargets,
        [string]$TaskDocsImpactReason
    )
    $templatePath = Join-Path $RoadmapsRoot 'templates/TASK.md'
    $body = Get-TemplateBody $templatePath
    $body = $body.Replace('RM-000-T01', $TaskId).Replace('RM-000', $RoadmapId).Replace('Primer corte', $NewTaskTitle)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '---',
        "id: $TaskId",
        "roadmap: $RoadmapId",
        "title: $NewTaskTitle",
        'status: ready',
        "type: $NewTaskType",
        "workflow: $TaskWorkflow",
        "executor_skill: $TaskExecutorSkill",
        "verification_skills: $TaskVerificationSkills",
        'depends_on: none',
        "docs_impact: $TaskDocsImpact"
    )) { $lines.Add($line) }
    if (-not [string]::IsNullOrWhiteSpace($TaskDocsTargets)) { $lines.Add("docs_targets: $TaskDocsTargets") }
    if (-not [string]::IsNullOrWhiteSpace($TaskDocsImpactReason)) { $lines.Add("docs_impact_reason: $TaskDocsImpactReason") }
    $lines.Add("updated: $((Get-Date).ToString('yyyy-MM-dd'))")
    $lines.Add('---')
    $lines.Add('')
    return ($lines -join "`n") + $body.TrimEnd() + "`n"
}

function Invoke-NewRoadmap {
    foreach ($field in @(
        @($Roadmap, 'Roadmap'), @($Title, 'Title'), @($RoadmapSlug, 'RoadmapSlug'), @($Priority, 'Priority'),
        @($Lane, 'Lane'), @($Now, 'Now'), @($NextGate, 'NextGate'), @($Task, 'Task'),
        @($TaskTitle, 'TaskTitle'), @($TaskSlug, 'TaskSlug'), @($TaskType, 'TaskType'),
        @($Workflow, 'Workflow'), @($ExecutorSkill, 'ExecutorSkill'),
        @($VerificationSkills, 'VerificationSkills'), @($DocsImpact, 'DocsImpact')
    )) { Assert-SingleLineValue ([string]$field[0]) ([string]$field[1]) }
    Assert-PortableSlug $RoadmapSlug 'RoadmapSlug'
    Assert-PortableSlug $TaskSlug 'TaskSlug'
    Assert-PortableName $Roadmap 'Roadmap'
    Assert-PortableName $Task 'Task'
    Assert-PortableName $Workflow 'Workflow'
    Assert-PortableName $ExecutorSkill 'ExecutorSkill'
    if ($Roadmap -notmatch $RoadmapIdPattern) { throw [ArgumentException]::new("ID de roadmap inválido: '$Roadmap'.") }
    if ($Task -notmatch $TaskIdPattern) { throw [ArgumentException]::new("ID de tarea inválido: '$Task'.") }
    if (-not $Task.StartsWith("$Roadmap-", [StringComparison]::Ordinal)) {
        throw [ArgumentException]::new("La tarea '$Task' no pertenece a '$Roadmap'.")
    }
    if ($Priority -notin $ValidPriorities) { throw [ArgumentException]::new("Priority inválida '$Priority'.") }
    if ($Lane -notin $ValidLanes) { throw [ArgumentException]::new("Lane inválido '$Lane'.") }
    if ($TaskType -notin @('implementation', 'research', 'verification', 'maintenance')) {
        throw [ArgumentException]::new("TaskType inválido '$TaskType'.")
    }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkflowRoot "$Workflow.md") -PathType Leaf)) {
        throw [ArgumentException]::new("Workflow inexistente '$Workflow'.")
    }
    foreach ($skill in @($ExecutorSkill) + @($VerificationSkills -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        Assert-PortableName $skill 'VerificationSkills'
        if (-not (Test-SkillExists $skill)) { throw [ArgumentException]::new("Skill inexistente '$skill'.") }
    }
    if ($DocsImpact -eq 'none' -and $TaskType -ne 'research' -and [string]::IsNullOrWhiteSpace($DocsImpactReason)) {
        throw [ArgumentException]::new('DocsImpact none exige DocsImpactReason fuera de research.')
    }
    if (-not [string]::IsNullOrWhiteSpace($DocsTargets)) { Assert-SingleLineValue $DocsTargets 'DocsTargets' }
    if (-not [string]::IsNullOrWhiteSpace($DocsImpactReason)) { Assert-SingleLineValue $DocsImpactReason 'DocsImpactReason' }

    $existingOpen = Get-OpenRoadmaps | Where-Object { (Get-MetaValue $_ 'id') -eq $Roadmap } | Select-Object -First 1
    if ($existingOpen -or (Get-ArchivedRoadmapById $Roadmap)) {
        throw [ArgumentException]::new("Roadmap ya existente: $Roadmap")
    }
    $folderName = "$Roadmap-$RoadmapSlug"
    $targetRoot = Join-Path $OpenRoot $folderName
    if (Test-Path -LiteralPath $targetRoot) { throw [ArgumentException]::new("Destino ya existente: $targetRoot") }
    $taskRelativePath = "tasks/$TaskSlug.md"
    $roadmapContent = Get-NewRoadmapContent $Roadmap $Title $Priority $Lane $Now $NextGate $taskRelativePath $TaskSlug $TaskTitle
    $taskContent = Get-NewTaskContent $Roadmap $Task $TaskTitle $TaskType $Workflow $ExecutorSkill $VerificationSkills $DocsImpact $DocsTargets $DocsImpactReason
    $indexSnapshot = Get-FileSnapshot $IndexPath
    $openRootExisted = Test-Path -LiteralPath $OpenRoot -PathType Container
    $stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("roadmap-new-" + [guid]::NewGuid().ToString('N'))
    $stagedRoadmap = Join-Path $stagingRoot $folderName
    $moved = $false
    try {
        Write-Utf8Text (Join-Path $stagedRoadmap 'README.md') $roadmapContent
        Write-Utf8Text (Join-Path $stagedRoadmap $taskRelativePath) $taskContent
        New-Item -ItemType Directory -Force -Path $OpenRoot | Out-Null
        Move-Item -LiteralPath $stagedRoadmap -Destination $targetRoot
        $moved = $true
        Invoke-LifecycleFaultIfRequested
        if (-not (Invoke-Check -SkipGeneratedIndexLinks)) { throw [InvalidOperationException]::new('El roadmap creado no supera check.') }
        Write-Index
        Invoke-LifecycleFaultIfRequested
        if (-not (Invoke-Check)) { throw [InvalidOperationException]::new('El índice generado no supera check.') }
        Write-Host "Roadmap creado: $RoadmapsRelativeRoot/open/$folderName"
        Write-Host "Tarea inicial: $RoadmapsRelativeRoot/open/$folderName/$taskRelativePath"
    }
    catch {
        if ($moved -and (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            [IO.Directory]::Delete($targetRoot, $true)
        }
        Restore-FileSnapshot $IndexPath $indexSnapshot
        if (-not $openRootExisted -and (Test-Path -LiteralPath $OpenRoot -PathType Container) -and
            @(Get-ChildItem -LiteralPath $OpenRoot -Force).Count -eq 0) {
            [IO.Directory]::Delete($OpenRoot, $false)
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot -PathType Container) { [IO.Directory]::Delete($stagingRoot, $true) }
    }
}

function Get-CloseoutContent {
    param($RoadmapRecord, [string]$CloseDate, [string]$Commit, [string[]]$DocumentationPaths)
    $roadmapId = Get-MetaValue $RoadmapRecord 'id'
    $roadmapTitle = Get-MetaValue $RoadmapRecord 'title'
    $templatePath = Join-Path $RoadmapsRoot 'templates/CLOSEOUT.md'
    $body = Get-TemplateBody $templatePath
    $body = $body.Replace('RM-000', $roadmapId).Replace('Nombre del roadmap', $roadmapTitle)
    $body = $body.Replace('Qué quedó funcionando y para quién.', "El lifecycle de $roadmapId quedó verificado y fue retirado del contexto activo.")
    $body = $body.Replace('| Condición de cierre | Test, smoke o commit |', '| Condición de cierre | `roadmap close` ejecutó Living Docs close-check y el check post-archivo |')
    $body = $body.Replace('- Paths administrados bajo `docs/`, separados por coma en el frontmatter si son varios.', (($DocumentationPaths | ForEach-Object { "- ``$_``" }) -join "`n"))
    $body = $body.Replace('- Trabajo que no impide el cierre y, si corresponde, su nuevo roadmap.', '- `roadmap close` no infiere deuda; este registro sólo afirma los gates automáticos que ejecutó.')
    $frontMatter = @(
        '---',
        "id: $roadmapId",
        "title: $roadmapTitle",
        'status: closed',
        "closed: $CloseDate",
        "closing_commit: $Commit",
        "documentation: $($DocumentationPaths -join ', ')",
        '---',
        ''
    ) -join "`n"
    return $frontMatter + $body.TrimEnd() + "`n"
}

function Get-ClosedRoadmapReadmeContent {
    param([string]$Path, [string]$CloseDate, [string]$Commit)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) { $lines.Add($line) }
    $frontMatterClosed = $false
    $delimiterCount = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $delimiterCount++
            if ($delimiterCount -eq 2) { $frontMatterClosed = $true }
            continue
        }
        if ($frontMatterClosed) { continue }
        if ($lines[$i] -match '^status:') { $lines[$i] = 'status: closed' }
        elseif ($lines[$i] -match '^updated:') { $lines[$i] = "updated: $CloseDate" }
        elseif ($lines[$i] -match '^last_verified_commit:') { $lines[$i] = "last_verified_commit: $Commit" }
        elseif ($lines[$i] -match '^next_task:') { $lines[$i] = 'next_task: none' }
        elseif ($lines[$i] -match '^now:') { $lines[$i] = 'now: Cerrado y archivado con documentación estable' }
        elseif ($lines[$i] -match '^next_gate:') { $lines[$i] = 'next_gate: none' }
    }
    return ($lines -join "`n") + "`n"
}

function Update-ArchivedMarkdownLinks {
    param([string]$OriginalRoot, [string]$ArchivedRoot)
    $originalPrefix = $OriginalRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($file in Get-ChildItem -LiteralPath $ArchivedRoot -Recurse -File -Filter '*.md') {
        $relativeFile = [IO.Path]::GetRelativePath($ArchivedRoot, $file.FullName)
        $originalFile = Join-Path $OriginalRoot $relativeFile
        $originalDirectory = Split-Path -Parent $originalFile
        $archivedDirectory = Split-Path -Parent $file.FullName
        $content = Get-Content -Raw -LiteralPath $file.FullName
        $rewritten = [regex]::Replace($content, '(?<prefix>!?\[[^\]]*\]\()(?<target>[^)]+)(?<suffix>\))', [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $target = $match.Groups['target'].Value.Trim()
            if (-not $target -or $target.StartsWith('#') -or $target -match '^[a-z][a-z0-9+.-]*:') { return $match.Value }
            $angled = $target.StartsWith('<') -and $target.EndsWith('>')
            if ($angled) { $target = $target.Trim('<', '>') }
            $parts = $target -split '#', 2
            $pathPart = $parts[0]
            if (-not $pathPart) { return $match.Value }
            $fragment = if ($parts.Count -eq 2) { '#' + $parts[1] } else { '' }
            try {
                $absoluteTarget = [IO.Path]::GetFullPath((Join-Path $originalDirectory ([uri]::UnescapeDataString($pathPart))))
            }
            catch { return $match.Value }
            if ($absoluteTarget.Equals($OriginalRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $absoluteTarget.StartsWith($originalPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $match.Value
            }
            $newTarget = [IO.Path]::GetRelativePath($archivedDirectory, $absoluteTarget).Replace('\', '/') + $fragment
            if ($angled -or $newTarget.Contains(' ')) { $newTarget = "<$newTarget>" }
            return $match.Groups['prefix'].Value + $newTarget + $match.Groups['suffix'].Value
        })
        if ($rewritten -cne $content) { Write-Utf8Text $file.FullName $rewritten }
    }
}

function Get-ArchiveIndexContent {
    param($RoadmapRecord, [string]$FolderName, [string]$CloseDate, [string]$Commit, [string[]]$DocumentationPaths)
    $roadmapId = Get-MetaValue $RoadmapRecord 'id'
    $title = Escape-MarkdownCell (Get-MetaValue $RoadmapRecord 'title')
    $year = $CloseDate.Substring(0, 4)
    $documentationCells = @($DocumentationPaths | ForEach-Object {
        $target = [IO.Path]::GetRelativePath($ArchiveRoot, (Join-Path $RepoRoot $_)).Replace('\', '/')
        "[``$_``]($target)"
    })
    $row = "| $roadmapId | [$title]($year/$FolderName/CLOSEOUT.md) | closed | $CloseDate | ``$Commit`` | $($documentationCells -join '<br>') |"
    $raw = if (Test-Path -LiteralPath $ArchiveIndexPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $ArchiveIndexPath).Replace("`r`n", "`n").Replace("`r", "`n")
    }
    else { "# Roadmaps archivados`n`nLos roadmaps cerrados se conservan fuera del backlog activo.`n" }
    if ($raw -match "(?m)^\|\s*$([regex]::Escape($roadmapId))\s*\|") { return $raw }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($raw.TrimEnd("`n") -split "`n")) { $lines.Add($line) }
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\|\s*ID\s*\|.*\|$') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) {
        $lines.Add('')
        $lines.Add('| ID | Iniciativa | Estado | Cierre | Commit de referencia | Documentación estable |')
        $lines.Add('|---|---|---|---|---|---|')
        $lines.Add($row)
    }
    else {
        $insertAt = $headerIndex + 2
        while ($insertAt -lt $lines.Count -and $lines[$insertAt] -match '^\|.*\|$') { $insertAt++ }
        $lines.Insert($insertAt, $row)
    }
    return ($lines -join "`n") + "`n"
}

function Invoke-CloseRoadmap {
    Assert-SingleLineValue $Roadmap 'Roadmap'
    $archived = Get-ArchivedRoadmapById $Roadmap
    $roadmapRecord = Get-OpenRoadmaps | Where-Object { (Get-MetaValue $_ 'id') -eq $Roadmap } | Select-Object -First 1
    if (-not $roadmapRecord) {
        if ($archived) {
            if (-not (Invoke-Check)) { throw [InvalidOperationException]::new('El archivo existente no supera check.') }
            Write-Host "Roadmap ya archivado; no-op: $Roadmap"
            return
        }
        throw [ArgumentException]::new("Roadmap abierto inexistente: $Roadmap")
    }
    Assert-SingleLineValue $Documentation 'Documentation'
    Assert-SingleLineValue $ClosingCommit 'ClosingCommit'
    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($ClosedDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
        throw [ArgumentException]::new('ClosedDate debe usar yyyy-MM-dd.')
    }
    & git -C $RepoRoot cat-file -e "$ClosingCommit`^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw [ArgumentException]::new("ClosingCommit inexistente '$ClosingCommit'.") }
    if ((Get-MetaValue $roadmapRecord 'next_task') -ne 'none') {
        throw [ArgumentException]::new("$Roadmap debe declarar next_task: none antes del cierre.")
    }
    $tasks = @(Get-ChildItem -LiteralPath (Join-Path $roadmapRecord.Root 'tasks') -File -Filter '*.md' -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { throw [ArgumentException]::new("$Roadmap no contiene tareas verificables.") }
    foreach ($taskFile in $tasks) {
        $taskMeta = Read-FrontMatter $taskFile.FullName
        if (-not $taskMeta.Contains('status') -or [string]$taskMeta['status'] -ne 'done') {
            throw [ArgumentException]::new("Tarea no terminada: $($taskFile.Name)")
        }
    }
    $documentationPaths = @($Documentation -split ',' | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ })
    if ($documentationPaths.Count -eq 0) { throw [ArgumentException]::new('Documentation no puede estar vacío.') }
    $docsPrefix = ([string]$KitConfig.paths.docs).TrimEnd('/') + '/'
    foreach ($path in $documentationPaths) {
        if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)' -or $path.Contains(':') -or
            -not $path.StartsWith($docsPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf)) {
            throw [ArgumentException]::new("Documentation inválida o inexistente: '$path'.")
        }
    }
    if (-not (Invoke-Check)) { throw [InvalidOperationException]::new('El roadmap no supera check previo al cierre.') }

    $folderName = Split-Path -Leaf $roadmapRecord.Root
    $year = $ClosedDate.Substring(0, 4)
    $archiveYearRoot = Join-Path $ArchiveRoot $year
    $archiveTarget = Join-Path $archiveYearRoot $folderName
    if (Test-Path -LiteralPath $archiveTarget) { throw [ArgumentException]::new("Destino de archivo ya existente: $archiveTarget") }
    $closeoutPath = Join-Path $roadmapRecord.Root 'CLOSEOUT.md'
    if (Test-Path -LiteralPath $closeoutPath) { throw [ArgumentException]::new("CLOSEOUT.md ya existe en $Roadmap.") }
    $closeoutContent = Get-CloseoutContent $roadmapRecord $ClosedDate $ClosingCommit $documentationPaths
    $roadmapReadmePath = Join-Path $roadmapRecord.Root 'README.md'
    $closedRoadmapContent = Get-ClosedRoadmapReadmeContent $roadmapReadmePath $ClosedDate $ClosingCommit
    $roadmapReadmeSnapshot = Get-FileSnapshot $roadmapReadmePath
    $markdownSnapshots = @(Get-ChildItem -LiteralPath $roadmapRecord.Root -Recurse -File -Filter '*.md' | ForEach-Object {
        [pscustomobject]@{
            Relative = [IO.Path]::GetRelativePath($roadmapRecord.Root, $_.FullName)
            Bytes = [IO.File]::ReadAllBytes($_.FullName)
        }
    })
    $archiveIndexContent = Get-ArchiveIndexContent $roadmapRecord $folderName $ClosedDate $ClosingCommit $documentationPaths
    $openIndexSnapshot = Get-FileSnapshot $IndexPath
    $archiveIndexSnapshot = Get-FileSnapshot $ArchiveIndexPath
    $archiveYearExisted = Test-Path -LiteralPath $archiveYearRoot -PathType Container
    $moved = $false
    try {
        Write-Utf8Text $closeoutPath $closeoutContent
        Invoke-LifecycleFaultIfRequested
        $docsOutput = @(& pwsh -NoProfile -File $DocsScript close-check -Roadmap $Roadmap -RepoRoot $RepoRoot 2>&1)
        $docsExit = $LASTEXITCODE
        foreach ($line in $docsOutput) { Write-Host $line }
        if ($docsExit -ne 0) { throw [InvalidOperationException]::new('Living Docs close-check bloqueó el cierre.') }

        New-Item -ItemType Directory -Force -Path $archiveYearRoot | Out-Null
        Move-Item -LiteralPath $roadmapRecord.Root -Destination $archiveTarget
        $moved = $true
        Invoke-LifecycleFaultIfRequested
        Write-Utf8Text (Join-Path $archiveTarget 'README.md') $closedRoadmapContent
        Invoke-LifecycleFaultIfRequested
        Update-ArchivedMarkdownLinks $roadmapRecord.Root $archiveTarget
        Invoke-LifecycleFaultIfRequested
        Write-Utf8Text $ArchiveIndexPath $archiveIndexContent
        Invoke-LifecycleFaultIfRequested
        Write-Index
        Invoke-LifecycleFaultIfRequested
        if (-not (Invoke-Check)) { throw [InvalidOperationException]::new('El archivo no supera check post-cierre.') }
        Write-Host "Roadmap archivado: $RoadmapsRelativeRoot/archive/$year/$folderName"
    }
    catch {
        if ($moved -and (Test-Path -LiteralPath $archiveTarget -PathType Container)) {
            Move-Item -LiteralPath $archiveTarget -Destination $roadmapRecord.Root
            $moved = $false
        }
        Restore-FileSnapshot $roadmapReadmePath $roadmapReadmeSnapshot
        foreach ($snapshot in $markdownSnapshots) {
            [IO.File]::WriteAllBytes((Join-Path $roadmapRecord.Root $snapshot.Relative), $snapshot.Bytes)
        }
        if (Test-Path -LiteralPath $closeoutPath -PathType Leaf) { Remove-Item -LiteralPath $closeoutPath -Force }
        Restore-FileSnapshot $ArchiveIndexPath $archiveIndexSnapshot
        Restore-FileSnapshot $IndexPath $openIndexSnapshot
        if (-not $archiveYearExisted -and (Test-Path -LiteralPath $archiveYearRoot -PathType Container) -and
            @(Get-ChildItem -LiteralPath $archiveYearRoot -Force).Count -eq 0) {
            [IO.Directory]::Delete($archiveYearRoot, $false)
        }
        throw
    }
}

function Show-Next {
    $roadmaps = @(Get-OpenRoadmaps)
    $selected = @($roadmaps | Where-Object { (Get-MetaValue $_ 'status') -in @('active', 'ready') } | Sort-Object `
        @{ Expression = { if ((Get-MetaValue $_ 'status') -eq 'active') { 0 } else { 1 } } },
        @{ Expression = { Get-ConfiguredRank $ValidPriorities (Get-MetaValue $_ 'priority') } },
        @{ Expression = { Get-MetaValue $_ 'id' } })
    foreach ($roadmap in $selected) {
        Write-Host "$(Get-MetaValue $roadmap 'id') [$(Get-MetaValue $roadmap 'status')/$(Get-MetaValue $roadmap 'priority')]: $(Get-MetaValue $roadmap 'now')"
        Write-Host "  $($roadmap.Folder)/$(Get-MetaValue $roadmap 'next_task')"
    }
}

function Get-RoadmapProjection {
    param([Parameter(Mandatory)]$RoadmapRecord)

    $taskRel = Get-MetaValue $RoadmapRecord 'next_task'
    $task = $null
    if ($taskRel -and $taskRel -ne 'none') {
        $taskPath = Join-Path $RoadmapRecord.Root $taskRel
        if (Test-Path -LiteralPath $taskPath -PathType Leaf) {
            $taskMeta = Read-FrontMatter -Path $taskPath
            $verification = @(([string]$taskMeta['verification_skills']) -split ',' |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $task = [ordered]@{
                id = [string]$taskMeta['id']
                title = [string]$taskMeta['title']
                status = [string]$taskMeta['status']
                type = [string]$taskMeta['type']
                workflow = [string]$taskMeta['workflow']
                executorSkill = [string]$taskMeta['executor_skill']
                verificationSkills = $verification
            }
        }
    }

    $status = Get-MetaValue $RoadmapRecord 'status'
    $taskStatus = if ($null -ne $task) { [string]$task.status } else { '' }
    return [ordered]@{
        id = Get-MetaValue $RoadmapRecord 'id'
        title = Get-MetaValue $RoadmapRecord 'title'
        status = $status
        priority = Get-MetaValue $RoadmapRecord 'priority'
        lane = Get-MetaValue $RoadmapRecord 'lane'
        now = Get-MetaValue $RoadmapRecord 'now'
        nextGate = Get-MetaValue $RoadmapRecord 'next_gate'
        nextTask = $taskRel
        eligible = ($status -in @('active', 'ready') -and $taskStatus -in @('ready', 'doing'))
        task = $task
    }
}

function Get-PortfolioProjections {
    $statusRank = @{}
    for ($i = 0; $i -lt $ValidRoadmapStatuses.Count; $i++) { $statusRank[$ValidRoadmapStatuses[$i]] = $i }
    return @(Get-OpenRoadmaps | Sort-Object `
        @{ Expression = { $statusRank[(Get-MetaValue $_ 'status')] } },
        @{ Expression = { Get-ConfiguredRank $ValidPriorities (Get-MetaValue $_ 'priority') } },
        @{ Expression = { Get-MetaValue $_ 'id' } } | ForEach-Object { Get-RoadmapProjection $_ })
}

function Write-StructuredJson {
    param([Parameter(Mandatory)]$Value)
    Write-Output ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Show-Portfolio {
    $items = @(Get-PortfolioProjections)
    if ($OutputFormat -eq 'json') {
        Write-StructuredJson ([ordered]@{ schemaVersion = 1; command = 'portfolio'; items = $items })
        return
    }

    foreach ($item in $items) {
        $eligibility = if ($item.eligible) { 'ejecutable' } else { 'sólo lectura' }
        Write-Host "$($item.id) [$($item.status)/$($item.priority)] ($eligibility): $($item.now)"
        Write-Host "  $($item.nextTask)"
    }
}

function Show-Resume {
    $roadmaps = @(Get-OpenRoadmaps)
    $selected = $null
    if ($Roadmap) {
        $selected = $roadmaps | Where-Object { (Get-MetaValue $_ 'id') -eq $Roadmap } | Select-Object -First 1
        if (-not $selected) { throw "Roadmap abierto inexistente: $Roadmap" }
    }
    else {
        $selected = $roadmaps | Where-Object { (Get-MetaValue $_ 'status') -in @('active', 'ready') } | Sort-Object `
            @{ Expression = { if ((Get-MetaValue $_ 'status') -eq 'active') { 0 } else { 1 } } },
            @{ Expression = { Get-ConfiguredRank $ValidPriorities (Get-MetaValue $_ 'priority') } },
            @{ Expression = { Get-MetaValue $_ 'id' } } | Select-Object -First 1
        if (-not $selected) { throw 'No hay roadmaps active/ready para retomar.' }
    }

    $id = Get-MetaValue $selected 'id'
    $taskRel = Get-MetaValue $selected 'next_task'
    $roadmapRel = [IO.Path]::GetRelativePath($RepoRoot, $selected.Path)
    if ($OutputFormat -eq 'json') {
        $readOrder = [System.Collections.Generic.List[string]]::new()
        $readOrder.Add("$RoadmapsRelativeRoot/AGENTS.md")
        $readOrder.Add($roadmapRel.Replace('\\', '/'))
        if ($taskRel -ne 'none') {
            $taskPath = Join-Path $selected.Root $taskRel
            $readOrder.Add([IO.Path]::GetRelativePath($RepoRoot, $taskPath).Replace('\\', '/'))
        }
        Write-StructuredJson ([ordered]@{
            schemaVersion = 1
            command = 'resume'
            roadmap = Get-RoadmapProjection $selected
            readOrder = @($readOrder)
        })
        return
    }

    Write-Host "$id — $(Get-MetaValue $selected 'title')"
    Write-Host "Estado: $(Get-MetaValue $selected 'status') / $(Get-MetaValue $selected 'priority') / $(Get-MetaValue $selected 'lane')"
    Write-Host "Ahora: $(Get-MetaValue $selected 'now')"
    Write-Host "Gate: $(Get-MetaValue $selected 'next_gate')"
    Write-Host 'Leer, en este orden:'
    Write-Host "  $RoadmapsRelativeRoot/AGENTS.md"
    Write-Host "  $roadmapRel"

    if ($taskRel -eq 'none') {
        Write-Host 'No hay next_task; ejecutar triage antes de implementar.'
        return
    }

    $taskPath = Join-Path $selected.Root $taskRel
    $taskMeta = Read-FrontMatter -Path $taskPath
    $taskPathRel = [IO.Path]::GetRelativePath($RepoRoot, $taskPath)
    Write-Host "  $taskPathRel"
    Write-Host "Workflow: $($taskMeta['workflow'])"
    Write-Host "Executor skill: $($taskMeta['executor_skill'])"
    Write-Host "Verification skills: $($taskMeta['verification_skills'])"
    if ((Get-MetaValue $selected 'status') -in @('paused', 'blocked', 'proposed')) {
        Write-Host 'Primero: roadmap-triage; no implementar hasta reactivar y validar dependencias.'
    }
}

switch ($Command) {
    'check' {
        if (-not (Invoke-Check)) { exit 1 }
    }
    'index' {
        # El índice es una vista reparable: después de archivar un roadmap su
        # versión anterior contiene exactamente el link que index debe retirar.
        # Validamos todo salvo esa vista, la regeneramos y recién entonces
        # exigimos el check completo para no ocultar ningún otro enlace roto.
        if (-not (Invoke-Check -SkipGeneratedIndexLinks)) { exit 1 }
        Write-Index
        if (-not (Invoke-Check)) { exit 1 }
    }
    'next' {
        if (-not (Invoke-Check)) { exit 1 }
        Show-Next
    }
    'portfolio' {
        if ($OutputFormat -eq 'json') {
            if (-not (Invoke-Check -Quiet)) { exit 1 }
        }
        elseif (-not (Invoke-Check)) { exit 1 }
        Show-Portfolio
    }
    'resume' {
        if ($OutputFormat -eq 'json') {
            if (-not (Invoke-Check -Quiet)) { exit 1 }
        }
        elseif (-not (Invoke-Check)) { exit 1 }
        Show-Resume
    }
    'new' {
        Invoke-NewRoadmap
    }
    'close-check' {
        if (-not $Roadmap) { throw 'close-check exige -Roadmap RM-###.' }
        if (-not (Invoke-Check)) { exit 1 }
        & pwsh -NoProfile -File $DocsScript close-check -Roadmap $Roadmap -RepoRoot $RepoRoot
        exit $LASTEXITCODE
    }
    'close' {
        Invoke-CloseRoadmap
    }
}
