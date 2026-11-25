[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$DocsScript = Join-Path $PSScriptRoot 'docs.ps1'
$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$Sandbox = Join-Path $TempBase ("roadmap-kit-docs-tests-" + [guid]::NewGuid().ToString('N'))
$Sandbox = [IO.Path]::GetFullPath($Sandbox)

if (-not $Sandbox.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Sandbox fuera del directorio temporal: $Sandbox"
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function New-ValidFixture {
    param([string]$Name)

    $root = Join-Path $Sandbox $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'docs') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null

    Write-Utf8File (Join-Path $root 'src/example.txt') 'source'
    Write-Utf8File (Join-Path $root 'docs/.legacy-baseline.txt') "# Legacy permitido durante la migración`n"
    Write-Utf8File (Join-Path $root 'docs/README.md') @'
# Fixture docs

Intro authored.

<!-- docs:index:start -->
contenido viejo
<!-- docs:index:end -->
'@
    Write-Utf8File (Join-Path $root 'docs/valid.md') @'
---
id: DOC-TEST-VALID
title: Documento válido
kind: reference
area: test
status: current
owner: project
order: 10
source_paths: src/example.txt
last_verified_commit: self
summary: Fixture válido
diagram_mode: none
---

# Documento válido

Contenido.
'@
    return $root
}

function Add-LegacyDocument {
    param(
        [string]$Root,
        [string]$RelativePath = 'docs/legacy.md',
        [string]$Content = "# Documento legacy`n`nContenido sin metadata.`n"
    )

    $fullPath = Join-Path $Root $RelativePath
    Write-Utf8File $fullPath $Content
    Add-Content -LiteralPath (Join-Path $Root 'docs/.legacy-baseline.txt') -Value $RelativePath -Encoding utf8
    return $fullPath
}

function New-MigrationManifestEntry {
    param(
        [string]$Document,
        [string]$DocumentId,
        [string]$Title
    )

    return [ordered]@{
        document = $Document
        documentId = $DocumentId
        documentTitle = $Title
        kind = 'reference'
        area = 'test'
        documentStatus = 'current'
        owner = 'project'
        sourcePaths = 'src/example.txt'
        roadmaps = 'RM-900'
        diagramMode = 'none'
    }
}

function Write-MigrationManifest {
    param(
        [string]$Root,
        [object[]]$Documents,
        [string]$Schema = 'roadmap-kit.docs-migration/v1',
        [string]$RelativePath = 'docs-migration.json'
    )

    $payload = [ordered]@{ schema = $Schema; documents = @($Documents) }
    $path = Join-Path $Root $RelativePath
    Write-Utf8File $path ($payload | ConvertTo-Json -Depth 8)
    return $path
}

function Invoke-DocsFixture {
    param(
        [string]$Root,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )

    $output = @(& pwsh -NoProfile -File $DocsScript @Arguments -RepoRoot $Root 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Initialize-GitFixture {
    param([string]$Root)

    & git -C $Root init --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init falló en $Root" }
    & git -C $Root config user.email 'docs-fixture@roadmap-kit.local'
    & git -C $Root config user.name 'Living Docs Fixture'
    & git -C $Root add --all 2>$null
    & git -C $Root commit --quiet -m 'fixture baseline'
    if ($LASTEXITCODE -ne 0) { throw "git commit falló en $Root" }
}

function New-RoadmapFixture {
    param(
        [string]$Root,
        [string]$Impact = 'create:DOC-FIXTURE-FEATURE',
        [string]$TaskStatus = 'doing',
        [string]$ImpactReason = '',
        [string]$TaskType = 'implementation'
    )

    $roadmapRoot = Join-Path $Root 'roadmaps/open/RM-900-fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $roadmapRoot 'tasks') | Out-Null
    Write-Utf8File (Join-Path $roadmapRoot 'README.md') @'
---
id: RM-900
title: Fixture lifecycle
status: active
priority: P3
lane: maintenance
updated: 2026-11-17
last_verified_commit: HEAD
next_task: tasks/deliver.md
depends_on: none
now: Probar living docs
next_gate: Closeout documental satisfecho
---
# RM-900 fixture
'@
    $reasonLine = if ($ImpactReason) { "docs_impact_reason: $ImpactReason`n" } else { '' }
    Write-Utf8File (Join-Path $roadmapRoot 'tasks/deliver.md') @"
---
id: RM-900-T01
roadmap: RM-900
title: Entregar feature fixture
status: $TaskStatus
type: $TaskType
workflow: roadmap-delivery
executor_skill: roadmap-execute
verification_skills: roadmap-verify
depends_on: none
docs_impact: $Impact
${reasonLine}docs_targets: DOC-FIXTURE-FEATURE=docs/fixture/feature.md
updated: 2026-11-17
---
# Entregar feature fixture

## Evidencia de cierre

Fixture reproducible.
"@
    return $roadmapRoot
}

function Write-FixtureCloseout {
    param([string]$RoadmapRoot, [string]$Documentation = 'docs/fixture/feature.md')
    Write-Utf8File (Join-Path $RoadmapRoot 'CLOSEOUT.md') @"
---
id: RM-900
title: Fixture lifecycle
status: closed
closed: 2026-11-17
closing_commit: HEAD
documentation: $Documentation
---
# Cierre RM-900
"@
}

function Assert-ExitCode {
    param($Result, [int]$Expected, [string]$Case)

    if ($Result.ExitCode -ne $Expected) {
        throw "$Case esperaba exit $Expected y obtuvo $($Result.ExitCode).`n$($Result.Output)"
    }
    Write-Host "PASS $Case"
}

if (-not (Test-Path -LiteralPath $DocsScript -PathType Leaf)) {
    throw "RED: falta el sujeto bajo prueba: $DocsScript"
}

New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null
try {
    $valid = New-ValidFixture 'valid'
    Assert-ExitCode (Invoke-DocsFixture $valid check) 0 'documento válido'

    $duplicate = New-ValidFixture 'duplicate'
    $duplicateContent = (Get-Content -Raw -LiteralPath (Join-Path $duplicate 'docs/valid.md')).Replace('# Documento válido', '# Documento duplicado')
    Write-Utf8File (Join-Path $duplicate 'docs/duplicate.md') $duplicateContent
    Assert-ExitCode (Invoke-DocsFixture $duplicate check) 1 'ID duplicado'

    $missing = New-ValidFixture 'missing-field'
    $missingContent = (Get-Content -Raw -LiteralPath (Join-Path $missing 'docs/valid.md')).Replace("owner: project`n", '')
    Write-Utf8File (Join-Path $missing 'docs/valid.md') $missingContent
    Assert-ExitCode (Invoke-DocsFixture $missing check) 1 'campo obligatorio ausente'

    $invalidEnum = New-ValidFixture 'invalid-enum'
    $invalidEnumContent = (Get-Content -Raw -LiteralPath (Join-Path $invalidEnum 'docs/valid.md')).Replace('kind: reference', 'kind: fantasy')
    Write-Utf8File (Join-Path $invalidEnum 'docs/valid.md') $invalidEnumContent
    Assert-ExitCode (Invoke-DocsFixture $invalidEnum check) 1 'enum inválido'

    $semanticMissing = New-ValidFixture 'semantic-missing-mermaid'
    $semanticMissingContent = (Get-Content -Raw -LiteralPath (Join-Path $semanticMissing 'docs/valid.md')).Replace('diagram_mode: none', 'diagram_mode: semantic')
    Write-Utf8File (Join-Path $semanticMissing 'docs/valid.md') $semanticMissingContent
    Assert-ExitCode (Invoke-DocsFixture $semanticMissing check) 1 'semantic exige bloque Mermaid'

    $semanticUnbalanced = New-ValidFixture 'semantic-unbalanced-mermaid'
    $semanticUnbalancedContent = (Get-Content -Raw -LiteralPath (Join-Path $semanticUnbalanced 'docs/valid.md')).Replace('diagram_mode: none', 'diagram_mode: semantic') + @'

```mermaid
flowchart LR
    A --> B
'@
    Write-Utf8File (Join-Path $semanticUnbalanced 'docs/valid.md') $semanticUnbalancedContent
    Assert-ExitCode (Invoke-DocsFixture $semanticUnbalanced check) 1 'semantic rechaza fence Mermaid desbalanceado'

    $semanticValid = New-ValidFixture 'semantic-valid-mermaid'
    $semanticValidContent = (Get-Content -Raw -LiteralPath (Join-Path $semanticValid 'docs/valid.md')).Replace('diagram_mode: none', 'diagram_mode: semantic') + @'

```mermaid
flowchart LR
    A --> B
```
'@
    Write-Utf8File (Join-Path $semanticValid 'docs/valid.md') $semanticValidContent
    Assert-ExitCode (Invoke-DocsFixture $semanticValid check) 0 'semantic acepta Mermaid balanceado con owner y sources'

    $semanticWithoutSources = New-ValidFixture 'semantic-without-sources'
    $semanticWithoutSourcesContent = (Get-Content -Raw -LiteralPath (Join-Path $semanticWithoutSources 'docs/valid.md')).Replace('source_paths: src/example.txt', "source_paths: none`nsource_reason: Fixture sin fuentes mecánicas").Replace('diagram_mode: none', 'diagram_mode: semantic') + @'

```mermaid
flowchart LR
    A --> B
```
'@
    Write-Utf8File (Join-Path $semanticWithoutSources 'docs/valid.md') $semanticWithoutSourcesContent
    Assert-ExitCode (Invoke-DocsFixture $semanticWithoutSources check) 1 'semantic exige source_paths verificables'

    $generatedWrongMode = New-ValidFixture 'generated-wrong-mode'
    $generatedWrongModeContent = (Get-Content -Raw -LiteralPath (Join-Path $generatedWrongMode 'docs/valid.md')).Replace('kind: reference', "kind: generated`ngenerated_by: fixture")
    Write-Utf8File (Join-Path $generatedWrongMode 'docs/valid.md') $generatedWrongModeContent
    Assert-ExitCode (Invoke-DocsFixture $generatedWrongMode check) 1 'generated exige diagram_mode structural'

    $generatedStructural = New-ValidFixture 'generated-structural'
    $generatedStructuralContent = (Get-Content -Raw -LiteralPath (Join-Path $generatedStructural 'docs/valid.md')).Replace('kind: reference', "kind: generated`ngenerated_by: fixture").Replace('diagram_mode: none', 'diagram_mode: structural')
    Write-Utf8File (Join-Path $generatedStructural 'docs/valid.md') $generatedStructuralContent
    Assert-ExitCode (Invoke-DocsFixture $generatedStructural check) 0 'generated structural no exige semántica authored'

    $escapedSource = New-ValidFixture 'escaped-source'
    $escapedSourceContent = (Get-Content -Raw -LiteralPath (Join-Path $escapedSource 'docs/valid.md')).Replace('source_paths: src/example.txt', 'source_paths: ../outside.txt')
    Write-Utf8File (Join-Path $escapedSource 'docs/valid.md') $escapedSourceContent
    Assert-ExitCode (Invoke-DocsFixture $escapedSource check) 1 'source path fuera del repo'

    $legacy = New-ValidFixture 'new-legacy'
    Write-Utf8File (Join-Path $legacy 'docs/unmanaged.md') "# Legacy nuevo`n"
    Assert-ExitCode (Invoke-DocsFixture $legacy check) 1 'legacy nuevo fuera del baseline'

    $balanced = New-ValidFixture 'balanced-link'
    Write-Utf8File (Join-Path $balanced 'docs/target(1).md') "# Target`n"
    Write-Utf8File (Join-Path $balanced 'docs/.legacy-baseline.txt') "docs/target(1).md`n"
    $balancedContent = (Get-Content -Raw -LiteralPath (Join-Path $balanced 'docs/valid.md')).Replace('Contenido.', '[target](target(1).md)')
    Write-Utf8File (Join-Path $balanced 'docs/valid.md') $balancedContent
    Assert-ExitCode (Invoke-DocsFixture $balanced check) 0 'link con paréntesis balanceados'

    $broken = New-ValidFixture 'broken-link'
    $brokenContent = (Get-Content -Raw -LiteralPath (Join-Path $broken 'docs/valid.md')).Replace('Contenido.', '[missing](missing(1).md)')
    Write-Utf8File (Join-Path $broken 'docs/valid.md') $brokenContent
    Assert-ExitCode (Invoke-DocsFixture $broken check) 1 'link local roto'

    $cycle = New-ValidFixture 'supersession-cycle'
    Write-Utf8File (Join-Path $cycle 'docs/a.md') @'
---
id: DOC-TEST-A
title: A
kind: archive
area: test
status: archived
owner: project
supersedes: DOC-TEST-B
---
# A
'@
    Write-Utf8File (Join-Path $cycle 'docs/b.md') @'
---
id: DOC-TEST-B
title: B
kind: archive
area: test
status: archived
owner: project
supersedes: DOC-TEST-A
---
# B
'@
    Assert-ExitCode (Invoke-DocsFixture $cycle check) 1 'ciclo de supersession'

    $graph = New-ValidFixture 'graph'
    Assert-ExitCode (Invoke-DocsFixture $graph graph) 0 'primer grafo estructural'
    $graphPath = Join-Path $graph 'docs/_generated/structure.md'
    $graphHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $graphPath).Hash
    Assert-ExitCode (Invoke-DocsFixture $graph graph) 0 'segundo grafo estructural'
    if ($graphHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $graphPath).Hash) {
        throw 'La segunda generación del grafo cambió bytes.'
    }
    $graphContent = Get-Content -Raw -LiteralPath $graphPath
    if (-not $graphContent.Contains('AREA_TEST --> DOC_TEST_VALID') -or
        $graphContent -match 'sequenceDiagram|stateDiagram') {
        throw 'El grafo no usa IDs canónicos o inventó relaciones semánticas.'
    }

    $relevant = New-ValidFixture 'relevant-drift'
    Initialize-GitFixture $relevant
    Assert-ExitCode (Invoke-DocsFixture $relevant affected -Base refs/heads/missing -Head WORKTREE) 1 'affected rechaza ref inexistente'
    Write-Utf8File (Join-Path $relevant 'src/example.txt') 'source changed'
    $affected = Invoke-DocsFixture $relevant affected -Base HEAD -Head WORKTREE -Format json
    Assert-ExitCode $affected 0 'affected relevante'
    $affectedPayload = $affected.Output | ConvertFrom-Json
    if ($affectedPayload.matches.Count -ne 1 -or
        $affectedPayload.matches[0].document_id -ne 'DOC-TEST-VALID' -or
        $affectedPayload.matches[0].source_glob -ne 'src/example.txt') {
        throw "affected no explicó el match esperado: $($affected.Output)"
    }
    $attention = Invoke-DocsFixture $relevant drift -Head WORKTREE -Format json
    Assert-ExitCode $attention 1 'drift relevante pide atención'
    $attentionPayload = $attention.Output | ConvertFrom-Json
    if ($attentionPayload.documents.Count -ne 1 -or $attentionPayload.documents[0].health -ne 'attention') {
        throw "drift relevante no quedó en attention: $($attention.Output)"
    }

    $whitespace = New-ValidFixture 'whitespace-drift'
    Initialize-GitFixture $whitespace
    Write-Utf8File (Join-Path $whitespace 'src/example.txt') 'source     '
    $freshWhitespace = Invoke-DocsFixture $whitespace drift -Head WORKTREE -Format json
    Assert-ExitCode $freshWhitespace 0 'whitespace-only no genera drift'
    if (($freshWhitespace.Output | ConvertFrom-Json).documents[0].health -ne 'fresh') {
        throw "Whitespace-only no quedó fresh: $($freshWhitespace.Output)"
    }

    $ignored = New-ValidFixture 'ignored-drift'
    Write-Utf8File (Join-Path $ignored 'src/ignored.txt') 'before'
    $ignoredDoc = (Get-Content -Raw -LiteralPath (Join-Path $ignored 'docs/valid.md')).Replace('source_paths: src/example.txt', "source_paths: src/**`ndrift_ignore: src/ignored.txt")
    Write-Utf8File (Join-Path $ignored 'docs/valid.md') $ignoredDoc
    Initialize-GitFixture $ignored
    Write-Utf8File (Join-Path $ignored 'src/ignored.txt') 'after'
    $freshIgnored = Invoke-DocsFixture $ignored drift -Head WORKTREE -Format json
    Assert-ExitCode $freshIgnored 0 'drift_ignore filtra path preregistrado'
    if (($freshIgnored.Output | ConvertFrom-Json).documents[0].health -ne 'fresh') {
        throw "drift_ignore no quedó fresh: $($freshIgnored.Output)"
    }

    $unknown = New-ValidFixture 'unknown-baseline'
    $unknownDoc = (Get-Content -Raw -LiteralPath (Join-Path $unknown 'docs/valid.md')).Replace('last_verified_commit: self', 'last_verified_commit: deadbeef')
    Write-Utf8File (Join-Path $unknown 'docs/valid.md') $unknownDoc
    Initialize-GitFixture $unknown
    Assert-ExitCode (Invoke-DocsFixture $unknown drift -Head WORKTREE) 1 'baseline inexistente falla explícitamente'

    $invalidImpact = New-ValidFixture 'invalid-impact'
    [void](New-RoadmapFixture $invalidImpact -Impact 'explode:DOC-FIXTURE-FEATURE')
    Assert-ExitCode (Invoke-DocsFixture $invalidImpact check) 1 'docs_impact inválido'

    $noneWithoutReason = New-ValidFixture 'none-without-reason'
    [void](New-RoadmapFixture $noneWithoutReason -Impact 'none')
    Assert-ExitCode (Invoke-DocsFixture $noneWithoutReason check) 1 'docs_impact none exige razón'

    $promotion = New-ValidFixture 'promotion'
    [void](New-RoadmapFixture $promotion)
    $promotionTarget = Join-Path $promotion 'docs/fixture/feature.md'
    $plan = Invoke-DocsFixture $promotion promote -Roadmap RM-900 -Task RM-900-T01 -Format json
    Assert-ExitCode $plan 0 'promote plan no escribe'
    if (Test-Path -LiteralPath $promotionTarget) { throw 'promote plan escribió el target.' }
    $apply = Invoke-DocsFixture $promotion promote -Roadmap RM-900 -Task RM-900-T01 -Apply -Format json
    Assert-ExitCode $apply 0 'promote apply crea scaffold'
    $promotionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $promotionTarget).Hash
    Assert-ExitCode (Invoke-DocsFixture $promotion promote -Roadmap RM-900 -Task RM-900-T01 -Apply) 0 'promote apply repetido es no-op'
    if ($promotionHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $promotionTarget).Hash) {
        throw 'promote apply repetido modificó el scaffold.'
    }

    $conflict = New-ValidFixture 'promotion-conflict'
    [void](New-RoadmapFixture $conflict)
    Assert-ExitCode (Invoke-DocsFixture $conflict promote -Roadmap RM-900 -Task RM-900-T01 -Apply) 0 'promote prepara conflicto'
    $conflictPath = Join-Path $conflict 'docs/fixture/feature.md'
    $conflictContent = (Get-Content -Raw -LiteralPath $conflictPath).Replace('id: DOC-FIXTURE-FEATURE', 'id: DOC-OTHER')
    Write-Utf8File $conflictPath $conflictContent
    Assert-ExitCode (Invoke-DocsFixture $conflict promote -Roadmap RM-900 -Task RM-900-T01 -Apply) 1 'promote rechaza authored conflictivo'

    $migration = New-ValidFixture 'migration-plan'
    $legacyPath = Add-LegacyDocument $migration
    $migrationArgs = @(
        'migrate', '-Document', 'docs/legacy.md', '-DocumentId', 'DOC-TEST-LEGACY',
        '-DocumentTitle', 'Documento legacy migrado', '-Kind', 'reference', '-Area', 'test',
        '-DocumentStatus', 'current', '-Owner', 'project', '-SourcePaths', 'src/example.txt',
        '-Roadmaps', 'RM-900', '-DiagramMode', 'none', '-Format', 'json'
    )
    $legacyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyPath).Hash
    $baselinePath = Join-Path $migration 'docs/.legacy-baseline.txt'
    $baselineHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $baselinePath).Hash
    $migrationPlan = Invoke-DocsFixture $migration @migrationArgs
    Assert-ExitCode $migrationPlan 0 'migrate plan no escribe'
    $migrationPayload = $migrationPlan.Output | ConvertFrom-Json
    if ($migrationPayload.apply -or $migrationPayload.state -ne 'planned' -or
        $migrationPayload.document -ne 'docs/legacy.md' -or
        $migrationPayload.metadata.id -ne 'DOC-TEST-LEGACY' -or
        $migrationPayload.metadata.status -ne 'current' -or
        $migrationPayload.body_sha256 -ne $legacyHash.ToLowerInvariant()) {
        throw "Plan de migración inesperado: $($migrationPlan.Output)"
    }
    if ($legacyHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyPath).Hash -or
        $baselineHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $baselinePath).Hash) {
        throw 'migrate plan modificó el documento o el baseline.'
    }

    $legacyBodyBytes = [IO.File]::ReadAllBytes($legacyPath)
    $migrationApply = Invoke-DocsFixture $migration @migrationArgs -Apply
    Assert-ExitCode $migrationApply 0 'migrate apply actualiza documento y baseline'
    $migratedBytes = [IO.File]::ReadAllBytes($legacyPath)
    if ($migratedBytes.Length -le $legacyBodyBytes.Length) { throw 'La migración no agregó frontmatter.' }
    $bodyOffset = $migratedBytes.Length - $legacyBodyBytes.Length
    for ($i = 0; $i -lt $legacyBodyBytes.Length; $i++) {
        if ($legacyBodyBytes[$i] -ne $migratedBytes[$bodyOffset + $i]) {
            throw "La migración alteró el cuerpo legacy en el byte $i."
        }
    }
    if ((Get-Content -Raw -LiteralPath $baselinePath).Contains('docs/legacy.md')) {
        throw 'La migración no retiró el documento del baseline.'
    }
    Assert-ExitCode (Invoke-DocsFixture $migration check -Strict) 0 'migrate deja vistas estrictas vigentes'
    $migratedGraph = Get-Content -Raw -LiteralPath (Join-Path $migration 'docs/_generated/structure.md')
    if (-not $migratedGraph.Contains('DOC_TEST_LEGACY')) { throw 'El grafo no contiene el documento migrado.' }

    $missingReason = New-ValidFixture 'migration-missing-reason'
    $missingReasonPath = Add-LegacyDocument $missingReason
    $missingReasonHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $missingReasonPath).Hash
    Assert-ExitCode (Invoke-DocsFixture $missingReason migrate -Document docs/legacy.md -DocumentId DOC-TEST-LEGACY -DocumentTitle 'Documento legacy' -Kind reference -Area test -DocumentStatus current -Owner project -SourcePaths none -Roadmaps RM-900 -DiagramMode none) 1 'migrate rechaza source_paths none sin razón'
    if ($missingReasonHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $missingReasonPath).Hash) {
        throw 'migrate inválido alteró el documento.'
    }

    $outsideMigration = New-ValidFixture 'migration-outside-docs'
    Assert-ExitCode (Invoke-DocsFixture $outsideMigration migrate -Document ../outside.md -DocumentId DOC-TEST-OUTSIDE -DocumentTitle Fuera -Kind reference -Area test -DocumentStatus current -Owner project -SourcePaths src/example.txt -Roadmaps RM-900 -DiagramMode none) 1 'migrate rechaza path fuera de docs'

    $notLegacyMigration = New-ValidFixture 'migration-not-legacy'
    Write-Utf8File (Join-Path $notLegacyMigration 'docs/unlisted.md') "# No listado`n"
    Assert-ExitCode (Invoke-DocsFixture $notLegacyMigration migrate -Document docs/unlisted.md -DocumentId DOC-TEST-UNLISTED -DocumentTitle 'No listado' -Kind reference -Area test -DocumentStatus current -Owner project -SourcePaths src/example.txt -Roadmaps RM-900 -DiagramMode none) 1 'migrate rechaza documento fuera del baseline'

    $rollbackMigration = New-ValidFixture 'migration-rollback'
    $rollbackPath = Add-LegacyDocument $rollbackMigration -Content "# Legacy roto`n`n[enlace roto](missing.md)`n"
    Assert-ExitCode (Invoke-DocsFixture $rollbackMigration index) 0 'migrate rollback prepara índice'
    Assert-ExitCode (Invoke-DocsFixture $rollbackMigration graph) 0 'migrate rollback prepara grafo'
    $rollbackFiles = @(
        $rollbackPath,
        (Join-Path $rollbackMigration 'docs/.legacy-baseline.txt'),
        (Join-Path $rollbackMigration 'docs/README.md'),
        (Join-Path $rollbackMigration 'docs/_generated/catalog.md'),
        (Join-Path $rollbackMigration 'docs/_generated/structure.md')
    )
    $rollbackHashes = @{}
    foreach ($file in $rollbackFiles) { $rollbackHashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash }
    Assert-ExitCode (Invoke-DocsFixture $rollbackMigration migrate -Document docs/legacy.md -DocumentId DOC-TEST-BROKEN -DocumentTitle 'Documento roto' -Kind reference -Area test -DocumentStatus current -Owner project -SourcePaths src/example.txt -Roadmaps RM-900 -DiagramMode none -Apply) 1 'migrate revierte cuando la validación final falla'
    foreach ($file in $rollbackFiles) {
        if ($rollbackHashes[$file] -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash) {
            throw "Rollback de migración no restauró $file."
        }
    }

    $batchMigration = New-ValidFixture 'migration-batch'
    $batchA = Add-LegacyDocument $batchMigration -RelativePath docs/a.md -Content "# Legacy A`n`nCuerpo A.`n"
    $batchB = Add-LegacyDocument $batchMigration -RelativePath docs/b.md -Content "# Legacy B`n`nCuerpo B.`n"
    [void](Write-MigrationManifest $batchMigration @(
        (New-MigrationManifestEntry docs/a.md DOC-TEST-BATCH-A 'Documento A'),
        (New-MigrationManifestEntry docs/b.md DOC-TEST-BATCH-B 'Documento B')
    ))
    $batchBaseline = Join-Path $batchMigration 'docs/.legacy-baseline.txt'
    $batchHashes = @{}
    foreach ($file in @($batchA, $batchB, $batchBaseline)) { $batchHashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash }
    $batchPlan1 = Invoke-DocsFixture $batchMigration migrate -Manifest docs-migration.json -Format json
    Assert-ExitCode $batchPlan1 0 'migrate batch plan no escribe'
    $batchPlan2 = Invoke-DocsFixture $batchMigration migrate -Manifest docs-migration.json -Format json
    Assert-ExitCode $batchPlan2 0 'migrate batch plan es determinista'
    if ($batchPlan1.Output -cne $batchPlan2.Output) { throw 'El plan batch cambió entre ejecuciones.' }
    $batchPayload = $batchPlan1.Output | ConvertFrom-Json
    if ($batchPayload.schema -ne 'roadmap-kit.docs-migration/v1' -or $batchPayload.entries.Count -ne 2 -or $batchPayload.apply) {
        throw "Plan batch inesperado: $($batchPlan1.Output)"
    }
    foreach ($file in @($batchA, $batchB, $batchBaseline)) {
        if ($batchHashes[$file] -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash) {
            throw "El plan batch modificó $file."
        }
    }
    Assert-ExitCode (Invoke-DocsFixture $batchMigration migrate -Manifest docs-migration.json -Apply) 0 'migrate batch aplica dos documentos'
    Assert-ExitCode (Invoke-DocsFixture $batchMigration check -Strict) 0 'migrate batch deja vistas estrictas vigentes'
    $batchBaselineContent = Get-Content -Raw -LiteralPath $batchBaseline
    if ($batchBaselineContent.Contains('docs/a.md') -or $batchBaselineContent.Contains('docs/b.md')) {
        throw 'El batch no retiró todas las entradas del baseline.'
    }

    $unknownSchema = New-ValidFixture 'migration-batch-schema'
    [void](Write-MigrationManifest $unknownSchema @() -Schema 'roadmap-kit.docs-migration/v99')
    Assert-ExitCode (Invoke-DocsFixture $unknownSchema migrate -Manifest docs-migration.json) 1 'migrate batch rechaza schema desconocido'

    $missingBatchProperty = New-ValidFixture 'migration-batch-missing-property'
    [void](Add-LegacyDocument $missingBatchProperty)
    $incompleteEntry = New-MigrationManifestEntry docs/legacy.md DOC-TEST-INCOMPLETE 'Incompleto'
    $incompleteEntry.Remove('owner')
    [void](Write-MigrationManifest $missingBatchProperty @($incompleteEntry))
    Assert-ExitCode (Invoke-DocsFixture $missingBatchProperty migrate -Manifest docs-migration.json) 1 'migrate batch rechaza propiedad faltante'

    $duplicateBatch = New-ValidFixture 'migration-batch-duplicate'
    [void](Add-LegacyDocument $duplicateBatch)
    [void](Write-MigrationManifest $duplicateBatch @(
        (New-MigrationManifestEntry docs/legacy.md DOC-TEST-DUPLICATE 'Duplicado A'),
        (New-MigrationManifestEntry docs/legacy.md DOC-TEST-DUPLICATE 'Duplicado B')
    ))
    Assert-ExitCode (Invoke-DocsFixture $duplicateBatch migrate -Manifest docs-migration.json) 1 'migrate batch rechaza paths e IDs duplicados'

    $batchRollback = New-ValidFixture 'migration-batch-rollback'
    $batchRollbackA = Add-LegacyDocument $batchRollback -RelativePath docs/a.md -Content "# Válido`n"
    $batchRollbackB = Add-LegacyDocument $batchRollback -RelativePath docs/b.md -Content "# Roto`n`n[missing](missing.md)`n"
    [void](Write-MigrationManifest $batchRollback @(
        (New-MigrationManifestEntry docs/a.md DOC-TEST-ROLLBACK-A 'Rollback A'),
        (New-MigrationManifestEntry docs/b.md DOC-TEST-ROLLBACK-B 'Rollback B')
    ))
    Assert-ExitCode (Invoke-DocsFixture $batchRollback index) 0 'migrate batch rollback prepara índice'
    Assert-ExitCode (Invoke-DocsFixture $batchRollback graph) 0 'migrate batch rollback prepara grafo'
    $batchRollbackFiles = @(
        $batchRollbackA,
        $batchRollbackB,
        (Join-Path $batchRollback 'docs/.legacy-baseline.txt'),
        (Join-Path $batchRollback 'docs/README.md'),
        (Join-Path $batchRollback 'docs/_generated/catalog.md'),
        (Join-Path $batchRollback 'docs/_generated/structure.md')
    )
    $batchRollbackHashes = @{}
    foreach ($file in $batchRollbackFiles) { $batchRollbackHashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash }
    Assert-ExitCode (Invoke-DocsFixture $batchRollback migrate -Manifest docs-migration.json -Apply) 1 'migrate batch revierte el lote completo'
    foreach ($file in $batchRollbackFiles) {
        if ($batchRollbackHashes[$file] -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash) {
            throw "Rollback batch no restauró $file."
        }
    }

    $closeout = New-ValidFixture 'closeout'
    $closeoutRoadmap = New-RoadmapFixture $closeout -TaskStatus 'done'
    Write-FixtureCloseout $closeoutRoadmap
    Assert-ExitCode (Invoke-DocsFixture $closeout close-check -Roadmap RM-900) 1 'closeout bloquea impacto incumplido'
    Assert-ExitCode (Invoke-DocsFixture $closeout promote -Roadmap RM-900 -Task RM-900-T01 -Apply) 0 'closeout crea scaffold'
    $closeoutTarget = Join-Path $closeout 'docs/fixture/feature.md'
    $reviewed = (Get-Content -Raw -LiteralPath $closeoutTarget).Replace('promotion_state: scaffold', 'promotion_state: reviewed').Replace('> TODO: reemplazar este scaffold por documentación verificada antes del closeout.', 'Comportamiento estable verificado por RM-900.')
    Write-Utf8File $closeoutTarget $reviewed
    Assert-ExitCode (Invoke-DocsFixture $closeout index) 0 'closeout regenera índice'
    Assert-ExitCode (Invoke-DocsFixture $closeout graph) 0 'closeout regenera grafo'
    Assert-ExitCode (Invoke-DocsFixture $closeout close-check -Roadmap RM-900) 0 'closeout acepta impacto satisfecho'
    Assert-ExitCode (Invoke-DocsFixture $closeout close-check -Roadmap RM-900) 0 'closeout repetido es idempotente'

    $idempotent = New-ValidFixture 'idempotent-index'
    Assert-ExitCode (Invoke-DocsFixture $idempotent index) 0 'primera indexación'
    $indexedReadme = Get-Content -Raw -LiteralPath (Join-Path $idempotent 'docs/README.md')
    if (-not $indexedReadme.Contains('# Fixture docs') -or
        -not $indexedReadme.Contains('Intro authored.') -or
        $indexedReadme.Contains('contenido viejo')) {
        throw 'La indexación no preservó el intro authored o no reemplazó la región delimitada.'
    }
    $readmeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $idempotent 'docs/README.md')).Hash
    $catalogHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $idempotent 'docs/_generated/catalog.md')).Hash
    Assert-ExitCode (Invoke-DocsFixture $idempotent index) 0 'segunda indexación'
    if ($readmeHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $idempotent 'docs/README.md')).Hash -or
        $catalogHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $idempotent 'docs/_generated/catalog.md')).Hash) {
        throw 'La segunda indexación cambió bytes.'
    }
    Assert-ExitCode (Invoke-DocsFixture $idempotent check -Strict) 0 'strict sobre índice vigente'

    Add-Content -LiteralPath (Join-Path $idempotent 'docs/_generated/catalog.md') -Value 'tamper' -Encoding utf8
    Assert-ExitCode (Invoke-DocsFixture $idempotent check -Strict) 1 'strict detecta catálogo alterado'
    Assert-ExitCode (Invoke-DocsFixture $idempotent index) 0 'index repara catálogo alterado'

    $json = Invoke-DocsFixture $idempotent check -Format json
    Assert-ExitCode $json 0 'salida JSON'
    $payload = $json.Output | ConvertFrom-Json
    if (-not $payload.ok -or $payload.managed -ne 2 -or $payload.legacy -ne 0 -or $payload.errors.Count -ne 0) {
        throw "Salida JSON inesperada: $($json.Output)"
    }

    Write-Host 'Docs fixtures: OK.'
}
finally {
    if (Test-Path -LiteralPath $Sandbox) {
        $resolvedSandbox = [IO.Path]::GetFullPath($Sandbox)
        if (-not $resolvedSandbox.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Se rechazó limpiar un path fuera del temporal: $resolvedSandbox"
        }
        Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
    }
}
