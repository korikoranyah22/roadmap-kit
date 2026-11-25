[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'index', 'graph', 'affected', 'drift', 'promote', 'migrate', 'close-check')]
    [string]$Command = 'check',

    [ValidateSet('text', 'json')]
    [string]$Format = 'text',

    [switch]$Strict,

    [string]$Base,

    [string]$Head = 'WORKTREE',

    [string]$Roadmap,

    [string]$Task,

    [string]$Document,

    [string]$Manifest,

    [string]$DocumentId,

    [string]$DocumentTitle,

    [string]$Kind,

    [string]$Area,

    [string]$DocumentStatus,

    [string]$Owner,

    [string]$SourcePaths,

    [string]$SourceReason,

    [string]$Roadmaps,

    [string]$DiagramMode,

    [string]$Summary,

    [string]$DocumentOrder,

    [string]$Supersedes,

    [switch]$Apply,

    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$ConfigModule = Join-Path $PSScriptRoot 'roadmap-kit-config.psm1'
if (-not (Test-Path -LiteralPath $ConfigModule -PathType Leaf)) { throw "Falta el loader de configuración: $ConfigModule" }
Import-Module $ConfigModule -Force
$KitConfig = Get-RoadmapKitConfig -RepoRoot $RepoRoot
$DocsRelativeRoot = [string]$KitConfig.paths.docs
$RoadmapsRelativeRoot = [string]$KitConfig.paths.roadmaps
$DocsRepoPrefix = $DocsRelativeRoot.TrimEnd('/') + '/'
$GeneratedRepoPrefix = $DocsRepoPrefix + '_generated/'
$DocsRoot = Join-Path $RepoRoot $DocsRelativeRoot
$RoadmapsRoot = Join-Path $RepoRoot $RoadmapsRelativeRoot
$OpenRoadmapsRoot = Join-Path $RoadmapsRoot 'open'
$ReadmePath = Join-Path $DocsRoot 'README.md'
$LegacyBaselinePath = Join-Path $RepoRoot ([string]$KitConfig.docs.legacyBaseline)
$CatalogPath = Join-Path $DocsRoot '_generated/catalog.md'
$GraphPath = Join-Path $DocsRoot '_generated/structure.md'
$ReadmeRepoPath = $DocsRepoPrefix + 'README.md'
$LegacyBaselineRepoPath = [string]$KitConfig.docs.legacyBaseline
$CatalogRepoPath = $GeneratedRepoPrefix + 'catalog.md'
$GraphRepoPath = $GeneratedRepoPrefix + 'structure.md'
$IndexStart = '<!-- docs:index:start -->'
$IndexEnd = '<!-- docs:index:end -->'

$ValidKinds = @($KitConfig.docs.kinds)
$ValidStatuses = @($KitConfig.docs.statuses)
$ValidDiagramModes = @('none', 'semantic', 'structural')

function ConvertTo-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetRelativePath($RepoRoot, [IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

function New-Issue {
    param(
        [string]$Path,
        [int]$Line,
        [string]$Code,
        [string]$Message,
        [ValidateSet('error', 'warning')][string]$Severity
    )
    return [pscustomobject]@{
        path = $Path
        line = $Line
        code = $Code
        message = $Message
        severity = $Severity
    }
}

function Add-Issue {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Path,
        [int]$Line,
        [string]$Code,
        [string]$Message,
        [ValidateSet('error', 'warning')][string]$Severity
    )
    $List.Add((New-Issue -Path $Path -Line $Line -Code $Code -Message $Message -Severity $Severity))
}

function Read-DocumentFrontMatter {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [System.Collections.Generic.List[object]]$Errors
    )

    $lines = @(Get-Content -LiteralPath $File.FullName)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        return [pscustomobject]@{ HasFrontMatter = $false; Meta = [ordered]@{}; Lines = $lines }
    }

    $meta = [ordered]@{}
    $closed = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') {
            $closed = $true
            break
        }
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -lt 1) {
            Add-Issue $Errors (ConvertTo-RepoPath $File.FullName) ($i + 1) 'FRONTMATTER_SYNTAX' "Línea inválida: $line" 'error'
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($meta.Contains($key)) {
            Add-Issue $Errors (ConvertTo-RepoPath $File.FullName) ($i + 1) 'FRONTMATTER_DUPLICATE' "Campo duplicado '$key'." 'error'
        }
        else {
            $meta[$key] = $value
        }
    }
    if (-not $closed) {
        Add-Issue $Errors (ConvertTo-RepoPath $File.FullName) 1 'FRONTMATTER_UNCLOSED' 'Frontmatter sin cierre.' 'error'
    }
    return [pscustomobject]@{ HasFrontMatter = $true; Meta = $meta; Lines = $lines }
}

function Split-MetadataList {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'none') { return @() }
    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Read-FlatMetadataFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [ArgumentException]::new("Archivo inexistente: $Path")
    }
    $issues = [System.Collections.Generic.List[object]]::new()
    $parsed = Read-DocumentFrontMatter -File (Get-Item -LiteralPath $Path) -Errors $issues
    if (-not $parsed.HasFrontMatter) {
        throw [ArgumentException]::new("Frontmatter ausente en $(ConvertTo-RepoPath $Path).")
    }
    if ($issues.Count -gt 0) {
        throw [ArgumentException]::new(($issues | ForEach-Object { $_.message }) -join '; ')
    }
    return $parsed.Meta
}

function Parse-KeyValueMetadata {
    param([string]$Value)
    $result = @{}
    foreach ($entry in Split-MetadataList $Value) {
        $separator = $entry.IndexOf('=')
        if ($separator -lt 1 -or $separator -eq $entry.Length - 1) {
            throw [ArgumentException]::new("Mapping inválido '$entry'; usar ID=valor.")
        }
        $key = $entry.Substring(0, $separator).Trim()
        $mappedValue = $entry.Substring($separator + 1).Trim()
        if ($result.ContainsKey($key)) {
            throw [ArgumentException]::new("Mapping duplicado para '$key'.")
        }
        $result[$key] = $mappedValue
    }
    return $result
}

function Parse-DocsImpact {
    param([string]$Value)

    $problems = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $problems.Add('docs_impact está vacío.')
        return [pscustomobject]@{ Valid = $false; Problems = @($problems); Actions = @() }
    }
    $entries = if ($Value.Trim() -eq 'none') { @('none') } else { @(Split-MetadataList $Value) }
    if (@($entries).Count -eq 0) {
        $problems.Add('docs_impact está vacío.')
    }
    if ($entries -contains 'none') {
        if (@($entries).Count -ne 1) { $problems.Add("'none' no puede mezclarse con otras acciones.") }
        else { $actions.Add([pscustomobject]@{ action = 'none'; document_id = $null; replacement_id = $null }) }
    }
    else {
        foreach ($entry in $entries) {
            if ($entry -match '^(create|update|verify):(?<id>DOC-[A-Z0-9]+(?:-[A-Z0-9]+)*)$') {
                $actions.Add([pscustomobject]@{ action = $Matches[1]; document_id = $Matches['id']; replacement_id = $null })
                continue
            }
            if ($entry -match '^supersede:(?<old>DOC-[A-Z0-9]+(?:-[A-Z0-9]+)*)->(?<new>DOC-[A-Z0-9]+(?:-[A-Z0-9]+)*)$') {
                $actions.Add([pscustomobject]@{ action = 'supersede'; document_id = $Matches['old']; replacement_id = $Matches['new'] })
                continue
            }
            $problems.Add("Acción inválida '$entry'.")
        }
    }
    $duplicates = @($actions | Group-Object action, document_id, replacement_id | Where-Object Count -gt 1)
    foreach ($duplicate in $duplicates) { $problems.Add("Acción duplicada '$($duplicate.Name)'.") }
    return [pscustomobject]@{ Valid = $problems.Count -eq 0; Problems = @($problems); Actions = @($actions) }
}

function Get-RoadmapRecord {
    param([string]$RoadmapId)
    if ([string]::IsNullOrWhiteSpace($RoadmapId)) {
        throw [ArgumentException]::new('La operación exige -Roadmap RM-###.')
    }
    if (-not (Test-Path -LiteralPath $OpenRoadmapsRoot -PathType Container)) {
        throw [ArgumentException]::new("No existe $RoadmapsRelativeRoot/open en $RepoRoot.")
    }
    foreach ($folder in Get-ChildItem -LiteralPath $OpenRoadmapsRoot -Directory) {
        $readme = Join-Path $folder.FullName 'README.md'
        if (-not (Test-Path -LiteralPath $readme -PathType Leaf)) { continue }
        $meta = Read-FlatMetadataFile $readme
        if ($meta.Contains('id') -and [string]$meta['id'] -eq $RoadmapId) {
            return [pscustomobject]@{ Id = $RoadmapId; Root = $folder.FullName; Meta = $meta; Path = $readme }
        }
    }
    throw [ArgumentException]::new("Roadmap abierto inexistente: '$RoadmapId'.")
}

function Get-RoadmapTaskRecord {
    param($RoadmapRecord, [string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        throw [ArgumentException]::new('promote exige -Task <task-id>.')
    }
    $tasksRoot = Join-Path $RoadmapRecord.Root 'tasks'
    if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $tasksRoot -File -Filter '*.md') {
            $meta = Read-FlatMetadataFile $file.FullName
            if ($meta.Contains('id') -and [string]$meta['id'] -eq $TaskId) {
                return [pscustomobject]@{ Id = $TaskId; Meta = $meta; Path = $file.FullName; File = $file }
            }
        }
    }
    throw [ArgumentException]::new("Tarea '$TaskId' inexistente en $($RoadmapRecord.Id).")
}

function Test-RoadmapImpactMetadata {
    param([System.Collections.Generic.List[object]]$Errors)
    if (-not (Test-Path -LiteralPath $OpenRoadmapsRoot -PathType Container)) { return }
    foreach ($task in Get-ChildItem -LiteralPath $OpenRoadmapsRoot -Recurse -File -Filter '*.md' | Where-Object {
        $_.DirectoryName -match '[\\/]tasks$'
    }) {
        $meta = Read-FlatMetadataFile $task.FullName
        if (-not $meta.Contains('docs_impact')) { continue }
        $parsed = Parse-DocsImpact ([string]$meta['docs_impact'])
        foreach ($problem in $parsed.Problems) {
            Add-Issue $Errors (ConvertTo-RepoPath $task.FullName) 1 'DOCS_IMPACT_INVALID' $problem 'error'
        }
        $taskType = if ($meta.Contains('type')) { [string]$meta['type'] } else { '' }
        if (@($parsed.Actions | Where-Object action -eq 'none').Count -gt 0 -and $taskType -ne 'research' -and
            (-not $meta.Contains('docs_impact_reason') -or [string]::IsNullOrWhiteSpace([string]$meta['docs_impact_reason']))) {
            Add-Issue $Errors (ConvertTo-RepoPath $task.FullName) 1 'DOCS_IMPACT_REASON' 'docs_impact: none exige docs_impact_reason fuera de research.' 'error'
        }
        $creates = @($parsed.Actions | Where-Object action -eq 'create')
        if ($creates.Count -gt 0) {
            if (-not $meta.Contains('docs_targets')) {
                Add-Issue $Errors (ConvertTo-RepoPath $task.FullName) 1 'DOCS_TARGETS_REQUIRED' "Una acción create exige docs_targets con ID=$DocsRelativeRoot/path.md." 'error'
            }
            else {
                try {
                    $targets = Parse-KeyValueMetadata ([string]$meta['docs_targets'])
                    foreach ($action in $creates) {
                        if (-not $targets.ContainsKey($action.document_id)) {
                            Add-Issue $Errors (ConvertTo-RepoPath $task.FullName) 1 'DOCS_TARGET_MISSING' "Falta target para '$($action.document_id)'." 'error'
                        }
                    }
                }
                catch {
                    Add-Issue $Errors (ConvertTo-RepoPath $task.FullName) 1 'DOCS_TARGETS_INVALID' $_.Exception.Message 'error'
                }
            }
        }
    }
}

function Get-RepositoryFiles {
    $gitDir = Join-Path $RepoRoot '.git'
    if (Test-Path -LiteralPath $gitDir) {
        $paths = @(& git -C $RepoRoot ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0) {
            return @($paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
        }
    }
    return @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | ForEach-Object {
        ConvertTo-RepoPath $_.FullName
    } | Sort-Object -Unique)
}

function Convert-GlobToRegex {
    param([string]$Glob)
    $escaped = [regex]::Escape($Glob.Replace('\', '/'))
    $escaped = $escaped.Replace('\*\*', '.*')
    $escaped = $escaped.Replace('\*', '[^/]*')
    $escaped = $escaped.Replace('\?', '[^/]')
    return '^' + $escaped + '$'
}

function Test-SourceGlob {
    param(
        [string]$Glob,
        [string[]]$RepositoryFiles
    )
    if ([IO.Path]::IsPathRooted($Glob) -or $Glob -match '(^|[\\/])\.\.([\\/]|$)' -or $Glob.Contains(':')) {
        return [pscustomobject]@{ Valid = $false; Matches = @() }
    }
    $normalized = $Glob.Replace('\', '/')
    $regex = Convert-GlobToRegex $normalized
    $matches = @($RepositoryFiles | Where-Object { $_ -match $regex })
    return [pscustomobject]@{ Valid = $true; Matches = $matches }
}

function Get-MarkdownLinks {
    param([Parameter(Mandatory)][string]$Path)

    $links = [System.Collections.Generic.List[object]]::new()
    $lines = @(Get-Content -LiteralPath $Path)
    $inFence = $false
    $fenceToken = ''

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ($line -match '^\s*(```|~~~)') {
            $token = $Matches[1]
            if (-not $inFence) { $inFence = $true; $fenceToken = $token }
            elseif ($token -eq $fenceToken) { $inFence = $false; $fenceToken = '' }
            continue
        }
        if ($inFence) { continue }

        $searchFrom = 0
        while ($searchFrom -lt $line.Length) {
            $closeLabel = $line.IndexOf('](', $searchFrom, [StringComparison]::Ordinal)
            if ($closeLabel -lt 0) { break }
            $openLabel = $line.LastIndexOf('[', $closeLabel)
            if ($openLabel -lt 0 -or ($openLabel -gt 0 -and $line[$openLabel - 1] -eq '!')) {
                $searchFrom = $closeLabel + 2
                continue
            }

            $targetStart = $closeLabel + 2
            if ($targetStart -ge $line.Length) { break }
            $target = $null
            $next = $targetStart
            if ($line[$targetStart] -eq '<') {
                $targetEnd = $line.IndexOf('>', $targetStart + 1)
                if ($targetEnd -gt $targetStart) {
                    $target = $line.Substring($targetStart + 1, $targetEnd - $targetStart - 1)
                    $next = $targetEnd + 1
                }
            }
            else {
                $depth = 0
                $escaped = $false
                for ($j = $targetStart; $j -lt $line.Length; $j++) {
                    $ch = $line[$j]
                    if ($escaped) { $escaped = $false; continue }
                    if ($ch -eq '\') { $escaped = $true; continue }
                    if ($ch -eq '(') { $depth++; continue }
                    if ($ch -eq ')') {
                        if ($depth -eq 0) {
                            $target = $line.Substring($targetStart, $j - $targetStart).Trim()
                            $next = $j + 1
                            break
                        }
                        $depth--
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                $links.Add([pscustomobject]@{ Target = $target; Line = $lineIndex + 1 })
            }
            $searchFrom = [Math]::Max($next, $closeLabel + 2)
        }
    }
    return @($links)
}

function Test-DocumentLinks {
    param(
        [IO.FileInfo]$File,
        [ValidateSet('error', 'warning')][string]$Severity,
        [System.Collections.Generic.List[object]]$Errors,
        [System.Collections.Generic.List[object]]$Warnings
    )
    foreach ($link in Get-MarkdownLinks -Path $File.FullName) {
        $target = $link.Target.Trim()
        if (-not $target -or $target.StartsWith('#') -or $target -match '^[a-z][a-z0-9+.-]*:') { continue }
        $pathPart = ($target -split '#', 2)[0]
        if (-not $pathPart) { continue }
        try {
            $decoded = [uri]::UnescapeDataString($pathPart)
            $resolved = [IO.Path]::GetFullPath((Join-Path $File.DirectoryName $decoded))
            $insideRepo = $resolved.Equals($RepoRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $resolved.StartsWith($RepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            if (-not $insideRepo -or -not (Test-Path -LiteralPath $resolved)) {
                if ($Severity -eq 'error') {
                    Add-Issue $Errors (ConvertTo-RepoPath $File.FullName) $link.Line 'BROKEN_LINK' "Enlace local inexistente '$target'." $Severity
                }
                else {
                    Add-Issue $Warnings (ConvertTo-RepoPath $File.FullName) $link.Line 'BROKEN_LINK' "Enlace local inexistente '$target'." $Severity
                }
            }
        }
        catch {
            if ($Severity -eq 'error') {
                Add-Issue $Errors (ConvertTo-RepoPath $File.FullName) $link.Line 'BROKEN_LINK' "Enlace local inválido '$target'." $Severity
            }
            else {
                Add-Issue $Warnings (ConvertTo-RepoPath $File.FullName) $link.Line 'BROKEN_LINK' "Enlace local inválido '$target'." $Severity
            }
        }
    }
}

function Test-SupersessionNode {
    param(
        [string]$Id,
        [hashtable]$Edges,
        [hashtable]$States,
        [hashtable]$DocumentsById,
        [System.Collections.Generic.List[object]]$Errors
    )
    if ($States.ContainsKey($Id) -and $States[$Id] -eq 2) { return }
    if ($States.ContainsKey($Id) -and $States[$Id] -eq 1) {
        $doc = $DocumentsById[$Id]
        Add-Issue $Errors $doc.RelPath 1 'SUPERSESSION_CYCLE' "Ciclo de supersession que vuelve a '$Id'." 'error'
        return
    }
    $States[$Id] = 1
    if ($Edges.ContainsKey($Id)) {
        foreach ($target in $Edges[$Id]) {
            if ($DocumentsById.ContainsKey($target)) {
                Test-SupersessionNode $target $Edges $States $DocumentsById $Errors
            }
        }
    }
    $States[$Id] = 2
}

function Get-MermaidFenceAudit {
    param([string[]]$Lines)

    $count = 0
    $insideFence = $false
    $openFence = ''
    $openIsMermaid = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        $match = [regex]::Match($trimmed, '^(?<fence>[`]{3,}|[~]{3,})(?<info>.*)$')
        if (-not $match.Success) { continue }

        $fence = $match.Groups['fence'].Value
        $info = $match.Groups['info'].Value.Trim()
        if (-not $insideFence) {
            $insideFence = $true
            $openFence = $fence
            $openIsMermaid = $info -match '^(?i:mermaid)(?:\s|$)'
            if ($openIsMermaid) { $count++ }
            continue
        }

        $sameMarker = $fence[0] -eq $openFence[0]
        $longEnough = $fence.Length -ge $openFence.Length
        if ($sameMarker -and $longEnough -and [string]::IsNullOrWhiteSpace($info)) {
            $insideFence = $false
            $openFence = ''
            $openIsMermaid = $false
        }
    }

    return [pscustomobject]@{
        Count = $count
        UnclosedMermaid = $insideFence -and $openIsMermaid
    }
}

function Invoke-DocsValidation {
    if (-not (Test-Path -LiteralPath $DocsRoot -PathType Container)) {
        throw "No existe el directorio documental configurado: $DocsRoot"
    }

    $errors = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    $documents = [System.Collections.Generic.List[object]]::new()
    $legacy = [System.Collections.Generic.List[string]]::new()
    $documentsById = @{}
    $edges = @{}
    $repositoryFiles = @(Get-RepositoryFiles)

    $baseline = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $LegacyBaselinePath -PathType Leaf)) {
        Add-Issue $errors $LegacyBaselineRepoPath 1 'LEGACY_BASELINE_MISSING' 'Falta el baseline de compatibilidad legacy.' 'error'
    }
    else {
        $baselineLine = 0
        foreach ($line in Get-Content -LiteralPath $LegacyBaselinePath) {
            $baselineLine++
            $entry = $line.Trim().Replace('\', '/')
            if (-not $entry -or $entry.StartsWith('#')) { continue }
            if (-not $entry.StartsWith($DocsRepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Issue $errors $LegacyBaselineRepoPath $baselineLine 'LEGACY_PATH' "El path debe ser relativo al repo y comenzar con ${DocsRepoPrefix}: '$entry'." 'error'
                continue
            }
            if (-not $baseline.Add($entry)) {
                Add-Issue $errors $LegacyBaselineRepoPath $baselineLine 'LEGACY_DUPLICATE' "Entrada duplicada '$entry'." 'error'
            }
        }
    }

    $files = @(Get-ChildItem -LiteralPath $DocsRoot -Recurse -File -Filter '*.md' | Where-Object {
        $_.FullName -ne $ReadmePath
    } | Sort-Object FullName)

    foreach ($file in $files) {
        $relPath = ConvertTo-RepoPath $file.FullName
        $parsed = Read-DocumentFrontMatter -File $file -Errors $errors
        if (-not $parsed.HasFrontMatter) {
            if ($baseline.Contains($relPath)) {
                $legacy.Add($relPath)
            }
            else {
                Add-Issue $errors $relPath 1 'UNMANAGED_DOCUMENT' 'Documento sin frontmatter y fuera del baseline legacy.' 'error'
            }
            continue
        }

        if ($baseline.Contains($relPath)) {
            Add-Issue $errors $LegacyBaselineRepoPath 1 'MIGRATED_STILL_LEGACY' "'$relPath' ya tiene metadata; retirarlo del baseline." 'error'
        }

        $meta = $parsed.Meta
        foreach ($key in @('id', 'title', 'kind', 'area', 'status', 'owner')) {
            if (-not $meta.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$meta[$key])) {
                Add-Issue $errors $relPath 1 'REQUIRED_FIELD' "Falta metadata '$key'." 'error'
            }
        }

        $doc = [pscustomobject]@{ File = $file; RelPath = $relPath; Meta = $meta }
        $documents.Add($doc)

        $id = if ($meta.Contains('id')) { [string]$meta['id'] } else { '' }
        if ($id) {
            if ($id -notmatch '^DOC-[A-Z0-9]+(?:-[A-Z0-9]+)*$') {
                Add-Issue $errors $relPath 2 'INVALID_ID' "ID inválido '$id'." 'error'
            }
            elseif ($documentsById.ContainsKey($id)) {
                Add-Issue $errors $relPath 2 'DUPLICATE_ID' "ID duplicado '$id'; primero en $($documentsById[$id].RelPath)." 'error'
            }
            else {
                $documentsById[$id] = $doc
            }
        }

        $kind = if ($meta.Contains('kind')) { [string]$meta['kind'] } else { '' }
        $status = if ($meta.Contains('status')) { [string]$meta['status'] } else { '' }
        if ($kind -and $kind -notin $ValidKinds) {
            Add-Issue $errors $relPath 1 'INVALID_KIND' "kind inválido '$kind'." 'error'
        }
        if ($status -and $status -notin $ValidStatuses) {
            Add-Issue $errors $relPath 1 'INVALID_STATUS' "status inválido '$status'." 'error'
        }
        if ($meta.Contains('order')) {
            $order = 0
            if (-not [int]::TryParse([string]$meta['order'], [ref]$order)) {
                Add-Issue $errors $relPath 1 'INVALID_ORDER' 'order debe ser entero.' 'error'
            }
        }
        $diagramMode = if ($meta.Contains('diagram_mode')) { [string]$meta['diagram_mode'] } else { '' }
        if ($diagramMode -and $diagramMode -notin $ValidDiagramModes) {
            Add-Issue $errors $relPath 1 'INVALID_DIAGRAM_MODE' "diagram_mode inválido '$diagramMode'." 'error'
        }
        if ($kind -eq 'generated' -and (-not $meta.Contains('generated_by') -or [string]::IsNullOrWhiteSpace([string]$meta['generated_by']))) {
            Add-Issue $errors $relPath 1 'GENERATED_BY_REQUIRED' 'Un documento generated debe declarar generated_by.' 'error'
        }
        if ($kind -eq 'generated' -and $diagramMode -ne 'structural') {
            Add-Issue $errors $relPath 1 'GENERATED_DIAGRAM_MODE' 'Un documento generated debe declarar diagram_mode: structural.' 'error'
        }
        if ($diagramMode -eq 'semantic') {
            if (-not $meta.Contains('source_paths') -or [string]::IsNullOrWhiteSpace([string]$meta['source_paths']) -or [string]$meta['source_paths'] -eq 'none') {
                Add-Issue $errors $relPath 1 'SEMANTIC_SOURCES_REQUIRED' 'diagram_mode: semantic exige source_paths verificables.' 'error'
            }
            $mermaid = Get-MermaidFenceAudit -Lines $parsed.Lines
            if ($mermaid.Count -eq 0) {
                Add-Issue $errors $relPath 1 'SEMANTIC_MERMAID_REQUIRED' 'diagram_mode: semantic exige al menos un bloque Mermaid.' 'error'
            }
            elseif ($mermaid.UnclosedMermaid) {
                Add-Issue $errors $relPath 1 'MERMAID_FENCE_UNCLOSED' 'Bloque Mermaid sin fence de cierre compatible.' 'error'
            }
        }
        if ($status -eq 'current' -and $kind -notin @('generated', 'archive')) {
            if (-not $meta.Contains('source_paths') -or [string]::IsNullOrWhiteSpace([string]$meta['source_paths'])) {
                Add-Issue $errors $relPath 1 'SOURCE_PATHS_REQUIRED' 'Un documento current debe declarar source_paths.' 'error'
            }
            elseif ([string]$meta['source_paths'] -eq 'none') {
                if (-not $meta.Contains('source_reason') -or [string]::IsNullOrWhiteSpace([string]$meta['source_reason'])) {
                    Add-Issue $errors $relPath 1 'SOURCE_REASON_REQUIRED' 'source_paths: none exige source_reason.' 'error'
                }
            }
            else {
                if (-not $meta.Contains('last_verified_commit') -or [string]::IsNullOrWhiteSpace([string]$meta['last_verified_commit'])) {
                    Add-Issue $errors $relPath 1 'VERIFIED_COMMIT_REQUIRED' 'source_paths exige last_verified_commit.' 'error'
                }
                elseif ([string]$meta['last_verified_commit'] -ne 'self' -and [string]$meta['last_verified_commit'] -notmatch '^[0-9a-fA-F]{7,40}$') {
                    Add-Issue $errors $relPath 1 'INVALID_VERIFIED_COMMIT' 'last_verified_commit debe ser un SHA o self; HEAD no es estable.' 'error'
                }
                elseif ([string]$meta['last_verified_commit'] -ne 'self' -and (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
                    $verifiedCommit = [string]$meta['last_verified_commit']
                    & git -C $RepoRoot cat-file -e "$verifiedCommit`^{commit}" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Add-Issue $errors $relPath 1 'VERIFIED_COMMIT_NOT_FOUND' "last_verified_commit no existe: '$verifiedCommit'." 'error'
                    }
                }
                foreach ($glob in Split-MetadataList ([string]$meta['source_paths'])) {
                    $globResult = Test-SourceGlob -Glob $glob -RepositoryFiles $repositoryFiles
                    if (-not $globResult.Valid) {
                        Add-Issue $errors $relPath 1 'INVALID_SOURCE_GLOB' "source_paths sale del repo o no es relativo: '$glob'." 'error'
                    }
                    elseif (@($globResult.Matches).Count -eq 0) {
                        Add-Issue $errors $relPath 1 'SOURCE_NOT_FOUND' "source_paths no encuentra archivos: '$glob'." 'error'
                    }
                }
            }
        }
        if ($meta.Contains('drift_ignore')) {
            foreach ($glob in Split-MetadataList ([string]$meta['drift_ignore'])) {
                $globResult = Test-SourceGlob -Glob $glob -RepositoryFiles $repositoryFiles
                if (-not $globResult.Valid) {
                    Add-Issue $errors $relPath 1 'INVALID_DRIFT_IGNORE' "drift_ignore sale del repo o no es relativo: '$glob'." 'error'
                }
                elseif (@($globResult.Matches).Count -eq 0) {
                    Add-Issue $errors $relPath 1 'DRIFT_IGNORE_NOT_FOUND' "drift_ignore no encuentra archivos: '$glob'." 'error'
                }
            }
        }

        $supersedes = if ($meta.Contains('supersedes')) { @(Split-MetadataList ([string]$meta['supersedes'])) } else { @() }
        if ($id -and @($supersedes).Count -gt 0) { $edges[$id] = @($supersedes) }
    }

    foreach ($entry in $baseline) {
        $absolute = Join-Path $RepoRoot $entry
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
            Add-Issue $errors $LegacyBaselineRepoPath 1 'LEGACY_MISSING' "El baseline conserva un path inexistente: '$entry'." 'error'
        }
    }

    foreach ($sourceId in $edges.Keys) {
        foreach ($targetId in $edges[$sourceId]) {
            if (-not $documentsById.ContainsKey($targetId)) {
                Add-Issue $errors $documentsById[$sourceId].RelPath 1 'SUPERSEDES_UNKNOWN' "supersedes referencia un ID desconocido '$targetId'." 'error'
            }
        }
    }
    $states = @{}
    foreach ($id in $documentsById.Keys) {
        Test-SupersessionNode $id $edges $states $documentsById $errors
    }

    foreach ($doc in $documents) {
        $severity = if ($doc.Meta.Contains('status') -and [string]$doc.Meta['status'] -eq 'archived') { 'warning' } else { 'error' }
        Test-DocumentLinks -File $doc.File -Severity $severity -Errors $errors -Warnings $warnings
    }
    if (Test-Path -LiteralPath $ReadmePath -PathType Leaf) {
        Test-DocumentLinks -File (Get-Item -LiteralPath $ReadmePath) -Severity 'error' -Errors $errors -Warnings $warnings
    }
    else {
        Add-Issue $errors $ReadmeRepoPath 1 'README_MISSING' "Falta $ReadmeRepoPath." 'error'
    }

    if ($legacy.Count -gt 0) {
        Add-Issue $warnings $LegacyBaselineRepoPath 1 'LEGACY_REMAINS' "$($legacy.Count) documento(s) siguen bajo compatibilidad legacy." 'warning'
    }

    Test-RoadmapImpactMetadata -Errors $errors

    return [pscustomobject]@{
        Errors = $errors
        Warnings = $warnings
        Documents = @($documents)
        Legacy = @($legacy | Sort-Object)
    }
}

function Escape-MarkdownCell {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-DocumentOrder {
    param($Document)
    if (-not $Document.Meta.Contains('order')) { return [int]::MaxValue }
    $order = 0
    if ([int]::TryParse([string]$Document.Meta['order'], [ref]$order)) { return $order }
    return [int]::MaxValue
}

function Format-MarkdownTarget {
    param([string]$Path, [string]$BaseDirectory)
    $relative = [IO.Path]::GetRelativePath($BaseDirectory, (Join-Path $RepoRoot $Path)).Replace('\', '/')
    return "<$relative>"
}

function Get-IndexRegionLines {
    param($Validation, [string]$BaseDirectory = $DocsRoot)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Catálogo administrado')
    $lines.Add('')
    $lines.Add('> Vista generada por `scripts/docs.ps1 index`. La metadata canónica vive en cada documento; no edites esta región a mano.')

    $managed = @($Validation.Documents | Where-Object {
        -not ($_.Meta.Contains('kind') -and [string]$_.Meta['kind'] -eq 'generated')
    } | Sort-Object `
        @{ Expression = { if ($_.Meta.Contains('area')) { [string]$_.Meta['area'] } else { '' } } }, `
        @{ Expression = { Get-DocumentOrder $_ } }, `
        @{ Expression = { if ($_.Meta.Contains('title')) { [string]$_.Meta['title'] } else { '' } } }, `
        @{ Expression = { if ($_.Meta.Contains('id')) { [string]$_.Meta['id'] } else { '' } } })

    foreach ($areaGroup in @($managed | Group-Object { [string]$_.Meta['area'] })) {
        $lines.Add('')
        $lines.Add("### $($areaGroup.Name)")
        $lines.Add('')
        $lines.Add('| Documento | Tipo | Estado | Owner | Resumen |')
        $lines.Add('|---|---|---|---|---|')
        foreach ($doc in $areaGroup.Group) {
            $title = Escape-MarkdownCell ([string]$doc.Meta['title'])
            $kind = Escape-MarkdownCell ([string]$doc.Meta['kind'])
            $status = Escape-MarkdownCell ([string]$doc.Meta['status'])
            $owner = Escape-MarkdownCell ([string]$doc.Meta['owner'])
            $summary = if ($doc.Meta.Contains('summary')) { Escape-MarkdownCell ([string]$doc.Meta['summary']) } else { '—' }
            $target = Format-MarkdownTarget $doc.RelPath $BaseDirectory
            $lines.Add("| [$title]($target) | $kind | $status | $owner | $summary |")
        }
    }

    $lines.Add('')
    $lines.Add('## Legado pendiente de migración')
    $lines.Add('')
    if (@($Validation.Legacy).Count -eq 0) {
        $lines.Add('No quedan documentos bajo compatibilidad legacy.')
    }
    else {
        $lines.Add("$(@($Validation.Legacy).Count) documento(s) permanecen legibles pero todavía no aportan metadata al catálogo:")
        $lines.Add('')
        foreach ($path in $Validation.Legacy) {
            $target = Format-MarkdownTarget $path $BaseDirectory
            $label = $path.Substring($DocsRepoPrefix.Length)
            $lines.Add("- [$label]($target)")
        }
    }
    return @($lines)
}

function Get-CatalogContent {
    param($Validation)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '---',
        'id: DOC-GENERATED-CATALOG',
        'title: Catálogo documental',
        'kind: generated',
        'area: maintenance',
        'status: current',
        'owner: project',
        'order: 999',
        'generated_by: scripts/docs.ps1 index',
        'diagram_mode: structural',
        '---',
        '',
        '# Catálogo documental',
        '',
        '> Archivo generado. Regenerar con `pwsh -NoProfile -File scripts/docs.ps1 index`.'
    )) { $lines.Add($line) }
    $lines.Add('')
    foreach ($line in Get-IndexRegionLines $Validation (Split-Path -Parent $CatalogPath)) { $lines.Add($line) }
    return ($lines -join "`n") + "`n"
}

function ConvertTo-MermaidId {
    param([string]$Value)
    return ($Value.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
}

function Escape-MermaidLabel {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('"', "'").Replace("`r", ' ').Replace("`n", ' ')
}

function Get-GraphContent {
    param($Validation)

    $documents = @($Validation.Documents | Where-Object {
        $_.Meta.Contains('kind') -and [string]$_.Meta['kind'] -ne 'generated'
    } | Sort-Object { [string]$_.Meta['id'] })
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '---',
        'id: DOC-GENERATED-STRUCTURE',
        'title: Mapa estructural de documentación',
        'kind: generated',
        'area: maintenance',
        'status: current',
        'owner: project',
        'order: 998',
        'generated_by: scripts/docs.ps1 graph',
        'diagram_mode: structural',
        '---',
        '',
        '# Mapa estructural de documentación',
        '',
        '> Vista generada exclusivamente desde metadata explícita. No representa secuencias ni arquitectura inferida.',
        '',
        '```mermaid',
        'flowchart LR'
    )) { $lines.Add($line) }

    $areas = @($documents | Group-Object { [string]$_.Meta['area'] } | Sort-Object Name)
    foreach ($area in $areas) {
        $areaId = 'AREA_' + (ConvertTo-MermaidId $area.Name)
        $lines.Add("    $areaId[`"area: $(Escape-MermaidLabel $area.Name)`"]")
    }
    foreach ($doc in $documents) {
        $docId = ConvertTo-MermaidId ([string]$doc.Meta['id'])
        $title = Escape-MermaidLabel ([string]$doc.Meta['title'])
        $lines.Add("    $docId[`"$title`"]")
    }
    foreach ($doc in $documents | Sort-Object { [string]$_.Meta['area'] }, { Get-DocumentOrder $_ }, { [string]$_.Meta['id'] }) {
        $areaId = 'AREA_' + (ConvertTo-MermaidId ([string]$doc.Meta['area']))
        $docId = ConvertTo-MermaidId ([string]$doc.Meta['id'])
        $lines.Add("    $areaId --> $docId")
    }

    $roadmapIds = @($documents | ForEach-Object {
        if ($_.Meta.Contains('roadmaps')) { Split-MetadataList ([string]$_.Meta['roadmaps']) }
    } | Sort-Object -Unique)
    foreach ($roadmapId in $roadmapIds) {
        $nodeId = 'ROADMAP_' + (ConvertTo-MermaidId $roadmapId)
        $lines.Add("    $nodeId[`"$roadmapId`"]")
    }
    foreach ($doc in $documents) {
        if (-not $doc.Meta.Contains('roadmaps')) { continue }
        foreach ($roadmapId in @(Split-MetadataList ([string]$doc.Meta['roadmaps']) | Sort-Object)) {
            $nodeId = 'ROADMAP_' + (ConvertTo-MermaidId $roadmapId)
            $docId = ConvertTo-MermaidId ([string]$doc.Meta['id'])
            $lines.Add("    $nodeId -->|origin| $docId")
        }
    }
    foreach ($doc in $documents) {
        if (-not $doc.Meta.Contains('supersedes')) { continue }
        foreach ($target in @(Split-MetadataList ([string]$doc.Meta['supersedes']) | Sort-Object)) {
            $docId = ConvertTo-MermaidId ([string]$doc.Meta['id'])
            $targetId = ConvertTo-MermaidId $target
            $lines.Add("    $docId -->|supersedes| $targetId")
        }
    }
    foreach ($doc in $documents) {
        $docId = ConvertTo-MermaidId ([string]$doc.Meta['id'])
        $target = [IO.Path]::GetRelativePath((Split-Path -Parent $GraphPath), $doc.File.FullName).Replace('\', '/')
        $title = Escape-MermaidLabel ([string]$doc.Meta['title'])
        $lines.Add("    click $docId `"$target`" `"$title`"")
    }
    $lines.Add('```')
    return ($lines -join "`n") + "`n"
}

function Get-ReadmeIndexedContent {
    param($Validation)
    if (-not (Test-Path -LiteralPath $ReadmePath -PathType Leaf)) { throw "Falta $ReadmeRepoPath." }
    $raw = Get-Content -Raw -LiteralPath $ReadmePath
    $start = $raw.IndexOf($IndexStart, [StringComparison]::Ordinal)
    $end = $raw.IndexOf($IndexEnd, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        throw "$ReadmeRepoPath debe contener una única región docs:index delimitada."
    }
    if ($raw.IndexOf($IndexStart, $start + $IndexStart.Length, [StringComparison]::Ordinal) -ge 0 -or
        $raw.IndexOf($IndexEnd, $end + $IndexEnd.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "$ReadmeRepoPath contiene marcadores docs:index duplicados."
    }
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $region = (Get-IndexRegionLines $Validation) -join $newline
    $replacement = $IndexStart + $newline + $region + $newline + $IndexEnd
    return $raw.Substring(0, $start) + $replacement + $raw.Substring($end + $IndexEnd.Length)
}

function Set-FileIfChanged {
    param([string]$Path, [string]$Content)
    $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -Raw -LiteralPath $Path } else { $null }
    if ($existing -ceq $Content) { return $false }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
    return $true
}

function Get-FileSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    return [pscustomobject]@{
        Path = $Path
        Exists = $exists
        Bytes = if ($exists) { [IO.File]::ReadAllBytes($Path) } else { $null }
    }
}

function Restore-FileSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    if ($Snapshot.Exists) {
        $parent = Split-Path -Parent $Snapshot.Path
        if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::WriteAllBytes($Snapshot.Path, $Snapshot.Bytes)
    }
    elseif (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) {
        Remove-Item -LiteralPath $Snapshot.Path -Force
    }
}

function Assert-FlatMigrationValue {
    param(
        [string]$Name,
        [string]$Value,
        [switch]$Optional
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Optional) { return }
        throw [ArgumentException]::new("migrate exige -$Name.")
    }
    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw [ArgumentException]::new("-$Name debe ocupar una sola línea.")
    }
}

function Get-MigrationBaselineContent {
    param([string]$DocumentPath)

    $raw = Get-Content -Raw -LiteralPath $LegacyBaselinePath
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @([regex]::Split($raw, "`r`n|`n|`r"))
    $kept = [System.Collections.Generic.List[string]]::new()
    $removed = 0
    foreach ($line in $lines) {
        $entry = $line.Trim().Replace('\', '/')
        if ($entry -and -not $entry.StartsWith('#') -and $entry.Equals($DocumentPath, [StringComparison]::OrdinalIgnoreCase)) {
            $removed++
            continue
        }
        $kept.Add($line)
    }
    if ($removed -ne 1) {
        throw [ArgumentException]::new("El baseline debe contener exactamente una entrada para '$DocumentPath'; encontró $removed.")
    }
    return ($kept -join $newline)
}

function Get-MigrationFrontMatter {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '---',
        "id: $DocumentId",
        "title: $DocumentTitle",
        "kind: $Kind",
        "area: $Area",
        "status: $DocumentStatus",
        "owner: $Owner"
    )) { $lines.Add($line) }
    if (-not [string]::IsNullOrWhiteSpace($DocumentOrder)) { $lines.Add("order: $DocumentOrder") }
    $lines.Add("source_paths: $SourcePaths")
    if ($SourcePaths -eq 'none') { $lines.Add("source_reason: $SourceReason") }
    else { $lines.Add('last_verified_commit: self') }
    $lines.Add("roadmaps: $Roadmaps")
    if (-not [string]::IsNullOrWhiteSpace($Supersedes)) { $lines.Add("supersedes: $Supersedes") }
    if (-not [string]::IsNullOrWhiteSpace($Summary)) { $lines.Add("summary: $Summary") }
    $lines.Add("diagram_mode: $DiagramMode")
    $lines.Add('---')
    $lines.Add('')
    return ($lines -join "`n") + "`n"
}

function Get-MigrationPayload {
    param($Validation, [bool]$ShouldApply, $Spec = $null)

    if ($null -eq $Spec) {
        $Spec = [pscustomobject]@{
            document = $Document
            documentId = $DocumentId
            documentTitle = $DocumentTitle
            kind = $Kind
            area = $Area
            documentStatus = $DocumentStatus
            owner = $Owner
            sourcePaths = $SourcePaths
            sourceReason = $SourceReason
            roadmaps = $Roadmaps
            diagramMode = $DiagramMode
            summary = $Summary
            documentOrder = $DocumentOrder
            supersedes = $Supersedes
        }
    }
    $Document = [string]$Spec.document
    $DocumentId = [string]$Spec.documentId
    $DocumentTitle = [string]$Spec.documentTitle
    $Kind = [string]$Spec.kind
    $Area = [string]$Spec.area
    $DocumentStatus = [string]$Spec.documentStatus
    $Owner = [string]$Spec.owner
    $SourcePaths = [string]$Spec.sourcePaths
    $SourceReason = [string]$Spec.sourceReason
    $Roadmaps = [string]$Spec.roadmaps
    $DiagramMode = [string]$Spec.diagramMode
    $Summary = [string]$Spec.summary
    $DocumentOrder = [string]$Spec.documentOrder
    $Supersedes = [string]$Spec.supersedes

    foreach ($required in @(
        @('Document', $Document), @('DocumentId', $DocumentId), @('DocumentTitle', $DocumentTitle),
        @('Kind', $Kind), @('Area', $Area), @('DocumentStatus', $DocumentStatus),
        @('Owner', $Owner), @('SourcePaths', $SourcePaths), @('Roadmaps', $Roadmaps),
        @('DiagramMode', $DiagramMode)
    )) { Assert-FlatMigrationValue ([string]$required[0]) ([string]$required[1]) }
    foreach ($optional in @(
        @('SourceReason', $SourceReason), @('Summary', $Summary),
        @('DocumentOrder', $DocumentOrder), @('Supersedes', $Supersedes)
    )) { Assert-FlatMigrationValue ([string]$optional[0]) ([string]$optional[1]) -Optional }

    if ($DocumentId -notmatch '^DOC-[A-Z0-9]+(?:-[A-Z0-9]+)*$') {
        throw [ArgumentException]::new("DocumentId inválido '$DocumentId'.")
    }
    if ($Kind -notin $ValidKinds -or $Kind -eq 'generated') {
        throw [ArgumentException]::new("Kind inválido para migración authored '$Kind'.")
    }
    if ($DocumentStatus -notin $ValidStatuses) {
        throw [ArgumentException]::new("DocumentStatus inválido '$DocumentStatus'.")
    }
    if ($DiagramMode -notin @('none', 'semantic')) {
        throw [ArgumentException]::new("DiagramMode inválido para migración authored '$DiagramMode'.")
    }
    if ($SourcePaths -eq 'none' -and [string]::IsNullOrWhiteSpace($SourceReason)) {
        throw [ArgumentException]::new('source_paths: none exige -SourceReason explícito.')
    }
    if (-not [string]::IsNullOrWhiteSpace($DocumentOrder)) {
        $parsedOrder = 0
        if (-not [int]::TryParse($DocumentOrder, [ref]$parsedOrder)) {
            throw [ArgumentException]::new("DocumentOrder debe ser entero: '$DocumentOrder'.")
        }
    }
    if ($null -ne (Get-DocumentById $Validation $DocumentId)) {
        throw [ArgumentException]::new("DocumentId '$DocumentId' ya existe.")
    }

    $target = Resolve-DocsTargetPath $Document
    if ($target.Relative.Equals($ReadmeRepoPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new("$ReadmeRepoPath es un shell especial y no puede migrarse.")
    }
    if (-not (Test-Path -LiteralPath $target.FullPath -PathType Leaf)) {
        throw [ArgumentException]::new("Documento legacy inexistente: '$($target.Relative)'.")
    }
    if ($target.Relative -notin @($Validation.Legacy)) {
        throw [ArgumentException]::new("'$($target.Relative)' no es un documento legacy vigente del baseline.")
    }

    $metadataLines = Get-MigrationFrontMatter
    $bodyBytes = [IO.File]::ReadAllBytes($target.FullPath)
    $prefixBytes = [Text.UTF8Encoding]::new($false).GetBytes($metadataLines)
    $candidateBytes = [byte[]]::new($prefixBytes.Length + $bodyBytes.Length)
    [Array]::Copy($prefixBytes, 0, $candidateBytes, 0, $prefixBytes.Length)
    [Array]::Copy($bodyBytes, 0, $candidateBytes, $prefixBytes.Length, $bodyBytes.Length)
    $baselineContent = Get-MigrationBaselineContent $target.Relative

    $plannedMetadata = [ordered]@{
        id = $DocumentId
        title = $DocumentTitle
        kind = $Kind
        area = $Area
        status = $DocumentStatus
        owner = $Owner
        source_paths = $SourcePaths
        roadmaps = $Roadmaps
        diagram_mode = $DiagramMode
    }
    if ($SourcePaths -eq 'none') { $plannedMetadata.source_reason = $SourceReason }
    else { $plannedMetadata.last_verified_commit = 'self' }
    if (-not [string]::IsNullOrWhiteSpace($DocumentOrder)) { $plannedMetadata.order = $DocumentOrder }
    if (-not [string]::IsNullOrWhiteSpace($Supersedes)) { $plannedMetadata.supersedes = $Supersedes }
    if (-not [string]::IsNullOrWhiteSpace($Summary)) { $plannedMetadata.summary = $Summary }

    $basePayload = [ordered]@{
        command = 'migrate'
        ok = $true
        apply = $ShouldApply
        document = $target.Relative
        document_id = $DocumentId
        state = if ($ShouldApply) { 'applied' } else { 'planned' }
        body_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bodyBytes)).ToLowerInvariant()
        metadata = $plannedMetadata
        changed = @()
        warnings = @($Validation.Warnings)
    }
    if (-not $ShouldApply) { return [pscustomobject]$basePayload }

    $snapshots = @(
        (Get-FileSnapshot $target.FullPath),
        (Get-FileSnapshot $LegacyBaselinePath),
        (Get-FileSnapshot $ReadmePath),
        (Get-FileSnapshot $CatalogPath),
        (Get-FileSnapshot $GraphPath)
    )
    try {
        [IO.File]::WriteAllBytes($target.FullPath, $candidateBytes)
        [IO.File]::WriteAllText($LegacyBaselinePath, $baselineContent, [Text.UTF8Encoding]::new($false))

        $postValidation = Invoke-DocsValidation
        if ($postValidation.Errors.Count -gt 0) {
            $details = @($postValidation.Errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; '
            throw [ArgumentException]::new("Migración inválida; se revierte: $details")
        }

        $readmeContent = Get-ReadmeIndexedContent $postValidation
        [void](Set-FileIfChanged -Path $ReadmePath -Content $readmeContent)
        $catalogContent = Get-CatalogContent $postValidation
        [void](Set-FileIfChanged -Path $CatalogPath -Content $catalogContent)
        $graphContent = Get-GraphContent $postValidation
        [void](Set-FileIfChanged -Path $GraphPath -Content $graphContent)

        $finalValidation = Invoke-DocsValidation
        if ($finalValidation.Errors.Count -eq 0) { Add-StrictGeneratedChecks $finalValidation }
        if ($finalValidation.Errors.Count -gt 0) {
            $details = @($finalValidation.Errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; '
            throw [ArgumentException]::new("Vistas de migración inválidas; se revierte: $details")
        }
        $basePayload.changed = @($target.Relative, $LegacyBaselineRepoPath, $ReadmeRepoPath, $CatalogRepoPath, $GraphRepoPath)
        $basePayload.warnings = @($finalValidation.Warnings)
        return [pscustomobject]$basePayload
    }
    catch {
        foreach ($snapshot in $snapshots) { Restore-FileSnapshot $snapshot }
        throw
    }
}

function Get-ManifestStringProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Optional
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        if ($Optional) { return '' }
        throw [ArgumentException]::new("El manifiesto exige '$Name' en cada documento.")
    }
    $value = [string]$property.Value
    if ($value.Contains("`r") -or $value.Contains("`n")) {
        throw [ArgumentException]::new("'$Name' debe ocupar una sola línea.")
    }
    return $value
}

function Read-MigrationManifest {
    Assert-FlatMigrationValue 'Manifest' $Manifest
    $normalized = $Manifest.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|/)\.\.(/|$)' -or $normalized.Contains(':')) {
        throw [ArgumentException]::new("Manifest inválido '$Manifest'; usar un path relativo al repositorio.")
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot $normalized))
    $repoPrefix = $RepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw [ArgumentException]::new("Manifest inexistente o fuera del repositorio: '$Manifest'.")
    }
    try { $payload = Get-Content -Raw -LiteralPath $fullPath | ConvertFrom-Json -ErrorAction Stop }
    catch { throw [ArgumentException]::new("Manifest JSON inválido: $($_.Exception.Message)") }

    $topAllowed = @('schema', 'documents')
    foreach ($name in @($payload.PSObject.Properties.Name)) {
        if ($name -cnotin $topAllowed) { throw [ArgumentException]::new("Propiedad desconocida en manifest: '$name'.") }
    }
    $schema = Get-ManifestStringProperty $payload 'schema'
    if ($schema -ne 'roadmap-kit.docs-migration/v1') {
        throw [ArgumentException]::new("Schema de migración desconocido '$schema'.")
    }
    if ($null -eq $payload.PSObject.Properties['documents']) {
        throw [ArgumentException]::new("El manifiesto exige 'documents'.")
    }
    $documents = @($payload.documents)
    if ($documents.Count -eq 0) { throw [ArgumentException]::new('El manifiesto debe contener al menos un documento.') }

    $required = @('document', 'documentId', 'documentTitle', 'kind', 'area', 'documentStatus', 'owner', 'sourcePaths', 'roadmaps', 'diagramMode')
    $optional = @('sourceReason', 'summary', 'documentOrder', 'supersedes')
    $allowed = @($required + $optional)
    $specs = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $documents) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
            throw [ArgumentException]::new('Cada entrada de documents debe ser un objeto JSON.')
        }
        foreach ($name in @($entry.PSObject.Properties.Name)) {
            if ($name -cnotin $allowed) { throw [ArgumentException]::new("Propiedad desconocida en documento de manifest: '$name'.") }
        }
        $values = @{}
        foreach ($name in $required) { $values[$name] = Get-ManifestStringProperty $entry $name }
        foreach ($name in $optional) { $values[$name] = Get-ManifestStringProperty $entry $name -Optional }
        $specs.Add([pscustomobject]@{
            document = $values.document
            documentId = $values.documentId
            documentTitle = $values.documentTitle
            kind = $values.kind
            area = $values.area
            documentStatus = $values.documentStatus
            owner = $values.owner
            sourcePaths = $values.sourcePaths
            sourceReason = $values.sourceReason
            roadmaps = $values.roadmaps
            diagramMode = $values.diagramMode
            summary = $values.summary
            documentOrder = $values.documentOrder
            supersedes = $values.supersedes
        })
    }
    return [pscustomobject]@{ Schema = $schema; RelativePath = $normalized; FullPath = $fullPath; Specs = @($specs) }
}

function Get-BatchMigrationPayload {
    param($Validation, [bool]$ShouldApply)

    foreach ($pair in @(
        @('Document', $Document), @('DocumentId', $DocumentId), @('DocumentTitle', $DocumentTitle),
        @('Kind', $Kind), @('Area', $Area), @('DocumentStatus', $DocumentStatus),
        @('Owner', $Owner), @('SourcePaths', $SourcePaths), @('SourceReason', $SourceReason),
        @('Roadmaps', $Roadmaps), @('DiagramMode', $DiagramMode), @('Summary', $Summary),
        @('DocumentOrder', $DocumentOrder), @('Supersedes', $Supersedes)
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) {
            throw [ArgumentException]::new("-$($pair[0]) no puede combinarse con -Manifest.")
        }
    }

    $manifestRecord = Read-MigrationManifest
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $plans = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in $manifestRecord.Specs) {
        $normalizedPath = ([string]$spec.document).Replace('\', '/')
        if (-not $paths.Add($normalizedPath)) { throw [ArgumentException]::new("Path duplicado en manifest: '$normalizedPath'.") }
        if (-not $ids.Add([string]$spec.documentId)) { throw [ArgumentException]::new("DocumentId duplicado en manifest: '$($spec.documentId)'.") }
        $plans.Add((Get-MigrationPayload $Validation $false $spec))
    }

    $payload = [ordered]@{
        command = 'migrate'
        ok = $true
        schema = $manifestRecord.Schema
        manifest = $manifestRecord.RelativePath
        apply = $ShouldApply
        state = if ($ShouldApply) { 'applied' } else { 'planned' }
        entries = @($plans)
        changed = @()
        warnings = @($Validation.Warnings)
    }
    if (-not $ShouldApply) { return [pscustomobject]$payload }

    $snapshotPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in $manifestRecord.Specs) {
        [void]$snapshotPaths.Add((Resolve-DocsTargetPath ([string]$spec.document)).FullPath)
    }
    foreach ($path in @($LegacyBaselinePath, $ReadmePath, $CatalogPath, $GraphPath)) { [void]$snapshotPaths.Add($path) }
    $snapshots = @($snapshotPaths | Sort-Object | ForEach-Object { Get-FileSnapshot $_ })

    try {
        $applied = [System.Collections.Generic.List[object]]::new()
        foreach ($spec in $manifestRecord.Specs) {
            $currentValidation = Invoke-DocsValidation
            if ($currentValidation.Errors.Count -gt 0) {
                $details = @($currentValidation.Errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; '
                throw [ArgumentException]::new("Estado intermedio inválido; se revierte el lote: $details")
            }
            $applied.Add((Get-MigrationPayload $currentValidation $true $spec))
        }
        $finalValidation = Invoke-DocsValidation
        if ($finalValidation.Errors.Count -eq 0) { Add-StrictGeneratedChecks $finalValidation }
        if ($finalValidation.Errors.Count -gt 0) {
            $details = @($finalValidation.Errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; '
            throw [ArgumentException]::new("Lote inválido; se revierte: $details")
        }
        $payload.entries = @($applied)
        $payload.changed = @($applied | ForEach-Object { $_.changed } | Sort-Object -Unique)
        $payload.warnings = @($finalValidation.Warnings)
        return [pscustomobject]$payload
    }
    catch {
        foreach ($snapshot in $snapshots) { Restore-FileSnapshot $snapshot }
        throw
    }
}

function Add-GraphGeneratedCheck {
    param($Validation)
    try {
        if (-not (Test-Path -LiteralPath $GraphPath -PathType Leaf)) { return }
        $expectedGraph = Get-GraphContent $Validation
        if ((Get-Content -Raw -LiteralPath $GraphPath) -cne $expectedGraph) {
            Add-Issue $Validation.Errors $GraphRepoPath 1 'GRAPH_DRIFT' 'El grafo generado no coincide con docs graph.' 'error'
        }
    }
    catch {
        Add-Issue $Validation.Errors $GraphRepoPath 1 'GRAPH_GENERATION' $_.Exception.Message 'error'
    }
}

function Add-StrictGeneratedChecks {
    param($Validation)
    try {
        $expectedReadme = Get-ReadmeIndexedContent $Validation
        if ((Get-Content -Raw -LiteralPath $ReadmePath) -cne $expectedReadme) {
            Add-Issue $Validation.Errors $ReadmeRepoPath 1 'INDEX_DRIFT' 'La región generada no coincide con docs index.' 'error'
        }
        $expectedCatalog = Get-CatalogContent $Validation
        if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf) -or (Get-Content -Raw -LiteralPath $CatalogPath) -cne $expectedCatalog) {
            Add-Issue $Validation.Errors $CatalogRepoPath 1 'CATALOG_DRIFT' 'El catálogo generado no coincide con docs index.' 'error'
        }
    }
    catch {
        Add-Issue $Validation.Errors $ReadmeRepoPath 1 'INDEX_MARKERS' $_.Exception.Message 'error'
    }
    Add-GraphGeneratedCheck $Validation
}

function Test-PathMatchesGlob {
    param([string]$Path, [string]$Glob)
    return $Path.Replace('\', '/') -match (Convert-GlobToRegex $Glob)
}

function Resolve-GitCommit {
    param([string]$Reference)
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        throw [ArgumentException]::new("La operación requiere un repositorio Git: $RepoRoot")
    }
    $resolved = @(& git -C $RepoRoot rev-parse --verify "$Reference`^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $resolved.Count -eq 0) {
        throw [ArgumentException]::new("Referencia Git inexistente: '$Reference'.")
    }
    return $resolved[-1].Trim()
}

function Get-ChangedPathSet {
    param(
        [string]$BaseReference,
        [string]$HeadReference,
        [string[]]$RelevantGlobs = @()
    )

    $baseCommit = Resolve-GitCommit $BaseReference
    $isWorktree = $HeadReference -eq 'WORKTREE'
    $headCommit = if ($isWorktree) { Resolve-GitCommit 'HEAD' } else { Resolve-GitCommit $HeadReference }
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $untracked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $diffPaths = if ($isWorktree) {
        @(& git -C $RepoRoot diff --name-only $baseCommit -- 2>$null)
    }
    else {
        @(& git -C $RepoRoot diff --name-only $baseCommit $headCommit -- 2>$null)
    }
    if ($LASTEXITCODE -ne 0) {
        throw [ArgumentException]::new("No se pudo comparar '$BaseReference' con '$HeadReference'.")
    }
    foreach ($path in $diffPaths) {
        if ($path) { [void]$paths.Add($path.Replace('\', '/')) }
    }

    if ($isWorktree) {
        foreach ($path in @(& git -C $RepoRoot ls-files --others --exclude-standard 2>$null)) {
            if (-not $path) { continue }
            $normalized = $path.Replace('\', '/')
            [void]$paths.Add($normalized)
            [void]$untracked.Add($normalized)
        }
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($paths | Sort-Object)) {
        $whitespaceOnly = $false
        $needsWhitespaceCheck = @($RelevantGlobs | Where-Object { Test-PathMatchesGlob $path $_ }).Count -gt 0
        if ($needsWhitespaceCheck -and -not $untracked.Contains($path)) {
            if ($isWorktree) {
                & git -C $RepoRoot diff --quiet --ignore-all-space $baseCommit -- $path 2>$null
            }
            else {
                & git -C $RepoRoot diff --quiet --ignore-all-space $baseCommit $headCommit -- $path 2>$null
            }
            $diffExit = $LASTEXITCODE
            if ($diffExit -gt 1) {
                throw [ArgumentException]::new("No se pudo clasificar el diff de '$path'.")
            }
            $whitespaceOnly = $diffExit -eq 0
        }
        $changes.Add([pscustomobject]@{
            path = $path
            whitespace_only = $whitespaceOnly
            untracked = $untracked.Contains($path)
        })
    }

    return [pscustomobject]@{
        base = $baseCommit
        head = if ($isWorktree) { 'WORKTREE' } else { $headCommit }
        changes = @($changes)
    }
}

function Get-DocumentMatches {
    param($Document, [object[]]$Changes)

    if (-not $Document.Meta.Contains('source_paths') -or [string]$Document.Meta['source_paths'] -eq 'none') { return @() }
    $sourceGlobs = @(Split-MetadataList ([string]$Document.Meta['source_paths']))
    $ignoreGlobs = if ($Document.Meta.Contains('drift_ignore')) { @(Split-MetadataList ([string]$Document.Meta['drift_ignore'])) } else { @() }
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($change in $Changes) {
        foreach ($sourceGlob in $sourceGlobs) {
            if (-not (Test-PathMatchesGlob $change.path $sourceGlob)) { continue }
            $ignoredBy = @($ignoreGlobs | Where-Object { Test-PathMatchesGlob $change.path $_ })
            $matches.Add([pscustomobject]@{
                document_id = [string]$Document.Meta['id']
                document = $Document.RelPath
                path = $change.path
                source_glob = $sourceGlob
                whitespace_only = [bool]$change.whitespace_only
                ignored = $ignoredBy.Count -gt 0
                ignored_by = @($ignoredBy)
            })
        }
    }
    return @($matches)
}

function Get-AffectedPayload {
    param($Validation, [string]$BaseReference, [string]$HeadReference)
    if ([string]::IsNullOrWhiteSpace($BaseReference)) {
        throw [ArgumentException]::new('affected exige -Base <sha>.')
    }
    $relevantGlobs = @($Validation.Documents | ForEach-Object {
        if ($_.Meta.Contains('source_paths')) { Split-MetadataList ([string]$_.Meta['source_paths']) }
    } | Sort-Object -Unique)
    $changeSet = Get-ChangedPathSet $BaseReference $HeadReference $relevantGlobs
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $Validation.Documents | Where-Object {
        $_.Meta.Contains('status') -and [string]$_.Meta['status'] -eq 'current' -and
        $_.Meta.Contains('kind') -and [string]$_.Meta['kind'] -notin @('generated', 'archive')
    } | Sort-Object { [string]$_.Meta['id'] }) {
        foreach ($match in Get-DocumentMatches $doc $changeSet.changes) { $matches.Add($match) }
    }
    return [pscustomobject]@{
        command = 'affected'
        ok = $true
        base = $changeSet.base
        head = $changeSet.head
        changed_paths = @($changeSet.changes)
        matches = @($matches | Sort-Object document_id, path, source_glob)
        warnings = @($Validation.Warnings)
    }
}

function Test-DocumentChangedInWorktree {
    param($Document)
    $status = @(& git -C $RepoRoot status --porcelain -- $Document.RelPath 2>$null)
    return $status.Count -gt 0
}

function Resolve-DocumentBaseline {
    param($Document, [string]$HeadReference)

    $declared = [string]$Document.Meta['last_verified_commit']
    if ($declared -ne 'self') {
        return [pscustomobject]@{ known = $true; reference = Resolve-GitCommit $declared; reason = 'declared_sha' }
    }
    if ($HeadReference -eq 'WORKTREE' -and (Test-DocumentChangedInWorktree $Document)) {
        return [pscustomobject]@{ known = $true; reference = 'WORKTREE'; reason = 'document_updated_in_worktree' }
    }

    $headCommit = if ($HeadReference -eq 'WORKTREE') { Resolve-GitCommit 'HEAD' } else { Resolve-GitCommit $HeadReference }
    $history = @(& git -C $RepoRoot log -1 --format=%H $headCommit -- $Document.RelPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $history.Count -eq 0 -or [string]::IsNullOrWhiteSpace($history[-1])) {
        return [pscustomobject]@{ known = $false; reference = $null; reason = 'self_without_history' }
    }
    return [pscustomobject]@{ known = $true; reference = $history[-1].Trim(); reason = 'self_document_commit' }
}

function Get-DriftPayload {
    param($Validation, [string]$HeadReference)

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        throw [ArgumentException]::new("drift requiere un repositorio Git: $RepoRoot")
    }
    if ($HeadReference -ne 'WORKTREE') { [void](Resolve-GitCommit $HeadReference) }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $Validation.Documents | Where-Object {
        $_.Meta.Contains('status') -and [string]$_.Meta['status'] -eq 'current' -and
        $_.Meta.Contains('kind') -and [string]$_.Meta['kind'] -notin @('generated', 'archive')
    } | Sort-Object { [string]$_.Meta['id'] }) {
        if (-not $doc.Meta.Contains('source_paths') -or [string]$doc.Meta['source_paths'] -eq 'none') {
            $results.Add([pscustomobject]@{
                document_id = [string]$doc.Meta['id']; document = $doc.RelPath; health = 'unknown'
                baseline = $null; reason = 'source_paths_none'; matches = @()
            })
            continue
        }

        $baseline = Resolve-DocumentBaseline $doc $HeadReference
        if (-not $baseline.known) {
            $results.Add([pscustomobject]@{
                document_id = [string]$doc.Meta['id']; document = $doc.RelPath; health = 'unknown'
                baseline = $null; reason = $baseline.reason; matches = @()
            })
            continue
        }
        if ($baseline.reference -eq 'WORKTREE') {
            $results.Add([pscustomobject]@{
                document_id = [string]$doc.Meta['id']; document = $doc.RelPath; health = 'fresh'
                baseline = 'WORKTREE'; reason = $baseline.reason; matches = @()
            })
            continue
        }

        $sourceGlobs = @(Split-MetadataList ([string]$doc.Meta['source_paths']))
        $changeSet = Get-ChangedPathSet $baseline.reference $HeadReference $sourceGlobs
        $matches = @(Get-DocumentMatches $doc $changeSet.changes)
        $relevant = @($matches | Where-Object { -not $_.whitespace_only -and -not $_.ignored })
        $health = if ($relevant.Count -gt 0) { 'attention' } else { 'fresh' }
        $results.Add([pscustomobject]@{
            document_id = [string]$doc.Meta['id']
            document = $doc.RelPath
            health = $health
            baseline = $baseline.reference
            reason = if ($health -eq 'attention') { 'source_paths_changed' } else { 'no_relevant_source_changes' }
            matches = @($matches)
        })
    }
    $needsAttention = @($results | Where-Object { $_.health -in @('attention', 'unknown') }).Count -gt 0
    return [pscustomobject]@{
        command = 'drift'
        ok = -not $needsAttention
        head = $HeadReference
        documents = @($results)
        warnings = @($Validation.Warnings)
    }
}

function Get-DocumentById {
    param($Validation, [string]$DocumentId)
    return $Validation.Documents | Where-Object {
        $_.Meta.Contains('id') -and [string]$_.Meta['id'] -eq $DocumentId
    } | Select-Object -First 1
}

function Resolve-DocsTargetPath {
    param([string]$RelativePath)
    $normalized = $RelativePath.Replace('\', '/')
    if (-not $normalized.StartsWith($DocsRepoPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $normalized.EndsWith('.md') -or
        $normalized.StartsWith($GeneratedRepoPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::IsPathRooted($normalized) -or
        $normalized -match '(^|/)\.\.(/|$)' -or $normalized.Contains(':')) {
        throw [ArgumentException]::new("Target documental inválido '$RelativePath'; usar $DocsRelativeRoot/<area>/<nombre>.md fuera de _generated.")
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot $normalized))
    if (-not $fullPath.StartsWith($DocsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new("Target fuera de ${DocsRelativeRoot}/: '$RelativePath'.")
    }
    return [pscustomobject]@{ Relative = $normalized; FullPath = $fullPath }
}

function Get-PromotionScaffold {
    param($RoadmapRecord, $TaskRecord, $Action, $Target)
    $segments = $Target.Relative -split '/'
    $area = if ($segments.Count -gt 2) { $segments[1] } else { 'general' }
    $title = if ($TaskRecord.Meta.Contains('title')) { [string]$TaskRecord.Meta['title'] } else { $Action.document_id }
    $lines = @(
        '---',
        "id: $($Action.document_id)",
        "title: $title",
        'kind: reference',
        "area: $area",
        'status: current',
        'owner: project',
        'source_paths: none',
        "source_reason: Scaffold creado explícitamente desde $($TaskRecord.Id); completar fuentes verificables si aplican",
        "roadmaps: $($RoadmapRecord.Id)",
        'last_verified_commit: self',
        'promotion_state: scaffold',
        'diagram_mode: none',
        '---',
        '',
        "# $title",
        '',
        '> TODO: reemplazar este scaffold por documentación verificada antes del closeout.',
        ''
    )
    return ($lines -join "`n")
}

function Get-PromotionPayload {
    param($Validation, [string]$RoadmapId, [string]$TaskId, [bool]$ShouldApply)
    $roadmapRecord = Get-RoadmapRecord $RoadmapId
    $taskRecord = Get-RoadmapTaskRecord $roadmapRecord $TaskId
    if (-not $taskRecord.Meta.Contains('docs_impact')) {
        throw [ArgumentException]::new("$TaskId no declara docs_impact.")
    }
    $impact = Parse-DocsImpact ([string]$taskRecord.Meta['docs_impact'])
    if (-not $impact.Valid) {
        throw [ArgumentException]::new(($impact.Problems -join '; '))
    }
    $targets = if ($taskRecord.Meta.Contains('docs_targets')) {
        Parse-KeyValueMetadata ([string]$taskRecord.Meta['docs_targets'])
    }
    else { @{} }
    $operations = [System.Collections.Generic.List[object]]::new()
    $conflicts = [System.Collections.Generic.List[string]]::new()

    foreach ($action in $impact.Actions) {
        if ($action.action -eq 'none') {
            $operations.Add([pscustomobject]@{ action = 'none'; document_id = $null; target = $null; state = 'no_impact'; changed = $false })
            continue
        }
        if ($action.action -eq 'create') {
            if (-not $targets.ContainsKey($action.document_id)) {
                $conflicts.Add("Falta docs_targets para '$($action.document_id)'.")
                continue
            }
            $target = Resolve-DocsTargetPath ([string]$targets[$action.document_id])
            $expected = Get-PromotionScaffold $roadmapRecord $taskRecord $action $target
            $changed = $false
            $state = 'planned_create'
            if (Test-Path -LiteralPath $target.FullPath -PathType Leaf) {
                try {
                    $existingMeta = Read-FlatMetadataFile $target.FullPath
                    if (-not $existingMeta.Contains('id') -or [string]$existingMeta['id'] -ne $action.document_id) {
                        $conflicts.Add("Target '$($target.Relative)' pertenece a otro documento.")
                        continue
                    }
                    $promotionState = if ($existingMeta.Contains('promotion_state')) { [string]$existingMeta['promotion_state'] } else { 'reviewed' }
                    if ($promotionState -eq 'scaffold') {
                        $existing = Get-Content -Raw -LiteralPath $target.FullPath
                        if ($existing -cne $expected) {
                            $conflicts.Add("Scaffold '$($target.Relative)' fue editado; no se sobrescribe.")
                            continue
                        }
                        $state = 'scaffold_exists'
                    }
                    else {
                        $state = 'authored_exists'
                    }
                }
                catch {
                    $conflicts.Add("Target '$($target.Relative)' no es un documento managed: $($_.Exception.Message)")
                    continue
                }
            }
            elseif ($ShouldApply) {
                $changed = Set-FileIfChanged -Path $target.FullPath -Content $expected
                $state = 'scaffold_created'
            }
            $operations.Add([pscustomobject]@{
                action = 'create'; document_id = $action.document_id; target = $target.Relative
                state = $state; changed = $changed
            })
            continue
        }

        $documentId = if ($action.action -eq 'supersede') { $action.replacement_id } else { $action.document_id }
        $document = Get-DocumentById $Validation $documentId
        if ($null -eq $document) {
            $conflicts.Add("Documento '$documentId' inexistente para '$($action.action)'.")
            continue
        }
        $operations.Add([pscustomobject]@{
            action = $action.action; document_id = $action.document_id; replacement_id = $action.replacement_id
            target = $document.RelPath; state = 'review_existing'; changed = $false
        })
    }
    return [pscustomobject]@{
        command = 'promote'
        ok = $conflicts.Count -eq 0
        roadmap = $RoadmapId
        task = $TaskId
        apply = $ShouldApply
        operations = @($operations)
        conflicts = @($conflicts)
        warnings = @($Validation.Warnings)
    }
}

function Get-CloseCheckPayload {
    param($Validation, [string]$RoadmapId)
    $roadmapRecord = Get-RoadmapRecord $RoadmapId
    $issues = [System.Collections.Generic.List[string]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $closeoutPath = Join-Path $roadmapRecord.Root 'CLOSEOUT.md'
    $documentationPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $closeoutPath -PathType Leaf)) {
        $issues.Add("Falta CLOSEOUT.md en $RoadmapId.")
    }
    else {
        try {
            $closeMeta = Read-FlatMetadataFile $closeoutPath
            if (-not $closeMeta.Contains('id') -or [string]$closeMeta['id'] -ne $RoadmapId) { $issues.Add('CLOSEOUT.md declara otro id.') }
            if (-not $closeMeta.Contains('status') -or [string]$closeMeta['status'] -ne 'closed') { $issues.Add("CLOSEOUT.md debe declarar status: closed.") }
            if (-not $closeMeta.Contains('documentation') -or [string]::IsNullOrWhiteSpace([string]$closeMeta['documentation']) -or [string]$closeMeta['documentation'] -eq 'none') {
                $issues.Add('CLOSEOUT.md debe listar documentation estable.')
            }
            else {
                foreach ($path in Split-MetadataList ([string]$closeMeta['documentation'])) {
                    try {
                        $target = Resolve-DocsTargetPath $path
                        if (-not (Test-Path -LiteralPath $target.FullPath -PathType Leaf)) { $issues.Add("Documentation inexistente: '$path'.") }
                        else { [void]$documentationPaths.Add($target.Relative) }
                    }
                    catch { $issues.Add($_.Exception.Message) }
                }
            }
        }
        catch { $issues.Add("CLOSEOUT.md inválido: $($_.Exception.Message)") }
    }

    $tasksRoot = Join-Path $roadmapRecord.Root 'tasks'
    if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
        foreach ($taskFile in Get-ChildItem -LiteralPath $tasksRoot -File -Filter '*.md' | Sort-Object Name) {
            $meta = Read-FlatMetadataFile $taskFile.FullName
            if (-not $meta.Contains('status') -or [string]$meta['status'] -ne 'done') { continue }
            $taskId = if ($meta.Contains('id')) { [string]$meta['id'] } else { $taskFile.BaseName }
            $taskType = if ($meta.Contains('type')) { [string]$meta['type'] } else { '' }
            if (-not $meta.Contains('docs_impact')) {
                if ($taskType -ne 'research') { $issues.Add("$taskId done no declara docs_impact.") }
                continue
            }
            $impact = Parse-DocsImpact ([string]$meta['docs_impact'])
            if (-not $impact.Valid) {
                $issues.Add("${taskId}: $($impact.Problems -join '; ')")
                continue
            }
            foreach ($action in $impact.Actions) {
                $satisfied = $true
                $reason = 'satisfied'
                $documentPath = $null
                if ($action.action -eq 'none') {
                    if ($taskType -ne 'research' -and (-not $meta.Contains('docs_impact_reason') -or [string]::IsNullOrWhiteSpace([string]$meta['docs_impact_reason']))) {
                        $satisfied = $false; $reason = 'missing_reason'
                    }
                }
                elseif ($action.action -in @('create', 'update', 'verify')) {
                    $doc = Get-DocumentById $Validation $action.document_id
                    if ($null -eq $doc) { $satisfied = $false; $reason = 'document_missing' }
                    else {
                        $documentPath = $doc.RelPath
                        if ([string]$doc.Meta['status'] -ne 'current') { $satisfied = $false; $reason = 'document_not_current' }
                        elseif ($doc.Meta.Contains('promotion_state') -and [string]$doc.Meta['promotion_state'] -eq 'scaffold') { $satisfied = $false; $reason = 'scaffold_not_reviewed' }
                        elseif (-not $doc.Meta.Contains('roadmaps') -or $RoadmapId -notin @(Split-MetadataList ([string]$doc.Meta['roadmaps']))) { $satisfied = $false; $reason = 'roadmap_provenance_missing' }
                        elseif (-not $documentationPaths.Contains($doc.RelPath)) { $satisfied = $false; $reason = 'closeout_documentation_missing' }
                    }
                }
                elseif ($action.action -eq 'supersede') {
                    $oldDoc = Get-DocumentById $Validation $action.document_id
                    $newDoc = Get-DocumentById $Validation $action.replacement_id
                    if ($null -eq $oldDoc -or $null -eq $newDoc) { $satisfied = $false; $reason = 'supersession_document_missing' }
                    else {
                        $documentPath = $newDoc.RelPath
                        $supersedes = if ($newDoc.Meta.Contains('supersedes')) { @(Split-MetadataList ([string]$newDoc.Meta['supersedes'])) } else { @() }
                        if ([string]$oldDoc.Meta['status'] -notin @('superseded', 'archived') -or [string]$newDoc.Meta['status'] -ne 'current' -or $action.document_id -notin $supersedes) {
                            $satisfied = $false; $reason = 'supersession_not_materialized'
                        }
                        elseif (-not $documentationPaths.Contains($newDoc.RelPath)) { $satisfied = $false; $reason = 'closeout_documentation_missing' }
                    }
                }
                if (-not $satisfied) { $issues.Add("$taskId $($action.action):$($action.document_id) incumplido ($reason).") }
                $results.Add([pscustomobject]@{
                    task = $taskId; action = $action.action; document_id = $action.document_id
                    replacement_id = $action.replacement_id; document = $documentPath; satisfied = $satisfied; reason = $reason
                })
            }
        }
    }

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { $issues.Add("Falta $CatalogRepoPath; ejecutar docs index.") }
    if (-not (Test-Path -LiteralPath $GraphPath -PathType Leaf)) { $issues.Add("Falta $GraphRepoPath; ejecutar docs graph.") }
    if ($issues.Count -eq 0) {
        Add-StrictGeneratedChecks $Validation
        foreach ($error in $Validation.Errors) { $issues.Add("$($error.code): $($error.message)") }
    }
    return [pscustomobject]@{
        command = 'close-check'
        ok = $issues.Count -eq 0
        roadmap = $RoadmapId
        impacts = @($results)
        documentation = @($documentationPaths | Sort-Object)
        issues = @($issues)
        warnings = @($Validation.Warnings)
    }
}

function Write-OperationPayload {
    param($Payload)
    if ($Format -eq 'json') {
        $Payload | ConvertTo-Json -Depth 8
        return
    }
    foreach ($warning in @($Payload.warnings)) {
        Write-Output "WARNING $($warning.path):$($warning.line) [$($warning.code)] $($warning.message)"
    }
    if ($Payload.command -eq 'promote') {
        foreach ($operation in @($Payload.operations)) {
            Write-Output "$($operation.action) $($operation.document_id) -> $($operation.target) [$($operation.state)]"
        }
        foreach ($conflict in @($Payload.conflicts)) { Write-Output "CONFLICT $conflict" }
        Write-Output "Docs promote: $(@($Payload.operations).Count) operación(es), $(@($Payload.conflicts).Count) conflicto(s), apply=$($Payload.apply)."
        return
    }
    if ($Payload.command -eq 'migrate') {
        foreach ($path in @($Payload.changed)) { Write-Output "changed $path" }
        if ($null -ne $Payload.PSObject.Properties['schema']) {
            foreach ($entry in @($Payload.entries)) {
                Write-Output "$($entry.document_id) -> $($entry.document) [$($entry.state)]"
            }
            Write-Output "Docs migrate: $(@($Payload.entries).Count) documento(s), schema=$($Payload.schema), apply=$($Payload.apply)."
            return
        }
        Write-Output "Docs migrate: $($Payload.document_id) -> $($Payload.document) [$($Payload.state)], apply=$($Payload.apply)."
        return
    }
    if ($Payload.command -eq 'close-check') {
        foreach ($impact in @($Payload.impacts)) {
            Write-Output "$($impact.task) $($impact.action):$($impact.document_id) satisfied=$($impact.satisfied) ($($impact.reason))"
        }
        foreach ($issue in @($Payload.issues)) { Write-Output "BLOCK $issue" }
        Write-Output "Docs close-check: $(@($Payload.impacts | Where-Object satisfied).Count)/$(@($Payload.impacts).Count) impacto(s) satisfecho(s), $(@($Payload.issues).Count) bloqueo(s)."
        return
    }
    if ($Payload.command -eq 'affected') {
        foreach ($match in @($Payload.matches)) {
            $flags = @()
            if ($match.whitespace_only) { $flags += 'whitespace-only' }
            if ($match.ignored) { $flags += 'ignored' }
            $suffix = if ($flags.Count) { ' [' + ($flags -join ', ') + ']' } else { '' }
            Write-Output "$($match.document_id) <- $($match.path) via $($match.source_glob)$suffix"
        }
        Write-Output "Docs affected: $(@($Payload.matches).Count) match(es), $(@($Payload.changed_paths).Count) path(s) cambiado(s)."
        return
    }
    foreach ($doc in @($Payload.documents)) {
        $paths = @($doc.matches | Where-Object { -not $_.whitespace_only -and -not $_.ignored } | ForEach-Object { $_.path } | Sort-Object -Unique)
        $suffix = if ($paths.Count) { ': ' + ($paths -join ', ') } else { '' }
        Write-Output "$($doc.document_id) $($doc.health) ($($doc.reason))$suffix"
    }
    Write-Output "Docs drift: $(@($Payload.documents | Where-Object health -eq 'attention').Count) attention, $(@($Payload.documents | Where-Object health -eq 'unknown').Count) unknown."
}

function Write-Result {
    param(
        [string]$ExecutedCommand,
        $Validation,
        [string[]]$Changed = @()
    )
    $payload = [pscustomobject]@{
        command = $ExecutedCommand
        ok = ($Validation.Errors.Count -eq 0)
        managed = @($Validation.Documents).Count
        legacy = @($Validation.Legacy).Count
        generated = @($Validation.Documents | Where-Object { $_.Meta.Contains('kind') -and [string]$_.Meta['kind'] -eq 'generated' }).Count
        changed = @($Changed)
        errors = @($Validation.Errors)
        warnings = @($Validation.Warnings)
    }
    if ($Format -eq 'json') {
        $payload | ConvertTo-Json -Depth 6
        return
    }
    foreach ($issue in $Validation.Errors) {
        Write-Output "$($issue.path):$($issue.line) [$($issue.code)] $($issue.message)"
    }
    foreach ($issue in $Validation.Warnings) {
        Write-Output "WARNING $($issue.path):$($issue.line) [$($issue.code)] $($issue.message)"
    }
    if ($Validation.Errors.Count -eq 0) {
        $suffix = if (@($Changed).Count -gt 0) { "; actualizados: $($Changed -join ', ')" } else { '' }
        Write-Output "Docs $ExecutedCommand`: OK ($($payload.managed) managed, $($payload.legacy) legacy, $($payload.generated) generated$suffix)."
    }
    else {
        Write-Output "Docs $ExecutedCommand`: $($Validation.Errors.Count) error(es), $($Validation.Warnings.Count) advertencia(s)."
    }
}

try {
    $validation = Invoke-DocsValidation
    if ($Command -eq 'check') {
        if ($Strict -and $validation.Errors.Count -eq 0) { Add-StrictGeneratedChecks $validation }
        Write-Result 'check' $validation
        if ($validation.Errors.Count -gt 0) { exit 1 }
        exit 0
    }

    if ($validation.Errors.Count -gt 0) {
        Write-Result $Command $validation
        exit 1
    }

    if ($Command -eq 'promote') {
        $payload = Get-PromotionPayload $validation $Roadmap $Task ([bool]$Apply)
        Write-OperationPayload $payload
        if ($payload.ok) { exit 0 }
        exit 1
    }

    if ($Command -eq 'migrate') {
        $payload = if (-not [string]::IsNullOrWhiteSpace($Manifest)) {
            Get-BatchMigrationPayload $validation ([bool]$Apply)
        }
        else {
            Get-MigrationPayload $validation ([bool]$Apply)
        }
        Write-OperationPayload $payload
        if ($payload.ok) { exit 0 }
        exit 1
    }

    if ($Command -eq 'close-check') {
        $payload = Get-CloseCheckPayload $validation $Roadmap
        Write-OperationPayload $payload
        if ($payload.ok) { exit 0 }
        exit 1
    }

    if ($Command -eq 'affected') {
        $payload = Get-AffectedPayload $validation $Base $Head
        Write-OperationPayload $payload
        exit 0
    }

    if ($Command -eq 'drift') {
        $payload = Get-DriftPayload $validation $Head
        Write-OperationPayload $payload
        if ($payload.ok) { exit 0 }
        exit 1
    }

    if ($Command -eq 'graph') {
        $changed = [System.Collections.Generic.List[string]]::new()
        $graphContent = Get-GraphContent $validation
        if (Set-FileIfChanged -Path $GraphPath -Content $graphContent) { $changed.Add($GraphRepoPath) }
        $postValidation = Invoke-DocsValidation
        if ($postValidation.Errors.Count -eq 0) { Add-GraphGeneratedCheck $postValidation }
        Write-Result 'graph' $postValidation -Changed @($changed)
        if ($postValidation.Errors.Count -gt 0) { exit 1 }
        exit 0
    }

    $changed = [System.Collections.Generic.List[string]]::new()
    $readmeContent = Get-ReadmeIndexedContent $validation
    if (Set-FileIfChanged -Path $ReadmePath -Content $readmeContent) { $changed.Add($ReadmeRepoPath) }
    $catalogContent = Get-CatalogContent $validation
    if (Set-FileIfChanged -Path $CatalogPath -Content $catalogContent) { $changed.Add($CatalogRepoPath) }

    $postValidation = Invoke-DocsValidation
    if ($postValidation.Errors.Count -eq 0) { Add-StrictGeneratedChecks $postValidation }
    Write-Result 'index' $postValidation -Changed @($changed)
    if ($postValidation.Errors.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    $actionable = $_.Exception -is [ArgumentException]
    $exitCode = if ($actionable) { 1 } else { 2 }
    if ($Format -eq 'json') {
        [pscustomobject]@{
            command = $Command
            ok = $false
            error = $_.Exception.Message
            error_kind = if ($actionable) { 'input' } else { 'internal' }
        } | ConvertTo-Json
    }
    else {
        $label = if ($actionable) { 'error' } else { 'error interno' }
        Write-Output "Docs $Command`: $label`: $($_.Exception.Message)"
        if (-not $actionable) { Write-Output $_.ScriptStackTrace }
    }
    exit $exitCode
}
